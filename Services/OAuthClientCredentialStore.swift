import Foundation
import LocalAuthentication
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
    /// The data-protection keychain (which honors LAContext for prompt-free
    /// non-interactive reads) requires the app to be code-signed with an
    /// application-identifier. The signed .app has it; an unsigned `swift test`
    /// / `swift run` process does not and would get errSecMissingEntitlement, so
    /// fall back to the file keychain there. Probed once per store.
    private let usesDataProtectionKeychain: Bool

    init(
        userDefaults: UserDefaults = .standard,
        service: String = "com.macstories.MacRemote.oauthClientCredentials",
        account: String = "default"
    ) {
        self.userDefaults = userDefaults
        self.service = service
        self.legacyAccount = account
        self.usesDataProtectionKeychain = Self.dataProtectionKeychainAvailable(service: service)
    }

    private static func dataProtectionKeychainAvailable(service: String) -> Bool {
        // A read of an absent item returns errSecItemNotFound even when the
        // process lacks the entitlement, so probe with a real add+delete — the
        // same path that would otherwise fail with errSecMissingEntitlement.
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "\(service).__probe",
            kSecAttrAccount as String: "__probe",
            kSecValueData as String: Data("probe".utf8),
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(probe as CFDictionary)
        let addStatus = SecItemAdd(probe as CFDictionary, nil)
        if addStatus == errSecSuccess {
            SecItemDelete(probe as CFDictionary)
            return true
        }
        return addStatus != errSecMissingEntitlement
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
        guard let clientID = userDefaults.string(forKey: Self.clientIDKey),
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

    private func readSecret(account: String, interactive: Bool = true) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard !interactive else {
            return try copyMatchingSecret(query)
        }

        // Non-interactive reads must never block launch on a SecurityAgent
        // password prompt (observed after re-signed rebuilds on macOS 27).
        // Data-protection keychain honors LAContext.interactionNotAllowed; the
        // legacy file keychain (where a dev-signed app without the
        // application-identifier entitlement stores items) ignores it and needs
        // the process-wide interaction gate instead. Locked entries surface in
        // Settings › Security for a user-initiated unlock.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        if usesDataProtectionKeychain {
            return try copyMatchingSecret(query)
        }
        return try legacyKeychainGate.withInteractionDisabled {
            try copyMatchingSecret(query)
        }
    }

    private func copyMatchingSecret(_ query: [String: Any]) throws -> String {
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
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Modern keychain (signed app): honors LAContext for non-interactive
        // reads and avoids the legacy login-keychain ACL password prompt.
        if usesDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
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

// The SecKeychain* interaction gate is the only way to suppress the
// SecurityAgent prompt for file-based keychain items. The APIs are deprecated;
// the protocol indirection scopes that deprecation to the one implementation
// method (deprecated contexts don't re-warn) while call sites stay warning-free.
private protocol LegacyKeychainInteractionGating: Sendable {
    func withInteractionDisabled<T>(_ body: () throws -> T) rethrows -> T
}

private struct LegacyKeychainInteractionGate: LegacyKeychainInteractionGating {
    @available(macOS, deprecated: 12.0, message: "file-keychain-only escape hatch")
    func withInteractionDisabled<T>(_ body: () throws -> T) rethrows -> T {
        var wasAllowed: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&wasAllowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer {
            SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue)
        }
        return try body()
    }
}

private let legacyKeychainGate: any LegacyKeychainInteractionGating = LegacyKeychainInteractionGate()
