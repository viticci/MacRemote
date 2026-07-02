import Foundation
import Testing
@testable import MacRemote

struct ToolCallApprovalCoordinatorTests {
    @Test func approvalWaitsForHostDecisionAndRedactsStdinPreview() async throws {
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
            await coordinator.requestApproval(
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
        #expect(request.argumentsPreview.contains("args=add Test -l Work"))
        #expect(request.argumentsPreview.contains("stdin=<6 chars>"))
        #expect(request.argumentsPreview.contains("secret") == false)

        #expect(coordinator.approve(requestID: request.id))
        let approved = await approvalTask.value
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
            await coordinator.requestApproval(tool: tool, parameters: ["args": .stringArray(["write"])])
        }

        let request = try await waitForPendingApproval(in: coordinator)
        #expect(coordinator.deny(requestID: request.id))
        let approved = await approvalTask.value
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
            await coordinator.requestApproval(tool: tool, parameters: ["args": .stringArray(["delete"])])
        }

        _ = try await waitForPendingApproval(in: coordinator)
        coordinator.denyAllPending()

        let approved = await approvalTask.value
        #expect(approved == false)
        #expect(coordinator.approvalSnapshot().first?.state == .denied)
    }
}

private func waitForPendingApproval(
    in coordinator: ToolCallApprovalCoordinator,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> ToolCallApprovalRequest {
    for _ in 0..<50 {
        if let request = coordinator.approvalSnapshot().first(where: { $0.state == .pending }) {
            return request
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    Issue.record("Timed out waiting for pending tool approval.", sourceLocation: sourceLocation)
    throw NSError(domain: "MacRemoteTests", code: 1)
}
