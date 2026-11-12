import Foundation
@testable import MacRemote

/// Every `AppModel` a test builds has to own its Cloudflare helper.
///
/// The default `CloudflaredManager` reads the real
/// `~/Library/Application Support/MacRemote/CloudflaredHelper` and the real
/// `ExecutableLocator` search path, so `tunnelStatus` — and everything derived
/// from it, including `connectionReadiness` — would depend on whether this
/// particular Mac happens to have Homebrew's `cloudflared` installed. Pinning
/// the external resolver to a file that always exists makes "a helper is
/// available" a constant of the test, not a property of the machine.
@MainActor
func makeIsolatedCloudflaredManager(
    externalPath: String? = "/usr/bin/true"
) -> CloudflaredManager {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacRemoteTests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent(CloudflaredInstallStore.directoryName, isDirectory: true)
    return CloudflaredManager(
        store: CloudflaredInstallStore(rootDirectory: root),
        externalResolver: { externalPath }
    )
}
