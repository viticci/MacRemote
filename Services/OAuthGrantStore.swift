import Foundation

struct OAuthGrantSnapshot: Codable, Equatable, Sendable {
    var clients: [OAuthStoredClient]
    var accessTokens: [OAuthStoredToken]
    var refreshTokens: [OAuthStoredToken]

    static let empty = OAuthGrantSnapshot(clients: [], accessTokens: [], refreshTokens: [])
}

struct OAuthStoredClient: Codable, Equatable, Sendable {
    let id: String
    let trustID: String?
    let name: String
    let redirectURIs: [String]
    let scopes: [String]
    let createdAt: Date
}

struct OAuthStoredToken: Codable, Equatable, Sendable {
    let tokenHash: String
    let clientID: String
    let issuer: String
    let resource: String
    let scopes: [String]
    let issuedAt: Date
    let expiresAt: Date
}

struct OAuthGrantStore: @unchecked Sendable {
    private static let storageKey = "MacRemote.oauthGrants"

    private let userDefaults: UserDefaults
    private let storageKey: String

    init(userDefaults: UserDefaults = .standard, storageKey: String = Self.storageKey) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
    }

    func loadSnapshot() throws -> OAuthGrantSnapshot {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return .empty
        }
        return try JSONDecoder().decode(OAuthGrantSnapshot.self, from: data)
    }

    func saveSnapshot(_ snapshot: OAuthGrantSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        userDefaults.set(data, forKey: storageKey)
    }

    func clear() {
        userDefaults.removeObject(forKey: storageKey)
    }
}
