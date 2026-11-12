import Foundation

/// Product identity MacRemote publishes when it speaks MCP as either a server
/// or a client. Keep this aligned with the packaged app version.
enum MacRemoteProductInfo {
    static let name = "MacRemote"
    static let version = "1.0"
    /// Where people read about MacRemote. Each Mac's own public link is a
    /// private endpoint, not a product page.
    static let websiteURL = "https://www.macstories.net"

    static var mcpClientInfo: [String: Any] {
        [
            "name": name,
            "version": version
        ]
    }
}
