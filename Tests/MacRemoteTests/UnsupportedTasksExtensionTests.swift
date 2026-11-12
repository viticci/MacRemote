import Foundation
import Testing
@testable import MacRemote

/// MacRemote does not implement the MCP Tasks extension. A client that asks
/// for it anyway gets the ordinary synchronous result and the ordinary
/// unknown-method error.
@Suite(.serialized)
struct UnsupportedTasksExtensionTests {
    @Test func legacyInitializationAndToolListingDoNotAdvertiseTasks() async throws {
        let harness = try LegacyTaskFallbackHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .legacy())

        let initialized = try await client.initializeLegacy()
        #expect(initialized.statusCode == 200)
        let initializeResult = try #require(initialized.result)
        let capabilities = try #require(initializeResult["capabilities"] as? [String: Any])
        #expect(capabilities["tasks"] == nil)

        let listed = try await client.listTools()
        #expect(listed.statusCode == 200)
        let listResult = try #require(listed.result)
        let tools = try #require(listResult["tools"] as? [[String: Any]])
        let tool = try #require(tools.first { $0["name"] as? String == "test_echo" })
        let execution = tool["execution"] as? [String: Any]
        #expect(execution?["taskSupport"] == nil)
    }

    @Test func legacyTaskMetadataIsIgnoredAndToolExecutesOnceSynchronously() async throws {
        let harness = try LegacyTaskFallbackHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .legacy())

        let response = try await client.send(
            method: "tools/call",
            params: [
                "name": "test_echo",
                "arguments": ["value": "legacy-task"],
                "task": ["ttl": 60_000]
            ],
            id: "legacy-task-call"
        )

        try expectSynchronousToolResult(response, expectedStdout: "executed:legacy-task")
        let invocationCount = await harness.executor.invocationCount
        #expect(invocationCount == 1)
    }

    @Test func legacyTaskMethodsRemainUnavailable() async throws {
        let harness = try LegacyTaskFallbackHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .legacy())

        let probes: [(method: String, params: [String: Any])] = [
            ("tasks/get", ["taskId": "legacy-task-id"]),
            ("tasks/result", ["taskId": "legacy-task-id"]),
            ("tasks/list", [:]),
            ("tasks/cancel", ["taskId": "legacy-task-id"])
        ]

        for probe in probes {
            let response = try await client.send(
                method: probe.method,
                params: probe.params,
                id: probe.method
            )
            #expect(response.statusCode == 200)
            let error = try #require(response.error)
            #expect(error["code"] as? Int == -32601)
        }
    }

    @Test func modernCallsWithoutTheTasksExtensionNeverReceiveTasks() async throws {
        let harness = try LegacyTaskFallbackHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()

        let modernCapabilities: [[String: Any]] = [
            ["tools": [:]],
            [
                "tools": [:],
                "tasks": [
                    "list": [:],
                    "cancel": [:],
                    "requests": [
                        "tools": ["call": [:]]
                    ]
                ]
            ]
        ]

        for (index, capabilities) in modernCapabilities.enumerated() {
            let client = harness.client(
                mode: .modern(clientCapabilities: capabilities)
            )
            var params: [String: Any] = [
                "name": "test_echo",
                "arguments": ["value": "modern-\(index)"]
            ]
            if index == 1 {
                params["task"] = ["ttl": 60_000]
            }

            let response = try await client.send(
                method: "tools/call",
                params: params,
                id: "modern-\(index)"
            )
            try expectSynchronousToolResult(response, expectedStdout: "executed:modern-\(index)")
        }

        let invocationCount = await harness.executor.invocationCount
        #expect(invocationCount == 2)
    }

    @Test func modernClientOfferingTasksGetsNoExtensionNoTaskAndNoTaskMethods() async throws {
        let harness = try LegacyTaskFallbackHarness()
        defer { harness.server.stop() }
        try await harness.waitUntilReady()
        let tasksExtension = "io.modelcontextprotocol/tasks"
        let client = harness.client(
            mode: .modern(
                clientCapabilities: [
                    "tools": [:],
                    "extensions": [tasksExtension: [:]]
                ]
            )
        )

        let discovered = try await client.discover()
        #expect(discovered.statusCode == 200)
        let capabilities = try #require(
            discovered.result?["capabilities"] as? [String: Any]
        )
        let extensions = try #require(capabilities["extensions"] as? [String: Any])
        #expect(extensions[tasksExtension] == nil)

        let called = try await client.send(
            method: "tools/call",
            params: [
                "name": "test_echo",
                "arguments": ["value": "offered"],
                "task": ["ttl": 60_000]
            ],
            id: "offered"
        )
        try expectSynchronousToolResult(called, expectedStdout: "executed:offered")
        let invocationCount = await harness.executor.invocationCount
        #expect(invocationCount == 1)

        for method in ["tasks/get", "tasks/update", "tasks/cancel", "tasks/list", "tasks/result"] {
            let response = try await client.send(
                method: method,
                params: ["taskId": "task-1"],
                id: method
            )
            #expect(response.statusCode == 404)
            let error = try #require(response.error)
            #expect(error["code"] as? Int == -32601)
        }
    }
}

private actor LegacyTaskCountingExecutor: ToolExecuting {
    private(set) var invocationCount = 0

    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue]
    ) async throws -> ToolExecutionOutcome {
        invocationCount += 1
        return ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Echo",
            exitCode: 0,
            stdout: "executed:\(parameters["value"]?.stringValue ?? "")",
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct LegacyTaskFallbackHarness {
    let server: LocalMCPServer
    let executor: LegacyTaskCountingExecutor
    let baseURL: URL

    private let bearerToken = "legacy-task-fallback-token"

    init() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(
            bearerToken,
            clientName: "Legacy Tasks Probe"
        )
        let executor = LegacyTaskCountingExecutor()
        let server = LocalMCPServer(
            instanceID: "legacy-task-fallback",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a value for protocol compatibility tests.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [
                        ToolParameter(
                            name: "value",
                            title: "Value",
                            kind: .string,
                            maximumLength: 64
                        )
                    ],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024,
                    origin: .userDefined
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: executor
        )
        let port = try server.start()
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            server.stop()
            throw URLError(.badURL)
        }

        self.server = server
        self.executor = executor
        self.baseURL = baseURL
    }

    func waitUntilReady() async throws {
        let healthURL = baseURL.appendingPathComponent("health")
        var delayNanoseconds: UInt64 = 20_000_000
        var lastError: Error?

        for _ in 0..<45 {
            do {
                let (_, response) = try await URLSession.shared.data(from: healthURL)
                if (response as? HTTPURLResponse)?.statusCode == 200 {
                    return
                }
            } catch {
                lastError = error
            }
            try await Task.sleep(nanoseconds: delayNanoseconds)
            delayNanoseconds = min(delayNanoseconds * 3 / 2, 300_000_000)
        }

        throw lastError ?? URLError(.timedOut)
    }

    func client(mode: MCPTestProtocolMode) -> MCPTestClient {
        MCPTestClient(
            baseURL: baseURL
                .appendingPathComponent("mcp")
                .appendingPathComponent("legacy-task-fallback"),
            bearerToken: bearerToken,
            mode: mode
        )
    }
}

private func expectSynchronousToolResult(
    _ response: MCPTestHTTPResponse,
    expectedStdout: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(response.statusCode == 200, sourceLocation: sourceLocation)
    #expect(response.json["error"] == nil, sourceLocation: sourceLocation)

    let result = try #require(
        response.json["result"] as? [String: Any],
        sourceLocation: sourceLocation
    )
    #expect(result["resultType"] as? String != "task", sourceLocation: sourceLocation)
    #expect(result["task"] == nil, sourceLocation: sourceLocation)
    #expect(result["content"] != nil, sourceLocation: sourceLocation)

    let structuredContent = try #require(
        result["structuredContent"] as? [String: Any],
        sourceLocation: sourceLocation
    )
    #expect(
        structuredContent["stdout"] as? String == expectedStdout,
        sourceLocation: sourceLocation
    )
}
