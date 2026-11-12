import Foundation
import Security
@testable import MacRemote

/// Deterministic Keychain substitute for unit tests. One instance represents
/// one service namespace and can be shared across reconstructed stores to test
/// relaunch persistence without calling Security.framework.
final class InMemoryKeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    private let writeError: KeychainSecretStoreError?

    init(writeError: KeychainSecretStoreError? = nil) {
        self.writeError = writeError
    }

    func read(account: String, interactive: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }
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
