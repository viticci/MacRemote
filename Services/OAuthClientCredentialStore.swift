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
    static let defaultService = "com.macstories.MacRemote.oauthClientCredentials"

    private static let clientIDKey = "MacRemote.oauthClientCredentials.clientID"
    private static let createdAtKey = "MacRemote.oauthClientCredentials.createdAt"
    private static let credentialsMetadataKey = "MacRemote.oauthClientCredentials.items"

    private struct Metadata: Codable, Equatable {
        var label: String
        var clientID: String
        var createdAt: Date

        init(_ credential: OAuthClientCredentials) {
            label = credential.label
            clientID = credential.clientID
            createdAt = credential.createdAt
        }
    }

    private let userDefaults: UserDefaults
    private let keychain: any KeychainSecretStoring
    private let legacyAccount: String
    // The UserDefaults keys are derived from the service so two stores (OAuth
    // client credentials, connector header token) never share metadata. The
    // default service keeps its historical key names.
    private let metadataDefaultsKey: String
    private let legacyClientIDDefaultsKey: String
    private let legacyCreatedAtDefaultsKey: String

    init(
        userDefaults: UserDefaults = .standard,
        service: String = OAuthClientCredentialStore.defaultService,
        account: String = "default",
        keychain: (any KeychainSecretStoring)? = nil
    ) {
        self.userDefaults = userDefaults
        self.keychain = keychain ?? KeychainSecretStore(service: service)
        self.legacyAccount = account
        if service == Self.defaultService {
            self.metadataDefaultsKey = Self.credentialsMetadataKey
            self.legacyClientIDDefaultsKey = Self.clientIDKey
            self.legacyCreatedAtDefaultsKey = Self.createdAtKey
        } else {
            self.metadataDefaultsKey = "\(service).items"
            self.legacyClientIDDefaultsKey = "\(service).clientID"
            self.legacyCreatedAtDefaultsKey = "\(service).createdAt"
        }
    }

    func load() -> OAuthClientCredentials? {
        loadAll().first
    }

    func loadAll() -> [OAuthClientCredentials] {
        loadAllDetailed(interactive: true).credentials
    }

    /// Non-interactive loads never trigger the macOS Keychain password prompt:
    /// after a re-sign/rebuild the item ACL no longer matches the binary, and a
    /// startup-time prompt blocks the app before its first window (observed on
    /// macOS 27). Locked entries are reported so the UI can offer a
    /// user-initiated unlock instead.
    func loadAllDetailed(interactive: Bool) -> (credentials: [OAuthClientCredentials], lockedClientIDs: [String]) {
        var locked: [String] = []

        if let metadata = loadMetadata() {
            let credentials: [OAuthClientCredentials] = metadata.compactMap { item in
                guard !item.clientID.isEmpty else { return nil }
                do {
                    let clientSecret = try readSecret(account: item.clientID, interactive: interactive)
                    guard !clientSecret.isEmpty else { return nil }
                    return OAuthClientCredentials(
                        label: item.label,
                        clientID: item.clientID,
                        clientSecret: clientSecret,
                        createdAt: item.createdAt
                    )
                } catch OAuthClientCredentialStoreError.keychain(let status)
                    where status == errSecInteractionNotAllowed || status == errSecAuthFailed {
                    locked.append(item.clientID)
                    return nil
                } catch {
                    return nil
                }
            }
            return (credentials, locked)
        }

        guard let legacy = loadLegacyCredential(interactive: interactive, lockedClientIDs: &locked) else {
            return ([], locked)
        }
        return ([legacy], locked)
    }

    private func loadLegacyCredential(interactive: Bool, lockedClientIDs: inout [String]) -> OAuthClientCredentials? {
        guard let clientID = userDefaults.string(forKey: legacyClientIDDefaultsKey),
              !clientID.isEmpty else {
            return nil
        }
        let clientSecret: String
        do {
            clientSecret = try readSecret(account: legacyAccount, interactive: interactive)
        } catch OAuthClientCredentialStoreError.keychain(let status)
            where status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            lockedClientIDs.append(clientID)
            return nil
        } catch {
            return nil
        }
        guard !clientSecret.isEmpty else {
            return nil
        }
        let createdAtTimestamp = userDefaults.double(forKey: legacyCreatedAtDefaultsKey)
        let createdAt = createdAtTimestamp > 0 ? Date(timeIntervalSince1970: createdAtTimestamp) : Date()
        return OAuthClientCredentials(
            label: "OAuth Client",
            clientID: clientID,
            clientSecret: clientSecret,
            createdAt: createdAt
        )
    }

    func generate(label: String = "OAuth Client") throws -> OAuthClientCredentials {
        var listed = try listedMetadata()
        let credential = OAuthClientCredentials(
            label: Self.normalizedLabel(label, existingLabels: Set(listed.map(\.label))),
            clientID: "macremote-oauth-\(try Self.randomToken(byteCount: 18))",
            clientSecret: try Self.randomToken(byteCount: 36),
            createdAt: Date()
        )
        try writeSecret(credential.clientSecret, account: credential.clientID)
        listed.append(Metadata(credential))
        saveListed(listed)
        return credential
    }

    func save(_ credentials: OAuthClientCredentials) throws {
        try saveAll([credentials])
    }

    func rotate(clientID: String) throws -> OAuthClientCredentials? {
        var listed = try listedMetadata()
        guard let index = listed.firstIndex(where: { $0.clientID == clientID }) else {
            return nil
        }
        let replacement = OAuthClientCredentials(
            label: listed[index].label,
            clientID: "macremote-oauth-\(try Self.randomToken(byteCount: 18))",
            clientSecret: try Self.randomToken(byteCount: 36),
            createdAt: Date()
        )
        try writeSecret(replacement.clientSecret, account: replacement.clientID)
        listed[index] = Metadata(replacement)
        saveListed(listed)
        deleteSecret(account: clientID)
        return replacement
    }

    func delete(clientID: String) throws {
        saveListed(try listedMetadata().filter { $0.clientID != clientID })
        deleteSecret(account: clientID)
        if userDefaults.string(forKey: legacyClientIDDefaultsKey) == clientID {
            userDefaults.removeObject(forKey: legacyClientIDDefaultsKey)
            userDefaults.removeObject(forKey: legacyCreatedAtDefaultsKey)
            deleteSecret(account: legacyAccount)
        }
    }

    private func saveAll(_ credentials: [OAuthClientCredentials]) throws {
        for credential in credentials {
            try writeSecret(credential.clientSecret, account: credential.clientID)
        }
        saveListed(credentials.map(Metadata.init))
    }

    /// Every credential the store lists, including one whose secret the
    /// Keychain will not hand over right now (after a rebuild, until the owner
    /// unlocks it). A change builds its new list from this, never from
    /// `loadAll()`, which leaves such a credential out and would erase it.
    private func listedMetadata() throws -> [Metadata] {
        if let metadata = loadMetadata() {
            return metadata.filter { !$0.clientID.isEmpty }
        }
        // A store from before the list holds one credential outside it. Its
        // secret moves under its own account when the list is first written.
        let legacy = loadAll()
        for credential in legacy {
            try writeSecret(credential.clientSecret, account: credential.clientID)
        }
        return legacy.map(Metadata.init)
    }

    private func saveListed(_ metadata: [Metadata]) {
        saveMetadata(metadata)

        if let first = metadata.first {
            userDefaults.set(first.clientID, forKey: legacyClientIDDefaultsKey)
            userDefaults.set(first.createdAt.timeIntervalSince1970, forKey: legacyCreatedAtDefaultsKey)
        } else {
            userDefaults.removeObject(forKey: legacyClientIDDefaultsKey)
            userDefaults.removeObject(forKey: legacyCreatedAtDefaultsKey)
        }
    }

    func clear() {
        for item in loadMetadata() ?? [] {
            deleteSecret(account: item.clientID)
        }
        deleteSecret(account: legacyAccount)
        userDefaults.removeObject(forKey: legacyClientIDDefaultsKey)
        userDefaults.removeObject(forKey: legacyCreatedAtDefaultsKey)
        userDefaults.removeObject(forKey: metadataDefaultsKey)
    }

    // Keychain mechanics live in KeychainSecretStore; these wrappers keep the
    // store's public thrown-error type stable. Locked entries surface in
    // Settings › Security for a user-initiated unlock.
    private func readSecret(account: String, interactive: Bool = true) throws -> String {
        do {
            return try keychain.read(account: account, interactive: interactive)
        } catch let KeychainSecretStoreError.keychain(status) {
            throw OAuthClientCredentialStoreError.keychain(status)
        }
    }

    private func writeSecret(_ secret: String, account: String) throws {
        do {
            try keychain.write(secret, account: account)
        } catch let KeychainSecretStoreError.keychain(status) {
            throw OAuthClientCredentialStoreError.keychain(status)
        }
    }

    private func deleteSecret(account: String) {
        keychain.delete(account: account)
    }

    private func loadMetadata() -> [Metadata]? {
        guard let data = userDefaults.data(forKey: metadataDefaultsKey) else {
            return nil
        }
        return try? JSONDecoder().decode([Metadata].self, from: data)
    }

    private func saveMetadata(_ metadata: [Metadata]) {
        guard let data = try? JSONEncoder().encode(metadata) else {
            return
        }
        userDefaults.set(data, forKey: metadataDefaultsKey)
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
