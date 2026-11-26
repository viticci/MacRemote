import Foundation

/// Persisted MCP config-scan memory: seen-set hashes, config fingerprint, and
/// last quiet refresh date. Candidates and raw bridge identities never hit disk.
struct LocalMCPScanCache: Codable, Equatable, Sendable {
    var hashedSeenBridgeIdentities: Set<String>
    var configSnapshot: String
    var lastConfigScanDate: Date

    init(
        hashedSeenBridgeIdentities: Set<String> = [],
        configSnapshot: String = "",
        lastConfigScanDate: Date = .distantPast
    ) {
        self.hashedSeenBridgeIdentities = hashedSeenBridgeIdentities
        self.configSnapshot = configSnapshot
        self.lastConfigScanDate = lastConfigScanDate
    }
}
