import Foundation
import Security
import Testing
@testable import MacRemote

struct OAuthClientCredentialStoreTests {
    @Test func generateLoadAndClearOAuthClientCredentials() throws {
        let suiteName = "MacRemoteTests.OAuthClientCredentialStore.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)

        let service = "com.macstories.MacRemote.tests.oauthClientCredentials.\(UUID().uuidString)"
        let account = "test-\(UUID().uuidString)"
        let store = OAuthClientCredentialStore(
            userDefaults: defaults,
            service: service,
            account: account
        )
        defer {
            store.clear()
            defaults.removePersistentDomain(forName: suiteName)
        }

        #expect(store.load() == nil)

        let generated: OAuthClientCredentials
        let second: OAuthClientCredentials
        do {
            generated = try store.generate(label: "Claude")
            second = try store.generate(label: "Raycast")
        } catch OAuthClientCredentialStoreError.keychain(errSecInteractionNotAllowed) {
            // Keychain writes are not available to this test runner (Swift Testing
            // has no runtime skip, so pass without exercising the remaining checks).
            return
        }
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
            account: account
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
}
