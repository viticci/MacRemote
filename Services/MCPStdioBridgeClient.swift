import Foundation

struct MCPStdioBridgeClient: Sendable {
    private let baseEnvironment: [String: String]

    init(environment: [String: String]) {
        self.baseEnvironment = environment
    }

    func probe(
        command: String,
        args: [String],
        environmentVariables: [MCPStdioEnvironmentVariable],
        protocolVersion: String,
        timeoutSeconds: TimeInterval
    ) async throws -> LocalMCPProbeResult {
        let baseEnvironment = baseEnvironment
        return try await Task.detached {
            let environment = try Self.resolvedEnvironment(
                baseEnvironment: baseEnvironment,
                variables: environmentVariables
            )
            let session = try MCPStdioSession(
                command: command,
                args: args,
                environment: environment
            )
            defer { session.stop() }

            let initialize = try session.request(
                id: "init",
                method: "initialize",
                params: [
                    "protocolVersion": protocolVersion,
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "MacRemote",
                        "version": "0.1.0"
                    ]
                ],
                timeoutSeconds: timeoutSeconds
            )
            if let error = initialize["error"] {
                throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
            }

            let result = initialize["result"] as? [String: Any] ?? [:]
            session.notification(method: "notifications/initialized", params: [:])

            let toolsResponse = try session.request(
                id: "tools",
                method: "tools/list",
                params: nil,
                timeoutSeconds: timeoutSeconds
            )
            if let error = toolsResponse["error"] {
                throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
            }

            let toolsResult = toolsResponse["result"] as? [String: Any] ?? [:]
            let tools = (toolsResult["tools"] as? [[String: Any]] ?? []).compactMap(Self.toolSummary)
            return LocalMCPProbeResult(
                serverInfo: Self.serverInfo(from: result["serverInfo"] as? [String: Any] ?? [:]),
                tools: tools
            )
        }.value
    }

    func call(tool: ToolDefinition, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        guard let bridge = tool.mcpStdioBridge else {
            throw ToolValidationError.invalidMCPBridge("missing stdio bridge configuration")
        }

        try ToolArgumentResolver.validate(tool)
        let started = Date()
        let baseEnvironment = baseEnvironment

        do {
            let resultBox = try await Task.detached {
                let environment = try Self.resolvedEnvironment(
                    baseEnvironment: baseEnvironment,
                    variables: bridge.environment
                )
                let session = try MCPStdioSession(
                    command: bridge.command,
                    args: bridge.args,
                    environment: environment
                )
                defer { session.stop() }

                let initialize = try session.request(
                    id: "init-\(UUID().uuidString)",
                    method: "initialize",
                    params: [
                        "protocolVersion": bridge.protocolVersion,
                        "capabilities": [:],
                        "clientInfo": [
                            "name": "MacRemote",
                            "version": "0.1.0"
                        ]
                    ],
                    timeoutSeconds: bridge.startupTimeoutSeconds ?? tool.timeoutSeconds
                )
                if let error = initialize["error"] {
                    throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
                }

                session.notification(method: "notifications/initialized", params: [:])

                let arguments = parameters.mapValues { $0.jsonValue.anyValue }
                let response = try session.request(
                    id: "call-\(UUID().uuidString)",
                    method: "tools/call",
                    params: [
                        "name": bridge.toolName,
                        "arguments": arguments
                    ],
                    timeoutSeconds: tool.timeoutSeconds
                )
                if let error = response["error"] {
                    throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
                }
                guard let result = response["result"] as? [String: Any] else {
                    throw MCPStdioBridgeError.invalidResponse("tools/call returned no result")
                }
                return MCPStdioJSONObject(value: result)
            }.value
            let result = resultBox.value

            let stdout = Self.cappedString(from: Self.serializedJSON(result), limit: tool.outputByteLimit)
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
            let stderr = Self.cappedString(from: error.localizedDescription, limit: tool.outputByteLimit)
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: 1,
                stdout: "",
                stderr: stderr.value,
                duration: Date().timeIntervalSince(started),
                timedOut: error.isTimeoutError,
                truncatedStdout: false,
                truncatedStderr: stderr.truncated
            )
        }
    }

    private static func resolvedEnvironment(
        baseEnvironment: [String: String],
        variables: [MCPStdioEnvironmentVariable]
    ) throws -> [String: String] {
        var environment = baseEnvironment
        for variable in variables {
            let value: String
            if let literal = variable.value {
                value = literal
            } else if let source = variable.valueSource {
                switch source.kind {
                case .environment:
                    guard let key = source.environmentKey,
                          let environmentValue = ProcessInfo.processInfo.environment[key] ?? baseEnvironment[key] else {
                        throw MCPStdioBridgeError.missingEnvironment(variable.name)
                    }
                    value = environmentValue
                case .jsonFile:
                    value = try jsonFileValue(source: source, variableName: variable.name)
                case .tomlFile:
                    value = try tomlFileValue(source: source, variableName: variable.name)
                }
            } else {
                throw MCPStdioBridgeError.missingEnvironment(variable.name)
            }
            environment[variable.name] = (variable.valueSource?.prefix ?? "") + value
        }
        return environment
    }

    private static func jsonFileValue(source: MCPBridgeHeaderValueSource, variableName: String) throws -> String {
        guard let rawPath = source.filePath,
              let keyPath = source.keyPath else {
            throw MCPStdioBridgeError.missingEnvironment(variableName)
        }

        let path = (rawPath as NSString).expandingTildeInPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let object = try JSONSerialization.jsonObject(with: data)
        var cursor: Any = object
        for key in keyPath {
            guard let dictionary = cursor as? [String: Any],
                  let next = dictionary[key] else {
                throw MCPStdioBridgeError.missingEnvironment(variableName)
            }
            cursor = next
        }
        guard let value = cursor as? String, !value.isEmpty else {
            throw MCPStdioBridgeError.missingEnvironment(variableName)
        }
        return value
    }

    private static func tomlFileValue(source: MCPBridgeHeaderValueSource, variableName: String) throws -> String {
        guard let rawPath = source.filePath,
              let keyPath = source.keyPath,
              keyPath.count >= 2 else {
            throw MCPStdioBridgeError.missingEnvironment(variableName)
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

        throw MCPStdioBridgeError.missingEnvironment(variableName)
    }

    private static func serverInfo(from object: [String: Any]) -> LocalMCPServerInfo {
        LocalMCPServerInfo(
            name: object["name"] as? String,
            title: object["title"] as? String,
            version: object["version"] as? String,
            description: object["description"] as? String
        )
    }

    private static func toolSummary(from object: [String: Any]) -> LocalMCPToolSummary? {
        guard let name = object["name"] as? String, !name.isEmpty else {
            return nil
        }
        return LocalMCPToolSummary(
            name: name,
            title: object["title"] as? String,
            description: object["description"] as? String,
            inputSchema: JSONValue.fromJSONObject(object["inputSchema"] ?? [:]),
            annotations: JSONValue.fromJSONObject(object["annotations"] ?? [:])
        )
    }

    private static func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func cappedString(from string: String, limit: Int) -> (value: String, truncated: Bool) {
        let data = Data(string.utf8)
        let truncated = data.count > limit
        let capped = truncated ? data.prefix(limit) : data[...]
        return (String(decoding: capped, as: UTF8.self), truncated)
    }

    private static func unquotedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }
}

private final class MCPStdioSession: @unchecked Sendable {
    private let process: Process
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let inbox = MCPStdioMessageInbox()

    init(command: String, args: [String], environment: [String: String]) throws {
        process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = args
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [inbox] _ in
            inbox.close()
        }

        startReader(fileHandle: stdoutPipe.fileHandleForReading) { [inbox] data in
            inbox.appendStdout(data)
        }
        startReader(fileHandle: stderrPipe.fileHandleForReading) { [inbox] data in
            inbox.appendStderr(data)
        }

        try process.run()
    }

    func request(
        id: String,
        method: String,
        params: [String: Any]?,
        timeoutSeconds: TimeInterval
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        try write(payload)
        return try inbox.waitForResponse(id: id, timeoutSeconds: timeoutSeconds)
    }

    func notification(method: String, params: [String: Any]) {
        try? write([
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ])
    }

    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
            if process.isRunning {
                process.interrupt()
            }
        }
        inbox.close()
    }

    private func write(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [])
        var line = Data()
        line.append(data)
        line.append(0x0A)
        stdinPipe.fileHandleForWriting.write(line)
    }

    private func startReader(fileHandle: FileHandle, append: @escaping @Sendable (Data) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = fileHandle.availableData
                if data.isEmpty {
                    break
                }
                append(data)
            }
        }
    }
}

private final class MCPStdioMessageInbox: @unchecked Sendable {
    private let condition = NSCondition()
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var messagesByID: [String: [String: Any]] = [:]
    private var closed = false

    func appendStdout(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        condition.lock()
        stdoutBuffer += chunk
        while let newline = stdoutBuffer.firstIndex(of: "\n") {
            let rawLine = String(stdoutBuffer[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
            stdoutBuffer.removeSubrange(...newline)
            if rawLine.isEmpty {
                continue
            }
            guard let lineData = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = Self.idString(from: object["id"]) else {
                continue
            }
            messagesByID[id] = object
            condition.broadcast()
        }
        condition.unlock()
    }

    func appendStderr(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        condition.lock()
        stderrBuffer += chunk
        if stderrBuffer.count > 8_000 {
            stderrBuffer = String(stderrBuffer.suffix(8_000))
        }
        condition.broadcast()
        condition.unlock()
    }

    func waitForResponse(id: String, timeoutSeconds: TimeInterval) throws -> [String: Any] {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        condition.lock()
        defer { condition.unlock() }

        while messagesByID[id] == nil && !closed {
            if !condition.wait(until: deadline) {
                throw MCPStdioBridgeError.timeout(stderrSnippet)
            }
        }

        if let message = messagesByID.removeValue(forKey: id) {
            return message
        }
        throw MCPStdioBridgeError.processExited(stderrSnippet)
    }

    func close() {
        condition.lock()
        closed = true
        condition.broadcast()
        condition.unlock()
    }

    private var stderrSnippet: String {
        let value = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "no stderr output" : value
    }

    private static func idString(from value: Any?) -> String? {
        switch value {
        case let string as String:
            string
        case let int as Int:
            String(int)
        case let double as Double:
            Int(exactly: double).map(String.init)
        default:
            nil
        }
    }
}

private enum MCPStdioBridgeError: LocalizedError {
    case timeout(String)
    case processExited(String)
    case invalidResponse(String)
    case jsonRPCError(String)
    case missingEnvironment(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let stderr):
            "Stdio MCP server timed out: \(stderr)"
        case .processExited(let stderr):
            "Stdio MCP server exited before responding: \(stderr)"
        case .invalidResponse(let detail):
            "Invalid stdio MCP response: \(detail)"
        case .jsonRPCError(let detail):
            "Stdio MCP JSON-RPC error: \(detail)"
        case .missingEnvironment(let variable):
            "Could not resolve MCP environment variable: \(variable)"
        }
    }
}

private struct MCPStdioJSONObject: @unchecked Sendable {
    let value: [String: Any]
}

private extension Error {
    var isTimeoutError: Bool {
        if let error = self as? MCPStdioBridgeError,
           case .timeout = error {
            return true
        }
        return false
    }
}
