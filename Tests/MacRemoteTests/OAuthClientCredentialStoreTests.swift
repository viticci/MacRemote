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
