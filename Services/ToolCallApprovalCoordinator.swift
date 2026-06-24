import Foundation

final class ToolCallApprovalCoordinator: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([ToolCallApprovalRequest]) -> Void

    private struct PendingCall {
        let continuation: CheckedContinuation<Bool, Never>
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let changeHandler: ChangeHandler?
    private let timeoutSeconds: TimeInterval
    private var requests: [UUID: ToolCallApprovalRequest] = [:]
    private var pendingCalls: [UUID: PendingCall] = [:]

    init(timeoutSeconds: TimeInterval = 120, changeHandler: ChangeHandler? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.changeHandler = changeHandler
    }

    func requestApproval(
        tool: ToolDefinition,
        parameters: [String: ToolArgumentValue],
        client: AuthenticatedClientContext? = nil
    ) async -> Bool {
        let id = UUID()
        let request = ToolCallApprovalRequest(
            id: id,
            clientID: client?.clientID,
            clientName: client?.clientName,
            toolID: tool.id,
            toolName: tool.name,
            capability: tool.capability,
            argumentsPreview: Self.argumentsPreview(parameters),
            createdAt: Date(),
            state: .pending
        )

        return await withCheckedContinuation { continuation in
            let snapshot: [ToolCallApprovalRequest] = lock.withLock {
                requests[id] = request
                pendingCalls[id] = PendingCall(
                    continuation: continuation,
                    expiresAt: Date().addingTimeInterval(timeoutSeconds)
                )
                return snapshotLocked()
            }
            notify(snapshot)
            scheduleExpiration(for: id)
        }
    }

    func approve(requestID: UUID) -> Bool {
        resolve(requestID: requestID, state: .approved, result: true)
    }

    func deny(requestID: UUID) -> Bool {
        resolve(requestID: requestID, state: .denied, result: false)
    }

    func approvalSnapshot() -> [ToolCallApprovalRequest] {
        lock.withLock {
            return snapshotLocked()
        }
    }

    func denyAllPending() {
        let denied: (continuations: [CheckedContinuation<Bool, Never>], snapshot: [ToolCallApprovalRequest]) = lock.withLock {
            var continuations: [CheckedContinuation<Bool, Never>] = []

            for requestID in pendingCalls.keys {
                if var request = requests[requestID], request.state == .pending {
                    request.state = .denied
                    requests[requestID] = request
                }
            }

            continuations = pendingCalls.values.map(\.continuation)
            pendingCalls.removeAll()
            return (continuations, snapshotLocked())
        }

        notify(denied.snapshot)
        denied.continuations.forEach { $0.resume(returning: false) }
    }

    private func resolve(requestID: UUID, state: ToolCallApprovalRequest.State, result: Bool) -> Bool {
        let resolved: (continuation: CheckedContinuation<Bool, Never>?, snapshot: [ToolCallApprovalRequest], changed: Bool) = lock.withLock {
            guard var request = requests[requestID],
                  request.state == .pending,
                  let pending = pendingCalls.removeValue(forKey: requestID) else {
                return (nil, snapshotLocked(), false)
            }

            request.state = state
            requests[requestID] = request
            return (pending.continuation, snapshotLocked(), true)
        }

        notify(resolved.snapshot)
        resolved.continuation?.resume(returning: result)
        return resolved.changed
    }

    private func scheduleExpiration(for requestID: UUID) {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            self.expire(requestID: requestID)
        }
    }

    private func expire(requestID: UUID) {
        let expired: (continuation: CheckedContinuation<Bool, Never>?, snapshot: [ToolCallApprovalRequest]) = lock.withLock {
            guard var request = requests[requestID],
                  request.state == .pending,
                  let pending = pendingCalls.removeValue(forKey: requestID) else {
                return (nil, snapshotLocked())
            }

            request.state = .expired
            requests[requestID] = request
            return (pending.continuation, snapshotLocked())
        }

        notify(expired.snapshot)
        expired.continuation?.resume(returning: false)
    }

    private func snapshotLocked() -> [ToolCallApprovalRequest] {
        requests.values.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
    }

    private func notify(_ snapshot: [ToolCallApprovalRequest]) {
        changeHandler?(snapshot)
    }

    private static func argumentsPreview(_ parameters: [String: ToolArgumentValue]) -> String {
        let parts = parameters.keys.sorted().map { key -> String in
            guard key != "stdin" else {
                let count = parameters[key]?.stringValue?.count ?? 0
                return "stdin=<\(count) chars>"
            }

            switch parameters[key] {
            case .string(let value):
                return "\(key)=\(value)"
            case .stringArray(let values):
                return "\(key)=\(values.joined(separator: " "))"
            case nil:
                return "\(key)=<missing>"
            }
        }

        let preview = parts.isEmpty ? "No arguments" : parts.joined(separator: " ")
        return String(preview.prefix(700))
    }
}
