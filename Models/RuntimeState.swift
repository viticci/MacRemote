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

enum CloudflareCustomDomainState: Equatable, Sendable {
    case idle
    case loadingDomains
    case ready
    case preparingLocalServer
    case deploying
    case deployed(String)
    case failed(String)

    var title: String {
        switch self {
        case .idle: "Not Loaded"
        case .loadingDomains: "Loading Domains"
        case .ready: "Ready"
        case .preparingLocalServer: "Starting Local Server"
        case .deploying: "Deploying"
        case .deployed: "Deployed"
        case .failed: "Failed"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "Load Cloudflare domains from the Wrangler account on this Mac."
        case .loadingDomains:
            return "Checking Wrangler auth and loading Cloudflare zones."
        case .ready:
            return "Choose a domain and subdomain, then deploy a named tunnel."
        case .preparingLocalServer:
            return "Starting the local MCP server before deploying the named tunnel."
        case .deploying:
            return "Creating or updating Cloudflare Tunnel, DNS, and optional Access resources."
        case .deployed(let hostname):
            return hostname
        case .failed(let message):
            return message
        }
    }

    var isWorking: Bool {
        switch self {
        case .loadingDomains, .preparingLocalServer, .deploying: true
        default: false
        }
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

struct AuthenticatedClientContext: Equatable, Sendable {
    let clientID: String
    let clientName: String
    let issuer: String
    let resource: String
    let scopes: [String]
    let accessTokenExpiresAt: Date
}

struct ConnectedClient: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let redirectURIs: [String]
    let issuer: String?
    let resource: String?
    let scopes: [String]
    let createdAt: Date
    let lastAuthorizedAt: Date
    let activeAccessTokens: Int
    let activeRefreshTokens: Int
}

struct ToolCallApprovalRequest: Identifiable, Hashable, Sendable {
    enum State: String, Sendable {
        case pending
        case approved
        case denied
        case expired
    }

    let id: UUID
    let clientID: String?
    let clientName: String?
    let toolID: String
    let toolName: String
    let capability: ToolCapability
    let argumentsPreview: String
    let createdAt: Date
    var state: State

    init(
        id: UUID,
        clientID: String? = nil,
        clientName: String? = nil,
        toolID: String,
        toolName: String,
        capability: ToolCapability,
        argumentsPreview: String,
        createdAt: Date,
        state: State
    ) {
        self.id = id
        self.clientID = clientID
        self.clientName = clientName
        self.toolID = toolID
        self.toolName = toolName
        self.capability = capability
        self.argumentsPreview = argumentsPreview
        self.createdAt = createdAt
        self.state = state
    }

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
    case confirmationRequired
    case helperOpened
    case failed(String)

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .checking: "Checking"
        case .ready: "Ready"
        case .required: "Required"
        case .confirmationRequired: "Confirm Setup"
        case .helperOpened: "Helper Opened"
        case .failed: "Failed"
        }
    }
}

enum FullDiskAccessTargetRole: String, Equatable, Sendable {
    case hostApp
    case toolExecutable
    case toolInterpreter
    case helperReported

    var title: String {
        switch self {
        case .hostApp: "Host app"
        case .toolExecutable: "Tool"
        case .toolInterpreter: "Interpreter"
        case .helperReported: "Helper"
        }
    }

    var systemImage: String {
        switch self {
        case .hostApp: "app.badge"
        case .toolExecutable: "terminal"
        case .toolInterpreter: "curlybraces"
        case .helperReported: "checklist.checked"
        }
    }

    var sortOrder: Int {
        switch self {
        case .hostApp: 0
        case .helperReported: 1
        case .toolInterpreter: 2
        case .toolExecutable: 3
        }
    }
}

struct FullDiskAccessTarget: Identifiable, Equatable, Sendable {
    var id: String { path }
    let title: String
    let path: String
    let subtitle: String
    let role: FullDiskAccessTargetRole

    init(
        title: String,
        path: String,
        subtitle: String,
        role: FullDiskAccessTargetRole = .helperReported
    ) {
        self.title = title
        self.path = path
        self.subtitle = subtitle
        self.role = role
    }
}

struct FullDiskAccessReport: Equatable, Sendable {
    var state: FullDiskAccessState = .unknown
    var detail: String = "Check Full Disk Access before exposing tools that require protected local data."
    var targets: [FullDiskAccessTarget] = []
    var requiresManualConfirmation = false
    var confirmationSignature: String?
    var automaticChecksPassed = false

    var isReady: Bool {
        state == .ready
    }
}

struct FullDiskAccessPrompt: Identifiable, Equatable, Sendable {
    enum Reason: String, Sendable {
        case serverStart
        case remCTLTest
        case remoteProof
        case manualCheck

        var title: String {
            switch self {
            case .serverStart: "Full Disk Access Required"
            case .remCTLTest: "Reminders Test Blocked"
            case .remoteProof: "Remote MCP Proof Blocked"
            case .manualCheck: "Full Disk Access Required"
            }
        }

        var detail: String {
            switch self {
            case .serverStart:
                "MacRemote cannot start an MCP server with FDA-required tools until the app-launched CLI process can read its protected data."
            case .remCTLTest:
                "The test tool must run from the same app process context that remote MCP calls will use."
            case .remoteProof:
                "Remote MCP verification is blocked until FDA-required tools pass their local permission check."
            case .manualCheck:
                "Grant access to every listed target. If System Settings already shows access enabled, relaunch MacRemote, then check again."
            }
        }
    }

    let id = UUID()
    let reason: Reason
}

enum MacOSPrivacyAccessState: Equatable, Sendable {
    case unknown
    case checking
    case ready
    case required([ToolPermissionRequirement])
    case failed(String)

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .checking: "Checking"
        case .ready: "Ready"
        case .required: "Required"
        case .failed: "Failed"
        }
    }
}

struct MacOSPrivacyAccessReport: Equatable, Sendable {
    var state: MacOSPrivacyAccessState = .unknown
    var detail: String = "Check macOS privacy access before exposing tools that use protected app data."
    var checkedRequirements: [ToolPermissionRequirement] = []

    var isReady: Bool {
        state == .ready
    }
}

enum SmokeTestMode: String, Equatable, Sendable {
    case preflight
    case anthropicAPI

    var title: String {
        switch self {
        case .preflight: "MCP Preflight"
        case .anthropicAPI: "Anthropic API Smoke"
        }
    }

    var logTitle: String {
        switch self {
        case .preflight: "MacRemote MCP preflight"
        case .anthropicAPI: "Anthropic API smoke test"
        }
    }
}

enum SmokeTestState: Equatable, Sendable {
    case idle
    case running(SmokeTestMode)
    case passed(SmokeTestMode, String)
    case failed(SmokeTestMode, String)

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }

    var title: String {
        switch self {
        case .idle: "Not Run"
        case .running(let mode): "Running \(mode.title)"
        case .passed(let mode, _): "\(mode.title) Passed"
        case .failed(let mode, _): "\(mode.title) Failed"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            "Run a direct MCP preflight first, then the full Anthropic API smoke test."
        case .running(let mode):
            "\(mode.title) is running. Approve the OAuth request in Approvals when prompted."
        case .passed(_, let message), .failed(_, let message):
            message
        }
    }
}

enum AnthropicCredentialState: Equatable, Sendable {
    case unknown
    case checking
    case ready
    case failed(String)

    var title: String {
        switch self {
        case .unknown: "Unknown"
        case .checking: "Checking"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    var isReady: Bool {
        if case .ready = self { true } else { false }
    }
}

enum SmokeReadinessStatus: String, Equatable, Sendable {
    case ready
    case checking
    case warning
    case blocked

    var title: String {
        switch self {
        case .ready: "Ready"
        case .checking: "Checking"
        case .warning: "Warning"
        case .blocked: "Blocked"
        }
    }
}

struct SmokeReadinessCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: SmokeReadinessStatus
    let detail: String
}

struct SmokeReadiness: Equatable, Sendable {
    let checks: [SmokeReadinessCheck]
    let canRunPreflight: Bool
    let canRunAnthropicAPI: Bool

    var blockingDetails: [String] {
        checks
            .filter { $0.status == .blocked }
            .map { "\($0.title): \($0.detail)" }
    }
}

struct SmokeProofRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let date: Date
    let mode: SmokeTestMode
    let mcpURL: String
    let toolSurface: String
    let succeeded: Bool
    let resultSummary: String
    let exitCode: Int32?
    let duration: TimeInterval?
    let markers: [String]

    init(
        id: UUID = UUID(),
        date: Date,
        mode: SmokeTestMode,
        mcpURL: String,
        toolSurface: String,
        succeeded: Bool,
        resultSummary: String,
        exitCode: Int32?,
        duration: TimeInterval?,
        markers: [String]
    ) {
        self.id = id
        self.date = date
        self.mode = mode
        self.mcpURL = mcpURL
        self.toolSurface = toolSurface
        self.succeeded = succeeded
        self.resultSummary = resultSummary
        self.exitCode = exitCode
        self.duration = duration
        self.markers = markers
    }

    var statusTitle: String {
        succeeded ? "Passed" : "Failed"
    }

    var clipboardText: String {
        var lines = [
            "MacRemote Remote MCP Proof",
            "Date: \(ISO8601DateFormatter().string(from: date))",
            "Mode: \(mode.title)",
            "Status: \(statusTitle)",
            "MCP URL: \(mcpURL)",
            "Tool surface: \(toolSurface)",
            "Result: \(resultSummary)"
        ]

        if let exitCode {
            lines.append("Exit code: \(exitCode)")
        }

        if let duration {
            lines.append("Duration: \(duration.formattedDuration)")
        }

        if !markers.isEmpty {
            lines.append("Markers:")
            lines.append(contentsOf: markers.map { "- \($0)" })
        }

        return lines.joined(separator: "\n")
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
