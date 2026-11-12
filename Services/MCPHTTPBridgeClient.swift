import Foundation

actor MCPHTTPBridgeClient {
    private let urlSession: URLSession
    private let oauth: MCPUpstreamOAuthClient
    private let maximumResponseBytes: Int
    private var sessions: [String: MCPBridgeConnection] = [:]

    init(
        urlSession: URLSession = .shared,
        oauthStore: MCPUpstreamOAuthStore = .shared,
        maximumResponseBytes: Int = MCPHTTPResponseBody.maximumBytes
    ) {
        self.urlSession = urlSession
        self.maximumResponseBytes = maximumResponseBytes
        // Bridge calls only read or refresh a stored sign-in; the browser flow
        // belongs to AppModel, so this client never opens a URL.
        self.oauth = MCPUpstreamOAuthClient(urlSession: urlSession, store: oauthStore, openURL: { _ in })
    }

    /// Calls one bridged tool. Everything the call needs from the network,
    /// from the first probe of the server to the last byte of the result and
    /// any token refresh or retry in between, ends by the tool's timeout.
    func call(tool: ToolDefinition, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        guard let bridge = tool.mcpBridge else {
            throw ToolValidationError.invalidMCPBridge("missing bridge configuration")
        }

        try ToolArgumentResolver.validate(tool)

        let started = Date()
        let timeoutSeconds = tool.timeoutSeconds
        do {
            let normalized: MCPBridgeNormalizedToolResult
            do {
                normalized = try await withDeadline(seconds: timeoutSeconds) {
                    try await self.normalizedResult(
                        bridge: bridge,
                        parameters: parameters,
                        timeoutSeconds: timeoutSeconds
                    )
                }
            } catch is DeadlineExceeded {
                throw MCPHTTPBridgeError.timedOut(timeoutSeconds)
            }
            let stdout = cappedString(from: normalized.stdout, limit: tool.outputByteLimit)
            let contextExceededLimit = normalized.upstreamContext != nil
                && normalized.encodedByteCount > tool.outputByteLimit
            let stderr = MCPBridgeToolResultNormalizer.hardCapDiagnostic(
                stdoutTruncated: stdout.truncated,
                preservationContextDropped: contextExceededLimit
            )
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: normalized.isError ? 1 : 0,
                stdout: stdout.value,
                stderr: stderr,
                duration: Date().timeIntervalSince(started),
                timedOut: false,
                truncatedStdout: stdout.truncated || contextExceededLimit,
                truncatedStderr: false,
                upstreamMCPResult: contextExceededLimit ? nil : normalized.upstreamContext
            )
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            let stderr = cappedString(from: error.localizedDescription, limit: tool.outputByteLimit)
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: 1,
                stdout: "",
                stderr: stderr.value,
                duration: Date().timeIntervalSince(started),
                timedOut: Self.isTimeout(error),
                truncatedStdout: false,
                truncatedStderr: stderr.truncated
            )
        }
    }

    /// The call's result in a form that can leave this actor, so the deadline
    /// in `call` can run it as a separate task.
    private func normalizedResult(
        bridge: MCPBridgeConfiguration,
        parameters: [String: ToolArgumentValue],
        timeoutSeconds: TimeInterval
    ) async throws -> MCPBridgeNormalizedToolResult {
        MCPBridgeToolResultNormalizer.normalize(
            try await callWithRetry(
                bridge: bridge,
                parameters: parameters,
                timeoutSeconds: timeoutSeconds
            )
        )
    }

    private func callWithRetry(
        bridge: MCPBridgeConfiguration,
        parameters: [String: ToolArgumentValue],
        timeoutSeconds: TimeInterval
    ) async throws -> [String: Any] {
        var resolvedBaseHeaders = try await resolvedHeaders(for: bridge)
        var key = sessionKey(for: bridge, resolvedHeaders: resolvedBaseHeaders)
        do {
            return try await callOnce(
                bridge: bridge,
                parameters: parameters,
                timeoutSeconds: timeoutSeconds,
                baseHeaders: resolvedBaseHeaders,
                sessionKey: key
            )
        } catch MCPHTTPBridgeError.httpStatus(401, _) {
            sessions[key] = nil
            if bridge.headers.contains(where: \.isUpstreamOAuth) {
                try await refreshRejectedSignIn(for: bridge)
            }
            resolvedBaseHeaders = try await resolvedHeaders(for: bridge)
            key = sessionKey(for: bridge, resolvedHeaders: resolvedBaseHeaders)
            return try await callOnce(
                bridge: bridge,
                parameters: parameters,
                timeoutSeconds: timeoutSeconds,
                baseHeaders: resolvedBaseHeaders,
                sessionKey: key
            )
        } catch MCPHTTPBridgeError.legacySessionRejected {
            sessions[key] = nil
            return try await callOnce(
                bridge: bridge,
                parameters: parameters,
                timeoutSeconds: timeoutSeconds,
                baseHeaders: resolvedBaseHeaders,
                sessionKey: key
            )
        }
    }

    /// The server refused the stored sign-in. One refresh attempt. The
    /// sign-in is forgotten, so the Tools page asks for a new one instead of
    /// every call failing with a bare 401, only when a refresh cannot work
    /// later either: there is no refresh token, or the server refused it. A
    /// refresh that failed because the network or the server did throws and
    /// leaves the sign-in alone.
    private func refreshRejectedSignIn(for bridge: MCPBridgeConfiguration) async throws {
        do {
            if try await oauth.refresh(serverURL: bridge.serverURL) != nil {
                return
            }
        } catch MCPUpstreamOAuthError.tokenExchangeFailed, MCPUpstreamOAuthError.insecureEndpoint {
            // Fall through: this sign-in cannot be refreshed.
        }
        oauth.forget(serverURL: bridge.serverURL)
        throw MCPUpstreamOAuthError.signInRequired(serverName: bridge.serverName)
    }

    private func callOnce(
        bridge: MCPBridgeConfiguration,
        parameters: [String: ToolArgumentValue],
        timeoutSeconds: TimeInterval,
        baseHeaders: [String: String],
        sessionKey: String
    ) async throws -> [String: Any] {
        let connection = try await upstreamConnection(
            for: bridge,
            baseHeaders: baseHeaders,
            sessionKey: sessionKey,
            startupTimeoutSeconds: min(60, timeoutSeconds)
        )
        let arguments = MCPBridgeArgumentCoercion.coerce(
            parameters.mapValues { $0.jsonValue.anyValue },
            toSchema: bridge.inputSchema
        )
        let params: [String: Any] = [
            "name": bridge.toolName,
            "arguments": arguments
        ]
        let payload: [String: Any]
        let protocolHeaders: [String: String]
        switch connection {
        case .modern:
            payload = MCPUpstreamProtocol.modernRequest(
                id: "call-\(UUID().uuidString)",
                method: "tools/call",
                params: params
            )
            protocolHeaders = try MCPUpstreamProtocol.modernToolCallHTTPHeaders(
                params: params,
                inputSchema: bridge.inputSchema?.anyValue
            )
        case .legacy(let headers):
            payload = [
                "jsonrpc": "2.0",
                "id": "call-\(UUID().uuidString)",
                "method": "tools/call",
                "params": params
            ]
            protocolHeaders = headers
        }

        let response: [String: Any]
        do {
            response = try await postJSONRPC(
                bridge: bridge,
                baseHeaders: baseHeaders,
                protocolHeaders: protocolHeaders,
                payload: payload,
                timeoutSeconds: timeoutSeconds
            )
        } catch MCPHTTPBridgeError.httpStatus(404, let body) {
            if case .legacy = connection {
                throw MCPHTTPBridgeError.legacySessionRejected(body)
            }
            throw MCPHTTPBridgeError.httpStatus(404, body)
        }

        if let error = response["error"] as? [String: Any] {
            throw MCPHTTPBridgeError.jsonRPCError(serializedJSON(error))
        }

        let result: [String: Any]
        switch connection {
        case .modern:
            result = try MCPUpstreamProtocol.completeResult(from: response)
        case .legacy:
            guard let legacyResult = response["result"] as? [String: Any] else {
                throw MCPHTTPBridgeError.invalidResponse("tools/call returned no result")
            }
            result = legacyResult
        }
        return result
    }

    private func upstreamConnection(
        for bridge: MCPBridgeConfiguration,
        baseHeaders: [String: String],
        sessionKey key: String,
        startupTimeoutSeconds: TimeInterval
    ) async throws -> MCPBridgeConnection {
        if let connection = sessions[key] {
            return connection
        }

        let verdict = try await discoverUpstream(
            bridge: bridge,
            baseHeaders: baseHeaders,
            timeoutSeconds: startupTimeoutSeconds
        )
        if verdict.isModern {
            let connection = MCPBridgeConnection.modern
            sessions[key] = connection
            return connection
        }

        // A renegotiated version applies to this connection only; the persisted
        // `bridge.protocolVersion` stays untouched because it is fingerprinted
        // security material, not a live negotiation state.
        let legacyVersion = verdict.renegotiatedLegacyVersion ?? bridge.protocolVersion

        let response = try await postJSONRPC(
            bridge: bridge,
            baseHeaders: baseHeaders,
            protocolHeaders: ["MCP-Protocol-Version": legacyVersion],
            payload: [
                "jsonrpc": "2.0",
                "id": "init-\(UUID().uuidString)",
                "method": "initialize",
                "params": [
                    "protocolVersion": legacyVersion,
                    "capabilities": [:],
                    "clientInfo": MCPUpstreamProtocol.clientInfo
                ]
            ],
            timeoutSeconds: startupTimeoutSeconds
        )

        guard response["error"] == nil else {
            throw MCPHTTPBridgeError.jsonRPCError(serializedJSON(response["error"] ?? response))
        }

        let responseHeaders = response["_headers"] as? [String: String] ?? [:]
        let negotiatedVersion = ((response["result"] as? [String: Any])?["protocolVersion"] as? String) ?? legacyVersion
        var sessionHeaders = ["MCP-Protocol-Version": negotiatedVersion]
        if let sessionID = headerValue(named: "Mcp-Session-Id", in: responseHeaders) {
            sessionHeaders["Mcp-Session-Id"] = sessionID
        }

        _ = try? await postJSONRPC(
            bridge: bridge,
            baseHeaders: baseHeaders,
            protocolHeaders: sessionHeaders,
            payload: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ],
            allowsEmptyResponse: true,
            timeoutSeconds: startupTimeoutSeconds
        )

        let connection = MCPBridgeConnection.legacy(headers: sessionHeaders)
        sessions[key] = connection
        return connection
    }

    /// Probes the upstream once and reports which flow to run. A server that is
    /// simply not modern — timeout, no JSON, an unrecognized error — reads as a
    /// plain legacy fallback with no renegotiated version.
    private func discoverUpstream(
        bridge: MCPBridgeConfiguration,
        baseHeaders: [String: String],
        timeoutSeconds: TimeInterval
    ) async throws -> MCPUpstreamDiscoverVerdict {
        let params: [String: Any] = [:]
        let payload = MCPUpstreamProtocol.modernRequest(
            id: "discover-\(UUID().uuidString)",
            method: "server/discover",
            params: params
        )
        let headers = MCPUpstreamProtocol.modernHTTPHeaders(
            method: "server/discover",
            params: params
        )

        let response: MCPHTTPBridgeResponse
        do {
            response = try await sendJSONRPC(
                bridge: bridge,
                baseHeaders: baseHeaders,
                protocolHeaders: headers,
                payload: payload,
                timeoutSeconds: timeoutSeconds
            )
        } catch {
            if Self.isTimeout(error) {
                return .legacy(requestedVersion: nil)
            }
            throw error
        }

        switch response.statusCode {
        case 200..<300:
            guard let object = response.object else {
                throw MCPHTTPBridgeError.invalidResponse("server/discover returned no JSON response")
            }
            return try MCPUpstreamProtocol.classifyDiscoverResponse(object)
        case 400, 404, 405:
            guard let object = response.object else {
                return .legacy(requestedVersion: nil)
            }
            return try MCPUpstreamProtocol.classifyDiscoverResponse(object)
        default:
            throw MCPHTTPBridgeError.httpStatus(response.statusCode, response.bodySnippet)
        }
    }

    private func postJSONRPC(
        bridge: MCPBridgeConfiguration,
        baseHeaders: [String: String],
        protocolHeaders: [String: String],
        payload: [String: Any],
        allowsEmptyResponse: Bool = false,
        timeoutSeconds: TimeInterval
    ) async throws -> [String: Any] {
        let response = try await sendJSONRPC(
            bridge: bridge,
            baseHeaders: baseHeaders,
            protocolHeaders: protocolHeaders,
            payload: payload,
            timeoutSeconds: timeoutSeconds
        )
        guard (200..<300).contains(response.statusCode) else {
            throw MCPHTTPBridgeError.httpStatus(response.statusCode, response.bodySnippet)
        }
        if response.data.isEmpty, allowsEmptyResponse {
            return ["_headers": response.headers]
        }
        guard var object = response.object else {
            throw MCPHTTPBridgeError.invalidResponse("response was neither JSON nor JSON SSE")
        }
        object["_headers"] = response.headers
        return object
    }

    private func sendJSONRPC(
        bridge: MCPBridgeConfiguration,
        baseHeaders: [String: String],
        protocolHeaders: [String: String],
        payload: [String: Any],
        timeoutSeconds: TimeInterval
    ) async throws -> MCPHTTPBridgeResponse {
        guard let url = URL(string: bridge.serverURL) else {
            throw MCPHTTPBridgeError.invalidResponse("invalid bridge URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.001, timeoutSeconds)
        request.httpBody = try JSONSerialization.checkedData(withJSONObject: payload, options: [])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")

        for (name, value) in baseHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        // Protocol-owned mirrors win over configured bridge headers.
        for (name, value) in protocolHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, urlResponse) = try await MCPHTTPResponseBody.data(
            for: request,
            session: urlSession,
            maximumBytes: maximumResponseBytes
        )
        guard let response = urlResponse as? HTTPURLResponse else {
            throw MCPHTTPBridgeError.invalidResponse("missing HTTP response")
        }

        return MCPHTTPBridgeResponse(
            statusCode: response.statusCode,
            data: data,
            headers: normalizedHeaders(from: response),
            object: try? jsonObject(from: data)
        )
    }

    private func resolvedHeaders(for bridge: MCPBridgeConfiguration) async throws -> [String: String] {
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
            case .oauth:
                guard let token = await oauth.accessToken(for: bridge.serverURL) else {
                    throw MCPUpstreamOAuthError.signInRequired(serverName: bridge.serverName)
                }
                value = token
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
        guard let object = MCPHTTPResponseBody.jsonRPCMessage(from: data) else {
            throw MCPHTTPBridgeError.invalidResponse("response was neither JSON nor JSON SSE")
        }
        return object
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

    private func sessionKey(
        for bridge: MCPBridgeConfiguration,
        resolvedHeaders: [String: String]
    ) -> String {
        var credentialHasher = Hasher()
        for (name, value) in resolvedHeaders.sorted(by: {
            $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
        }) {
            credentialHasher.combine(name.lowercased())
            credentialHasher.combine(value)
        }
        return "\(bridge.serverURL)\u{1f}\(bridge.serverName)\u{1f}\(credentialHasher.finalize())"
    }

    private func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.checkedData(withJSONObject: value, options: [.sortedKeys]) else {
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

    private static func isTimeout(_ error: Error) -> Bool {
        if case MCPHTTPBridgeError.timedOut = error {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut
    }
}

private enum MCPBridgeConnection: Sendable {
    case modern
    case legacy(headers: [String: String])
}

private struct MCPHTTPBridgeResponse {
    let statusCode: Int
    let data: Data
    let headers: [String: String]
    let object: [String: Any]?

    var bodySnippet: String {
        String(decoding: data.prefix(1024), as: UTF8.self)
    }
}

private enum MCPHTTPBridgeError: LocalizedError {
    case timedOut(TimeInterval)
    case httpStatus(Int, String)
    case legacySessionRejected(String)
    case invalidResponse(String)
    case jsonRPCError(String)
    case missingHeaderSource(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            return "Upstream MCP server did not finish answering within the \(seconds.formatted())-second limit."
        case .httpStatus(let status, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Upstream MCP server returned HTTP \(status)." : "Upstream MCP server returned HTTP \(status): \(detail)"
        case .legacySessionRejected(let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Upstream MCP legacy session expired."
                : "Upstream MCP legacy session expired: \(detail)"
        case .invalidResponse(let detail):
            return "Invalid upstream MCP response: \(detail)"
        case .jsonRPCError(let detail):
            return "Upstream MCP JSON-RPC error: \(detail)"
        case .missingHeaderSource(let header):
            return "Could not resolve MCP bridge header: \(header)"
        }
    }
}
