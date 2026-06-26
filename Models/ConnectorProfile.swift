import Foundation
import SwiftUI

enum CloudflareAccessMode: String, CaseIterable, Identifiable, Sendable {
    case macRemoteOAuthOnly
    case serviceTokenHeaders
    case serviceTokenAuthorizationHeader

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macRemoteOAuthOnly: "MacRemote OAuth"
        case .serviceTokenHeaders: "Access Headers"
        case .serviceTokenAuthorizationHeader: "Single Header"
        }
    }

    var shortTitle: String {
        switch self {
        case .macRemoteOAuthOnly: "OAuth"
        case .serviceTokenHeaders: "Headers"
        case .serviceTokenAuthorizationHeader: "Single"
        }
    }

    var systemImage: String {
        switch self {
        case .macRemoteOAuthOnly: "person.badge.key"
        case .serviceTokenHeaders: "key.horizontal"
        case .serviceTokenAuthorizationHeader: "key.viewfinder"
        }
    }

    var requiresCloudflareAccess: Bool {
        self != .macRemoteOAuthOnly
    }

    var readServiceTokensFromHeader: String? {
        switch self {
        case .serviceTokenAuthorizationHeader: "Authorization"
        case .macRemoteOAuthOnly, .serviceTokenHeaders: nil
        }
    }

    var detail: String {
        switch self {
        case .macRemoteOAuthOnly:
            "MacRemote OAuth only. Use for Claude and Notion OAuth."
        case .serviceTokenHeaders:
            "Cloudflare Access service-token headers plus MacRemote OAuth."
        case .serviceTokenAuthorizationHeader:
            "One Authorization header plus MacRemote OAuth."
        }
    }

    var deployDetail: String {
        switch self {
        case .macRemoteOAuthOnly:
            "No Cloudflare Access app is created."
        case .serviceTokenHeaders:
            "Creates Cloudflare Access credentials for two HTTP headers."
        case .serviceTokenAuthorizationHeader:
            "Creates Cloudflare Access credentials for one Authorization header."
        }
    }

    var protectionTitle: String {
        switch self {
        case .macRemoteOAuthOnly:
            "MacRemote OAuth only"
        case .serviceTokenHeaders:
            "Access headers + MacRemote OAuth"
        case .serviceTokenAuthorizationHeader:
            "Single Access header + MacRemote OAuth"
        }
    }

    var copyButtonTitle: String {
        switch self {
        case .macRemoteOAuthOnly:
            "Copy OAuth URL"
        case .serviceTokenHeaders:
            "Copy Headers"
        case .serviceTokenAuthorizationHeader:
            "Copy Authorization"
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
        case .raycast: "sparkles"
        case .claude: "bubble.left.and.bubble.right"
        case .notion: "square.grid.2x2"
        case .generic: "network"
        }
    }

    var authLabel: String {
        switch self {
        case .raycast: "Dynamic OAuth"
        case .claude: "OAuth"
        case .notion: "OAuth / tokens"
        case .generic: "Client-defined"
        }
    }

    var headerLabel: String {
        switch self {
        case .raycast: "Custom headers"
        case .claude: "No headers"
        case .notion: "Auth modes"
        case .generic: "Varies"
        }
    }

    var recommendedAccessMode: CloudflareAccessMode {
        switch self {
        case .raycast: .serviceTokenHeaders
        case .claude, .notion, .generic: .macRemoteOAuthOnly
        }
    }

    func status(for mode: CloudflareAccessMode) -> ConnectorCompatibility {
        switch (self, mode) {
        case (.raycast, .serviceTokenHeaders),
             (.claude, .macRemoteOAuthOnly),
             (.notion, .macRemoteOAuthOnly),
             (.generic, .macRemoteOAuthOnly):
            .recommended
        case (.raycast, .macRemoteOAuthOnly),
             (.raycast, .serviceTokenAuthorizationHeader),
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
                "Use OAuth only. Claude web does not expose request headers."
            case .notion:
                "Choose OAuth for MacRemote. Token modes are for static-auth servers."
            case .generic:
                "Start with OAuth; add Access only if the client sends headers."
            }
        case .works:
            "This works if the client sends the selected Access credential."
        case .limited:
            "Only works if the client can send this header and still complete OAuth."
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
