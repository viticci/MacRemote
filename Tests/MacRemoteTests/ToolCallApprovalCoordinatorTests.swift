import Foundation
import Testing
@testable import MacRemote

struct ToolCallApprovalCoordinatorTests {
    @Test func approvalWaitsForHostDecisionAndShowsEveryArgument() async throws {
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let tool = ToolDefinition(
            id: "test.remctl",
            name: "Run RemCTL",
            summary: "Run full RemCTL.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [],
            capability: .destructive,
            timeoutSeconds: 5,
            outputByteLimit: 1024
        )

        let approvalTask = Task {
            try await coordinator.requestApproval(
                tool: tool,
                parameters: [
                    "args": .stringArray(["add", "Test", "-l", "Work"]),
                    "stdin": .string("secret")
                ]
            )
        }

        let request = try await waitForPendingApproval(in: coordinator)
        #expect(request.toolID == "test.remctl")
        #expect(request.capability == .destructive)
        // The card needs this to avoid promising that a Flexible Command
        // labeled Read-only only reads.
        #expect(request.isFlexibleCommand)
        // The owner sees every argument in full, including what the tool
        // will read from standard input.
        // Shortest value first, so a short path or mode is never hidden
        // below a long block of content.
        #expect(request.arguments.map(\.name) == ["stdin", "args"])
        #expect(request.arguments.map(\.value) == ["secret", "add Test -l Work"])

        #expect(coordinator.approve(requestID: request.id))
        let approved = try await approvalTask.value
        #expect(approved)
        #expect(coordinator.approvalSnapshot().first?.state == .approved)
    }

    @Test func deniedApprovalReturnsFalse() async throws {
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let tool = ToolDefinition(
            id: "test.write",
            name: "Write",
            summary: "Write something.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [],
            capability: .write,
            timeoutSeconds: 5,
            outputByteLimit: 1024
        )

        let approvalTask = Task {
            try await coordinator.requestApproval(tool: tool, parameters: ["args": .stringArray(["write"])])
        }

        let request = try await waitForPendingApproval(in: coordinator)
        #expect(coordinator.deny(requestID: request.id))
        let approved = try await approvalTask.value
        #expect(approved == false)
        #expect(coordinator.approvalSnapshot().first?.state == .denied)
    }

    @Test func denyAllPendingResolvesWaitingApprovals() async throws {
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 30)
        let tool = ToolDefinition(
            id: "test.destructive",
            name: "Destructive",
            summary: "Destructive action.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [],
            capability: .destructive,
            timeoutSeconds: 5,
            outputByteLimit: 1024
        )

        let approvalTask = Task {
            try await coordinator.requestApproval(tool: tool, parameters: ["args": .stringArray(["delete"])])
        }

        _ = try await waitForPendingApproval(in: coordinator)
        coordinator.denyAllPending()

        let approved = try await approvalTask.value
        #expect(approved == false)
        #expect(coordinator.approvalSnapshot().first?.state == .denied)
    }

    @Test func cancellationExpiresOnlyItsApprovalAndLeavesNoPendingWaiter() async throws {
        let recorder = ApprovalSnapshotRecorder()
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 30) {
            recorder.record($0)
        }
        let firstTool = approvalTool(id: "test.first", name: "First")
        let secondTool = approvalTool(id: "test.second", name: "Second")

        let firstTask = Task {
            try await coordinator.requestApproval(tool: firstTool, parameters: [:])
        }
        let secondTask = Task {
            try await coordinator.requestApproval(tool: secondTool, parameters: [:])
        }

        let firstRequest = try await waitForPendingApproval(
            toolID: firstTool.id,
            in: coordinator
        )
        let secondRequest = try await waitForPendingApproval(
            toolID: secondTool.id,
            in: coordinator
        )

        firstTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await firstTask.value
        }

        let afterCancellation = coordinator.approvalSnapshot()
        #expect(afterCancellation.first(where: { $0.id == firstRequest.id })?.state == .expired)
        #expect(afterCancellation.first(where: { $0.id == secondRequest.id })?.state == .pending)
        #expect(afterCancellation.count(where: { $0.state == .pending }) == 1)
        #expect(
            recorder.snapshots.contains { snapshot in
                snapshot.first(where: { $0.id == firstRequest.id })?.state == .expired
            }
        )

        #expect(coordinator.deny(requestID: secondRequest.id))
        #expect(try await secondTask.value == false)
        #expect(coordinator.approvalSnapshot().contains(where: { $0.state == .pending }) == false)
    }

    @Test(arguments: ApprovalRaceResolution.allCases)
    func hostResolutionAndCancelRaceResolvesExactlyOnce(
        resolution: ApprovalRaceResolution
    ) async throws {
        for iteration in 0..<16 {
            let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 30)
            let tool = approvalTool(id: "test.race.\(iteration)", name: "Race")
            let approvalTask = Task {
                try await coordinator.requestApproval(tool: tool, parameters: [:])
            }
            let request = try await waitForPendingApproval(in: coordinator)

            let hostResolutionWon = await withTaskGroup(of: Bool.self) { group in
                if iteration.isMultiple(of: 2) {
                    group.addTask {
                        resolution.resolve(requestID: request.id, in: coordinator)
                    }
                    group.addTask {
                        approvalTask.cancel()
                        return false
                    }
                } else {
                    group.addTask {
                        approvalTask.cancel()
                        return false
                    }
                    group.addTask {
                        resolution.resolve(requestID: request.id, in: coordinator)
                    }
                }

                var hostResolved = false
                for await result in group {
                    hostResolved = hostResolved || result
                }
                return hostResolved
            }

            do {
                let approved = try await approvalTask.value
                #expect(hostResolutionWon)
                #expect(approved == resolution.approvalResult)
            } catch is CancellationError {
                #expect(hostResolutionWon == false)
            } catch {
                Issue.record("Unexpected approval race error: \(error)")
            }

            let finalRequest = try #require(
                coordinator.approvalSnapshot().first(where: { $0.id == request.id })
            )
            #expect(
                finalRequest.state
                    == (hostResolutionWon ? resolution.requestState : .expired)
            )
            #expect(coordinator.approvalSnapshot().contains(where: { $0.state == .pending }) == false)
            #expect(coordinator.approve(requestID: request.id) == false)
            #expect(coordinator.deny(requestID: request.id) == false)
        }
    }

    @Test func expiryReturnsFalseAndPublishesNoLingeringPendingRequest() async throws {
        let recorder = ApprovalSnapshotRecorder()
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 0.02) {
            recorder.record($0)
        }
        let tool = approvalTool(id: "test.expiry", name: "Expiry")

        let approved = try await coordinator.requestApproval(tool: tool, parameters: [:])

        #expect(approved == false)
        let request = try #require(coordinator.approvalSnapshot().first)
        #expect(request.state == .expired)
        #expect(coordinator.approvalSnapshot().contains(where: { $0.state == .pending }) == false)
        #expect(coordinator.approve(requestID: request.id) == false)
        #expect(
            recorder.snapshots.contains { snapshot in
                snapshot.first(where: { $0.id == request.id })?.state == .pending
            }
        )
        #expect(
            recorder.snapshots.contains { snapshot in
                snapshot.first(where: { $0.id == request.id })?.state == .expired
            }
        )
    }
}

struct ToolCallApprovalArgumentTests {
    @Test func separateCommandLineItemsNeverLookLikeOne() {
        #expect(ToolCallApprovalArgument.commandLine(["add", "Test", "-l", "Work"]) == "add Test -l Work")
        #expect(ToolCallApprovalArgument.commandLine(["rm", "a b"]) == "rm \"a b\"")
        #expect(ToolCallApprovalArgument.commandLine(["rm", "a", "b"]) == "rm a b")
        #expect(ToolCallApprovalArgument.commandLine(["say", ""]) == "say \"\"")
        #expect(ToolCallApprovalArgument.commandLine(["echo", "one\ntwo"]) == "echo \"one\\ntwo\"")
    }

    @Test func longValuesAreNeverShortened() {
        let payload = String(repeating: "x", count: 5_000) + " --delete-everything"
        let argument = ToolCallApprovalArgument(name: "data", value: .string(payload))
        #expect(argument.value == payload)
        #expect(argument.displayValue.hasSuffix("--delete-everything"))
    }

    @Test func invisibleCharactersAreWrittenOut() {
        let argument = ToolCallApprovalArgument(
            name: "path",
            value: .string("safe.txt\r\u{202E}fdp.exe\u{200B}")
        )
        #expect(argument.displayValue == "safe.txt\\u{D}\\u{202E}fdp.exe\\u{200B}")
        // Line breaks and tabs are layout, not disguise.
        #expect(ToolCallApprovalArgument(name: "data", value: .string("a\n\tb")).displayValue == "a\n\tb")
    }

    /// A Flexible Command runs whatever arguments it is sent, so a Read-only
    /// label on one cannot be checked and must not skip approval.
    @Test func aFlexibleCommandAsksEvenWhenLabeledReadOnly() {
        func tool(pattern: [String]) -> ToolDefinition {
            ToolDefinition(
                id: "test.tool",
                name: "Tool",
                summary: "Test.",
                executablePath: "/usr/bin/jq",
                argumentPattern: pattern,
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024
            )
        }
        #expect(tool(pattern: ["{args}"]).asksBeforeRunning)
        #expect(!tool(pattern: ["--version"]).asksBeforeRunning)
    }

    @Test func oneAppCannotQueueUnlimitedApprovals() async throws {
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let tool = ToolDefinition(
            id: "test.write",
            name: "Write",
            summary: "Writes.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .write,
            timeoutSeconds: 5,
            outputByteLimit: 1024
        )
        let client = AuthenticatedClientContext(
            clientID: "client-a",
            clientTrustID: "trust-a",
            clientName: "A",
            issuer: "http://127.0.0.1",
            resource: "http://127.0.0.1/mcp",
            scopes: [],
            accessTokenExpiresAt: .distantFuture
        )
        let waiting = (0..<ToolCallApprovalCoordinator.maximumPendingPerClient).map { _ in
            Task { try await coordinator.requestApproval(tool: tool, parameters: [:], client: client) }
        }
        for _ in 0..<50 where coordinator.approvalSnapshot().count < waiting.count {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        await #expect(throws: ToolCallApprovalError.tooManyPending) {
            _ = try await coordinator.requestApproval(tool: tool, parameters: [:], client: client)
        }
        #expect(coordinator.denyAllPending() == waiting.count)
        for task in waiting {
            #expect(try await task.value == false)
        }
    }
}

private func waitForPendingApproval(
    toolID: String? = nil,
    in coordinator: ToolCallApprovalCoordinator,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> ToolCallApprovalRequest {
    for _ in 0..<50 {
        if let request = coordinator.approvalSnapshot().first(where: {
            $0.state == .pending && (toolID == nil || $0.toolID == toolID)
        }) {
            return request
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    Issue.record("Timed out waiting for pending tool approval.", sourceLocation: sourceLocation)
    throw NSError(domain: "MacRemoteTests", code: 1)
}

private func approvalTool(id: String, name: String) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: name,
        summary: "Approval test tool.",
        executablePath: "/bin/echo",
        argumentPattern: ["{args}"],
        parameters: [],
        capability: .write,
        timeoutSeconds: 5,
        outputByteLimit: 1024
    )
}

private final class ApprovalSnapshotRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[ToolCallApprovalRequest]] = []

    var snapshots: [[ToolCallApprovalRequest]] {
        lock.withLock { storage }
    }

    func record(_ snapshot: [ToolCallApprovalRequest]) {
        lock.withLock {
            storage.append(snapshot)
        }
    }
}

enum ApprovalRaceResolution: CaseIterable, Sendable {
    case approve
    case deny
    case denyAll

    var approvalResult: Bool {
        self == .approve
    }

    var requestState: ToolCallApprovalRequest.State {
        self == .approve ? .approved : .denied
    }

    func resolve(
        requestID: UUID,
        in coordinator: ToolCallApprovalCoordinator
    ) -> Bool {
        switch self {
        case .approve:
            return coordinator.approve(requestID: requestID)
        case .deny:
            return coordinator.deny(requestID: requestID)
        case .denyAll:
            coordinator.denyAllPending()
            return coordinator.approvalSnapshot()
                .first(where: { $0.id == requestID })?
                .state == .denied
        }
    }
}
