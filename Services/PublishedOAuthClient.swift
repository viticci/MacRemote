import Foundation

/// An app that names itself with a web address instead of registering: its
/// client ID is the address of a document it publishes (a Client ID Metadata
/// Document). Claude's "Use Claude's published identity" option signs in this
/// way.
///
/// MacRemote never fetches such a document. Fetching an address a stranger
/// supplies would let anyone make this Mac call hosts on the owner's network.
/// It carries the documents below instead, and refuses every other address.
/// The ID is shared by everyone who uses that app, so it identifies the app,
/// never a person: each sign-in still needs the owner's approval on the Mac.
struct PublishedOAuthClient: Equatable {
    let clientID: String
    let name: String
    let redirectURIs: [String]

    static let known: [PublishedOAuthClient] = [
        // https://claude.ai/oauth/mcp-oauth-client-metadata, read 2026-11-13.
        // Used by Claude on the web, desktop, and mobile.
        PublishedOAuthClient(
            clientID: "https://claude.ai/oauth/mcp-oauth-client-metadata",
            name: "Claude",
            redirectURIs: ["https://claude.ai/api/mcp/auth_callback"]
        )
    ]

    static func named(_ clientID: String) -> PublishedOAuthClient? {
        known.first { $0.clientID == clientID }
    }
}
