import Foundation

/// Bounds how many tool executions may run at once across all MCP clients.
/// Approval waits happen outside this gate; only `toolExecutor.execute` is limited.
actor ToolExecutionLimiter {
    /// Enough parallelism for multi-tool workflows without letting burst traffic
    /// spawn unbounded child processes on a single Mac.
    static let maxConcurrentExecutions = 8

    /// Brief wait before load-shedding so a finishing call can hand off its slot.
    static let defaultAcquireTimeout: Duration = .seconds(3)

    private let acquireTimeout: Duration
    private var availableSlots: Int
    private var waiters: [Waiter] = []

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    init(
        maxSlots: Int = ToolExecutionLimiter.maxConcurrentExecutions,
        acquireTimeout: Duration = ToolExecutionLimiter.defaultAcquireTimeout
    ) {
        precondition(maxSlots > 0, "ToolExecutionLimiter requires at least one slot")
        self.acquireTimeout = acquireTimeout
        self.availableSlots = maxSlots
    }

    /// Acquires a slot (waiting up to `timeout`), runs `body`, then always releases.
    /// Returns `nil` when no slot became available in time.
    func withSlot<T: Sendable>(
        timeout: Duration? = nil,
        _ body: @Sendable () async throws -> T
    ) async throws -> T? {
        guard await acquire(timeout: timeout ?? acquireTimeout) else { return nil }
        defer { release() }
        return try await body()
    }

    private func acquire(timeout: Duration) async -> Bool {
        if availableSlots > 0 {
            availableSlots -= 1
            return true
        }

        let waiterID = UUID()
        return await withCheckedContinuation { continuation in
            waiters.append(Waiter(id: waiterID, continuation: continuation))
            Task {
                try? await Task.sleep(for: timeout)
                await timeoutWaiter(id: waiterID)
            }
        }
    }

    private func timeoutWaiter(id: UUID) async {
        expireWaiter(id: id)
    }

    private func expireWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            availableSlots += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: true)
        }
    }
}
