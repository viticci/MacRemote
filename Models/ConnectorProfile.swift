import Foundation
import SwiftUI

/// How a remote MCP client signs in to MacRemote. Every mode is enforced by
/// MacRemote's own server — nothing is gated at the tunnel edge.
enum ConnectorAuthMode: String, CaseIterable, Identifiable, Sendable {
    case oauthClientSecret
    case macRemoteOAuthOnly
    case singleHeaderToken

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
        switch self {
        case .oauthClientSecret: "OAuth Client Secret"
        case .macRemoteOAuthOnly: "Dynamic OAuth"
        case .singleHeaderToken: "Single Header"
        }
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

    var detail: String {
        switch self {
        case .oauthClientSecret:
            "MacRemote's own sign-in with the generated client ID and secret. New apps still need your approval to connect."
        case .macRemoteOAuthOnly:
            "Compatibility mode for apps that can't send a client ID and secret."
        case .singleHeaderToken:
            "MacRemote generates a secret token the app sends as one Authorization header. For apps that can send custom headers but can't finish an OAuth sign-in."
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

    var copyButtonTitle: String {
        switch self {
        case .oauthClientSecret:
            "Copy OAuth Credentials"
        case .macRemoteOAuthOnly:
            "Copy OAuth URL"
        case .singleHeaderToken:
            "Copy Header"
        }
    }
}

enum ConnectorProviderProfile: String, CaseIterable, Identifiable, Sendable {
    case raycast
    case claude
    case notion
    case generic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raycast: "Raycast"
        case .claude: "Claude"
        case .notion: "Notion"
        case .generic: "Generic"
        }
    }

    var systemImage: String {
        switch self {
        case .raycast: "rays"
        case .claude: "bubble.left.and.bubble.right"
        case .notion: "square.grid.2x2"
        case .generic: "network"
        }
    }

    var authLabel: String {
        switch self {
        case .raycast: "Dynamic OAuth"
        case .claude: "OAuth client secret"
        case .notion: "OAuth client secret"
        case .generic: "Client-defined"
        }
    }

    var headerLabel: String {
        switch self {
        case .raycast: "Custom headers"
        case .claude: "OAuth fields"
        case .notion: "OAuth fields"
        case .generic: "Varies"
        }
    }

    var recommendedAuthMode: ConnectorAuthMode {
        switch self {
        case .raycast: .macRemoteOAuthOnly
        case .claude, .notion, .generic: .oauthClientSecret
        }
    }

    func status(for mode: ConnectorAuthMode) -> ConnectorCompatibility {
        switch (self, mode) {
        case (.raycast, .macRemoteOAuthOnly),
             (.claude, .oauthClientSecret),
             (.notion, .oauthClientSecret),
             (.generic, .oauthClientSecret):
            .recommended
        case (.raycast, .oauthClientSecret),
             (.raycast, .singleHeaderToken),
             (.claude, .macRemoteOAuthOnly),
             (.notion, .macRemoteOAuthOnly),
             (.generic, .macRemoteOAuthOnly),
             (.generic, .singleHeaderToken):
            .works
        case (.claude, .singleHeaderToken),
             (.notion, .singleHeaderToken):
            .blocked
        }
    }

    func setupLine(for mode: ConnectorAuthMode) -> String {
        switch status(for: mode) {
        case .recommended:
            switch self {
            case .raycast:
                "Add MacRemote's URL and approve the sign-in request when Raycast asks."
            case .claude:
                "Paste MacRemote's OAuth client ID and secret into Claude."
            case .notion:
                "Paste MacRemote's OAuth client ID and secret into Notion."
            case .generic:
                "Start with OAuth Client Secret; use Single Header only for apps that can't sign in."
            }
        case .works:
            "Works — connect, then approve the request in MacRemote."
        case .limited:
            "Works only if the app can send this header and still finish signing in."
        case .blocked:
            "This app can't send custom headers. Use \(recommendedAuthMode.title) for \(title)."
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
