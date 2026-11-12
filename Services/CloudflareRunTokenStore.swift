import Foundation

/// Keeps the one Cloudflare secret MacRemote saves: the run token of the
/// deployed Your Domain tunnel, in the Keychain. The token lets Cloudflare's
/// helper connect that one tunnel. It cannot create tunnels or change DNS,
/// which is why it is saved and the API token never is. With it, a deployed
/// domain goes public again after a relaunch without Cloudflare credentials.
struct CloudflareRunTokenStore: Sendable {
    static let keychainService = "com.macstories.MacRemote.cloudflareRunToken"
    /// One deployed domain, so one item. A fixed name means a delete always
    /// finds it, whatever happened to the saved preferences.
    private static let account = "yourDomain"

    private struct SavedToken: Codable {
        let tunnelID: String
        let token: String
    }

    private let keychain: any KeychainSecretStoring

    init(keychain: (any KeychainSecretStoring)? = nil) {
        self.keychain = keychain ?? KeychainSecretStore(service: Self.keychainService)
    }

    /// Replaces whatever was saved, so a new deploy leaves no older token.
    func save(_ token: String, tunnelID: String) throws {
        let data = try JSONEncoder().encode(SavedToken(tunnelID: tunnelID, token: token))
        try keychain.write(String(decoding: data, as: UTF8.self), account: Self.account)
    }

    /// The saved token, only when it was saved for this tunnel. Never shows a
    /// Keychain prompt: a locked or missing item reads as nothing saved, and
    /// the owner deploys again instead.
    func token(forTunnelID tunnelID: String) -> String? {
        guard let raw = try? keychain.read(account: Self.account, interactive: false),
              let saved = try? JSONDecoder().decode(SavedToken.self, from: Data(raw.utf8)),
              saved.tunnelID == tunnelID,
              !saved.token.isEmpty else {
            return nil
        }
        return saved.token
    }

    func delete() {
        keychain.delete(account: Self.account)
    }
}
