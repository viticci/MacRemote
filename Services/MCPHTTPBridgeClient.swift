import Foundation

actor MCPHTTPBridgeClient {
    private let urlSession: URLSession
    private var sessions: [String: MCPBridgeSession] = [:]

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func call(tool: ToolDefinition, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        guard let bridge = tool.mcpBridge else {
            throw ToolValidationError.invalidMCPBridge("missing bridge configuration")
        }

        try ToolArgumentResolver.validate(tool)

        let started = Date()
        do {
            let result = try await callWithRetry(bridge: bridge, parameters: parameters)
            let stdout = cappedString(from: serializedJSON(result), limit: tool.outputByteLimit)
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: 0,
                stdout: stdout.value,
                stderr: "",
                duration: Date().timeIntervalSince(started),
                timedOut: false,
                truncatedStdout: stdout.truncated,
                truncatedStderr: false
            )
        } catch {
            let stderr = cappedString(from: error.localizedDescription, limit: tool.outputByteLimit)
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: 1,
                stdout: "",
                stderr: stderr.value,
                duration: Date().timeIntervalSince(started),
                timedOut: false,
                truncatedStdout: false,
                truncatedStderr: stderr.truncated
            )
        }
    }

    private func callWithRetry(bridge: MCPBridgeConfiguration, parameters: [String: ToolArgumentValue]) async throws -> [String: Any] {
        do {
            return try await callOnce(bridge: bridge, parameters: parameters)
        } catch MCPHTTPBridgeError.httpStatus(401, _) {
            sessions[sessionKey(for: bridge)] = nil
            return try await callOnce(bridge: bridge, parameters: parameters)
        }
    }

    private func callOnce(bridge: MCPBridgeConfiguration, parameters: [String: ToolArgumentValue]) async throws -> [String: Any] {
        let session = try await initializedSession(for: bridge)
        let arguments = parameters.mapValues { $0.jsonValue.anyValue }
        let response = try await postJSONRPC(
            bridge: bridge,
            headers: session.headers,
            payload: [
                "jsonrpc": "2.0",
                "id": "call-\(UUID().uuidString)",
                "method": "tools/call",
                "params": [
                    "name": bridge.toolName,
                    "arguments": arguments
                ]
            ]
        )

        if let error = response["error"] as? [String: Any] {
            throw MCPHTTPBridgeError.jsonRPCError(serializedJSON(error))
        }

        guard let result = response["result"] as? [String: Any] else {
            throw MCPHTTPBridgeError.invalidResponse("tools/call returned no result")
        }
        return result
    }

    private func initializedSession(for bridge: MCPBridgeConfiguration) async throws -> MCPBridgeSession {
        let key = sessionKey(for: bridge)
        if let session = sessions[key] {
            return session
        }

        let response = try await postJSONRPC(
            bridge: bridge,
            headers: [:],
            payload: [
                "jsonrpc": "2.0",
                "id": "init-\(UUID().uuidString)",
                "method": "initialize",
                "params": [
                    "protocolVersion": bridge.protocolVersion,
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "MacRemote",
                        "version": "0.1.0"
                    ]
                ]
            ]
        )

        guard response["error"] == nil else {
            throw MCPHTTPBridgeError.jsonRPCError(serializedJSON(response["error"] ?? response))
        }

        let responseHeaders = response["_headers"] as? [String: String] ?? [:]
        let negotiatedVersion = ((response["result"] as? [String: Any])?["protocolVersion"] as? String) ?? bridge.protocolVersion
        var sessionHeaders = ["MCP-Protocol-Version": negotiatedVersion]
        if let sessionID = headerValue(named: "Mcp-Session-Id", in: responseHeaders) {
            sessionHeaders["Mcp-Session-Id"] = sessionID
        }

        _ = try? await postJSONRPC(
            bridge: bridge,
            headers: sessionHeaders,
            payload: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ],
            allowsEmptyResponse: true
        )

        let session = MCPBridgeSession(headers: sessionHeaders)
        sessions[key] = session
        return session
    }

    private func postJSONRPC(
        bridge: MCPBridgeConfiguration,
        headers sessionHeaders: [String: String],
        payload: [String: Any],
        allowsEmptyResponse: Bool = false
    ) async throws -> [String: Any] {
        guard let url = URL(string: bridge.serverURL) else {
            throw MCPHTTPBridgeError.invalidResponse("invalid bridge URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue(bridge.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")

        for (name, value) in try resolvedHeaders(for: bridge) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        for (name, value) in sessionHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, urlResponse) = try await urlSession.data(for: request)
        guard let response = urlResponse as? HTTPURLResponse else {
            throw MCPHTTPBridgeError.invalidResponse("missing HTTP response")
        }

        guard (200..<300).contains(response.statusCode) else {
            let body = String(decoding: data.prefix(1024), as: UTF8.self)
            throw MCPHTTPBridgeError.httpStatus(response.statusCode, body)
        }

        if data.isEmpty, allowsEmptyResponse {
            return ["_headers": normalizedHeaders(from: response)]
        }

        var object = try jsonObject(from: data)
        object["_headers"] = normalizedHeaders(from: response)
        return object
    }

    private func resolvedHeaders(for bridge: MCPBridgeConfiguration) throws -> [String: String] {
        var headers = [String: String]()
        for header in bridge.headers {
            if let value = header.value {
                headers[header.name] = value
                continue
            }
            guard let source = header.valueSource else { continue }
            let value: String
            switch source.kind {
            case .environment:
                guard let key = source.environmentKey,
                      let environmentValue = ProcessInfo.processInfo.environment[key] else {
                    throw MCPHTTPBridgeError.missingHeaderSource(header.name)
                }
                value = environmentValue
            case .jsonFile:
                value = try jsonFileHeaderValue(source: source, headerName: header.name)
            case .tomlFile:
                value = try tomlFileHeaderValue(source: source, headerName: header.name)
            }
            headers[header.name] = (source.prefix ?? "") + value
        }
        return headers
    }

    private func jsonFileHeaderValue(source: MCPBridgeHeaderValueSource, headerName: String) throws -> String {
        guard let rawPath = source.filePath,
              let keyPath = source.keyPath else {
            throw MCPHTTPBridgeError.missingHeaderSource(headerName)
        }

        let path = (rawPath as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        var cursor: Any = object
        for key in keyPath {
            guard let dictionary = cursor as? [String: Any],
                  let next = dictionary[key] else {
                throw MCPHTTPBridgeError.missingHeaderSource(headerName)
            }
            cursor = next
        }
        guard let value = cursor as? String, !value.isEmpty else {
            throw MCPHTTPBridgeError.missingHeaderSource(headerName)
        }
        return value
    }

    private func tomlFileHeaderValue(source: MCPBridgeHeaderValueSource, headerName: String) throws -> String {
        guard let rawPath = source.filePath,
              let keyPath = source.keyPath,
              keyPath.count >= 2 else {
            throw MCPHTTPBridgeError.missingHeaderSource(headerName)
        }

        let path = (rawPath as NSString).expandingTildeInPath
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let sectionName = keyPath.dropLast().joined(separator: ".")
        let targetKey = keyPath.last ?? ""
        var currentSection: String?

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                continue
            }
            guard currentSection == sectionName,
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == targetKey else { continue }
            let rawValue = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = unquotedString(String(rawValue)), !value.isEmpty {
                return value
            }
        }

        throw MCPHTTPBridgeError.missingHeaderSource(headerName)
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        let text = String(decoding: data, as: UTF8.self)
        for event in text.components(separatedBy: "\n\n").reversed() {
            let dataLines = event
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
            guard !dataLines.isEmpty else { continue }
            let body = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.hasPrefix("{"),
                  let eventData = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                continue
            }
            return object
        }

        throw MCPHTTPBridgeError.invalidResponse("response was neither JSON nor JSON SSE")
    }

    private func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers = [String: String]()
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    private func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func sessionKey(for bridge: MCPBridgeConfiguration) -> String {
        let headerNames = bridge.headers.map(\.name).sorted().joined(separator: ",")
        return "\(bridge.serverURL)\u{1f}\(bridge.serverName)\u{1f}\(headerNames)"
    }

    private func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func cappedString(from string: String, limit: Int) -> (value: String, truncated: Bool) {
        let data = Data(string.utf8)
        let truncated = data.count > limit
        let capped = truncated ? data.prefix(limit) : data[...]
        return (String(decoding: capped, as: UTF8.self), truncated)
    }

    private func unquotedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }
}

private struct MCPBridgeSession: Sendable {
    let headers: [String: String]
}

private enum MCPHTTPBridgeError: LocalizedError {
    case httpStatus(Int, String)
    case invalidResponse(String)
    case jsonRPCError(String)
    case missingHeaderSource(String)

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Upstream MCP server returned HTTP \(status)." : "Upstream MCP server returned HTTP \(status): \(detail)"
        case .invalidResponse(let detail):
            return "Invalid upstream MCP response: \(detail)"
        case .jsonRPCError(let detail):
            return "Upstream MCP JSON-RPC error: \(detail)"
        case .missingHeaderSource(let header):
            return "Could not resolve MCP bridge header: \(header)"
        }
    }
}
