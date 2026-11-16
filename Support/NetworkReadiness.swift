import Foundation
import Network

/// Waits for this Mac to have a usable network path. Used only by Go Public
/// at Launch (D76): right after login, Wi-Fi can take a while to join, and a
/// public link started before then spends its reconnect attempts on nothing.
enum NetworkReadiness {
    /// True as soon as macOS reports a satisfied path, false when `timeout`
    /// passes first.
    static func waitUntilAvailable(timeout: Duration) async -> Bool {
        let monitor = NWPathMonitor()
        let statuses = AsyncStream<NWPath.Status> { continuation in
            monitor.pathUpdateHandler = { continuation.yield($0.status) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "MacRemote.NetworkReadiness"))
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await status in statuses where status == .satisfied {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
