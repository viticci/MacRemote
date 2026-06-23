import Foundation

enum ServerStatus: Equatable, Sendable {
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

enum TunnelStatus: Equatable, Sendable {
    case stopped
    case starting
    case unavailable
    case ready
    case running(URL)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .unavailable: "Unavailable"
        case .ready: "Ready"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }
}

struct ApprovalRequest: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case pending
        case approved
        case denied
        case expired
    }

    let id: UUID
    let clientName: String
    let redirectURI: String
    let issuer: String
    let resource: String
    let requestedScopes: [String]
    let createdAt: Date
    var state: State

    var stateTitle: String {
        switch state {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        case .expired: "Expired"
        }
    }
}

struct ToolCallApprovalRequest: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case pending
        case approved
        case denied
        case expired
    }

    let id: UUID
    let toolID: String
    let toolName: String
    let capability: ToolCapability
    let argumentsPreview: String
    let createdAt: Date
    var state: State

    var stateTitle: String {
        switch state {
        case .pending: "Pending"
        case .approved: "Approved"
        case .denied: "Denied"
        case .expired: "Expired"
        }
    }
}

enum FullDiskAccessState: Equatable, Sendable {
    case unknown
    case checking
    case ready
    case required
    case helperOpened
    case failed(String)

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .checking: "Checking"
        case .ready: "Ready"
        case .required: "Required"
        case .helperOpened: "Helper Opened"
        case .failed: "Failed"
        }
    }
}

struct FullDiskAccessTarget: Identifiable, Equatable, Sendable {
    var id: String { path }
    let title: String
    let path: String
    let subtitle: String
}

struct FullDiskAccessReport: Equatable, Sendable {
    var state: FullDiskAccessState = .unknown
    var detail: String = "Check Full Disk Access before exposing full RemCTL over MCP."
    var targets: [FullDiskAccessTarget] = []

    var isReady: Bool {
        state == .ready
    }
}

struct ToolExposureSummary: Equatable, Sendable {
    let total: Int
    let readOnly: Int
    let write: Int
    let destructive: Int
    let builtIn: Int
    let custom: Int
    let genericAdapters: Int
    let nonReadOnlyToolNames: [String]

    init(tools: [ToolDefinition]) {
        total = tools.count
        readOnly = tools.filter { $0.capability == .readOnly }.count
        write = tools.filter { $0.capability == .write }.count
        destructive = tools.filter { $0.capability == .destructive }.count
        builtIn = tools.filter { $0.origin == .builtIn }.count
        custom = tools.filter { $0.origin == .userDefined }.count
        genericAdapters = tools.filter(\.isGenericCLIAdapter).count
        nonReadOnlyToolNames = tools
            .filter { $0.capability != .readOnly }
            .map(\.name)
            .sorted()
    }

    var gatedToolCount: Int {
        write + destructive
    }

    var customDescription: String {
        custom == 0 ? "No custom tools" : "\(custom) custom"
    }

    var capabilityDescription: String {
        "\(readOnly) read-only, \(gatedToolCount) host-gated"
    }
}
