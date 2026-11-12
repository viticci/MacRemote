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
            let tools = (toolsResult["tools"] as? [[String: Any]] ?? []).compactMap {
                object -> LocalMCPToolSummary? in
                guard MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(object["inputSchema"]) else {
                    return nil
                }
                return Self.toolSummary(from: object)
            }
            return LocalMCPProbeResult(
                serverInfo: Self.serverInfo(from: connection.serverInfo),
                tools: tools
            )
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

    func call(tool: ToolDefinition, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        guard let bridge = tool.mcpStdioBridge else {
            throw ToolValidationError.invalidMCPBridge("missing stdio bridge configuration")
        }

        try ToolArgumentResolver.validate(tool)
        let started = Date()
        let baseEnvironment = baseEnvironment

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
                    cancellation.clear(session)
                    if keepWarm, !cancellation.wasCancelled, let established {
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
                let response = try Self.request(
                    session: session,
                    connection: connection,
                    id: "call-\(UUID().uuidString)",
                    method: "tools/call",
                    params: [
                        "name": bridge.toolName,
                        "arguments": arguments
                    ],
                    timeoutSeconds: tool.timeoutSeconds
                )
                if let error = response["error"] {
                    // A JSON-RPC error is a complete exchange; the process is
                    // still healthy and can serve the next call.
                    keepWarm = true
                    throw MCPStdioBridgeError.jsonRPCError(Self.serializedJSON(error))
                }
                let result: [String: Any]
                switch connection {
                case .modern:
                    result = try MCPUpstreamProtocol.completeResult(from: response)
                case .legacy:
                    guard let legacyResult = response["result"] as? [String: Any] else {
                        throw MCPStdioBridgeError.invalidResponse("tools/call returned no result")
                    }
                    result = legacyResult
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
            return .modern(serverInfo: MCPUpstreamProtocol.serverInfo(fromDiscoverResult: result))
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
                "capabilities": [:],
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

    private static func request(
        session: MCPStdioSession,
        connection: MCPStdioUpstreamConnection,
        id: String,
        method: String,
        params: [String: Any],
        timeoutSeconds: TimeInterval
    ) throws -> [String: Any] {
        switch connection {
        case .modern:
            let payload = MCPUpstreamProtocol.modernRequest(
                id: id,
                method: method,
                params: params
            )
            return try session.request(
                id: id,
                method: method,
                params: payload["params"] as? [String: Any],
                timeoutSeconds: timeoutSeconds
            )
        case .legacy:
            return try session.request(
                id: id,
                method: method,
                params: params.isEmpty ? nil : params,
                timeoutSeconds: timeoutSeconds
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

    private static func serializedJSON(_ value: Any) -> String {
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

private enum MCPStdioUpstreamConnection {
    case modern(serverInfo: [String: Any])
    case legacy(serverInfo: [String: Any])

    var serverInfo: [String: Any] {
        switch self {
        case .modern(let serverInfo), .legacy(let serverInfo):
            serverInfo
        }
    }
}

private final class MCPStdioCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var session: MCPStdioSession?
    private var cancelled = false

    func install(_ session: MCPStdioSession) -> Bool {
        lock.withLock {
            guard !cancelled else {
                return false
            }
            self.session = session
            return true
        }
    }

    func clear(_ session: MCPStdioSession) {
        lock.withLock {
            if self.session === session {
                self.session = nil
            }
        }
    }

    /// Stopping a server waits for it to exit, and a cancellation can arrive
    /// on any thread, one of Swift's async threads included, so the stop runs
    /// on a queue of its own.
    func cancel() {
        let session = lock.withLock {
            cancelled = true
            return self.session
        }
        guard let session else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            session.stop()
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

private final class MCPStdioSession: @unchecked Sendable {
    private let processID: pid_t
    private let processState: MCPStdioProcessState
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let inbox = MCPStdioMessageInbox()
    private let stopLock = NSLock()
    private var stopped = false

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
        let stdinDescriptor = stdinPipe.fileHandleForWriting.fileDescriptor
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
        // One deadline covers sending the request and waiting for the answer.
        let deadline = Date(timeIntervalSinceNow: timeoutSeconds)
        try write(payload, deadline: deadline)
        return try inbox.waitForResponse(
            id: id,
            timeoutSeconds: max(0, deadline.timeIntervalSinceNow)
        )
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

    func stop() {
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
        let descriptor = stdinPipe.fileHandleForWriting.fileDescriptor
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

final class MCPStdioMessageInbox: @unchecked Sendable {
    /// One JSON-RPC line may be large (a tool result), but not unbounded.
    static let maximumBufferedBytes = 32 * 1024 * 1024
    static let maximumUnclaimedMessages = 256

    private let condition = NSCondition()
    private var stdoutBuffer = Data()
    private var stderrBuffer = ""
    private var messagesByID: [String: [String: Any]] = [:]
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
        if stdoutBuffer.count > Self.maximumBufferedBytes || messagesByID.count > Self.maximumUnclaimedMessages {
            stdoutBuffer.removeAll()
            messagesByID.removeAll()
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
            guard let lineData = rawLine.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let id = Self.idString(from: object["id"]) else {
                continue
            }
            messagesByID[id] = object
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
