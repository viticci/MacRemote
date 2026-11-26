import Foundation
import Testing
@testable import MacRemote

struct ApprovalDecisionLogTests {
    private func makeTool(id: String = "test_tool") -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: "Test Tool",
            summary: "Test.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .write,
            timeoutSeconds: 1,
            outputByteLimit: 1024,
            approvalPolicy: .standard
        )
    }

    @Test func recordsCarryIdentifiersAndATruncatedTrustID() throws {
        let log = ApprovalDecisionLog(fileURL: nil)
        let longTrustID = "macremote-trust-" + String(repeating: "f", count: 64)
        log.record(
            tool: makeTool(),
            clientTrustID: longTrustID,
            source: .userApproved,
            grantStoreHit: false
        )

        let record = try #require(log.snapshot.last)
        #expect(record.toolID == "test_tool")
        #expect(record.capability == "write")
        #expect(record.approvalPolicy == "standard")
        #expect(record.source == .userApproved)
        #expect(record.grantStoreHit == false)
        // Never the full trust ID.
        #expect(record.clientTrustIDPrefix == String(longTrustID.prefix(24)))
        #expect(record.clientTrustIDPrefix.count < longTrustID.count)
    }

    @Test func ringBufferCapsAtTheMaximumKeepingNewestRecords() {
        let log = ApprovalDecisionLog(fileURL: nil)
        for index in 0..<(ApprovalDecisionLog.maximumRecordCount + 25) {
            log.record(
                tool: makeTool(id: "tool_\(index)"),
                clientTrustID: "trust",
                source: .readOnly,
                grantStoreHit: false
            )
        }
        let snapshot = log.snapshot
        #expect(snapshot.count == ApprovalDecisionLog.maximumRecordCount)
        #expect(snapshot.first?.toolID == "tool_25")
        #expect(snapshot.last?.toolID == "tool_\(ApprovalDecisionLog.maximumRecordCount + 24)")
    }

    @Test func persistedRecordsSurviveAReload() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-decisions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let log = ApprovalDecisionLog(fileURL: fileURL)
        log.record(tool: makeTool(), clientTrustID: "trust-a", source: .alwaysAllowGrant, grantStoreHit: true)
        log.record(tool: makeTool(id: "other"), clientTrustID: "trust-b", source: .userDenied, grantStoreHit: false)

        let reloaded = ApprovalDecisionLog(fileURL: fileURL)
        #expect(reloaded.snapshot == log.snapshot)
        #expect(reloaded.snapshot.count == 2)

        // A corrupt file degrades to an empty buffer, never a crash.
        try Data("not json".utf8).write(to: fileURL)
        #expect(ApprovalDecisionLog(fileURL: fileURL).snapshot.isEmpty)
    }
}
