import Foundation

enum NavigationSection: String, CaseIterable, Identifiable {
    case dashboard
    case tools
    case clients
    case approvals
    case tunnel
    case logs
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Dashboard"
        case .tools: "Tools"
        case .clients: "Clients"
        case .approvals: "Approvals"
        case .tunnel: "Tunnel"
        case .logs: "Logs"
        case .settings: "Settings"
        }
    }

    var detail: String? {
        switch self {
        case .dashboard: "Server status"
        case .tools: "Allowed commands"
        case .clients: "Trust policies"
        case .approvals: "Host gates"
        case .tunnel: "Cloudflare"
        case .logs: "Audit trail"
        case .settings: "Preferences"
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .tools: "terminal"
        case .clients: "person.2.badge.gearshape"
        case .approvals: "checkmark.shield"
        case .tunnel: "network"
        case .logs: "list.bullet.rectangle"
        case .settings: "gearshape"
        }
    }
}
