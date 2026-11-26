import Foundation
import Testing
@testable import MacRemote

/// The MCP Tasks extension (`io.modelcontextprotocol/tasks`, SPEC D81), as an
/// app sees it. A modern request that declares the extension can get a task
/// instead of a result; every other request is answered as it always was.
@Suite(.serialized)
struct TasksExtensionTests {
    private static let tasksExtension = "io.modelcontextprotocol/tasks"
    private static var withTasks: [String: Any] { ["extensions": [tasksExtension: [:]]] }

    // MARK: Apps that do not use the extension

    @Test func legacySessionsNeverSeeTasks() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .legacy(clientCapabilities: Self.withTasks))

        let initialized = try await client.initializeLegacy()
        let capabilities = try #require(initialized.result?["capabilities"] as? [String: Any])
        #expect(capabilities["tasks"] == nil)
        #expect((capabilities["extensions"] as? [String: Any])?[Self.tasksExtension] == nil)

        let called = try await harness.whileHeld {
            try await client.send(
                method: "tools/call",
                params: ["name": "test_slow", "arguments": [:], "task": ["ttl": 60_000]]
            )
        }
        try expectSynchronousResult(called, toolID: "test_slow")

        for method in ["tasks/get", "tasks/update", "tasks/cancel", "tasks/list", "tasks/result"] {
            let response = try await client.send(method: method, params: ["taskId": "legacy-task-id"])
            #expect(response.statusCode == 200)
            #expect(response.error?["code"] as? Int == -32601)
        }
    }

    @Test func modernCallsWithoutTheExtensionStaySynchronous() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()

        // The 2025-11-25 experimental `capabilities.tasks` is a different,
        // incompatible generation and does not count.
        let capabilitySets: [[String: Any]] = [
            [:],
            ["tasks": ["requests": ["tools": ["call": [:]]]]]
        ]
        for capabilities in capabilitySets {
            let client = harness.client(mode: .modern(clientCapabilities: capabilities))
            let called = try await harness.whileHeld {
                try await client.send(
                    method: "tools/call",
                    params: ["name": "test_slow", "arguments": [:], "task": ["ttl": 60_000]]
                )
            }
            try expectSynchronousResult(called, toolID: "test_slow")
        }
    }

    @Test func taskMethodsNeedTheExtensionOnTheRequest() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern())

        for method in ["tasks/get", "tasks/update", "tasks/cancel"] {
            let response = try await client.send(method: method, params: ["taskId": "any-task"])
            #expect(response.statusCode == 400)
            let error = try #require(response.error)
            #expect(error["code"] as? Int == -32021)
            let required = (error["data"] as? [String: Any])?["requiredCapabilities"] as? [String: Any]
            #expect((required?["extensions"] as? [String: Any])?[Self.tasksExtension] != nil)
        }
    }

    // MARK: Apps that use the extension

    @Test func discoveryAdvertisesTheExtension() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()

        let discovered = try await harness.client(mode: .modern()).discover()
        let capabilities = try #require(discovered.result?["capabilities"] as? [String: Any])
        let extensions = try #require(capabilities["extensions"] as? [String: Any])
        #expect(extensions[Self.tasksExtension] as? [String: Any] != nil)
    }

    @Test func aFastCallIsAnsweredInItsRequest() async throws {
        let harness = try TasksHarness(grace: .seconds(5))
        defer { harness.server.stop() }
        try await harness.waitUntilReady()

        let called = try await harness.client(mode: .modern(clientCapabilities: Self.withTasks))
            .callTool("test_echo")
        try expectSynchronousResult(called, toolID: "test_echo")
    }

    @Test func aSlowCallBecomesATaskThatCompletesWithTheSameResult() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))

        let created = try await client.callTool("test_slow")
        let task = try #require(created.result)
        #expect(created.statusCode == 200)
        #expect(task["resultType"] as? String == "task")
        #expect(task["status"] as? String == "working")
        let taskID = try #require(task["taskId"] as? String)
        #expect(taskID.count >= 32 && taskID.count <= 128)
        #expect(taskID.allSatisfy { $0.isASCII && !$0.isWhitespace })
        #expect(task["createdAt"] is String && task["lastUpdatedAt"] is String)
        #expect(task["pollIntervalMs"] as? Int == 2000)
        #expect(task["ttlMs"] as? Int == (2 + 3600) * 1000)

        let polled = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(polled.result?["resultType"] as? String == "complete")
        #expect(polled.result?["status"] as? String == "working")

        harness.gate.open()
        let completed = try await poll(client, taskID: taskID, until: "completed")
        let taskResult = try #require(completed["result"] as? [String: Any])
        #expect((completed["ttlMs"] as? Int ?? 0) >= 3600 * 1000)

        let synchronous = try await harness.client(mode: .modern()).callTool("test_slow")
        let expected = try #require(synchronous.result)
        #expect(NSDictionary(dictionary: taskResult["structuredContent"] as? [String: Any] ?? [:])
            == NSDictionary(dictionary: expected["structuredContent"] as? [String: Any] ?? [:]))
        #expect(NSArray(array: taskResult["content"] as? [Any] ?? [])
            == NSArray(array: expected["content"] as? [Any] ?? []))
        #expect(taskResult["isError"] as? Bool == false)
    }

    @Test func aLongRunningToolStartsAsATaskAndShowsTheApprovalWait() async throws {
        let harness = try TasksHarness(grace: .seconds(30))
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))
        harness.gate.open()

        let created = try await client.callTool("test_flagged_write")
        #expect(created.result?["resultType"] as? String == "task")
        let taskID = try #require(created.result?["taskId"] as? String)

        let waiting = try await poll(client, taskID: taskID) {
            $0["statusMessage"] as? String == "Waiting for approval on the Mac"
        }
        #expect(waiting["status"] as? String == "working")
        var approval = harness.approvals.approvalSnapshot().first { $0.state == .pending }
        for _ in 0..<200 where approval == nil {
            try await Task.sleep(for: .milliseconds(10))
            approval = harness.approvals.approvalSnapshot().first { $0.state == .pending }
        }
        #expect(harness.approvals.approve(requestID: try #require(approval).id))

        let completed = try await poll(client, taskID: taskID, until: "completed")
        let result = try #require(completed["result"] as? [String: Any])
        #expect((result["structuredContent"] as? [String: Any])?["stdout"] as? String == "executed:test_flagged_write")
    }

    @Test func runInBackgroundStartsAFlexibleCommandAsATaskAndNeverReachesIt() async throws {
        let harness = try TasksHarness(grace: .seconds(30))
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))

        let listed = try await client.listTools()
        let tools = try #require(listed.result?["tools"] as? [[String: Any]])
        func properties(_ name: String) -> [String: Any]? {
            let tool = tools.first { $0["name"] as? String == name }
            return (tool?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        }
        #expect((properties("test_flexible")?["run_in_background"] as? [String: Any])?["type"] as? String == "boolean")
        #expect(properties("test_slow")?["run_in_background"] == nil)

        let created = try await client.callTool(
            "test_flexible",
            arguments: ["args": ["--version"], "run_in_background": true]
        )
        #expect(created.result?["resultType"] as? String == "task")
        let taskID = try #require(created.result?["taskId"] as? String)

        harness.gate.open()
        _ = try await poll(client, taskID: taskID, until: "completed")
        let received = try #require(await harness.executor.parameters["test_flexible"])
        #expect(received["run_in_background"] == nil)
        #expect(received["args"] != nil)

        // An app without background tasks may send it too; it is ignored.
        let plain = try await harness.client(mode: .modern()).callTool(
            "test_flexible",
            arguments: ["args": ["--version"], "run_in_background": true]
        )
        try expectSynchronousResult(plain, toolID: "test_flexible")
    }

    @Test func cancellingATaskStopsItsWork() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))

        let created = try await client.callTool("test_slow")
        let taskID = try #require(created.result?["taskId"] as? String)

        let cancelled = try await client.send(method: "tasks/cancel", params: ["taskId": taskID])
        #expect(cancelled.result?["resultType"] as? String == "complete")
        #expect(cancelled.result?["status"] == nil)

        let state = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(state.result?["status"] as? String == "cancelled")
        #expect(state.result?["statusMessage"] is String)
        var stopped = await harness.executor.cancelledCount
        for _ in 0..<200 where stopped == 0 {
            try await Task.sleep(for: .milliseconds(10))
            stopped = await harness.executor.cancelledCount
        }
        #expect(stopped == 1)
    }

    @Test func anotherAppCannotReadOrCancelATask() async throws {
        let harness = try TasksHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let owner = harness.client(mode: .modern(clientCapabilities: Self.withTasks))
        let other = try harness.secondAppClient(mode: .modern(clientCapabilities: Self.withTasks))

        let created = try await owner.callTool("test_slow")
        let taskID = try #require(created.result?["taskId"] as? String)

        for method in ["tasks/get", "tasks/update", "tasks/cancel"] {
            let response = try await other.send(method: method, params: ["taskId": taskID])
            #expect(response.error?["code"] as? Int == -32602)
        }
        let unknown = try await owner.send(method: "tasks/get", params: ["taskId": "no-such-task"])
        #expect(unknown.error?["code"] as? Int == -32602)

        let stillOwned = try await owner.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(stillOwned.result?["status"] as? String == "working")
        harness.gate.open()
        _ = try await poll(owner, taskID: taskID, until: "completed")
    }

    /// A call still in its grace period stops when the server does, at once,
    /// not when the grace period would have made it a task.
    @Test func stoppingTheServerStopsACallInItsGracePeriodAtOnce() async throws {
        let harness = try TasksHarness(grace: .seconds(30))
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))

        let pending = Task { try await client.callTool("test_slow") }
        var running = await harness.executor.parameters["test_slow"] != nil
        for _ in 0..<200 where !running {
            try await Task.sleep(for: .milliseconds(10))
            running = await harness.executor.parameters["test_slow"] != nil
        }
        harness.server.stop()
        let stoppedAt = Date()

        let answered = try await pending.value
        #expect(Date().timeIntervalSince(stoppedAt) < 5)
        #expect(answered.result?["resultType"] as? String != "task", "\(answered.json)")
        var stopped = await harness.executor.cancelledCount
        for _ in 0..<200 where stopped == 0 {
            try await Task.sleep(for: .milliseconds(10))
            stopped = await harness.executor.cancelledCount
        }
        #expect(stopped == 1)
    }

    @Test func aRunInBackgroundThatIsNotABooleanIsRefusedBeforeAnythingRuns() async throws {
        let harness = try TasksHarness(grace: .seconds(30))
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        harness.gate.open()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))

        for value: Any in ["true", 1] {
            let called = try await client.callTool(
                "test_flexible",
                arguments: ["args": ["--version"], "run_in_background": value]
            )
            let result = try #require(called.result, "\(called.json)")
            #expect(result["resultType"] as? String != "task")
            #expect(result["isError"] as? Bool == true)
            #expect((result["structuredContent"] as? [String: Any])?["reason"] as? String == "invalid_argument")
        }
        #expect(await harness.executor.parameters["test_flexible"] == nil)
    }

    @Test func aFinishedTaskIsKeptForAnHourThenExpires() async throws {
        let clock = TestClock()
        let harness = try TasksHarness(now: { clock.now })
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.withTasks))

        let created = try await client.callTool("test_slow")
        let taskID = try #require(created.result?["taskId"] as? String)
        clock.advance(by: 61)
        let older = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(older.result?["pollIntervalMs"] as? Int == 10_000)

        harness.gate.open()
        let completed = try await poll(client, taskID: taskID, until: "completed")
        #expect(completed["ttlMs"] as? Int == (61 + 3600) * 1000)
        clock.advance(by: 3599)
        let kept = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(kept.result?["status"] as? String == "completed")

        clock.advance(by: 1)
        let expired = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(expired.error?["code"] as? Int == -32602)
    }
}

// MARK: - Harness

/// Polls `tasks/get` until `condition` holds, for up to ten seconds.
private func poll(
    _ client: MCPTestClient,
    taskID: String,
    until condition: ([String: Any]) -> Bool
) async throws -> [String: Any] {
    for _ in 0..<500 {
        let response = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        let task = try #require(response.result, "tasks/get failed: \(response.json)")
        if condition(task) { return task }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Task \(taskID) never reached the expected state.")
    throw CancellationError()
}

private func poll(_ client: MCPTestClient, taskID: String, until status: String) async throws -> [String: Any] {
    try await poll(client, taskID: taskID) { $0["status"] as? String == status }
}

private func expectSynchronousResult(
    _ response: MCPTestHTTPResponse,
    toolID: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(response.statusCode == 200, sourceLocation: sourceLocation)
    let result = try #require(response.result, "\(response.json)", sourceLocation: sourceLocation)
    #expect(result["resultType"] as? String != "task", sourceLocation: sourceLocation)
    #expect(result["taskId"] == nil, sourceLocation: sourceLocation)
    let structured = try #require(result["structuredContent"] as? [String: Any], sourceLocation: sourceLocation)
    #expect(structured["stdout"] as? String == "executed:\(toolID)", sourceLocation: sourceLocation)
}

/// Holds every call except `test_echo` until the test opens it, so a "slow"
/// call is slow for exactly as long as the test needs.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters = [UUID: CheckedContinuation<Void, Error>]()

    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let outcome: Result<Void, Error>? = lock.withLock {
                    if isOpen { return .success(()) }
                    if Task.isCancelled { return .failure(CancellationError()) }
                    waiters[id] = continuation
                    return nil
                }
                if let outcome { continuation.resume(with: outcome) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { waiters = [:] }
            return Array(waiters.values)
        }
        for waiter in waiting { waiter.resume() }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private actor TasksTestExecutor: ToolExecuting {
    let gate: Gate
    private(set) var parameters = [String: [String: ToolArgumentValue]]()
    private(set) var cancelledCount = 0

    init(gate: Gate) {
        self.gate = gate
    }

    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue]
    ) async throws -> ToolExecutionOutcome {
        self.parameters[toolID] = parameters
        if toolID != "test_echo" {
            do {
                try await gate.wait()
            } catch {
                cancelledCount += 1
                throw error
            }
        }
        return ToolExecutionOutcome(
            toolID: toolID,
            toolName: toolID,
            exitCode: 0,
            stdout: "executed:\(toolID)",
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct TasksHarness {
    static let instanceID = "tasks-tests"

    let server: LocalMCPServer
    let executor: TasksTestExecutor
    let approvals: ToolCallApprovalCoordinator
    let coordinator: OAuthCoordinator
    let gate: Gate
    let baseURL: URL

    private let bearerToken = "tasks-tests-token"

    init(
        grace: Duration = .milliseconds(50),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let tools = [
            Self.tool(id: "test_echo", capability: .readOnly),
            Self.tool(id: "test_slow", capability: .readOnly),
            Self.tool(id: "test_flagged_write", capability: .write),
            ToolDefinition(
                id: "test_flexible",
                name: "test_flexible",
                summary: "A Flexible Command.",
                executablePath: "/usr/bin/true",
                argumentPattern: ["{args}"],
                parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024,
                origin: .userDefined
            )
        ]
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(bearerToken, clientName: "Tasks Probe")
        // A Flexible Command asks first; this app has Always Allow for it.
        let suiteName = "MacRemoteTasksTests.\(UUID().uuidString)"
        let permissions = ClientToolPermissionStore(userDefaults: UserDefaults(suiteName: suiteName) ?? .standard)
        _ = permissions.replaceAllowedTools(
            tools.filter { $0.id == "test_flexible" },
            clientTrustID: OAuthCoordinator.staticHeaderClientID
        )
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        let gate = Gate()
        let executor = TasksTestExecutor(gate: gate)
        let approvals = ToolCallApprovalCoordinator(timeoutSeconds: 30)
        let server = LocalMCPServer(
            instanceID: Self.instanceID,
            tools: tools,
            longRunningTools: { ["test_flagged_write"] },
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: approvals,
            toolExecutor: executor,
            clientToolPermissionStore: permissions,
            toolCallTasks: ToolCallTaskStore(grace: grace, now: now)
        )
        let port = try server.start()
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            server.stop()
            throw URLError(.badURL)
        }
        self.server = server
        self.executor = executor
        self.approvals = approvals
        self.coordinator = coordinator
        self.gate = gate
        self.baseURL = baseURL
    }

    private static func tool(id: String, capability: ToolCapability) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: id,
            summary: "A tool for Tasks tests.",
            executablePath: "/usr/bin/true",
            argumentPattern: [],
            parameters: [],
            capability: capability,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            origin: .userDefined
        )
    }

    var endpoint: URL {
        baseURL.appendingPathComponent("mcp").appendingPathComponent(Self.instanceID)
    }

    func waitUntilReady() async throws {
        let healthURL = baseURL.appendingPathComponent("health")
        for _ in 0..<45 {
            if let (_, response) = try? await URLSession.shared.data(from: healthURL),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw URLError(.timedOut)
    }

    func client(mode: MCPTestProtocolMode) -> MCPTestClient {
        MCPTestClient(baseURL: endpoint, bearerToken: bearerToken, mode: mode)
    }

    /// A second app, signed in with Dynamic OAuth.
    func secondAppClient(mode: MCPTestProtocolMode) throws -> MCPTestClient {
        try dynamicOAuthTestClient(coordinator: coordinator, baseURL: baseURL, endpoint: endpoint, mode: mode)
    }

    /// Runs `call` and opens the gate only well after a task would have been
    /// made, so an answer that arrives with a result proves no task was made.
    func whileHeld(_ call: @escaping @Sendable () async throws -> MCPTestHTTPResponse) async throws -> MCPTestHTTPResponse {
        let pending = Task { try await call() }
        try await Task.sleep(for: .milliseconds(300))
        gate.open()
        return try await pending.value
    }
}
