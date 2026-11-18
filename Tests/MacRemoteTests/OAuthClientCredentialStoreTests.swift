import Foundation
import Testing
@testable import MacRemote

struct OAuthClientCredentialStoreTests {
    @Test func generateLoadAndClearOAuthClientCredentials() throws {
        let suiteName = "MacRemoteTests.OAuthClientCredentialStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let service = "com.macstories.MacRemote.tests.oauthClientCredentials.\(UUID().uuidString)"
        let account = "test-\(UUID().uuidString)"
        let keychain = InMemoryKeychainSecretStore()
        let store = OAuthClientCredentialStore(
            userDefaults: defaults,
            service: service,
            account: account,
            keychain: keychain
        )
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(store.load() == nil)

        let generated = try store.generate(label: "Claude")
        let second = try store.generate(label: "Raycast")
        #expect(generated.clientID.hasPrefix("macremote-oauth-"))
        #expect(generated.label == "Claude")
        #expect(second.label == "Raycast")
        #expect(generated.clientID != second.clientID)
        #expect(generated.clientSecret.count >= 40)
        #expect(
            (defaults.dictionaryRepresentation().values.contains {
                ($0 as? String) == generated.clientSecret
            }) == false)

        let reloadedStore = OAuthClientCredentialStore(
            userDefaults: defaults,
            service: service,
            account: account,
            keychain: keychain
        )
        #expect(reloadedStore.load() == generated)
        #expect(reloadedStore.loadAll() == [generated, second])

        let rotated = try #require(try reloadedStore.rotate(clientID: second.clientID))
        #expect(rotated.label == "Raycast")
        #expect(rotated.clientID != second.clientID)
        #expect(reloadedStore.loadAll() == [generated, rotated])

        try reloadedStore.delete(clientID: generated.clientID)
        #expect(reloadedStore.loadAll() == [rotated])

        reloadedStore.clear()
        #expect(reloadedStore.load() == nil)
    }

    /// A secret the Keychain will not hand over right now (after a rebuild,
    /// until the owner unlocks it) is still the owner's. Generating, replacing,
    /// or deleting another credential must leave it listed.
    @Test func changingOtherCredentialsKeepsALockedOneListed() throws {
        let suiteName = "MacRemoteTests.OAuthClientCredentialStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let keychain = InMemoryKeychainSecretStore()
        let store = OAuthClientCredentialStore(
            userDefaults: defaults,
            service: "com.macstories.MacRemote.tests.oauthClientCredentials.\(UUID().uuidString)",
            keychain: keychain
        )
        let locked = try store.generate(label: "Claude")
        let other = try store.generate(label: "Raycast")
        keychain.setLocked(true, account: locked.clientID)

        let added = try store.generate(label: "Cursor")
        let replaced = try #require(try store.rotate(clientID: other.clientID))
        try store.delete(clientID: added.clientID)

        #expect(store.loadAllDetailed(interactive: false).lockedClientIDs == [locked.clientID])
        keychain.setLocked(false, account: locked.clientID)
        #expect(store.loadAll() == [locked, replaced])
    }

    @Test func inMemoryKeychainPersistsAndDeletesByAccount() throws {
        let keychain = InMemoryKeychainSecretStore()

        try keychain.write("first", account: "one")
        try keychain.write("second", account: "two")
        #expect(try keychain.read(account: "one", interactive: false) == "first")
        #expect(try keychain.read(account: "two", interactive: true) == "second")

        keychain.delete(account: "one")
        #expect(throws: KeychainSecretStoreError.keychain(errSecItemNotFound)) {
            try keychain.read(account: "one", interactive: false)
        }
        #expect(try keychain.read(account: "two", interactive: false) == "second")
    }
}
