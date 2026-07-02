import Foundation
import SwiftUI

enum CloudflareAccessMode: String, CaseIterable, Identifiable, Sendable {
    case oauthClientSecret
    case macRemoteOAuthOnly
    case serviceTokenHeaders
    case serviceTokenAuthorizationHeader

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oauthClientSecret: "OAuth Client Secret"
        case .macRemoteOAuthOnly: "Dynamic OAuth"
        case .serviceTokenHeaders: "Access Headers"
        case .serviceTokenAuthorizationHeader: "Single Header"
        }
    }

    var shortTitle: String {
        switch self {
        case .oauthClientSecret: "Secret"
        case .macRemoteOAuthOnly: "Dynamic"
        case .serviceTokenHeaders: "Headers"
        case .serviceTokenAuthorizationHeader: "Single"
        }
    }

    var systemImage: String {
        switch self {
        case .oauthClientSecret: "key.fill"
        case .macRemoteOAuthOnly: "person.badge.key"
        case .serviceTokenHeaders: "key.horizontal"
        case .serviceTokenAuthorizationHeader: "key.card"
        }
    }

    var requiresCloudflareAccess: Bool {
        switch self {
        case .serviceTokenHeaders, .serviceTokenAuthorizationHeader:
            true
        case .oauthClientSecret, .macRemoteOAuthOnly:
            false
        }
    }

    var requiresOAuthClientSecret: Bool {
        self == .oauthClientSecret
    }

    var readServiceTokensFromHeader: String? {
        switch self {
        case .serviceTokenAuthorizationHeader: "CF-Access-Service-Token"
        case .oauthClientSecret, .macRemoteOAuthOnly, .serviceTokenHeaders: nil
        }
    }

    var detail: String {
        switch self {
        case .oauthClientSecret:
            "MacRemote's own sign-in with the generated client ID and secret. New apps still need your approval to connect."
        case .macRemoteOAuthOnly:
            "Compatibility mode for apps that can't send a client ID and secret."
        case .serviceTokenHeaders:
            "Cloudflare Access service-token headers plus MacRemote OAuth. Only for clients that can send custom headers (Raycast) — Claude.ai connectors can't, and Access will block them at /mcp."
        case .serviceTokenAuthorizationHeader:
            "One Cloudflare Access header plus MacRemote OAuth. Only for clients that can send custom headers — Claude.ai connectors can't, and Access will block them at /mcp."
        }
    }

    var deployDetail: String {
        switch self {
        case .oauthClientSecret:
            "No Cloudflare Access app is created."
        case .macRemoteOAuthOnly:
            "No Cloudflare Access app is created."
        case .serviceTokenHeaders:
            "Creates Cloudflare Access credentials for two HTTP headers."
        case .serviceTokenAuthorizationHeader:
            "Creates Cloudflare Access credentials for one custom HTTP header."
        }
    }

    var protectionTitle: String {
        switch self {
        case .oauthClientSecret:
            "OAuth client secret"
        case .macRemoteOAuthOnly:
            "Dynamic OAuth only"
        case .serviceTokenHeaders:
            "Access headers + MacRemote OAuth"
        case .serviceTokenAuthorizationHeader:
            "Single Access header + MacRemote OAuth"
        }
    }

    var copyButtonTitle: String {
        switch self {
        case .oauthClientSecret:
            "Copy OAuth Credentials"
        case .macRemoteOAuthOnly:
            "Copy OAuth URL"
        case .serviceTokenHeaders:
            "Copy Headers"
        case .serviceTokenAuthorizationHeader:
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

    var recommendedAccessMode: CloudflareAccessMode {
        switch self {
        case .raycast: .serviceTokenHeaders
        case .claude, .notion, .generic: .oauthClientSecret
        }
    }

    func status(for mode: CloudflareAccessMode) -> ConnectorCompatibility {
        switch (self, mode) {
        case (.raycast, .serviceTokenHeaders),
             (.claude, .oauthClientSecret),
             (.notion, .oauthClientSecret),
             (.generic, .oauthClientSecret):
            .recommended
        case (.raycast, .oauthClientSecret),
             (.raycast, .macRemoteOAuthOnly),
             (.raycast, .serviceTokenAuthorizationHeader),
             (.claude, .macRemoteOAuthOnly),
             (.notion, .macRemoteOAuthOnly),
             (.generic, .macRemoteOAuthOnly),
             (.generic, .serviceTokenHeaders),
             (.generic, .serviceTokenAuthorizationHeader):
            .works
        case (.notion, .serviceTokenAuthorizationHeader):
            .limited
        case (.claude, .serviceTokenHeaders),
             (.claude, .serviceTokenAuthorizationHeader),
             (.notion, .serviceTokenHeaders):
            .blocked
        }
    }

    func setupLine(for mode: CloudflareAccessMode) -> String {
        switch status(for: mode) {
        case .recommended:
            switch self {
            case .raycast:
                "Use Dynamic OAuth and copied Access headers."
            case .claude:
                "Paste MacRemote's OAuth client ID and secret into Claude."
            case .notion:
                "Paste MacRemote's OAuth client ID and secret into Notion."
            case .generic:
                "Start with OAuth Client Secret; add Access only if the app sends headers."
            }
        case .works:
            "Works if the app sends the selected Access credential."
        case .limited:
            "Works only if the app can send this header and still finish signing in."
        case .blocked:
            "Use \(recommendedAccessMode.title) for \(title)."
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
