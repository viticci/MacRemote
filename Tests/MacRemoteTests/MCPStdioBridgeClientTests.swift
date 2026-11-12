import Darwin
import Foundation
import Testing
@testable import MacRemote

struct MCPStdioMessageInboxTests {
    @Test func fragmentedUnicodeResponsePreservesEveryByteBoundary() throws {
        let text = "Caffè 👩🏽‍💻 東京"
        let data = Data("{\"id\":\"unicode\",\"result\":\"\(text)\"}\n".utf8)
        for split in 0...data.count {
            let inbox = MCPStdioMessageInbox()
            inbox.appendStdout(Data(data.prefix(split)))
            inbox.appendStdout(Data(data.dropFirst(split)))

            let response = try inbox.waitForResponse(id: "unicode", timeoutSeconds: 0)
            #expect(response["result"] as? String == text, "Split at byte \(split)")
        }
    }

    @Test func coalescedLinesIgnoreNoiseAndRetainTheIncompleteTail() throws {
        let inbox = MCPStdioMessageInbox()
        inbox.appendStdout(Data(" \nnot json\n{\"method\":\"notice\"}\n{\"id\":1,\"result\":\"first\"}\r\n{\"id\":\"second\",\"result\":\"second\"}\n{\"id\":\"tail\",\"result\":\"".utf8))
        inbox.appendStdout(Data())
        inbox.appendStdout(Data("complete\"}\n".utf8))

        let first = try inbox.waitForResponse(id: "1", timeoutSeconds: 0)
        let second = try inbox.waitForResponse(id: "second", timeoutSeconds: 0)
        let tail = try inbox.waitForResponse(id: "tail", timeoutSeconds: 0)
        #expect(first["result"] as? String == "first")
        #expect(second["result"] as? String == "second")
        #expect(tail["result"] as? String == "complete")
    }
}

@Suite(.serialized)
struct MCPStdioBridgeClientTests {
    @Test func modernServerUsesDiscoverAndPerRequestMetadata() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let outcome = try await fixture.call(mode: "modern")

        #expect(outcome.succeeded)
        #expect(outcome.stdout == #"{"mode":"modern"}"#)
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == ["server/discover", "tools/call"])
        let discoverMeta = try #require(transcript[0].params["_meta"] as? [String: Any])
        #expect(discoverMeta["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
        let callMeta = try #require(transcript[1].params["_meta"] as? [String: Any])
        #expect(callMeta["io.modelcontextprotocol/clientInfo"] as? [String: Any] != nil)
        #expect(callMeta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any] != nil)
    }

    @Test func unrecognizedDiscoverErrorFallsBackToSavedLegacyInitialize() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let outcome = try await fixture.call(mode: "unrecognized")

        #expect(outcome.succeeded)
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == [
            "server/discover", "initialize", "notifications/initialized", "tools/call"
        ])
        #expect(transcript[1].params["protocolVersion"] as? String == "2025-06-18")
        #expect(transcript[3].params["_meta"] == nil)
    }

    @Test func discoverTimeoutFallsBackToSavedLegacyInitialize() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let outcome = try await fixture.call(mode: "timeout", startupTimeout: 1)

        #expect(outcome.succeeded)
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == [
            "server/discover", "initialize", "notifications/initialized", "tools/call"
        ])
    }

    @Test func unsupportedVersionErrorWithoutAUsableListDoesNotDowngradeToLegacyInitialize()
        async throws
    {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let outcome = try await fixture.call(mode: "recognized")

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("-32022"))
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == ["server/discover"])
    }

    @Test func reservedModernErrorsNeverDowngradeToLegacyInitialize() async throws {
        for (mode, code) in [("header-mismatch", -32020), ("missing-capability", -32021)] {
            let fixture = try StdioProtocolFixture()
            defer { fixture.remove() }

            let outcome = try await fixture.call(mode: mode)

            #expect(!outcome.succeeded)
            #expect(outcome.stderr.contains("\(code)"))
            let transcript = try fixture.transcript()
            #expect(
                transcript.map(\.method) == ["server/discover"],
                "\(code) must block the legacy fallback outright."
            )
        }
    }

    @Test func unsupportedVersionErrorWithASharedVersionFallsBackToLegacyInitialize() async throws {
        // The upstream's advertised list and the versions our legacy initialize
        // implements overlap, so the bridge renegotiates instead of failing.
        let expectedVersions = [
            "renegotiate-oldest-pair": "2025-06-18",
            "renegotiate-newest": "2025-11-25",
            "renegotiate-beyond-saved": "2025-11-25"
        ]
        for (mode, expectedVersion) in expectedVersions {
            let fixture = try StdioProtocolFixture()
            defer { fixture.remove() }

            let outcome = try await fixture.call(mode: mode)

            #expect(outcome.succeeded, "\(mode) should have connected over legacy.")
            let transcript = try fixture.transcript()
            #expect(transcript.map(\.method) == [
                "server/discover", "initialize", "notifications/initialized", "tools/call"
            ])
            #expect(
                transcript[1].params["protocolVersion"] as? String == expectedVersion,
                "\(mode) must request the newest mutually supported version."
            )
            #expect(
                transcript[3].params["_meta"] == nil,
                "The renegotiated session must speak legacy, not modern."
            )
        }
    }

    @Test func unsupportedVersionErrorWithNoSharedVersionStillFailsClosed() async throws {
        for mode in [
            "unsupported-empty-list",
            "unsupported-string-list",
            "unsupported-disjoint"
        ] {
            let fixture = try StdioProtocolFixture()
            defer { fixture.remove() }

            let outcome = try await fixture.call(mode: mode)

            #expect(!outcome.succeeded, "\(mode) must not connect.")
            #expect(outcome.stderr.contains("-32022"))
            let transcript = try fixture.transcript()
            #expect(
                transcript.map(\.method) == ["server/discover"],
                "\(mode) must not attempt a legacy initialize."
            )
        }
    }

    @Test func concurrentSemanticNegotiationsRemainSessionIsolated() async throws {
        let modes = ["renegotiate-newest", "unsupported-disjoint"]
        let observations = try await withThrowingTaskGroup(
            of: StdioNegotiationObservation.self
        ) { group in
            for _ in 0..<8 {
                for mode in modes {
                    group.addTask {
                        let fixture = try StdioProtocolFixture()
                        defer { fixture.remove() }
                        let outcome = try await fixture.call(mode: mode)
                        let transcript = try fixture.transcript()
                        return StdioNegotiationObservation(
                            mode: mode,
                            succeeded: outcome.succeeded,
                            methods: transcript.map(\.method),
                            initializedVersion: transcript.first { $0.method == "initialize" }?
                                .params["protocolVersion"] as? String
                        )
                    }
                }
            }

            var collected: [StdioNegotiationObservation] = []
            for try await observation in group {
                collected.append(observation)
            }
            return collected
        }

        #expect(observations.count == 16)
        for observation in observations {
            if observation.mode == "renegotiate-newest" {
                #expect(observation.succeeded)
                #expect(observation.initializedVersion == "2025-11-25")
                #expect(observation.methods == [
                    "server/discover", "initialize", "notifications/initialized", "tools/call"
                ])
            } else {
                #expect(!observation.succeeded)
                #expect(observation.initializedVersion == nil)
                #expect(observation.methods == ["server/discover"])
            }
        }
    }

    @Test func discoverResultAdvertisingOnlyLegacyVersionsFallsBackToLegacyInitialize()
        async throws
    {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let outcome = try await fixture.call(mode: "legacy-only-result")

        #expect(outcome.succeeded)
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == [
            "server/discover", "initialize", "notifications/initialized", "tools/call"
        ])
        #expect(transcript[1].params["protocolVersion"] as? String == "2025-11-25")
        #expect(transcript[3].params["_meta"] == nil)
    }

    @Test func discoverResultAdvertisingNoImplementedVersionStillFailsClosed() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let outcome = try await fixture.call(mode: "legacy-only-result-disjoint")

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("2099-01-01"))
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == ["server/discover"])
    }

    @Test func consecutiveCallsReuseTheWarmUpstreamProcess() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let first = try await fixture.call(mode: "modern")
        let firstProcessIDs = try await fixture.waitForProcessIDs()
        let second = try await fixture.call(mode: "modern")
        let secondProcessIDs = try await fixture.waitForProcessIDs()

        #expect(first.succeeded)
        #expect(second.succeeded)
        #expect(firstProcessIDs == secondProcessIDs)
        // One handshake, two calls: the second call skipped server/discover.
        let transcript = try fixture.transcript()
        #expect(transcript.map(\.method) == ["server/discover", "tools/call", "tools/call"])
        #expect(MCPStdioSessionPool.shared.idleCount == 1)
    }

    @Test func aChangedExecutableStartsAFreshUpstreamProcess() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        _ = try await fixture.call(mode: "modern")
        let firstProcessIDs = try await fixture.waitForProcessIDs()
        // Simulate a CLI upgrade: same path, different mtime.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)],
            ofItemAtPath: fixture.serverPath
        )
        _ = try await fixture.call(mode: "modern")
        let secondProcessIDs = try await fixture.waitForProcessIDs()

        #expect(firstProcessIDs != secondProcessIDs)
        try await fixture.waitForProcessesToExit(firstProcessIDs)
    }

    @Test func probeNeverReusesAWarmSessionAndEvictsIt() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        _ = try await fixture.call(mode: "modern")
        #expect(MCPStdioSessionPool.shared.idleCount == 1)
        let warmProcessIDs = try await fixture.waitForProcessIDs()
        _ = try await fixture.probe(mode: "modern", timeoutSeconds: 10)

        #expect(MCPStdioSessionPool.shared.idleCount == 0)
        try await fixture.waitForProcessesToExit(warmProcessIDs)
    }

    /// Opt-in benchmark against the installed RemCTL MCP server. Prints cold and
    /// warm call durations; asserts only that the warm calls reused the process.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MR_STDIO_BENCH"] == "1"))
    func warmSessionBenchmarkAgainstInstalledRemCTL() async throws {
        let executable = try #require(FirstPartyMCPProviderCatalog.detectedExecutablePath(
            for: FirstPartyMCPProviderCatalog.remCTL
        ))
        let tool = ToolDefinition(
            id: "remctl_lists",
            name: "Reminder Lists",
            summary: "Benchmark.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 30,
            outputByteLimit: 4 * 1024 * 1024,
            origin: .userDefined,
            category: .reminders,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                serverName: "RemCTL",
                command: executable,
                args: ["mcp"],
                toolName: "lists",
                protocolVersion: "2025-06-18"
            )
        )
        let client = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        let pool = MCPStdioSessionPool.shared
        pool.drain()
        var durations: [TimeInterval] = []
        for _ in 0..<4 {
            let started = Date()
            let outcome = try await client.call(tool: tool, parameters: [:])
            durations.append(Date().timeIntervalSince(started))
            #expect(outcome.succeeded, "\(outcome.stderr)")
        }
        let formatted = durations.map { String(format: "%.0f ms", $0 * 1000) }.joined(separator: ", ")
        print("MR_STDIO_BENCH remctl lists: cold then warm = \(formatted); reuses = \(pool.reuseCount)")
        #expect(pool.reuseCount == 3)
        pool.drain()
    }

    @Test func cancellingDelayedCallStopsTheStdioServerPromptly() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let task = Task {
            try await fixture.call(
                mode: "delayed-call",
                startupTimeout: 2,
                toolTimeout: 30
            )
        }
        let processIDs = try await fixture.waitForProcessIDs()
        try await fixture.waitForMethod("tools/call")
        let cancelledAt = Date()
        task.cancel()

        var observedCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            observedCancellation = true
        }
        try await fixture.waitForProcessesToExit(processIDs)

        #expect(observedCancellation)
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
    }

    @Test func cancellingDelayedProbeStopsTheStdioServerPromptly() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let task = Task {
            try await fixture.probe(mode: "delayed-probe", timeoutSeconds: 30)
        }
        let processIDs = try await fixture.waitForProcessIDs()
        try await fixture.waitForMethod("server/discover")
        let cancelledAt = Date()
        task.cancel()
        _ = try? await task.value
        try await fixture.waitForProcessesToExit(processIDs)

        #expect(Date().timeIntervalSince(cancelledAt) < 2)
    }

    /// Swift's async runtime has about one thread per CPU core. Waiting on a
    /// server that does not answer must not hold any of them.
    @Test func unansweredCallsLeaveSwiftsAsyncThreadsFree() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let calls = (0..<ProcessInfo.processInfo.activeProcessorCount + 2).map { _ in
            Task {
                try await fixture.call(mode: "delayed-call", startupTimeout: 20, toolTimeout: 4)
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        try await Task.sleep(for: .milliseconds(300))
        await Task.detached {}.value
        let waited = clock.now - started
        for call in calls {
            call.cancel()
        }
        for call in calls {
            _ = try? await call.value
        }

        #expect(waited < .seconds(2))
    }

    /// A request larger than a pipe holds blocks its writer until the server
    /// reads it. A server that stops reading must still hit the tool timeout.
    @Test func aServerThatStopsReadingItsInputStillTimesOut() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let call = Task {
            try await fixture.call(
                mode: "deaf-call",
                toolTimeout: 1,
                query: String(repeating: "x", count: 1024 * 1024)
            )
        }
        // If the timeout does not work the call never ends; cancelling lets
        // the test fail instead of hang.
        let rescue = Task {
            try await Task.sleep(for: .seconds(6))
            call.cancel()
        }
        let outcome = try? await call.value
        rescue.cancel()

        #expect(outcome?.timedOut == true)
    }

    @Test func cancellationKillsNonCooperativeStdioProcessGroup() async throws {
        let fixture = try StdioProtocolFixture()
        defer { fixture.remove() }

        let task = Task {
            try await fixture.call(
                mode: "stubborn-group",
                startupTimeout: 2,
                toolTimeout: 30
            )
        }
        let processIDs = try await fixture.waitForProcessIDs()
        try await fixture.waitForMethod("tools/call")
        let cancelledAt = Date()
        task.cancel()

        var observedCancellation = false
        do {
            _ = try await task.value
        } catch is CancellationError {
            observedCancellation = true
        }
        try await fixture.waitForProcessesToExit(processIDs)

        #expect(observedCancellation)
        #expect(Date().timeIntervalSince(cancelledAt) < 2)
    }
}

private struct StdioTranscriptEntry {
    let method: String
    let params: [String: Any]
}

private struct StdioNegotiationObservation: Sendable {
    let mode: String
    let succeeded: Bool
    let methods: [String]
    let initializedVersion: String?
}

private final class StdioProtocolFixture: @unchecked Sendable {
    private let directory: URL
    private let serverURL: URL
    private let transcriptURL: URL
    private let terminationURL: URL
    private let processIDsURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-stdio-\(UUID().uuidString)", isDirectory: true)
        serverURL = directory.appendingPathComponent("server.py")
        transcriptURL = directory.appendingPathComponent("transcript.jsonl")
        terminationURL = directory.appendingPathComponent("terminated")
        processIDsURL = directory.appendingPathComponent("processes.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.serverScript.utf8).write(to: serverURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: serverURL.path
        )
    }

    func remove() {
        // Warm sessions keyed on this fixture's script must not outlive it.
        MCPStdioSessionPool.shared.drain()
        try? FileManager.default.removeItem(at: directory)
    }

    func call(
        mode: String,
        // Semantic protocol tests must not turn ordinary host load into the
        // product's intentional discover-timeout fallback. Timing-specific
        // tests pass their own tight startup or tool timeout below.
        startupTimeout: TimeInterval = 10,
        toolTimeout: TimeInterval = 10,
        query: String = "hello"
    ) async throws -> ToolExecutionOutcome {
        let tool = ToolDefinition(
            id: "stdio_protocol_\(mode)",
            name: "Stdio protocol \(mode)",
            summary: "Test upstream protocol negotiation.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: toolTimeout,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                serverName: "fixture",
                command: serverURL.path,
                args: [
                    mode,
                    transcriptURL.path,
                    terminationURL.path,
                    processIDsURL.path
                ],
                startupTimeoutSeconds: startupTimeout,
                toolName: "echo",
                protocolVersion: "2025-06-18"
            )
        )
        return try await MCPStdioBridgeClient(
            environment: ProcessInfo.processInfo.environment
        ).call(
            tool: tool,
            parameters: ["query": .string(query)]
        )
    }

    func probe(
        mode: String,
        timeoutSeconds: TimeInterval
    ) async throws -> LocalMCPProbeResult {
        try await MCPStdioBridgeClient(
            environment: ProcessInfo.processInfo.environment
        ).probe(
            command: serverURL.path,
            args: [
                mode,
                transcriptURL.path,
                terminationURL.path,
                processIDsURL.path
            ],
            environmentVariables: [],
            protocolVersion: "2025-06-18",
            timeoutSeconds: timeoutSeconds
        )
    }

    var serverPath: String { serverURL.path }

    func transcript() throws -> [StdioTranscriptEntry] {
        let text = try String(contentsOf: transcriptURL, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }
            return StdioTranscriptEntry(
                method: object["method"] as? String ?? "",
                params: object["params"] as? [String: Any] ?? [:]
            )
        }
    }

    func waitForMethod(_ method: String) async throws {
        try await waitUntil {
            (try? self.transcript().contains { $0.method == method }) == true
        }
    }

    func waitForProcessIDs() async throws -> [pid_t] {
        var processIDs: [pid_t]?
        try await waitUntil {
            guard let data = try? Data(contentsOf: self.processIDsURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Int],
                  let parent = object["parent"] else {
                return false
            }
            processIDs = [pid_t(parent)]
            if let child = object["child"] {
                processIDs?.append(pid_t(child))
            }
            return true
        }
        return processIDs ?? []
    }

    func waitForProcessesToExit(_ processIDs: [pid_t]) async throws {
        try await waitUntil {
            processIDs.allSatisfy { processID in
                kill(processID, 0) != 0 && errno == ESRCH
            }
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: 2)
        while !condition() {
            guard Date() < deadline else {
                throw StdioProtocolFixtureError.waitTimedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static let serverScript = """
    #!/usr/bin/env python3
    import json
    import os
    import signal
    import subprocess
    import sys
    import time

    mode = sys.argv[1]
    transcript_path = sys.argv[2]
    termination_path = sys.argv[3]
    process_ids_path = sys.argv[4]

    # -32022 rejections keyed by the data.supported payload they advertise.
    # `None` means the error carries no supported list at all.
    UNSUPPORTED_VERSION_MODES = {
        "renegotiate-oldest-pair": ["2025-03-26", "2025-06-18"],
        "renegotiate-newest": ["2025-06-18", "2025-11-25", "2025-03-26"],
        "renegotiate-beyond-saved": ["2025-11-25", "2025-03-26"],
        "unsupported-empty-list": [],
        "unsupported-string-list": "2025-06-18",
        "unsupported-disjoint": ["2099-01-01"],
    }

    # Reserved modern rejections that must never downgrade, whatever they carry.
    RESERVED_ERROR_MODES = {
        "header-mismatch": -32020,
        "missing-capability": -32021,
    }

    # server/discover results that succeed but advertise no modern version.
    LEGACY_ONLY_RESULT_MODES = {
        "legacy-only-result": ["2025-11-25", "2025-06-18"],
        "legacy-only-result-disjoint": ["2099-01-01"],
    }

    def terminate(_signal, _frame):
        with open(termination_path, "w", encoding="utf-8") as status:
            status.write("terminated")
        sys.exit(0)

    signal.signal(signal.SIGTERM, terminate)

    process_ids = {"parent": os.getpid()}
    if mode == "stubborn-group":
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        child_code = '''
    import signal
    import time
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    time.sleep(60)
    '''
        child = subprocess.Popen([sys.executable, "-c", child_code])
        process_ids["child"] = child.pid
    with open(process_ids_path, "w", encoding="utf-8") as processes:
        json.dump(process_ids, processes)

    def reply(message):
        print(json.dumps(message, sort_keys=True), flush=True)

    for line in sys.stdin:
        message = json.loads(line)
        with open(transcript_path, "a", encoding="utf-8") as transcript:
            transcript.write(json.dumps(message, sort_keys=True) + "\\n")

        method = message.get("method")
        if method == "server/discover":
            if mode == "delayed-probe":
                continue
            if mode == "modern":
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "resultType": "complete",
                        "supportedVersions": ["2026-07-28"],
                        "capabilities": {},
                        "_meta": {
                            "io.modelcontextprotocol/serverInfo": {
                                "name": "modern-stdio",
                                "version": "2.0.0"
                            }
                        }
                    }
                })
            elif mode == "recognized":
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "error": {
                        "code": -32022,
                        "message": "Unsupported protocol version"
                    }
                })
            elif mode in UNSUPPORTED_VERSION_MODES:
                error = {
                    "code": -32022,
                    "message": "Unsupported protocol version.",
                    "data": {"requested": "2026-07-28"}
                }
                supported = UNSUPPORTED_VERSION_MODES[mode]
                if supported is not None:
                    error["data"]["supported"] = supported
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "error": error
                })
            elif mode in RESERVED_ERROR_MODES:
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "error": {
                        "code": RESERVED_ERROR_MODES[mode],
                        "message": "Reserved modern rejection"
                    }
                })
            elif mode in LEGACY_ONLY_RESULT_MODES:
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "resultType": "complete",
                        "supportedVersions": LEGACY_ONLY_RESULT_MODES[mode],
                        "capabilities": {},
                        "_meta": {
                            "io.modelcontextprotocol/serverInfo": {
                                "name": "legacy-only-stdio",
                                "version": "1.5.0"
                            }
                        }
                    }
                })
            elif mode == "unrecognized":
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "error": {
                        "code": -32601,
                        "message": "Method not found"
                    }
                })
            elif mode in ("delayed-call", "stubborn-group", "deaf-call"):
                reply({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "resultType": "complete",
                        "supportedVersions": ["2026-07-28"],
                        "capabilities": {}
                    }
                })
            if mode == "deaf-call":
                # Answered the handshake; now stop reading input for good.
                time.sleep(60)
            continue

        if method == "tools/list":
            reply({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {"resultType": "complete", "tools": []}
            })
        elif method == "initialize":
            requested = (message.get("params") or {}).get("protocolVersion")
            reply({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "protocolVersion": requested or "2025-06-18",
                    "serverInfo": {"name": "legacy-stdio", "version": "1.0.0"},
                    "capabilities": {}
                }
            })
        elif method == "tools/call":
            if mode in ("delayed-call", "stubborn-group"):
                time.sleep(30)
            reply({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "resultType": "complete",
                    "content": [{"type": "text", "text": "ok"}],
                    "structuredContent": {
                        "mode": "modern" if mode == "modern" else "legacy"
                    }
                }
            })
    """
}

private enum StdioProtocolFixtureError: Error {
    case waitTimedOut
}
