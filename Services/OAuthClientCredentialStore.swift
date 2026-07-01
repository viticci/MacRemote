import Foundation
import Security

struct OAuthClientCredentials: Equatable, Sendable {
    let clientID: String
    let clientSecret: String
    let createdAt: Date
}

enum OAuthClientCredentialStoreError: LocalizedError, Equatable {
    case randomGenerationFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .randomGenerationFailed:
            "Could not generate secure OAuth client credentials."
        case .keychain(let status):
            "Could not save OAuth client credentials to Keychain (OSStatus \(status))."
        }
    }
}

struct OAuthClientCredentialStore: @unchecked Sendable {
    private static let clientIDKey = "MacRemote.oauthClientCredentials.clientID"
    private static let createdAtKey = "MacRemote.oauthClientCredentials.createdAt"

    private let userDefaults: UserDefaults
    private let service: String
    private let account: String

    init(
        userDefaults: UserDefaults = .standard,
        service: String = "com.macstories.MacRemote.oauthClientCredentials",
        account: String = "default"
    ) {
        self.userDefaults = userDefaults
        self.service = service
        self.account = account
    }

    func load() -> OAuthClientCredentials? {
        guard let clientID = userDefaults.string(forKey: Self.clientIDKey),
              !clientID.isEmpty,
              let clientSecret = try? readSecret(),
              !clientSecret.isEmpty else {
            return nil
        }
        let createdAtTimestamp = userDefaults.double(forKey: Self.createdAtKey)
        let createdAt = createdAtTimestamp > 0 ? Date(timeIntervalSince1970: createdAtTimestamp) : Date()
        return OAuthClientCredentials(clientID: clientID, clientSecret: clientSecret, createdAt: createdAt)
    }

    func generate() throws -> OAuthClientCredentials {
        let credentials = OAuthClientCredentials(
            clientID: "macremote-oauth-\(try Self.randomToken(byteCount: 18))",
            clientSecret: try Self.randomToken(byteCount: 36),
            createdAt: Date()
        )
        try save(credentials)
        return credentials
    }

    func save(_ credentials: OAuthClientCredentials) throws {
        try writeSecret(credentials.clientSecret)
        userDefaults.set(credentials.clientID, forKey: Self.clientIDKey)
        userDefaults.set(credentials.createdAt.timeIntervalSince1970, forKey: Self.createdAtKey)
    }

    func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        userDefaults.removeObject(forKey: Self.clientIDKey)
        userDefaults.removeObject(forKey: Self.createdAtKey)
    }

    private func readSecret() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw OAuthClientCredentialStoreError.keychain(status)
        }
        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw OAuthClientCredentialStoreError.keychain(errSecDecode)
        }
        return secret
    }

    private func writeSecret(_ secret: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery()
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw OAuthClientCredentialStoreError.keychain(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw OAuthClientCredentialStoreError.keychain(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private static func randomToken(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw OAuthClientCredentialStoreError.randomGenerationFailed
        }
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
