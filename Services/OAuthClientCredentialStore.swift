import Foundation
import Security

struct OAuthClientCredentials: Equatable, Sendable {
    let label: String
    let clientID: String
    let clientSecret: String
    let createdAt: Date

    init(
        label: String,
        clientID: String,
        clientSecret: String,
        createdAt: Date
    ) {
        self.label = label
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.createdAt = createdAt
    }
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
    private static let credentialsMetadataKey = "MacRemote.oauthClientCredentials.items"

    private struct Metadata: Codable, Equatable {
        var label: String
        var clientID: String
        var createdAt: Date
    }

    private let userDefaults: UserDefaults
    private let service: String
    private let legacyAccount: String

    init(
        userDefaults: UserDefaults = .standard,
        service: String = "com.macstories.MacRemote.oauthClientCredentials",
        account: String = "default"
    ) {
        self.userDefaults = userDefaults
        self.service = service
        self.legacyAccount = account
    }

    func load() -> OAuthClientCredentials? {
        loadAll().first
    }

    func loadAll() -> [OAuthClientCredentials] {
        if let metadata = loadMetadata() {
            return metadata.compactMap { item in
                guard !item.clientID.isEmpty,
                      let clientSecret = try? readSecret(account: item.clientID),
                      !clientSecret.isEmpty else {
                    return nil
                }
                return OAuthClientCredentials(
                    label: item.label,
                    clientID: item.clientID,
                    clientSecret: clientSecret,
                    createdAt: item.createdAt
                )
            }
        }

        guard let legacy = loadLegacyCredential() else {
            return []
        }
        return [legacy]
    }

    private func loadLegacyCredential() -> OAuthClientCredentials? {
        guard let clientID = userDefaults.string(forKey: Self.clientIDKey),
              !clientID.isEmpty,
              let clientSecret = try? readSecret(account: legacyAccount),
              !clientSecret.isEmpty else {
            return nil
        }
        let createdAtTimestamp = userDefaults.double(forKey: Self.createdAtKey)
        let createdAt = createdAtTimestamp > 0 ? Date(timeIntervalSince1970: createdAtTimestamp) : Date()
        return OAuthClientCredentials(
            label: "OAuth Client",
            clientID: clientID,
            clientSecret: clientSecret,
            createdAt: createdAt
        )
    }

    func generate(label: String = "OAuth Client") throws -> OAuthClientCredentials {
        var allCredentials = loadAll()
        let credential = OAuthClientCredentials(
            label: Self.normalizedLabel(label, existingLabels: Set(allCredentials.map(\.label))),
            clientID: "macremote-oauth-\(try Self.randomToken(byteCount: 18))",
            clientSecret: try Self.randomToken(byteCount: 36),
            createdAt: Date()
        )
        allCredentials.append(credential)
        try saveAll(allCredentials)
        return credential
    }

    func save(_ credentials: OAuthClientCredentials) throws {
        try saveAll([credentials])
    }

    func rotate(clientID: String) throws -> OAuthClientCredentials? {
        var credentials = loadAll()
        guard let index = credentials.firstIndex(where: { $0.clientID == clientID }) else {
            return nil
        }
        let existing = credentials[index]
        let replacement = OAuthClientCredentials(
            label: existing.label,
            clientID: "macremote-oauth-\(try Self.randomToken(byteCount: 18))",
            clientSecret: try Self.randomToken(byteCount: 36),
            createdAt: Date()
        )
        credentials[index] = replacement
        try saveAll(credentials)
        deleteSecret(account: clientID)
        return replacement
    }

    func delete(clientID: String) throws {
        let credentials = loadAll().filter { $0.clientID != clientID }
        try saveAll(credentials)
        deleteSecret(account: clientID)
        if userDefaults.string(forKey: Self.clientIDKey) == clientID {
            userDefaults.removeObject(forKey: Self.clientIDKey)
            userDefaults.removeObject(forKey: Self.createdAtKey)
            deleteSecret(account: legacyAccount)
        }
    }

    private func saveAll(_ credentials: [OAuthClientCredentials]) throws {
        for credential in credentials {
            try writeSecret(credential.clientSecret, account: credential.clientID)
        }
        saveMetadata(
            credentials.map {
                Metadata(label: $0.label, clientID: $0.clientID, createdAt: $0.createdAt)
            }
        )

        if let first = credentials.first {
            userDefaults.set(first.clientID, forKey: Self.clientIDKey)
            userDefaults.set(first.createdAt.timeIntervalSince1970, forKey: Self.createdAtKey)
        } else {
            userDefaults.removeObject(forKey: Self.clientIDKey)
            userDefaults.removeObject(forKey: Self.createdAtKey)
        }
    }

    func clear() {
        for credential in loadAll() {
            deleteSecret(account: credential.clientID)
        }
        deleteSecret(account: legacyAccount)
        userDefaults.removeObject(forKey: Self.clientIDKey)
        userDefaults.removeObject(forKey: Self.createdAtKey)
        userDefaults.removeObject(forKey: Self.credentialsMetadataKey)
    }

    private func readSecret(account: String) throws -> String {
        var query = baseQuery(account: account)
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

    private func writeSecret(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let query = baseQuery(account: account)
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

    private func deleteSecret(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func loadMetadata() -> [Metadata]? {
        guard let data = userDefaults.data(forKey: Self.credentialsMetadataKey) else {
            return nil
        }
        return try? JSONDecoder().decode([Metadata].self, from: data)
    }

    private func saveMetadata(_ metadata: [Metadata]) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }
        userDefaults.set(data, forKey: Self.credentialsMetadataKey)
    }

    private static func normalizedLabel(_ label: String, existingLabels: Set<String>) -> String {
        let base = label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "OAuth Client"
            : String(label.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard existingLabels.contains(base) else {
            return base
        }

        for index in 2...999 {
            let candidate = "\(base) \(index)"
            if !existingLabels.contains(candidate) {
                return candidate
            }
        }
        return "\(base) \(Int(Date().timeIntervalSince1970))"
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
