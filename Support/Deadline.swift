import Foundation

/// Thrown by `withDeadline` when the time is up.
struct DeadlineExceeded: Error {}

/// Runs `operation` and returns its result, or throws `DeadlineExceeded` once
/// `seconds` have passed.
///
/// At the deadline the operation is cancelled and the caller continues at
/// once, without waiting for the operation to notice. A task group would wait
/// for it, so a single step that ignores cancellation could hold the caller
/// far past the deadline. A network request's own timeout is no substitute:
/// it only limits the gap between bytes, and a server that keeps sending a
/// little never trips it.
func withDeadline<Value: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = DeadlineRace<Value>()
    let work = Task {
        do {
            race.finish(.success(try await operation()))
        } catch {
            race.finish(.failure(error))
        }
    }
    let timer = Task {
        try await Task.sleep(for: .seconds(max(0, seconds)))
        race.finish(.failure(DeadlineExceeded()))
    }
    defer {
        work.cancel()
        timer.cancel()
    }
    return try await withTaskCancellationHandler {
        try await race.value()
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// Holds the outcome of a `withDeadline` race. The first result wins and
/// later ones are dropped.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiter: CheckedContinuation<Value, any Error>?

    func finish(_ result: Result<Value, any Error>) {
        let waiter: CheckedContinuation<Value, any Error>? = lock.withLock {
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(with: result)
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<Value, any Error>? = lock.withLock {
                if result == nil {
                    waiter = continuation
                }
                return result
            }
            if let ready {
                continuation.resume(with: ready)
            }
        }
    }
}
