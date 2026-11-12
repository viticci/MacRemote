import Foundation
@testable import MacRemote

/// Models under test must not probe the login Keychain or the installed helper.
/// Pass a credential store explicitly when a test needs it to survive a reload.
@MainActor
func makeTestAppModel(
    userDefaults: UserDefaults,
    toolStore: ToolRegistryStore,
    oauthClientCredentialStore: OAuthClientCredentialStore? = nil,
    connectorHeaderTokenStore: OAuthClientCredentialStore? = nil,
    localMCPScanner: LocalMCPScanner = LocalMCPScanner(),
    cliScanner: LocalCLIScanner = LocalCLIScanner(),
    provenanceInspector: any ToolProvenanceInspecting = SecStaticCodeProvenanceInspector(),
    cloudflaredManager: CloudflaredManager? = nil,
    cloudflareRunTokenStore: CloudflareRunTokenStore? = nil,
    preferencesWereReset: Bool = false
) -> AppModel {
    // Most tests model an install that has run before, whose saved tools the
    // owner has already seen. With no such marker the app treats the
    // preferences as reset and starts every saved tool Not Shared.
    _ = sweepsEmptyTestPreferencesAtExit
    if !preferencesWereReset,
       userDefaults.object(forKey: "MacRemote.seenBuiltInFileTransferToolIDs") == nil {
        userDefaults.set([String](), forKey: "MacRemote.seenBuiltInFileTransferToolIDs")
    }
    return AppModel(
        userDefaults: userDefaults,
        toolStore: toolStore,
        oauthClientCredentialStore: oauthClientCredentialStore ?? OAuthClientCredentialStore(
            userDefaults: userDefaults,
            keychain: InMemoryKeychainSecretStore()
        ),
        connectorHeaderTokenStore: connectorHeaderTokenStore ?? OAuthClientCredentialStore(
            userDefaults: userDefaults,
            service: "com.macstories.MacRemote.connectorHeaderToken",
            keychain: InMemoryKeychainSecretStore()
        ),
        localMCPScanner: localMCPScanner,
        cliScanner: cliScanner,
        provenanceInspector: provenanceInspector,
        cloudflaredManager: cloudflaredManager ?? makeIsolatedCloudflaredManager(),
        cloudflareRunTokenStore: cloudflareRunTokenStore ?? CloudflareRunTokenStore(
            keychain: InMemoryKeychainSecretStore()
        )
    )
}

/// Tests give each model its own preferences and empty them afterwards with
/// `removePersistentDomain`. That leaves an empty file behind for every test,
/// and thousands had piled up in ~/Library/Preferences. When the test process
/// ends, this deletes every such empty file. An empty one belongs to a test
/// that has finished, so the sweep is safe while other test runs are going.
private let sweepsEmptyTestPreferencesAtExit: Void = {
    atexit {
        let folder = NSHomeDirectory() + "/Library/Preferences"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names
        where name.hasPrefix("MacRemote") && name.contains("Tests.") && name.hasSuffix(".plist") {
            let path = folder + "/" + name
            guard let data = FileManager.default.contents(atPath: path), data.count < 128,
                  let contents = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  (contents as? [String: Any])?.isEmpty == true else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}()
