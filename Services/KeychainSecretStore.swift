import Foundation
import LocalAuthentication
import Security

enum KeychainSecretStoreError: LocalizedError, Equatable {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            "Keychain operation failed (OSStatus \(status))."
        }
    }
}

/// Minimal credential-storage boundary. Production uses the macOS Keychain;
/// tests can inject a deterministic in-memory implementation without touching
/// the user's login keychain or changing any credential-store behavior.
protocol KeychainSecretStoring: Sendable {
    func read(account: String, interactive: Bool) throws -> String
    func write(_ secret: String, account: String) throws
    func delete(account: String)
}

/// Service-scoped generic-password storage shared by every credential store
/// (OAuth client secrets, connector header tokens).
/// Owns the two subtleties no caller should reimplement: the
/// data-protection-vs-file-keychain probe, and non-interactive reads that can
/// never block launch on a SecurityAgent password prompt.
struct KeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    let service: String
    /// The data-protection keychain (which honors LAContext for prompt-free
    /// non-interactive reads) requires the app to be code-signed with an
    /// application-identifier. The signed .app has it; an unsigned `swift test`
    /// / `swift run` process does not and would get errSecMissingEntitlement, so
    /// fall back to the file keychain there. Probed once per store.
    private let usesDataProtectionKeychain: Bool

    init(service: String) {
        self.service = service
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

    func read(account: String, interactive: Bool = true) throws -> String {
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
        // the process-wide interaction gate instead.
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
            throw KeychainSecretStoreError.keychain(status)
        }
        guard let data = item as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            throw KeychainSecretStoreError.keychain(errSecDecode)
        }
        return secret
    }

    func write(_ secret: String, account: String) throws {
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
            throw KeychainSecretStoreError.keychain(updateStatus)
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainSecretStoreError.keychain(addStatus)
        }
    }

    func delete(account: String) {
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
