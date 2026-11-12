import Foundation
import SwiftUI

/// How a remote MCP client signs in to MacRemote. Every mode is enforced by
/// MacRemote's own server — nothing is gated at the tunnel edge.
enum ConnectorAuthMode: String, CaseIterable, Identifiable, Sendable {
    case oauthClientSecret
    case macRemoteOAuthOnly
    case singleHeaderToken

    /// D42 — MacRemote's declared sign-in method. A fresh install starts here
    /// no matter which app is selected, and an unreadable persisted value
    /// falls back here rather than to something derived from the app picker.
    static let productDefault: ConnectorAuthMode = .macRemoteOAuthOnly

    /// Resolves a persisted raw value, migrating the retired Cloudflare
    /// Access modes (pre-2026-07). Both of those modes also ran MacRemote
    /// OAuth, so Dynamic OAuth keeps those clients connected once the edge
    /// wall is gone.
    static func from(persistedRawValue rawValue: String) -> ConnectorAuthMode? {
        if let mode = ConnectorAuthMode(rawValue: rawValue) {
            return mode
        }
        if rawValue == "serviceTokenHeaders" || rawValue == "serviceTokenAuthorizationHeader" {
            return .macRemoteOAuthOnly
        }
        return nil
    }

    var id: String { rawValue }

    var title: String {
        return switch self {
        case .oauthClientSecret: "OAuth Client Secret"
        case .macRemoteOAuthOnly: "Dynamic OAuth"
        case .singleHeaderToken: "Single Header"
        }
    }

    var isProductDefault: Bool {
        self == Self.productDefault
    }

    /// The Advanced picker names the default outright so the choice reads as a
    /// departure from it, not as one of three equal options.
    var pickerTitle: String {
        isProductDefault ? "\(title) (Default)" : title
    }

    var shortTitle: String {
        switch self {
        case .oauthClientSecret: "Secret"
        case .macRemoteOAuthOnly: "Dynamic"
        case .singleHeaderToken: "Header"
        }
    }

    var systemImage: String {
        switch self {
        case .oauthClientSecret: "key.fill"
        case .macRemoteOAuthOnly: "person.badge.key"
        case .singleHeaderToken: "key.card"
        }
    }

    var requiresOAuthClientSecret: Bool {
        self == .oauthClientSecret
    }

    /// What the user gives up or gains by choosing this method. Shown in the
    /// Advanced disclosure next to the picker — the Client Secret line states
    /// the real cost, which is that self-signing-up apps stop connecting.
    var tradeoffDetail: String {
        switch self {
        case .oauthClientSecret:
            "You paste a client ID and secret into the app. Use it only when the app asks for those two fields. While this is on, apps that sign themselves up can't connect — including ChatGPT and Claude over your public link."
        case .macRemoteOAuthOnly:
            "The app signs itself up and asks for your approval. Nothing to copy or paste. Works with ChatGPT, Claude, Raycast, and Notion."
        case .singleHeaderToken:
            "MacRemote makes one secret token the app sends with every request. For apps that can send a custom header but can't finish a sign-in. ChatGPT, Claude, and Notion can't send it."
        }
    }

    var protectionTitle: String {
        switch self {
        case .oauthClientSecret:
            "OAuth client secret"
        case .macRemoteOAuthOnly:
            "Dynamic OAuth only"
        case .singleHeaderToken:
            "Single header token"
        }
    }

}

enum ConnectorProviderProfile: String, CaseIterable, Identifiable, Sendable {
    case chatGPT
    case raycast
    case claude
    case notion
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chatGPT: "ChatGPT"
        case .raycast: "Raycast"
        case .claude: "Claude"
        case .notion: "Notion"
        case .generic: "Generic"
        }
    }

    var systemImage: String {
        switch self {
        case .chatGPT: "sparkles"
        case .raycast: "rays"
        case .claude: "bubble.left.and.bubble.right"
        case .notion: "square.grid.2x2"
        case .generic: "network"
        }
    }

    var authLabel: String {
        switch self {
        case .chatGPT: "Dynamic OAuth"
        case .raycast: "Dynamic OAuth"
        // Claude's connectors sign themselves up; saying "client secret" here
        // would contradict the blocked status that pairing now carries.
        case .claude: "Dynamic OAuth"
        case .notion: "OAuth fields or sign-up"
        case .generic: "Client-defined"
        }
    }

    var headerLabel: String {
        switch self {
        case .chatGPT: "OAuth discovery"
        case .raycast: "Custom headers"
        case .claude: "OAuth fields"
        case .notion: "OAuth fields"
        case .generic: "Varies"
        }
    }

    /// D42/R1 — every supported app can finish Dynamic OAuth, so it is the
    /// recommendation for all of them. This is deliberately not a per-app
    /// answer any more: the app picker is advisory (D43) and never rewrites
    /// the saved method.
    var recommendedAuthMode: ConnectorAuthMode {
        .productDefault
    }

    func status(for mode: ConnectorAuthMode) -> ConnectorCompatibility {
        switch (self, mode) {
        case (_, .macRemoteOAuthOnly):
            .recommended
        // Client Secret mode requires a confidential client, which turns off
        // self-registration server-wide — ChatGPT's developer-mode app and
        // Claude's custom connector both fail at that step.
        case (.chatGPT, .oauthClientSecret),
             (.claude, .oauthClientSecret):
            .blocked
        case (.raycast, .oauthClientSecret),
             (.notion, .oauthClientSecret),
             (.generic, .oauthClientSecret):
            .works
        case (.raycast, .singleHeaderToken),
             (.generic, .singleHeaderToken):
            .works
        case (.chatGPT, .singleHeaderToken),
             (.claude, .singleHeaderToken),
             (.notion, .singleHeaderToken):
            .blocked
        }
    }

    func setupLine(for mode: ConnectorAuthMode) -> String {
        return switch status(for: mode) {
        case .recommended:
            switch self {
            case .chatGPT:
                "In ChatGPT, open Settings ▸ Plugins, create a developer-mode app, paste the Public URL into MCP server URL, choose OAuth with Dynamic Client Registration, then approve the request in MacRemote."
            case .raycast:
                "Add MacRemote's URL and approve the sign-in request when Raycast asks."
            case .claude:
                "In Claude, open Settings ▸ Connectors ▸ Add Custom Connector, paste the link, then approve the request in MacRemote."
            case .notion:
                "In Notion, open Settings ▸ Connections, paste the link as a new connection, then approve the request in MacRemote."
            case .generic:
                "Paste the link where the app asks for a remote MCP server, then approve the request in MacRemote."
            }
        case .works:
            switch mode {
            case .oauthClientSecret:
                "Works — paste MacRemote's client ID and secret from Settings ▸ Security into \(title), then approve the request in MacRemote."
            case .singleHeaderToken:
                "Works — give \(title) the header token from Settings ▸ Security, then connect."
            case .macRemoteOAuthOnly:
                "Works — connect, then approve the request in MacRemote."
            }
        case .limited:
            "Works only if the app can send this header and still finish signing in."
        case .blocked:
            blockedLine(for: mode)
        }
    }

    /// A blocked pairing has to say *why* it is blocked — the two reasons are
    /// different, and the old copy claimed the header reason for both.
    private func blockedLine(for mode: ConnectorAuthMode) -> String {
        switch mode {
        case .oauthClientSecret:
            "\(title) signs itself up over your public link, and this method turns that off. Use \(ConnectorAuthMode.productDefault.title) for \(title)."
        case .singleHeaderToken:
            "\(title) can't send a fixed sign-in header. Use \(ConnectorAuthMode.productDefault.title) for \(title)."
        case .macRemoteOAuthOnly:
            "Use \(ConnectorAuthMode.productDefault.title) for \(title)."
        }
    }
}

enum ConnectorCompatibility: Equatable, Sendable {
    case recommended
    case works
    case limited
    case blocked

    var title: String {
        switch self {
        case .recommended: "Recommended"
        case .works: "Works"
        case .limited: "Limited"
        case .blocked: "Blocked"
        }
    }

    var systemImage: String {
        switch self {
        case .recommended: "checkmark.seal.fill"
        case .works: "checkmark.circle.fill"
        case .limited: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .recommended: .green
        case .works: .blue
        case .limited: .orange
        case .blocked: .red
        }
    }
}
