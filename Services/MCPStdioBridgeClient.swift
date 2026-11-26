import Darwin
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
        let cancellation = MCPStdioCancellationController()
        return try await Self.exchange(cancellation: cancellation) {
            let environment = try Self.resolvedEnvironment(
                baseEnvironment: baseEnvironment,
                variables: environmentVariables
            )
            MCPStdioSessionPool.shared.evict(
                MCPStdioSessionPool.Key(command: command, args: args, environment: environment)
            )
            let session = try MCPStdioSession(
                command: command,
                args: args,
                environment: environment
            )
            guard cancellation.install(session) else {
                session.stop()
                throw CancellationError()
            }
            defer {
                cancellation.clear(session)
                session.stop()
            }

            let connection = try Self.upstreamConnection(
                session: session,
                legacyProtocolVersion: protocolVersion,
                timeoutSeconds: timeoutSeconds
            )

            let toolsResponse = try Self.request(
                session: session,
                connection: connection,
                id: "tools",
                method: "tools/list",
                params: [:],
                timeoutSeconds: timeoutSeconds
            )
            if let error = toolsResponse["error"] {
                throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
            }

            let toolsResult: [String: Any]
            switch connection {
            case .modern:
                toolsResult = try MCPUpstreamProtocol.completeResult(from: toolsResponse)
            case .legacy:
                toolsResult = toolsResponse["result"] as? [String: Any] ?? [:]
            }
            let listed = toolsResult["tools"] as? [[String: Any]] ?? []
            let tools = listed.compactMap { object -> LocalMCPToolSummary? in
                guard MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(object["inputSchema"]) else {
                    return nil
                }
                return Self.toolSummary(from: object)
            }
            let usable = Set(tools.map(\.name))
            return LocalMCPProbeResult(
                serverInfo: Self.serverInfo(from: connection.serverInfo),
                tools: tools,
                skills: Self.upstreamSkills(session: session, connection: connection, timeoutSeconds: timeoutSeconds),
                skippedToolNames: listed.compactMap { $0["name"] as? String }.filter { !usable.contains($0) }
            )
        }
    }

    /// The server's skills when it declares the Skills extension on
    /// 2026-07-28 (SPEC D84), read on the connection the probe already
    /// holds. Skills are optional, so the whole read has its own short
    /// deadline; a slow or failed read costs only the skills, never the probe.
    private static func upstreamSkills(
        session: MCPStdioSession,
        connection: MCPStdioUpstreamConnection,
        timeoutSeconds: TimeInterval
    ) -> [MCPUpstreamSkill] {
        guard case .modern(_, let extensions) = connection,
              extensions.contains(MCPUpstreamSkillCollector.extensionIdentifier) else {
            return []
        }
        let deadline = Date().addingTimeInterval(min(timeoutSeconds, MCPUpstreamSkillCollector.readDeadlineSeconds))
        var collector = MCPUpstreamSkillCollector()
        do {
            while let next = collector.nextRequest() {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return [] }
                try collector.receive(request(
                    session: session,
                    connection: connection,
                    id: "skills-\(UUID().uuidString)",
                    method: next.method,
                    params: next.params,
                    timeoutSeconds: remaining
                ))
            }
            return collector.skills
        } catch {
            return []
        }
    }

    /// Runs one whole exchange with a server on a thread of its own, because
    /// every step waits on the server's pipes. The caller is suspended, not
    /// blocked, and cancelling it stops the server so the exchange ends.
    private static func exchange<Value: Sendable>(
        cancellation: MCPStdioCancellationController,
        _ work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            // A call that was cancelled before it began starts nothing.
            try Task.checkCancellation()
            let result = await onBlockingThread { Result { try work() } }
            let value = try result.get()
            try Task.checkCancellation()
            return value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Calls one bridged tool. The call, including any question the server
    /// asks and any upstream task it follows, ends by the tool's timeout. The
    /// server's questions go to the calling app through
    /// `MCPElicitationRelay.current` (SPEC D82).
    func call(tool: ToolDefinition, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        guard let bridge = tool.mcpStdioBridge else {
            throw ToolValidationError.invalidMCPBridge("missing stdio bridge configuration")
        }

        try ToolArgumentResolver.validate(tool)
        let started = Date()
        let baseEnvironment = baseEnvironment
        let relay = MCPElicitationRelay.current

        do {
            let cancellation = MCPStdioCancellationController()
            let resultBox = try await Self.exchange(cancellation: cancellation) {
                let environment = try Self.resolvedEnvironment(
                    baseEnvironment: baseEnvironment,
                    variables: bridge.environment
                )
                let pool = MCPStdioSessionPool.shared
                let key = MCPStdioSessionPool.Key(
                    command: bridge.command,
                    args: bridge.args,
                    environment: environment
                )
                let stamp = MCPStdioSessionPool.executableStamp(command: bridge.command, args: bridge.args)
                let warm = pool.checkout(key, executableStamp: stamp)
                let session = try warm?.session ?? MCPStdioSession(
                    command: bridge.command,
                    args: bridge.args,
                    environment: environment
                )
                // Installed before the handshake, so a cancellation stops a
                // server that is slow to start as promptly as a slow call.
                guard cancellation.install(session) else {
                    session.stop()
                    throw CancellationError()
                }
                // The session returns to the pool only after a complete,
                // successful exchange; every failure path stops it instead.
                var keepWarm = false
                var established = warm?.connection
                defer {
                    // A cancellation that took the session owns its stop, so
                    // the server keeps its second to acknowledge `tasks/cancel`
                    // even when the open poll ends first (SPEC D82).
                    if cancellation.clear(session) {
                        // Stopping elsewhere.
                    } else if keepWarm, !cancellation.wasCancelled, let established {
                        pool.checkin(key, session: session, connection: established, executableStamp: stamp)
                    } else {
                        session.stop()
                    }
                }
                let connection = try established ?? Self.upstreamConnection(
                    session: session,
                    legacyProtocolVersion: bridge.protocolVersion,
                    timeoutSeconds: bridge.startupTimeoutSeconds ?? tool.timeoutSeconds
                )
                established = connection

                let arguments = MCPBridgeArgumentCoercion.coerce(
                    parameters.mapValues { $0.jsonValue.anyValue },
                    toSchema: bridge.inputSchema
                )
                let exchange = MCPStdioToolCallExchange(
                    session: session,
                    connection: connection,
                    serverName: bridge.serverName,
                    relay: relay,
                    deadline: Date(timeIntervalSinceNow: tool.timeoutSeconds),
                    cancellation: cancellation
                )
                let toolCall: [String: Any] = ["name": bridge.toolName, "arguments": arguments]
                let response = try exchange.send(method: "tools/call", params: toolCall)
                if let error = response["error"] {
                    // A JSON-RPC error is a complete exchange; the process is
                    // still healthy and can serve the next call.
                    keepWarm = true
                    throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
                }
                guard let first = response["result"] as? [String: Any] else {
                    throw MCPStdioBridgeError.invalidResponse("tools/call returned no result")
                }
                let result: [String: Any]
                switch connection {
                case .modern:
                    result = try exchange.follow(MCPUpstreamToolCall(toolCall: toolCall), from: first)
                case .legacy:
                    result = first
                }
                keepWarm = true
                return MCPStdioJSONObject(value: result)
            }
            let result = resultBox.value

            let normalized = MCPBridgeToolResultNormalizer.normalize(result)
            let stdout = Self.cappedString(from: normalized.stdout, limit: tool.outputByteLimit)
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
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
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

    private static func upstreamConnection(
        session: MCPStdioSession,
        legacyProtocolVersion: String,
        timeoutSeconds: TimeInterval
    ) throws -> MCPStdioUpstreamConnection {
        let discoverResponse: [String: Any]
        do {
            let discover = MCPUpstreamProtocol.modernRequest(
                id: "discover-\(UUID().uuidString)",
                method: "server/discover"
            )
            discoverResponse = try session.request(
                id: discover["id"] as? String ?? "discover",
                method: "server/discover",
                params: discover["params"] as? [String: Any],
                timeoutSeconds: timeoutSeconds
            )
        } catch MCPStdioBridgeError.timeout {
            return try legacyConnection(
                session: session,
                protocolVersion: legacyProtocolVersion,
                timeoutSeconds: timeoutSeconds
            )
        }

        switch try MCPUpstreamProtocol.classifyDiscoverResponse(discoverResponse) {
        case .modern(let result):
            return .modern(
                serverInfo: MCPUpstreamProtocol.serverInfo(fromDiscoverResult: result),
                extensions: MCPUpstreamProtocol.declaredExtensions(fromDiscoverResult: result)
            )
        case .legacy(let requestedVersion):
            // A renegotiated version overrides the saved one for this launch
            // only; the bridge's persisted `protocolVersion` is fingerprinted
            // security material and is never rewritten from the wire.
            return try legacyConnection(
                session: session,
                protocolVersion: requestedVersion ?? legacyProtocolVersion,
                timeoutSeconds: timeoutSeconds
            )
        }
    }

    private static func legacyConnection(
        session: MCPStdioSession,
        protocolVersion: String,
        timeoutSeconds: TimeInterval
    ) throws -> MCPStdioUpstreamConnection {
        let initialize = try session.request(
            id: "init-\(UUID().uuidString)",
            method: "initialize",
            params: [
                "protocolVersion": protocolVersion,
                "capabilities": MCPUpstreamProtocol.legacyStdioClientCapabilities,
                "clientInfo": MCPUpstreamProtocol.clientInfo
            ],
            timeoutSeconds: timeoutSeconds
        )
        if let error = initialize["error"] {
            throw MCPStdioBridgeError.jsonRPCError(serializedJSON(error))
        }

        let result = initialize["result"] as? [String: Any] ?? [:]
        session.notification(
            method: "notifications/initialized",
            params: [:],
            timeoutSeconds: timeoutSeconds
        )
        return .legacy(serverInfo: result["serverInfo"] as? [String: Any] ?? [:])
    }

    fileprivate static func request(
        session: MCPStdioSession,
        connection: MCPStdioUpstreamConnection,
        id: String,
        method: String,
        params: [String: Any],
        capabilities: [String: Any] = MCPUpstreamProtocol.clientCapabilities,
        timeoutSeconds: TimeInterval,
        answeringServer: (_ request: [String: Any]) throws -> [String: Any] = MCPStdioSession.refuse
    ) throws -> [String: Any] {
        switch connection {
        case .modern:
            let payload = MCPUpstreamProtocol.modernRequest(
                id: id,
                method: method,
                params: params,
                capabilities: capabilities
            )
            return try session.request(
                id: id,
                method: method,
                params: payload["params"] as? [String: Any],
                timeoutSeconds: timeoutSeconds,
                answeringServer: answeringServer
            )
        case .legacy:
            return try session.request(
                id: id,
                method: method,
                params: params.isEmpty ? nil : params,
                timeoutSeconds: timeoutSeconds,
                answeringServer: answeringServer
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
                case .oauth:
                    // Sign-in tokens are HTTP headers only; a stdio server never
                    // receives them through its environment.
                    throw MCPStdioBridgeError.missingEnvironment(variable.name)
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

    fileprivate static func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.checkedData(withJSONObject: value, options: [.sortedKeys]) else {
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

/// One `tools/call` on a stdio session, from its first request to its tool
/// result, on the exchange's own thread. Every step shares the call's one
/// deadline. While a request waits, the server may ask the person a question
/// (`elicitation/create`), which goes through the relay; any other request
/// from the server is refused (SPEC D82).
private struct MCPStdioToolCallExchange {
    let session: MCPStdioSession
    let connection: MCPStdioUpstreamConnection
    let serverName: String
    let relay: (any MCPElicitationAnswering)?
    let deadline: Date
    /// Told what to send the server first if the call is cancelled.
    let cancellation: MCPStdioCancellationController
    let rounds = MCPElicitationRelay.Rounds()

    /// Sends one request of the call and returns the server's whole response.
    func send(method: String, params: [String: Any]) throws -> [String: Any] {
        try MCPStdioBridgeClient.request(
            session: session,
            connection: connection,
            id: "\(method)-\(UUID().uuidString)",
            method: method,
            params: params,
            capabilities: MCPUpstreamProtocol.toolCallCapabilities(relay: relay),
            timeoutSeconds: try remaining(),
            answeringServer: answer
        )
    }

    /// Follows a modern call to its tool result, the way the HTTP bridge
    /// does. When it ends any other way while an upstream task runs, the
    /// server is sent `tasks/cancel`; a cancelled call stops the server from
    /// another thread, so that thread is handed the request to send first.
    func follow(_ initial: MCPUpstreamToolCall, from first: [String: Any]) throws -> [String: Any] {
        var call = initial
        var result = first
        defer { cancellation.setFarewell(nil) }
        do {
            while true {
                let next = try call.next(after: result)
                cancellation.setFarewell(call.cancelRequest.map(Self.line))
                switch next {
                case .finished(let toolResult):
                    return toolResult
                case .ask(let questions):
                    result = try resultOf(call.request(answering: ask(questions)))
                case .poll(let delay):
                    try pause(delay)
                    result = try resultOf(call.pollRequest())
                }
            }
        } catch {
            if let cancel = call.cancelRequest, session.isRunning {
                _ = try? MCPStdioBridgeClient.request(
                    session: session,
                    connection: connection,
                    id: "tasks/cancel-\(UUID().uuidString)",
                    method: cancel.method,
                    params: cancel.params,
                    capabilities: MCPUpstreamProtocol.toolCallCapabilities(relay: nil),
                    timeoutSeconds: 1
                )
            }
            throw error
        }
    }

    /// The whole JSON-RPC line for one modern request.
    private static func line(_ request: (method: String, params: [String: Any])) -> MCPStdioJSONObject {
        MCPStdioJSONObject(value: MCPUpstreamProtocol.modernRequest(
            id: "\(request.method)-\(UUID().uuidString)",
            method: request.method,
            params: request.params,
            capabilities: MCPUpstreamProtocol.toolCallCapabilities(relay: nil)
        ))
    }

    private func resultOf(_ request: (method: String, params: [String: Any])) throws -> [String: Any] {
        let response = try send(method: request.method, params: request.params)
        if let error = response["error"] {
            throw MCPStdioBridgeError.jsonRPCError(MCPStdioBridgeClient.serializedJSON(error))
        }
        guard let result = response["result"] as? [String: Any] else {
            throw MCPStdioBridgeError.invalidResponse("\(request.method) returned no result")
        }
        return result
    }

    /// The reply to a request the server sent: the person's answer to an
    /// `elicitation/create`, an empty result for `ping`, and Method not found
    /// for anything else (`roots/list`, `sampling/createMessage`, ...).
    private func answer(_ request: [String: Any]) throws -> [String: Any] {
        switch request["method"] as? String {
        case MCPElicitationRelay.elicitationMethod:
            let question = JSONValue.fromJSONObject([
                "method": MCPElicitationRelay.elicitationMethod,
                "params": request["params"] ?? [String: Any]()
            ]) ?? .null
            let answers = try ask(["request": question])
            return ["result": answers["request"]?.anyValue ?? ["action": "cancel"]]
        case "ping":
            return ["result": [String: Any]()]
        default:
            return MCPStdioSession.refuse(request)
        }
    }

    /// Asks through the relay and waits on this thread, giving up at the
    /// deadline or when the server stops.
    private func ask(_ questions: [String: JSONValue]) throws -> [String: JSONValue] {
        let box = MCPStdioAnswerBox()
        let (serverName, relay, rounds) = (serverName, relay, rounds)
        let asking = Task {
            do {
                box.finish(.success(try await MCPElicitationRelay.ask(
                    questions,
                    server: serverName,
                    relay: relay,
                    rounds: rounds
                )))
            } catch {
                box.finish(.failure(error))
            }
        }
        while true {
            if let answers = box.wait(seconds: 0.1) { return try answers.get() }
            guard session.isRunning else {
                asking.cancel()
                throw MCPStdioBridgeError.processExited("the server stopped while a question was open")
            }
            guard Date() < deadline else {
                asking.cancel()
                throw MCPStdioBridgeError.timeout("no answer before the tool's time limit")
            }
        }
    }

    /// Waits `delay` on this thread, cut short by the deadline or a stop.
    private func pause(_ delay: Duration) throws {
        let until = Date(timeIntervalSinceNow: Double(delay.components.seconds)
            + Double(delay.components.attoseconds) / 1e18)
        while Date() < until {
            guard session.isRunning else {
                throw MCPStdioBridgeError.processExited("the server was stopped")
            }
            _ = try remaining()
            Thread.sleep(forTimeInterval: min(0.1, max(0, until.timeIntervalSinceNow)))
        }
    }

    private func remaining() throws -> TimeInterval {
        let left = deadline.timeIntervalSinceNow
        guard left > 0 else {
            throw MCPStdioBridgeError.timeout("the tool's time limit passed")
        }
        return left
    }
}

/// Hands a relay's answers, or its refusal, from its task to the waiting
/// exchange thread.
private final class MCPStdioAnswerBox: @unchecked Sendable {
    private let condition = NSCondition()
    private var answers: Result<[String: JSONValue], any Error>?

    func finish(_ answers: Result<[String: JSONValue], any Error>) {
        condition.withLock {
            self.answers = answers
            condition.broadcast()
        }
    }

    /// The answers, or nil when they did not arrive within `seconds`.
    func wait(seconds: TimeInterval) -> Result<[String: JSONValue], any Error>? {
        let until = Date(timeIntervalSinceNow: seconds)
        return condition.withLock {
            while answers == nil, condition.wait(until: until) {}
            return answers
        }
    }
}

private enum MCPStdioUpstreamConnection {
    /// `extensions` are the identifiers the server's discover result declared.
    case modern(serverInfo: [String: Any], extensions: Set<String>)
    case legacy(serverInfo: [String: Any])

    var serverInfo: [String: Any] {
        switch self {
        case .modern(let serverInfo, _), .legacy(let serverInfo):
            serverInfo
        }
    }
}

private final class MCPStdioCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var session: MCPStdioSession?
    private var cancelled = false
    /// What a cancelled call's server is sent before it stops: `tasks/cancel`
    /// while the call follows an upstream task (SPEC D82).
    private var farewell: MCPStdioJSONObject?

    /// Sets the request `cancel()` sends first; nil for none.
    func setFarewell(_ request: MCPStdioJSONObject?) {
        lock.withLock { farewell = request }
    }

    func install(_ session: MCPStdioSession) -> Bool {
        lock.withLock {
            guard !cancelled else {
                return false
            }
            self.session = session
            return true
        }
    }

    /// Ends the controller's hold on the session. Returns true when a
    /// cancellation already took it: that stop, which may still be waiting
    /// for the farewell's reply, is then the only one, and the caller must
    /// not stop the session itself.
    @discardableResult
    func clear(_ session: MCPStdioSession) -> Bool {
        lock.withLock {
            guard self.session === session else {
                return false
            }
            self.session = nil
            return cancelled
        }
    }

    /// Stopping a server waits for it to exit, and a cancellation can arrive
    /// on any thread, one of Swift's async threads included, so the stop runs
    /// on a queue of its own.
    func cancel() {
        let (session, farewell) = lock.withLock {
            cancelled = true
            return (self.session, self.farewell)
        }
        guard let session else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stop(farewell: farewell)
        }
    }

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }
}

/// Keeps one idle upstream process warm per exact launch contract so
/// back-to-back calls skip process startup and the MCP handshake. A warm
/// session is reused only while its process is alive and its executable is
/// byte-for-byte the one it was launched from; it expires after a short idle
/// period, and a probe or any failed exchange discards it.
final class MCPStdioSessionPool: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        let command: String
        let args: [String]
        let environment: [String: String]
    }

    fileprivate struct WarmSession {
        let session: MCPStdioSession
        let connection: MCPStdioUpstreamConnection
    }

    private struct Entry {
        let warm: WarmSession
        let executableStamp: String
        let expiry: DispatchWorkItem
    }

    static let shared = MCPStdioSessionPool()

    let idleTimeout: TimeInterval
    let capacity: Int
    private let lock = NSLock()
    private var idle: [Key: Entry] = [:]
    private var idleOrder: [Key] = []
    private(set) var reuseCount = 0

    init(idleTimeout: TimeInterval = 60, capacity: Int = 16) {
        self.idleTimeout = idleTimeout
        self.capacity = capacity
    }

    /// mtime and size of the launched executable and, for interpreter
    /// launches, of the script it runs. A CLI upgrade changes the stamp, so
    /// the next call starts the new binary instead of reusing the old process.
    static func executableStamp(command: String, args: [String]) -> String {
        var paths = [command]
        if let first = args.first, first.hasPrefix("/") {
            paths.append(first)
        }
        return paths.map { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
                return "\(path)|missing"
            }
            let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            return "\(path)|\(mtime)|\(size)"
        }.joined(separator: "\u{1f}")
    }

    fileprivate func checkout(_ key: Key, executableStamp: String) -> WarmSession? {
        let entry: Entry? = lock.withLock {
            guard let entry = idle.removeValue(forKey: key) else { return nil }
            idleOrder.removeAll { $0 == key }
            entry.expiry.cancel()
            return entry
        }
        guard let entry else { return nil }
        guard entry.executableStamp == executableStamp, entry.warm.session.isRunning else {
            entry.warm.session.stop()
            return nil
        }
        lock.withLock { reuseCount += 1 }
        return entry.warm
    }

    fileprivate func checkin(
        _ key: Key,
        session: MCPStdioSession,
        connection: MCPStdioUpstreamConnection,
        executableStamp: String
    ) {
        guard session.isRunning else {
            session.stop()
            return
        }
        let expiry = DispatchWorkItem { [weak self] in
            self?.expire(key, session: session)
        }
        let evicted: [WarmSession] = lock.withLock {
            var evicted: [WarmSession] = []
            if let existing = idle[key] {
                // Another call already parked a session for this contract.
                expiry.cancel()
                return [WarmSession(session: session, connection: connection)]
                    + (existing.warm.session.isRunning ? [] : [existing.warm])
            }
            idle[key] = Entry(
                warm: WarmSession(session: session, connection: connection),
                executableStamp: executableStamp,
                expiry: expiry
            )
            idleOrder.append(key)
            while idleOrder.count > capacity, let oldest = idleOrder.first {
                idleOrder.removeFirst()
                if let entry = idle.removeValue(forKey: oldest) {
                    entry.expiry.cancel()
                    evicted.append(entry.warm)
                }
            }
            return evicted
        }
        evicted.forEach { $0.session.stop() }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + idleTimeout,
            execute: expiry
        )
    }

    func evict(_ key: Key) {
        let entry: Entry? = lock.withLock {
            idleOrder.removeAll { $0 == key }
            let entry = idle.removeValue(forKey: key)
            entry?.expiry.cancel()
            return entry
        }
        entry?.warm.session.stop()
    }

    /// Stops the idle processes whose key matches. Tests use it to clean up
    /// their own fixture without emptying the pool under another suite.
    func evict(where matches: (Key) -> Bool) {
        let keys = lock.withLock { idle.keys.filter(matches) }
        for key in keys {
            evict(key)
        }
    }

    /// Stops every idle process. Called when the app quits so no upstream
    /// server outlives MacRemote.
    func drain() {
        let entries: [Entry] = lock.withLock {
            let all = Array(idle.values)
            idle.removeAll()
            idleOrder.removeAll()
            return all
        }
        for entry in entries {
            entry.expiry.cancel()
            entry.warm.session.stop()
        }
    }

    var idleCount: Int {
        lock.withLock { idle.count }
    }

    func idleCount(where matches: (Key) -> Bool) -> Int {
        lock.withLock { idle.keys.filter(matches).count }
    }

    private func expire(_ key: Key, session: MCPStdioSession) {
        let entry: Entry? = lock.withLock {
            guard let entry = idle[key], entry.warm.session === session else { return nil }
            idle.removeValue(forKey: key)
            idleOrder.removeAll { $0 == key }
            return entry
        }
        entry?.warm.session.stop()
    }
}

fileprivate final class MCPStdioSession: @unchecked Sendable {
    private let processID: pid_t
    private let processState: MCPStdioProcessState
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let inbox = MCPStdioMessageInbox()
    private let stopLock = NSLock()
    private var stopped = false
    /// Held for a whole line, so a farewell from another thread never lands
    /// inside one.
    private let writeLock = NSLock()
    /// How long a stopping server has to answer its farewell.
    static let farewellSeconds: TimeInterval = 1
    /// Read once at launch: asking the file handle again after `stop()`
    /// closed it raises an exception Swift cannot catch.
    private let stdinDescriptor: Int32

    init(command: String, args: [String], environment: [String: String]) throws {
        processID = try Self.spawnProcessGroup(
            command: command,
            args: args,
            environment: environment,
            stdinPipe: stdinPipe,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        processState = MCPStdioProcessState(processID: processID)

        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        // Without this, a write to a server that has already exited delivers
        // SIGPIPE, which ends MacRemote itself.
        stdinDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
        _ = fcntl(stdinDescriptor, F_SETNOSIGPIPE, 1)
        // Writes return at once when the pipe is full, so `write` can give up
        // at its deadline. Only MacRemote's end of the pipe is affected.
        _ = fcntl(stdinDescriptor, F_SETFL, fcntl(stdinDescriptor, F_GETFL) | O_NONBLOCK)

        startReader(fileHandle: stdoutPipe.fileHandleForReading) { [inbox] data in
            inbox.appendStdout(data)
        }
        startReader(fileHandle: stderrPipe.fileHandleForReading) { [inbox] data in
            inbox.appendStderr(data)
        }
        Self.startProcessWaiter(
            processID: processID,
            processState: processState,
            inbox: inbox
        )
    }

    /// Sends a request and waits for its response. A request the server
    /// sends meanwhile is answered with what `answeringServer` returns (a
    /// `result` or an `error`), under the server's own id.
    func request(
        id: String,
        method: String,
        params: [String: Any]?,
        timeoutSeconds: TimeInterval,
        answeringServer: (_ request: [String: Any]) throws -> [String: Any] = MCPStdioSession.refuse
    ) throws -> [String: Any] {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method
        ]
        if let params {
            payload["params"] = params
        }
        // One deadline covers sending the request and waiting for the answer.
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        try write(payload, deadline: deadline)
        while true {
            switch try inbox.next(for: id, timeoutSeconds: max(0, deadline.timeIntervalSinceNow)) {
            case .response(let response):
                return response
            case .serverRequest(let request):
                var reply = try answeringServer(request)
                reply["jsonrpc"] = "2.0"
                reply["id"] = request["id"]
                try write(reply, deadline: deadline)
            }
        }
    }

    /// Method not found: what MacRemote answers a server request it does not serve.
    static func refuse(_ request: [String: Any]) -> [String: Any] {
        ["error": ["code": -32601, "message": "Method not found"]]
    }

    func notification(method: String, params: [String: Any], timeoutSeconds: TimeInterval) {
        try? write(
            [
                "jsonrpc": "2.0",
                "method": method,
                "params": params
            ],
            deadline: Date(timeIntervalSinceNow: timeoutSeconds)
        )
    }

    var isRunning: Bool {
        stopLock.withLock { !stopped } && processState.isRunning
    }

    /// Stops the server. A `farewell` request is written first and its reply
    /// waited for, at most `farewellSeconds`, so a server whose call was
    /// cancelled hears `tasks/cancel` before its pipes close (SPEC D82).
    func stop(farewell: MCPStdioJSONObject? = nil) {
        if let farewell, let id = farewell.value["id"] as? String, isRunning {
            let deadline = Date(timeIntervalSinceNow: Self.farewellSeconds)
            if (try? write(farewell.value, deadline: deadline)) != nil {
                inbox.awaitResponse(to: id, until: deadline)
            }
        }
        let shouldStop = stopLock.withLock {
            guard !stopped else {
                return false
            }
            stopped = true
            return true
        }
        guard shouldStop else {
            return
        }
        // No write can be in progress: `write` touches the descriptor only
        // while it holds `stopLock` and sees `stopped` false.
        try? stdinPipe.fileHandleForWriting.close()
        guard processState.isRunning else {
            inbox.close()
            return
        }

        Self.signalProcessGroup(processID, signal: SIGTERM)
        if !processState.waitUntilExited(timeoutSeconds: 0.2) {
            // The leader's unreaped PID is the process-group identity here, so
            // it cannot be recycled before this escalation.
            Self.signalProcessGroup(processID, signal: SIGKILL)
            _ = processState.waitUntilExited(timeoutSeconds: 0.5)
        }
        inbox.close()
    }

    private static func spawnProcessGroup(
        command: String,
        args: [String],
        environment: [String: String],
        stdinPipe: Pipe,
        stdoutPipe: Pipe,
        stderrPipe: Pipe
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw MCPStdioBridgeError.spawnFailed("could not initialize posix_spawn")
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw MCPStdioBridgeError.spawnFailed("could not initialize posix_spawn attributes")
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let stdinRead = stdinPipe.fileHandleForReading.fileDescriptor
        let stdinWrite = stdinPipe.fileHandleForWriting.fileDescriptor
        let stdoutRead = stdoutPipe.fileHandleForReading.fileDescriptor
        let stdoutWrite = stdoutPipe.fileHandleForWriting.fileDescriptor
        let stderrRead = stderrPipe.fileHandleForReading.fileDescriptor
        let stderrWrite = stderrPipe.fileHandleForWriting.fileDescriptor

        for (source, destination) in [
            (stdinRead, STDIN_FILENO),
            (stdoutWrite, STDOUT_FILENO),
            (stderrWrite, STDERR_FILENO)
        ] {
            guard posix_spawn_file_actions_adddup2(
                &fileActions,
                source,
                destination
            ) == 0 else {
                throw MCPStdioBridgeError.spawnFailed("could not configure stdio")
            }
            if source != destination {
                _ = posix_spawn_file_actions_addclose(&fileActions, source)
            }
        }
        for descriptor in [stdinWrite, stdoutRead, stderrRead] {
            _ = posix_spawn_file_actions_addclose(&fileActions, descriptor)
        }

        // CLOEXEC_DEFAULT: the server gets only the three descriptors set up
        // above, never another server's pipes or any other open file.
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        ) == 0,
        posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
            throw MCPStdioBridgeError.spawnFailed("could not configure process group")
        }

        let argumentStrings = [command] + args
        let environmentStrings = environment
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        var processID: pid_t = 0
        let status = withCStringArray(argumentStrings) { argumentVector in
            withCStringArray(environmentStrings) { environmentVector in
                posix_spawn(
                    &processID,
                    command,
                    &fileActions,
                    &attributes,
                    argumentVector,
                    environmentVector
                )
            }
        }
        guard status == 0 else {
            throw MCPStdioBridgeError.spawnFailed(
                String(cString: strerror(status))
            )
        }
        return processID
    }

    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        let pointers = strings.map { strdup($0) }
        defer {
            for pointer in pointers {
                free(pointer)
            }
        }
        var vector = pointers + [nil]
        return try vector.withUnsafeMutableBufferPointer { buffer in
            try body(buffer.baseAddress!)
        }
    }

    /// Waits for the server to exit on a thread of its own. The wait lasts as
    /// long as the server runs, which for a warm server is minutes; a shared
    /// dispatch queue has a limited number of threads to lend.
    private static func startProcessWaiter(
        processID: pid_t,
        processState: MCPStdioProcessState,
        inbox: MCPStdioMessageInbox
    ) {
        Thread.detachNewThread {
            var status: Int32 = 0
            while waitpid(processID, &status, 0) == -1 && errno == EINTR {}
            processState.markExited()
            inbox.close()
        }
    }

    private static func signalProcessGroup(_ processID: pid_t, signal: Int32) {
        if kill(-processID, signal) != 0 {
            _ = kill(processID, signal)
        }
    }

    /// Sends one JSON-RPC line to the server, giving up at `deadline`.
    ///
    /// A request larger than the pipe holds can only be sent as fast as the
    /// server reads it. The pipe is non-blocking and each wait is a short
    /// poll(2), so a server that stops reading cannot hold the call past its
    /// timeout, and a stop() from another thread is noticed within a tenth of
    /// a second. Plain write(2) reports a closed pipe as a value.
    private func write(_ payload: [String: Any], deadline: Date) throws {
        var line = try JSONSerialization.checkedData(withJSONObject: payload, options: [])
        line.append(0x0A)
        guard writeLock.lock(before: deadline) else {
            throw MCPStdioBridgeError.timeout("another message to the server did not finish")
        }
        defer { writeLock.unlock() }
        let descriptor = stdinDescriptor
        var offset = 0
        while offset < line.count {
            // Under the lock, so stop() cannot close the descriptor mid-write.
            let (written, failure): (Int, Int32) = try stopLock.withLock {
                guard !stopped else {
                    throw MCPStdioBridgeError.processExited("the server was stopped")
                }
                let written = line.withUnsafeBytes { buffer in
                    Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                }
                return (written, errno)
            }
            if written > 0 {
                offset += written
                continue
            }
            guard written < 0, failure == EAGAIN || failure == EINTR else {
                throw MCPStdioBridgeError.processExited(
                    "could not write to the server: \(String(cString: strerror(failure)))"
                )
            }
            guard Date() < deadline else {
                throw MCPStdioBridgeError.timeout("the server stopped reading its input")
            }
            var poller = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
            _ = poll(&poller, 1, 100)
        }
    }

    /// Reads one of the server's output pipes on a thread of its own until
    /// the pipe closes. The read blocks for as long as the server is quiet.
    private func startReader(fileHandle: FileHandle, append: @escaping @Sendable (Data) -> Void) {
        // Plain read(2): it returns as soon as any bytes arrive, and reports a
        // failed read as a value. FileHandle's own calls either wait for a
        // full buffer or raise an exception Swift cannot catch.
        let descriptor = fileHandle.fileDescriptor
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let count = read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    append(Data(buffer[..<count]))
                } else if count == 0 || errno != EINTR {
                    break
                }
            }
            // Keeps the handle, and so its descriptor, alive for the loop.
            withExtendedLifetime(fileHandle) {}
        }
    }
}

private final class MCPStdioProcessState: @unchecked Sendable {
    private let condition = NSCondition()
    private var running = true

    init(processID _: pid_t) {}

    var isRunning: Bool {
        condition.withLock {
            running
        }
    }

    func markExited() {
        condition.withLock {
            running = false
            condition.broadcast()
        }
    }

    func waitUntilExited(timeoutSeconds: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        return condition.withLock {
            while running {
                if !condition.wait(until: deadline) {
                    break
                }
            }
            return !running
        }
    }
}

/// What a stdio server sent that a waiting request must handle.
enum MCPStdioInboxMessage: @unchecked Sendable {
    /// The response to the request being waited for.
    case response([String: Any])
    /// A request from the server (it has a `method` and an `id`), such as
    /// `elicitation/create`. Never taken for a response, whatever its id.
    case serverRequest([String: Any])
}

final class MCPStdioMessageInbox: @unchecked Sendable {
    /// One JSON-RPC line may be large (a tool result), but not unbounded.
    static let maximumBufferedBytes = 32 * 1024 * 1024
    static let maximumUnclaimedMessages = 256

    private let condition = NSCondition()
    private var stdoutBuffer = Data()
    private var stderrBuffer = ""
    private var messagesByID: [String: [String: Any]] = [:]
    private var serverRequests: [[String: Any]] = []
    private var closed = false

    func appendStdout(_ data: Data) {
        condition.lock()
        defer { condition.unlock() }

        // Earlier bytes contain no newline. Scan only the new bytes, and keep
        // partial UTF-8 scalars intact until their complete line arrives.
        guard !closed else { return }
        var searchStart = stdoutBuffer.endIndex
        stdoutBuffer.append(data)
        // A server that streams without ever ending a line, or floods replies
        // nobody asked for, would otherwise grow these without limit.
        if stdoutBuffer.count > Self.maximumBufferedBytes
            || messagesByID.count + serverRequests.count > Self.maximumUnclaimedMessages {
            stdoutBuffer.removeAll()
            messagesByID.removeAll()
            serverRequests.removeAll()
            closed = true
            condition.broadcast()
            return
        }
        var lineStart = stdoutBuffer.startIndex
        while let newline = stdoutBuffer[searchStart...].firstIndex(of: 0x0A) {
            let rawLine = String(decoding: stdoutBuffer[lineStart..<newline], as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            lineStart = stdoutBuffer.index(after: newline)
            searchStart = lineStart
            if rawLine.isEmpty {
                continue
            }
            // A line with a method is the server's: a request when it has an
            // id, otherwise a notification, which is ignored.
            guard let lineData = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = Self.idString(from: object["id"]) else {
                continue
            }
            if object["method"] is String {
                serverRequests.append(object)
            } else {
                messagesByID[id] = object
            }
            condition.broadcast()
        }
        stdoutBuffer.removeSubrange(..<lineStart)
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

    /// Waits for the response to request `id` or for a request from the
    /// server, whichever comes first; the server's requests in the order sent.
    func next(for id: String, timeoutSeconds: TimeInterval) throws -> MCPStdioInboxMessage {
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        condition.lock()
        defer { condition.unlock() }

        while messagesByID[id] == nil && serverRequests.isEmpty && !closed {
            if !condition.wait(until: deadline) {
                throw MCPStdioBridgeError.timeout(stderrSnippet)
            }
        }

        if !serverRequests.isEmpty {
            return .serverRequest(serverRequests.removeFirst())
        }
        if let message = messagesByID.removeValue(forKey: id) {
            return .response(message)
        }
        throw MCPStdioBridgeError.processExited(stderrSnippet)
    }

    /// Waits until the response to `id` arrives, the server stops, or
    /// `deadline` passes, and drops it. Requests from the server stay for
    /// the call's own waiter.
    func awaitResponse(to id: String, until deadline: Date) {
        condition.lock()
        defer { condition.unlock() }
        while messagesByID[id] == nil, !closed, condition.wait(until: deadline) {}
        messagesByID[id] = nil
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
    case spawnFailed(String)
    case timeout(String)
    case processExited(String)
    case invalidResponse(String)
    case jsonRPCError(String)
    case missingEnvironment(String)

    var errorDescription: String? {
        switch self {
        case .spawnFailed(let detail):
            "Could not launch stdio MCP server: \(detail)"
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
