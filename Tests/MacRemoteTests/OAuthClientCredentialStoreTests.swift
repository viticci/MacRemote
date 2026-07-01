import XCTest
@testable import MacRemote

final class OAuthClientCredentialStoreTests: XCTestCase {
    func testGenerateLoadAndClearOAuthClientCredentials() throws {
        let suiteName = "MacRemoteTests.OAuthClientCredentialStore.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

        XCTAssertNil(store.load())

        let generated: OAuthClientCredentials
        do {
            generated = try store.generate()
        } catch OAuthClientCredentialStoreError.keychain(errSecInteractionNotAllowed) {
            throw XCTSkip("Keychain writes are not available to this test runner.")
        }
        XCTAssertTrue(generated.clientID.hasPrefix("macremote-oauth-"))
        XCTAssertGreaterThanOrEqual(generated.clientSecret.count, 40)
        XCTAssertFalse(
            defaults.dictionaryRepresentation().values.contains {
                ($0 as? String) == generated.clientSecret
            }
        )

        let reloadedStore = OAuthClientCredentialStore(
            userDefaults: defaults,
            service: service,
            account: account
        )
        XCTAssertEqual(reloadedStore.load(), generated)

        reloadedStore.clear()
        XCTAssertNil(reloadedStore.load())
    }
}
