import Foundation

enum ToolCallApprovalError: Error, Equatable {
    /// The app already has as many calls waiting for the owner as it may hold.
    case tooManyPending
}

final class ToolCallApprovalCoordinator: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([ToolCallApprovalRequest]) -> Void

    /// Each waiting call is a prompt and a notification on the Mac and an open
    /// connection, so one app may queue only a few, and all apps together a few more.
    static let maximumPendingPerClient = 4
    static let maximumPending = 16
    /// Resolved requests are kept only as recent history.
    static let maximumResolvedHistory = 50

    private enum ApprovalResolution: Sendable {
        case decision(Bool)
        case cancelled

        func resume(_ continuation: CheckedContinuation<Bool, any Error>) {
            switch self {
            case .decision(let approved):
                continuation.resume(returning: approved)
            case .cancelled:
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    /// The coordinator removes a resolved request under its own lock before
    /// waking the caller. This small hand-off also covers the race where a host
    /// decision or task cancellation arrives just before `wait()` installs its
    /// continuation.
    private final class ApprovalWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, any Error>?
        private var resolution: ApprovalResolution?

        func wait() async throws -> Bool {
            try await withCheckedThrowingContinuation { continuation in
                let existingResolution: ApprovalResolution? = lock.withLock {
                    if let resolution {
                        return resolution
                    }
                    self.continuation = continuation
                    return nil
                }
                existingResolution?.resume(continuation)
            }
        }

        func resolve(_ resolution: ApprovalResolution) {
            let continuation: CheckedContinuation<Bool, any Error>? = lock.withLock {
                guard self.resolution == nil else { return nil }
                self.resolution = resolution
                defer { self.continuation = nil }
                return self.continuation
            }
            if let continuation {
                resolution.resume(continuation)
            }
        }
    }

    private struct PendingCall {
        let waiter: ApprovalWaiter
    }

    private let lock = NSLock()
    private let changeHandler: ChangeHandler?
    private let timeoutSeconds: TimeInterval
    private var requests: [UUID: ToolCallApprovalRequest] = [:]
    private var pendingCalls: [UUID: PendingCall] = [:]

    /// How long a call waits for the owner. A synchronous call must finish
    /// within the timeout of the public link and the app (Cloudflare's current
    /// default is 125 seconds; apps may give up sooner), so a longer wait would
    /// let the owner approve a call whose app has already been told it failed.
    static let defaultTimeoutSeconds: TimeInterval = 90

    init(timeoutSeconds: TimeInterval = defaultTimeoutSeconds, changeHandler: ChangeHandler? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.changeHandler = changeHandler
    }

    func requestApproval(
        tool: ToolDefinition,
        parameters: [String: ToolArgumentValue],
        client: AuthenticatedClientContext? = nil
    ) async throws -> Bool {
        try Task.checkCancellation()

        let id = UUID()
        let waiter = ApprovalWaiter()
        let request = ToolCallApprovalRequest(
            id: id,
            clientID: client?.clientID,
            clientTrustID: client?.clientTrustID,
            clientName: client?.clientName,
            toolID: tool.id,
            toolName: tool.name,
            toolSecurityFingerprint: tool.securityFingerprint,
            capability: tool.capability,
            approvalPolicy: tool.approvalPolicy,
            isFlexibleCommand: tool.isGenericCLIAdapter,
            // Shortest first, so a path or a mode is read before a long
            // block of content pushes it out of view.
            arguments: parameters.keys.sorted()
                .compactMap { name in
                    parameters[name].map { ToolCallApprovalArgument(name: name, value: $0) }
                }
                .sorted { ($0.value.count, $0.name) < ($1.value.count, $1.name) },
            createdAt: Date(),
            state: .pending
        )

        let clientKey = client?.clientID ?? client?.clientTrustID
        let snapshot: [ToolCallApprovalRequest]? = lock.withLock {
            let pendingForClient = pendingCalls.keys.count { pendingID in
                guard let pending = requests[pendingID] else { return false }
                return (pending.clientID ?? pending.clientTrustID) == clientKey
            }
            guard pendingCalls.count < Self.maximumPending,
                  pendingForClient < Self.maximumPendingPerClient else {
                return nil
            }
            requests[id] = request
            pendingCalls[id] = PendingCall(waiter: waiter)
            return snapshotLocked()
        }
        guard let snapshot else {
            throw ToolCallApprovalError.tooManyPending
        }
        notify(snapshot)
        scheduleExpiration(for: id)

        return try await withTaskCancellationHandler {
            try await waiter.wait()
        } onCancel: {
            self.cancel(requestID: id)
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

    @discardableResult
    func denyAllPending() -> Int {
        let denied: (waiters: [ApprovalWaiter], snapshot: [ToolCallApprovalRequest]) = lock.withLock {
            var waiters: [ApprovalWaiter] = []

            for requestID in pendingCalls.keys {
                if var request = requests[requestID], request.state == .pending {
                    request.state = .denied
                    requests[requestID] = request
                }
            }

            waiters = pendingCalls.values.map(\.waiter)
            pendingCalls.removeAll()
            return (waiters, snapshotLocked())
        }

        notify(denied.snapshot)
        denied.waiters.forEach { $0.resolve(.decision(false)) }
        return denied.waiters.count
    }

    /// Denies every pending call belonging to one app, and reports how many —
    /// sign-out claims "waiting requests removed", so the count has to be real.
    ///
    /// Matching is by client ID, falling back to the OAuth trust ID for
    /// requests that carry no client ID. That order matters: two confidential
    /// registrations with the same name, redirects, and scopes share a trust
    /// ID but are distinct clients, and signing one out must not cancel the
    /// other's waiting calls. The display name is deliberately never matched
    /// either — two registrations can both call themselves "Claude".
    @discardableResult
    func denyPending(clientTrustID: String?, clientID: String?) -> Int {
        guard clientTrustID != nil || clientID != nil else { return 0 }

        let denied: (waiters: [ApprovalWaiter], snapshot: [ToolCallApprovalRequest]) = lock.withLock {
            var waiters: [ApprovalWaiter] = []

            for requestID in Array(pendingCalls.keys) {
                guard var request = requests[requestID], request.state == .pending else { continue }
                let matches: Bool
                if let requestClientID = request.clientID {
                    matches = clientID != nil && requestClientID == clientID
                } else if let clientTrustID, let requestTrustID = request.clientTrustID {
                    matches = requestTrustID == clientTrustID
                } else {
                    matches = false
                }
                guard matches else { continue }

                request.state = .denied
                requests[requestID] = request
                if let pending = pendingCalls.removeValue(forKey: requestID) {
                    waiters.append(pending.waiter)
                }
            }

            return (waiters, snapshotLocked())
        }

        guard !denied.waiters.isEmpty else { return 0 }
        // Waiters resume outside the lock: resolving a continuation can run
        // arbitrary caller code that re-enters this coordinator.
        notify(denied.snapshot)
        denied.waiters.forEach { $0.resolve(.decision(false)) }
        return denied.waiters.count
    }

    private func resolve(requestID: UUID, state: ToolCallApprovalRequest.State, result: Bool) -> Bool {
        let resolved: (waiter: ApprovalWaiter?, snapshot: [ToolCallApprovalRequest], changed: Bool) = lock.withLock {
            guard var request = requests[requestID],
                  request.state == .pending,
                  let pending = pendingCalls.removeValue(forKey: requestID) else {
                return (nil, snapshotLocked(), false)
            }

            request.state = state
            requests[requestID] = request
            return (pending.waiter, snapshotLocked(), true)
        }

        notify(resolved.snapshot)
        resolved.waiter?.resolve(.decision(result))
        return resolved.changed
    }

    private func scheduleExpiration(for requestID: UUID) {
        Task { [weak self] in
            guard let timeoutSeconds = self?.timeoutSeconds else { return }
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            self?.expire(requestID: requestID)
        }
    }

    private func expire(requestID: UUID) {
        let expired: (waiter: ApprovalWaiter?, snapshot: [ToolCallApprovalRequest]) = lock.withLock {
            guard var request = requests[requestID],
                  request.state == .pending,
                  let pending = pendingCalls.removeValue(forKey: requestID) else {
                return (nil, snapshotLocked())
            }

            request.state = .expired
            requests[requestID] = request
            return (pending.waiter, snapshotLocked())
        }

        notify(expired.snapshot)
        expired.waiter?.resolve(.decision(false))
    }

    private func cancel(requestID: UUID) {
        let cancelled: (waiter: ApprovalWaiter?, snapshot: [ToolCallApprovalRequest]?) = lock.withLock {
            guard var request = requests[requestID],
                  request.state == .pending,
                  let pending = pendingCalls.removeValue(forKey: requestID) else {
                return (nil, nil)
            }

            // Cancellation means the approval is no longer actionable. Keep it
            // in history as expired so existing UI state remains exhaustive.
            request.state = .expired
            requests[requestID] = request
            return (pending.waiter, snapshotLocked())
        }

        if let snapshot = cancelled.snapshot {
            notify(snapshot)
        }
        cancelled.waiter?.resolve(.cancelled)
    }

    /// Newest first. Also drops resolved requests beyond the history limit, so
    /// the table cannot grow for the life of the process.
    private func snapshotLocked() -> [ToolCallApprovalRequest] {
        let sorted = requests.values.sorted { lhs, rhs in
            lhs.createdAt > rhs.createdAt
        }
        var resolvedKept = 0
        return sorted.filter { request in
            guard request.state != .pending else { return true }
            resolvedKept += 1
            if resolvedKept > Self.maximumResolvedHistory {
                requests[request.id] = nil
                return false
            }
            return true
        }
    }

    private func notify(_ snapshot: [ToolCallApprovalRequest]) {
        changeHandler?(snapshot)
    }
}
