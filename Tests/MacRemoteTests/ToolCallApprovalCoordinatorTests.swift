import XCTest
@testable import MacRemote

final class ToolCallApprovalCoordinatorTests: XCTestCase {
    func testApprovalWaitsForHostDecisionAndRedactsStdinPreview() async throws {
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
        XCTAssertEqual(request.toolID, "test.remctl")
        XCTAssertEqual(request.capability, .destructive)
        XCTAssertTrue(request.argumentsPreview.contains("args=add Test -l Work"))
        XCTAssertTrue(request.argumentsPreview.contains("stdin=<6 chars>"))
        XCTAssertFalse(request.argumentsPreview.contains("secret"))

        XCTAssertTrue(coordinator.approve(requestID: request.id))
        let approved = await approvalTask.value
        XCTAssertTrue(approved)
        XCTAssertEqual(coordinator.approvalSnapshot().first?.state, .approved)
    }

    func testDeniedApprovalReturnsFalse() async throws {
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
        XCTAssertTrue(coordinator.deny(requestID: request.id))
        let approved = await approvalTask.value
        XCTAssertFalse(approved)
        XCTAssertEqual(coordinator.approvalSnapshot().first?.state, .denied)
    }
}

private func waitForPendingApproval(
    in coordinator: ToolCallApprovalCoordinator,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> ToolCallApprovalRequest {
    for _ in 0..<50 {
        if let request = coordinator.approvalSnapshot().first(where: { $0.state == .pending }) {
            return request
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for pending tool approval.", file: file, line: line)
    throw NSError(domain: "MacRemoteTests", code: 1)
}
