import Foundation
import os

struct ApprovalDecisionRecord: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Read-only tools run without a gate.
        case readOnly = "read-only"
        /// A stored Always Allow grant matched the tool's fingerprint.
        case alwaysAllowGrant = "always-allow-grant"
        /// The owner approved this call in the Approval window.
        case userApproved = "user-approved"
        /// The owner denied the call, or it expired unanswered.
        case userDenied = "user-denied"
        /// No approval coordinator was available; the call was blocked.
        case gateUnavailable = "gate-unavailable"
    }

    var timestamp: Date
    var toolID: String
    var clientTrustIDPrefix: String
    var capability: String
    var approvalPolicy: String
    var source: Source
    var grantStoreHit: Bool
}

/// One line per tool-call authorization decision, written to both the unified
/// log (subsystem `com.macstories.MacRemote`, category `approvals`) and a
/// small persisted ring buffer, so "why did this call prompt?" stays
/// answerable after a relaunch. Records carry identifiers only — never
/// tokens, argv, or outputs (ARCHITECTURE_SECURITY audit rules), and only a
/// prefix of the client trust ID.
final class ApprovalDecisionLog: @unchecked Sendable {
    static let maximumRecordCount = 200
    private static let trustIDPrefixLength = 24
    private static let logger = Logger(subsystem: "com.macstories.MacRemote", category: "approvals")

    private let fileURL: URL?
    private let lock = NSLock()
    private var records: [ApprovalDecisionRecord]

    /// Pass nil to keep the ring buffer in memory only.
    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL,
           let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ApprovalDecisionRecord].self, from: data) {
            self.records = Array(decoded.suffix(Self.maximumRecordCount))
        } else {
            self.records = []
        }
    }

    func record(
        tool: ToolDefinition,
        clientTrustID: String,
        source: ApprovalDecisionRecord.Source,
        grantStoreHit: Bool
    ) {
        let record = ApprovalDecisionRecord(
            timestamp: Date(),
            toolID: tool.id,
            clientTrustIDPrefix: String(clientTrustID.prefix(Self.trustIDPrefixLength)),
            capability: tool.capability.rawValue,
            approvalPolicy: tool.approvalPolicy.rawValue,
            source: source,
            grantStoreHit: grantStoreHit
        )
        Self.logger.log(
            "decision source=\(record.source.rawValue, privacy: .public) tool=\(record.toolID, privacy: .public) client=\(record.clientTrustIDPrefix, privacy: .public) capability=\(record.capability, privacy: .public) policy=\(record.approvalPolicy, privacy: .public) grantHit=\(record.grantStoreHit, privacy: .public)"
        )
        lock.lock()
        defer { lock.unlock() }
        records.append(record)
        if records.count > Self.maximumRecordCount {
            records.removeFirst(records.count - Self.maximumRecordCount)
        }
        persistLocked()
    }

    /// Newest-last snapshot of the persisted ring buffer.
    var snapshot: [ApprovalDecisionRecord] {
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    private func persistLocked() {
        guard let fileURL else { return }
        do {
            let data = try JSONEncoder().encode(records)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.warning("Could not persist the approval decision ring buffer: \(error.localizedDescription, privacy: .public)")
        }
    }
}
