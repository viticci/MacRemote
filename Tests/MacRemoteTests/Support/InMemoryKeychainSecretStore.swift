import Foundation
import Security
@testable import MacRemote

/// Deterministic Keychain substitute for unit tests. One instance represents
/// one service namespace and can be shared across reconstructed stores to test
/// relaunch persistence without calling Security.framework.
final class InMemoryKeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private var lockedAccounts: Set<String> = []
    private let writeError: KeychainSecretStoreError?

    init(writeError: KeychainSecretStoreError? = nil) {
        self.writeError = writeError
    }

    /// Makes reads of one account fail the way a real item does after a
    /// rebuild, when its access list no longer matches the app.
    func setLocked(_ isLocked: Bool, account: String) {
        lock.lock()
        defer { lock.unlock() }
        if isLocked {
            lockedAccounts.insert(account)
        } else {
            lockedAccounts.remove(account)
        }
    }

    func read(account: String, interactive: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if lockedAccounts.contains(account) {
            throw KeychainSecretStoreError.keychain(errSecInteractionNotAllowed)
        }
        guard let secret = secrets[account] else {
            throw KeychainSecretStoreError.keychain(errSecItemNotFound)
        }
        return secret
    }

    func write(_ secret: String, account: String) throws {
        if let writeError { throw writeError }
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func delete(account: String) {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}
