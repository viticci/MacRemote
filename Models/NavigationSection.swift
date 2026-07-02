import Foundation

enum NavigationSection: String, CaseIterable, Identifiable {
    case connection
    case tools
    case apps
    case requests
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "Connection"
        case .tools: "Tools"
        case .apps: "Apps"
        case .requests: "Requests"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: "dot.radiowaves.left.and.right"
        case .tools: "wrench.and.screwdriver"
        case .apps: "app.badge.checkmark"
        case .requests: "hand.raised"
        case .activity: "waveform.path.ecg"
        }
    }

    /// ⌘1–⌘5 (View menu + sidebar order).
    var keyboardShortcutNumber: Int {
        switch self {
        case .connection: 1
        case .tools: 2
        case .apps: 3
        case .requests: 4
        case .activity: 5
        }
    }
}

/// Scene identifiers (spec §2.1). `AppModel.windowOpener` opens scenes by these IDs.
enum MacRemoteWindowID {
    static let main = "main"
    static let approval = "approval"
    static let welcome = "welcome"
}

/// The six Readiness rows on Connection, keyed to `SmokeReadinessCheck.id`.
/// `AppModel.readinessRowToExpand` uses this to auto-expand a row after a
/// programmatic jump (spec §2.4).
enum ReadinessRow: String, CaseIterable, Identifiable, Sendable {
    case fullDiskAccess = "full-disk-access"
    case privacyPermissions = "macos-privacy"
    case localServer = "local-server"
    case publicURL = "public-tunnel"
    case sharedTools = "tool-surface"
    case anthropicKey = "anthropic-key"

    var id: String { rawValue }
}
