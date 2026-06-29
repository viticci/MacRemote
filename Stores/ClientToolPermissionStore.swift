import Foundation

final class ClientToolPermissionStore: @unchecked Sendable {
    private static let storageKey = "MacRemote.clientToolPermissions"

    private let lock = NSLock()
    private let userDefaults: UserDefaults
    private var allowedToolIDsByClientID: [String: Set<String>]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.allowedToolIDsByClientID = Self.load(from: userDefaults)
    }

    func isAllowed(clientID: String, clientTrustID: String? = nil, toolID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let clientTrustID, allowedToolIDsByClientID[clientTrustID]?.contains(toolID) == true {
            return true
        }
        return allowedToolIDsByClientID[clientID]?.contains(toolID) == true
    }

    func allowedToolIDs(for clientID: String, clientTrustID: String? = nil) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        var toolIDs = allowedToolIDsByClientID[clientID] ?? []
        if let clientTrustID {
            toolIDs.formUnion(allowedToolIDsByClientID[clientTrustID] ?? [])
        }
        return toolIDs
    }

    func setAllowed(_ isAllowed: Bool, clientID: String, clientTrustID: String? = nil, toolID: String) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }

        let storageID = clientTrustID ?? clientID
        var tools = allowedToolIDsByClientID[storageID] ?? []
        if isAllowed {
            tools.insert(toolID)
        } else {
            tools.remove(toolID)
            allowedToolIDsByClientID[clientID]?.remove(toolID)
            if allowedToolIDsByClientID[clientID]?.isEmpty == true {
                allowedToolIDsByClientID.removeValue(forKey: clientID)
            }
        }

        if tools.isEmpty {
            allowedToolIDsByClientID.removeValue(forKey: storageID)
        } else {
            allowedToolIDsByClientID[storageID] = tools
        }
        persistLocked()
        return allowedToolIDsByClientID
    }

    func replaceAllowedToolIDs(_ toolIDs: Set<String>, clientID: String, clientTrustID: String? = nil) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }

        let storageID = clientTrustID ?? clientID
        if toolIDs.isEmpty {
            allowedToolIDsByClientID.removeValue(forKey: storageID)
        } else {
            allowedToolIDsByClientID[storageID] = toolIDs
        }
        if let clientTrustID, clientTrustID != clientID {
            allowedToolIDsByClientID.removeValue(forKey: clientID)
        }
        persistLocked()
        return allowedToolIDsByClientID
    }

    func removeClient(_ clientID: String, clientTrustID: String? = nil) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        allowedToolIDsByClientID.removeValue(forKey: clientID)
        if let clientTrustID {
            allowedToolIDsByClientID.removeValue(forKey: clientTrustID)
        }
        persistLocked()
        return allowedToolIDsByClientID
    }

    func migrateClientAllowances(clientID: String, clientTrustID: String) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }

        guard clientID != clientTrustID,
              let legacyToolIDs = allowedToolIDsByClientID.removeValue(forKey: clientID),
              !legacyToolIDs.isEmpty else {
            return allowedToolIDsByClientID
        }

        var trustedToolIDs = allowedToolIDsByClientID[clientTrustID] ?? []
        trustedToolIDs.formUnion(legacyToolIDs)
        allowedToolIDsByClientID[clientTrustID] = trustedToolIDs
        persistLocked()
        return allowedToolIDsByClientID
    }

    func removeToolIDFromAllClients(_ toolID: String) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        for clientID in Array(allowedToolIDsByClientID.keys) {
            allowedToolIDsByClientID[clientID]?.remove(toolID)
            if allowedToolIDsByClientID[clientID]?.isEmpty == true {
                allowedToolIDsByClientID.removeValue(forKey: clientID)
            }
        }
        persistLocked()
        return allowedToolIDsByClientID
    }

    func clear() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        allowedToolIDsByClientID.removeAll()
        persistLocked()
        return allowedToolIDsByClientID
    }

    func snapshot() -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        return allowedToolIDsByClientID
    }

    private func persistLocked() {
        let encoded = allowedToolIDsByClientID.mapValues { $0.sorted() }
        userDefaults.set(encoded, forKey: Self.storageKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [String: Set<String>] {
        guard let object = userDefaults.dictionary(forKey: storageKey) as? [String: [String]] else {
            return [:]
        }
        return object.mapValues(Set.init)
    }
}
