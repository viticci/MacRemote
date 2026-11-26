import Foundation
import Testing
@testable import MacRemote

/// A bridged server's questions, as the app that made the call sees them
/// (SPEC D82). The upstream is a real legacy stdio server that asks one
/// question with `elicitation/create` and reports the answer it got back.
@Suite(.serialized)
struct ElicitationRelayTests {
    private static let tasksExtension = "io.modelcontextprotocol/tasks"
    private static var tasksAndForms: [String: Any] {
        ["extensions": [tasksExtension: [:]], "elicitation": ["form": [:]]]
    }
    private static var formsOnly: [String: Any] { ["elicitation": [:]] }
    private static var blue: [String: Any] { ["action": "accept", "content": ["color": "blue"]] }

    @Test func aTasksAppSeesTheQuestionAndAnswersWithTasksUpdate() async throws {
        let harness = try RelayHarness()
        defer { harness.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.tasksAndForms))

        let created = try await client.callTool("fixture_ask")
        let task = try #require(created.result, "\(created.json)")
        #expect(task["resultType"] as? String == "task")
        #expect(task["status"] as? String == "input_required")
        let taskID = try #require(task["taskId"] as? String)
        let (key, question) = try #require(Self.onlyRequest(in: task))
        #expect(question["method"] as? String == "elicitation/create")
        let params = try #require(question["params"] as? [String: Any])
        #expect(params["message"] as? String == "[fixture] Pick a color.")
        #expect(NSDictionary(dictionary: params["requestedSchema"] as? [String: Any] ?? [:])
            == NSDictionary(dictionary: AskingMCPServer.colorSchema))

        let polled = try await client.send(method: "tasks/get", params: ["taskId": taskID])
        #expect(polled.result?["status"] as? String == "input_required")
        for malformed: Any? in [nil, false, [Any]()] {
            var params: [String: Any] = ["taskId": taskID]
            params["inputResponses"] = malformed
            let refused = try await client.send(method: "tasks/update", params: params)
            #expect(refused.error?["code"] as? Int == -32602)
        }

        let updated = try await client.send(
            method: "tasks/update",
            params: ["taskId": taskID, "inputResponses": [key: Self.blue]]
        )
        #expect(updated.result?["resultType"] as? String == "complete")
        let completed = try await pollTask(client, taskID: taskID) { $0["status"] as? String == "completed" }
        let answers = try Self.upstreamAnswers(in: try #require(completed["result"] as? [String: Any]))
        #expect(answers.count == 1)
        #expect(NSDictionary(dictionary: answers[0]) == NSDictionary(dictionary: Self.blue))
    }

    @Test func anElicitationAppAnswersBySendingTheCallAgain() async throws {
        let harness = try RelayHarness()
        defer { harness.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.formsOnly))

        let first = try await client.callTool("fixture_ask")
        let asked = try #require(first.result, "\(first.json)")
        #expect(asked["resultType"] as? String == "input_required")
        let requestState = try #require(asked["requestState"] as? String)
        let (key, question) = try #require(Self.onlyRequest(in: asked))
        #expect((question["params"] as? [String: Any])?["message"] as? String == "[fixture] Pick a color.")

        let retry: [String: Any] = [
            "name": "fixture_ask",
            "arguments": [String: Any](),
            "requestState": requestState,
            "inputResponses": [key: Self.blue]
        ]
        let final = try await client.send(method: "tools/call", params: retry)
        let result = try #require(final.result, "\(final.json)")
        #expect(result["resultType"] as? String == "complete")
        let answers = try Self.upstreamAnswers(in: result)
        #expect(NSDictionary(dictionary: answers.first ?? [:]) == NSDictionary(dictionary: Self.blue))

        let reused = try await client.send(method: "tools/call", params: retry)
        #expect(reused.error?["code"] as? Int == -32602)
    }

    @Test func whenNobodyCanAnswerTheUpstreamIsDeclinedAndTheCallFinishes() async throws {
        let harness = try RelayHarness()
        defer { harness.stop() }
        try await harness.waitUntilReady()
        let legacy = harness.client(mode: .legacy(clientCapabilities: ["elicitation": ["form": [:]]]))
        try await legacy.initializeLegacy()
        let clients = [
            legacy,
            harness.client(mode: .modern()),
            harness.client(mode: .modern(clientCapabilities: ["extensions": [Self.tasksExtension: [:]]]))
        ]

        for client in clients {
            let called = try await client.callTool("fixture_ask")
            let result = try #require(called.result, "\(called.json)")
            #expect(result["resultType"] as? String ?? "complete" == "complete")
            #expect(try Self.upstreamAnswers(in: result).first?["action"] as? String == "decline")
        }

        // A link question never goes to an app that declared forms only.
        let formsOnly = harness.client(mode: .modern(clientCapabilities: Self.formsOnly))
        let link = try await formsOnly.callTool("fixture_ask", arguments: ["kind": "url"])
        let result = try #require(link.result, "\(link.json)")
        #expect(result["resultType"] as? String == "complete")
        #expect(try Self.upstreamAnswers(in: result).first?["action"] as? String == "cancel")
    }

    @Test func aRequestStateWorksOnlyForItsAppToolAndArgumentsUntilItExpires() async throws {
        let harness = try RelayHarness()
        defer { harness.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.formsOnly))
        let other = try harness.otherApp(mode: .modern(clientCapabilities: Self.formsOnly))

        let first = try await client.callTool("fixture_ask")
        let asked = try #require(first.result, "\(first.json)")
        let requestState = try #require(asked["requestState"] as? String)
        let (key, _) = try #require(Self.onlyRequest(in: asked))
        func retry(state: String, arguments: [String: Any] = [:]) -> [String: Any] {
            [
                "name": "fixture_ask",
                "arguments": arguments,
                "requestState": state,
                "inputResponses": [key: Self.blue]
            ]
        }

        let refusals: [(String, MCPTestClient, [String: Any])] = [
            ("a made-up state", client, retry(state: String(repeating: "0", count: 64))),
            ("another app", other, retry(state: requestState)),
            ("other arguments", client, retry(state: requestState, arguments: ["kind": "url"]))
        ]
        for (what, caller, params) in refusals {
            let refused = try await caller.send(method: "tools/call", params: params)
            #expect(refused.error?["code"] as? Int == -32602, "\(what): \(refused.json)")
        }

        harness.clock.advance(by: 5 * 60 + 1)
        let expired = try await client.send(method: "tools/call", params: retry(state: requestState))
        #expect(expired.error?["code"] as? Int == -32602, "\(expired.json)")
    }

    /// A question goes only in a mode the request that receives it declared:
    /// a retry without elicitation is not sent the next question, the
    /// upstream is told `decline`, and the call finishes (SPEC D82).
    @Test func aRetryGetsOnlyQuestionsInTheModesItDeclared() async throws {
        let harness = try RelayHarness()
        defer { harness.stop() }
        try await harness.waitUntilReady()
        let forms = harness.client(mode: .modern(clientCapabilities: Self.formsOnly))
        let plain = harness.client(mode: .modern())

        let first = try await forms.callTool("fixture_ask", arguments: ["rounds": 2])
        let asked = try #require(first.result, "\(first.json)")
        let requestState = try #require(asked["requestState"] as? String)
        let (key, _) = try #require(Self.onlyRequest(in: asked))

        let retried = try await plain.send(method: "tools/call", params: [
            "name": "fixture_ask",
            "arguments": ["rounds": 2],
            "requestState": requestState,
            "inputResponses": [key: Self.blue]
        ])
        let result = try #require(retried.result, "\(retried.json)")
        #expect(result["resultType"] as? String == "complete")
        #expect(try Self.upstreamAnswers(in: result).map { $0["action"] as? String } == ["accept", "decline"])
    }

    /// The same rule when a retry leaves a question of the round unanswered:
    /// it is asked again only in a mode the retry declared, and the upstream
    /// is told `decline` for a form the retry cannot show.
    @Test func aPartialRetryIsAskedAgainOnlyInTheModesItDeclared() async throws {
        let store = ToolCallTaskStore()
        let handoff = ToolCallHandoff(modes: [.form], delivery: .requestState(
            store: store, ownerID: "app", toolName: "tool", arguments: .object([:])
        ))
        let form = JSONValue.object(["method": .string("elicitation/create"), "params": .object(["message": .string("Pick.")])])
        handoff.start { _ in
            let answers = try? await MCPElicitationRelay.ask(
                ["a": form, "b": form], server: "fixture", relay: handoff, rounds: MCPElicitationRelay.Rounds()
            )
            return .result(["answers": (answers ?? [:]).mapValues(\.anyValue)])
        }
        guard case .inputRequired(let requests, let requestState) = await handoff.answer() else {
            Issue.record("The call did not ask.")
            return
        }
        #expect(requests.count == 2)
        _ = store.resume(requestState: requestState, ownerID: "app", toolName: "tool", arguments: .object([:]))
        handoff.resume(with: [requests.keys.sorted()[0]: try #require(JSONValue.fromJSONObject(Self.blue))], modes: [])

        guard case .result(.result(let result)) = await handoff.answer() else {
            Issue.record("The call asked again.")
            return
        }
        let answers = try #require(result["answers"] as? [String: Any])
        #expect(NSDictionary(dictionary: answers["a"] as? [String: Any] ?? [:]) == NSDictionary(dictionary: Self.blue))
        #expect((answers["b"] as? [String: Any])?["action"] as? String == "decline")
    }

    /// A `requestState` that is there but is not a string handle refuses the
    /// call and runs nothing; answers that are not an object are refused too,
    /// and the handle still works afterwards (SPEC D82).
    @Test func aRequestStateThatIsNotALiveHandleRunsNothing() async throws {
        let harness = try RelayHarness()
        defer { harness.stop() }
        try await harness.waitUntilReady()
        let client = harness.client(mode: .modern(clientCapabilities: Self.formsOnly))

        for state: Any in [NSNull(), 123] {
            for responses: Any? in [nil, [String: Any]()] {
                var params: [String: Any] = ["name": "fixture_ask", "arguments": [String: Any](), "requestState": state]
                params["inputResponses"] = responses
                let refused = try await client.send(method: "tools/call", params: params)
                #expect(refused.error?["code"] as? Int == -32602, "\(state), \(String(describing: responses)): \(refused.json)")
            }
        }

        let first = try await client.callTool("fixture_ask")
        let asked = try #require(first.result, "\(first.json)")
        let requestState = try #require(asked["requestState"] as? String)
        let (key, _) = try #require(Self.onlyRequest(in: asked))
        func retry(_ responses: Any) -> [String: Any] {
            ["name": "fixture_ask", "arguments": [String: Any](), "requestState": requestState, "inputResponses": responses]
        }
        for responses: Any in [false, NSNull(), [Any]()] {
            let refused = try await client.send(method: "tools/call", params: retry(responses))
            #expect(refused.error?["code"] as? Int == -32602, "\(responses): \(refused.json)")
        }
        let final = try await client.send(method: "tools/call", params: retry([key: Self.blue]))
        let result = try #require(final.result, "\(final.json)")
        #expect(result["resultType"] as? String == "complete")
        #expect(try Self.upstreamAnswers(in: result).first?["action"] as? String == "accept")
    }

    private static func onlyRequest(in result: [String: Any]) -> (String, [String: Any])? {
        guard let requests = result["inputRequests"] as? [String: Any],
              requests.count == 1,
              let (key, value) = requests.first,
              let request = value as? [String: Any] else { return nil }
        return (key, request)
    }

    /// The answers the upstream server reports it received.
    private static func upstreamAnswers(in result: [String: Any]) throws -> [[String: Any]] {
        let stdout = try #require((result["structuredContent"] as? [String: Any])?["stdout"] as? String, "\(result)")
        let reported = try JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        return try #require(reported?["answers"] as? [[String: Any]], "\(stdout)")
    }
}

// MARK: - Harness

private func pollTask(
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

private final class RelayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: TimeInterval = 0

    var now: Date { lock.withLock { Date().addingTimeInterval(offset) } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { offset += seconds }
    }
}

private struct RelayHarness {
    static let instanceID = "relay-tests"

    let server: LocalMCPServer
    let coordinator: OAuthCoordinator
    let clock = RelayClock()
    let baseURL: URL
    private let directory: URL
    private let bearerToken = "relay-tests-token"

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-tests-\(UUID().uuidString)", isDirectory: true)
        let asking = try AskingMCPServer(in: directory)
        let tools = [asking.tool(id: "fixture_ask")]
        let artifactStore = ArtifactStore(rootDirectory: directory.appendingPathComponent("artifacts"))
        coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(bearerToken, clientName: "Relay Probe")
        let clock = clock
        server = LocalMCPServer(
            instanceID: Self.instanceID,
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: tools,
                environment: ProcessInfo.processInfo.environment,
                artifactStore: artifactStore
            ),
            artifactStore: artifactStore,
            toolCallTasks: ToolCallTaskStore(now: { clock.now })
        )
        let port = try server.start()
        guard let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
            server.stop()
            throw URLError(.badURL)
        }
        self.baseURL = baseURL
    }

    var endpoint: URL {
        baseURL.appendingPathComponent("mcp").appendingPathComponent(Self.instanceID)
    }

    func stop() {
        server.stop()
        let prefix = directory.path
        MCPStdioSessionPool.shared.evict { key in
            key.command.hasPrefix(prefix) || key.args.contains { $0.hasPrefix(prefix) }
        }
        try? FileManager.default.removeItem(at: directory)
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

    func otherApp(mode: MCPTestProtocolMode) throws -> MCPTestClient {
        try dynamicOAuthTestClient(coordinator: coordinator, baseURL: baseURL, endpoint: endpoint, mode: mode)
    }
}
