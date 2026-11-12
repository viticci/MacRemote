import Foundation

/// Persists Always Allow grants by stable OAuth trust identity and the exact
/// security contract of a tool. OAuth client IDs and bearer-token state are not
/// accepted by the v2 grant API, so reconnects and token rotation are inert.
final class ClientToolPermissionStore: @unchecked Sendable {
    private static let storageKey = "MacRemote.clientToolPermissions.v2"

    private struct Grant: Codable, Hashable, Sendable {
        let toolID: String
        let fingerprint: String
    }

    private struct PersistedState: Codable, Sendable {
        let version: Int
        let grantsByClientTrustID: [String: [Grant]]
    }

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private var grantsByClientTrustID: [String: Set<Grant>]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.grantsByClientTrustID = Self.load(from: userDefaults)
    }

    func isAllowed(clientTrustID: String, tool: ToolDefinition) -> Bool {
        let grant = Grant(toolID: tool.id, fingerprint: tool.securityFingerprint)
        return lock.withLock {
            grantsByClientTrustID[clientTrustID]?.contains(grant) == true
        }
    }

    @discardableResult
    func setAllowed(
        _ isAllowed: Bool,
        clientTrustID: String,
        tool: ToolDefinition
    ) -> [String: Set<String>] {
        lock.withLock {
            let grant = Grant(toolID: tool.id, fingerprint: tool.securityFingerprint)
            var grants = grantsByClientTrustID[clientTrustID] ?? []

            // Revoking a semantic tool clears stale generations as well.
            grants = Set(grants.filter { $0.toolID != tool.id })
            if isAllowed {
                grants.insert(grant)
            }

            if grants.isEmpty {
                grantsByClientTrustID.removeValue(forKey: clientTrustID)
            } else {
                grantsByClientTrustID[clientTrustID] = grants
            }
            persistLocked()
            return snapshotLocked()
        }
    }

    @discardableResult
    func replaceAllowedTools(
        _ tools: [ToolDefinition],
        clientTrustID: String
    ) -> [String: Set<String>] {
        lock.withLock {
            let grants = Set(tools.map {
                Grant(toolID: $0.id, fingerprint: $0.securityFingerprint)
            })
            if grants.isEmpty {
                grantsByClientTrustID.removeValue(forKey: clientTrustID)
            } else {
                grantsByClientTrustID[clientTrustID] = grants
            }
            persistLocked()
            return snapshotLocked()
        }
    }

    func allowedToolIDs(
        for clientTrustID: String,
        matching tools: [ToolDefinition]
    ) -> Set<String> {
        lock.withLock {
            let grants = grantsByClientTrustID[clientTrustID] ?? []
            return Set(tools.compactMap { tool in
                grants.contains(Grant(toolID: tool.id, fingerprint: tool.securityFingerprint))
                    ? tool.id
                    : nil
            })
        }
    }

    /// Returns the number of Always Allow rules actually removed alongside the
    /// new snapshot — sign-out reports that count to the user, so it has to be
    /// measured rather than assumed.
    @discardableResult
    func removeClientTrustID(
        _ clientTrustID: String
    ) -> (removedRules: Int, snapshot: [String: Set<String>]) {
        lock.withLock {
            let removed = grantsByClientTrustID.removeValue(forKey: clientTrustID)?.count ?? 0
            persistLocked()
            return (removed, snapshotLocked())
        }
    }

    @discardableResult
    func removeToolIDFromAllClients(_ toolID: String) -> [String: Set<String>] {
        lock.withLock {
            for trustID in Array(grantsByClientTrustID.keys) {
                let remaining = Set((grantsByClientTrustID[trustID] ?? []).filter {
                    $0.toolID != toolID
                })
                if remaining.isEmpty {
                    grantsByClientTrustID.removeValue(forKey: trustID)
                } else {
                    grantsByClientTrustID[trustID] = remaining
                }
            }
            persistLocked()
            return snapshotLocked()
        }
    }

    @discardableResult
    func clear() -> (removedRules: Int, snapshot: [String: Set<String>]) {
        lock.withLock {
            let removed = grantsByClientTrustID.values.reduce(0) { $0 + $1.count }
            grantsByClientTrustID.removeAll()
            persistLocked()
            return (removed, [:])
        }
    }

    /// UI projection only. Execution must always call `isAllowed` with the
    /// current ToolDefinition so stale fingerprints remain inactive.
    func snapshot() -> [String: Set<String>] {
        lock.withLock { snapshotLocked() }
    }

    func snapshot(matching tools: [ToolDefinition]) -> [String: Set<String>] {
        lock.withLock {
            var result = [String: Set<String>]()
            for (trustID, grants) in grantsByClientTrustID {
                let matchingIDs = Set(tools.compactMap { tool in
                    grants.contains(Grant(toolID: tool.id, fingerprint: tool.securityFingerprint))
                        ? tool.id
                        : nil
                })
                if !matchingIDs.isEmpty {
                    result[trustID] = matchingIDs
                }
            }
            return result
        }
    }

    // MARK: - Persistence

    private func snapshotLocked() -> [String: Set<String>] {
        grantsByClientTrustID.mapValues { Set($0.map(\.toolID)) }
    }

    private func persistLocked() {
        let encoded = grantsByClientTrustID.mapValues { grants in
            grants.sorted {
                if $0.toolID != $1.toolID { return $0.toolID < $1.toolID }
                return $0.fingerprint < $1.fingerprint
            }
        }
        let state = PersistedState(version: 2, grantsByClientTrustID: encoded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(state) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [String: Set<Grant>] {
        guard let data = userDefaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(PersistedState.self, from: data),
              state.version == 2 else {
            return [:]
        }
        return state.grantsByClientTrustID.mapValues(Set.init)
    }
}
