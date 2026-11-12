import Foundation

/// Runs blocking work, such as reading a pipe or waiting for a process, on a
/// thread of its own and suspends the caller until it finishes.
///
/// Swift's async runtime has about one thread per CPU core. A call that blocks
/// on one of them stalls every other async task in the app, the HTTP server
/// included, so anything that waits on another program runs here instead.
func onBlockingThread<Value: Sendable>(_ work: @escaping @Sendable () -> Value) async -> Value {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread {
            continuation.resume(returning: work())
        }
    }
}
