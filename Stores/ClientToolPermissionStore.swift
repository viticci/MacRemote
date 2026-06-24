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

    func isAllowed(clientID: String, toolID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowedToolIDsByClientID[clientID]?.contains(toolID) == true
    }

    func allowedToolIDs(for clientID: String) -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return allowedToolIDsByClientID[clientID] ?? []
    }

    func setAllowed(_ isAllowed: Bool, clientID: String, toolID: String) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }

        var tools = allowedToolIDsByClientID[clientID] ?? []
        if isAllowed {
            tools.insert(toolID)
        } else {
            tools.remove(toolID)
        }

        if tools.isEmpty {
            allowedToolIDsByClientID.removeValue(forKey: clientID)
        } else {
            allowedToolIDsByClientID[clientID] = tools
        }
        persistLocked()
        return allowedToolIDsByClientID
    }

    func replaceAllowedToolIDs(_ toolIDs: Set<String>, clientID: String) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }

        if toolIDs.isEmpty {
            allowedToolIDsByClientID.removeValue(forKey: clientID)
        } else {
            allowedToolIDsByClientID[clientID] = toolIDs
        }
        persistLocked()
        return allowedToolIDsByClientID
    }

    func removeClient(_ clientID: String) -> [String: Set<String>] {
        lock.lock()
        defer { lock.unlock() }
        allowedToolIDsByClientID.removeValue(forKey: clientID)
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
