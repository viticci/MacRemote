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
    let authenticationMethod: String?
    let secretHash: String?

    init(
        id: String,
        trustID: String?,
        name: String,
        redirectURIs: [String],
        scopes: [String],
        createdAt: Date,
        authenticationMethod: String? = nil,
        secretHash: String? = nil
    ) {
        self.id = id
        self.trustID = trustID
        self.name = name
        self.redirectURIs = redirectURIs
        self.scopes = scopes
        self.createdAt = createdAt
        self.authenticationMethod = authenticationMethod
        self.secretHash = secretHash
    }
}

/// One saved access or refresh token. The last two fields are optional so a
/// file written before they existed still loads.
struct OAuthStoredToken: Codable, Equatable, Sendable {
    let tokenHash: String
    let clientID: String
    let issuer: String
    let resource: String
    let scopes: [String]
    let issuedAt: Date
    let expiresAt: Date
    /// The approved sign-in this token came from.
    let signInID: String?
    /// Refresh tokens only: the hash of the token this one replaced.
    let replacedTokenHash: String?

    init(
        tokenHash: String,
        clientID: String,
        issuer: String,
        resource: String,
        scopes: [String],
        issuedAt: Date,
        expiresAt: Date,
        signInID: String? = nil,
        replacedTokenHash: String? = nil
    ) {
        self.tokenHash = tokenHash
        self.clientID = clientID
        self.issuer = issuer
        self.resource = resource
        self.scopes = scopes
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.signInID = signInID
        self.replacedTokenHash = replacedTokenHash
    }
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
