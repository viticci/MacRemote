import Foundation

enum DiscoveryFreshness: Equatable, Sendable {
    case neverScanned
    case current(lastScan: Date)
    case stale(lastScan: Date, reason: StaleReason)

    enum StaleReason: Equatable, Sendable {
        case configsChanged
        case installRecordsChanged
    }
}
