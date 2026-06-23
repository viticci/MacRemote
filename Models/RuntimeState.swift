import Foundation

enum ServerStatus: Equatable {
    case stopped
    case starting
    case running(URL)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

enum TunnelStatus: Equatable {
    case stopped
    case unavailable
    case ready
    case running(URL)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .unavailable: "Unavailable"
        case .ready: "Ready"
        case .running: "Running"
        case .failed: "Failed"
        }
    }
}

struct ApprovalRequest: Identifiable, Hashable {
    enum State: String {
        case pending
        case approved
        case denied
        case expired
    }

    let id: UUID
    let clientName: String
    let redirectURI: String
    let requestedScopes: [String]
    let createdAt: Date
    var state: State
}
