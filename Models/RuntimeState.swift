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
    case reconnecting(attempt: Int)
    case unavailable
    case ready
    case running(URL)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .reconnecting: "Reconnecting"
        case .unavailable: "Unavailable"
        case .ready: "Ready"
        case .running: "Running"
        case .failed: "Failed"
        }
    }

    var isRunning: Bool {
        if case .running = self { true } else { false }
    }

    var isRecovering: Bool {
        switch self {
        case .starting, .reconnecting: true
        default: false
        }
    }
}

enum CloudflareCustomDomainFailure: Equatable, Sendable {
    case loadingDomains(message: String, technicalDetail: String? = nil)
    case preparingLocalServer(String)
    case deploying(stage: CloudflareDeployStage, message: String, technicalDetail: String? = nil)

    var message: String {
        switch self {
        case .loadingDomains(let message, _), .preparingLocalServer(let message), .deploying(_, let message, _):
            message
        }
    }

    var technicalDetail: String? {
        switch self {
        case .loadingDomains(_, let detail), .deploying(_, _, let detail):
            detail
        case .preparingLocalServer:
            nil
        }
    }

    var deployStage: CloudflareDeployStage? {
        guard case .deploying(let stage, _, _) = self else { return nil }
        return stage
    }
}

enum CloudflareCustomDomainState: Equatable, Sendable {
    case idle
    case loadingDomains
    case ready
    case preparingLocalServer
    case deploying(CloudflareDeployStage)
    case deployed(String)
    case failed(CloudflareCustomDomainFailure)

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
            return "Paste an API token, then load your Cloudflare domains. Wrangler can also load domains when it is signed in."
        case .loadingDomains:
            return "Loading your Cloudflare domains."
        case .ready:
            return "Choose a domain and subdomain, then deploy."
        case .preparingLocalServer:
            return "Starting the local server before deploying."
        case .deploying(let stage):
            return stage.detail
        case .deployed(let hostname):
            return hostname
        case .failed(let failure):
            return failure.message
        }
    }

    var isWorking: Bool {
        switch self {
        case .loadingDomains, .preparingLocalServer, .deploying: true
        default: false
        }
    }

    var domainLoadFailureMessage: String? {
        guard case .failed(.loadingDomains(let message, _)) = self else { return nil }
        return message
    }

    var domainLoadFailureTechnicalDetail: String? {
        guard case .failed(.loadingDomains(_, let detail)) = self else { return nil }
        return detail
    }

    var deployFailure: (stage: CloudflareDeployStage, message: String)? {
        guard case .failed(.deploying(let stage, let message, _)) = self else { return nil }
        return (stage, message)
    }

    var activeDeployStage: CloudflareDeployStage? {
        if case .deploying(let stage) = self { return stage }
        return deployFailure?.stage
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
    let clientID: String
    let clientTrustID: String
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

    /// A short code shown both on the sign-in page of whoever started this
    /// request and on the Mac. Anyone who knows the public address can start a
    /// request and give it any name, so the name proves nothing; the owner
    /// approves only when the code on their own sign-in page matches.
    var verificationCode: String {
        Self.verificationCode(for: id)
    }

    static func verificationCode(for id: UUID) -> String {
        // The first four bytes of a random UUID are random.
        let bytes = id.uuid
        let value = (UInt32(bytes.0) << 24 | UInt32(bytes.1) << 16 | UInt32(bytes.2) << 8 | UInt32(bytes.3)) % 1_000_000
        return String(format: "%03d %03d", value / 1000, value % 1000)
    }

    /// Where the app's sign-in is sent after approval: the host for a web
    /// address, or the scheme for an app's own link type.
    var redirectDestination: String {
        guard let components = URLComponents(string: redirectURI) else { return redirectURI }
        if let host = components.host, !host.isEmpty { return host }
        return components.scheme.map { $0 + ":" } ?? redirectURI
    }
}

struct AuthenticatedClientContext: Equatable, Sendable {
    let clientID: String
    let clientTrustID: String
    let clientName: String
    let issuer: String
    let resource: String
    let scopes: [String]
    let accessTokenExpiresAt: Date
}

/// How a connected app proves it is itself at the token endpoint. Mirrors
/// `OAuthCoordinator.ClientAuthenticationMethod` so the UI stops guessing the
/// answer from a trust-ID prefix.
enum ConnectedAppAuthMethod: String, Hashable, Sendable {
    /// Public client — self-registered through Dynamic Client Registration.
    case none
    case clientSecret
    case clientSecretBasic
    case clientSecretPost

    var isConfidential: Bool { self != .none }
}

/// What the app's sign-in is actually doing right now. Three states, because a
/// freshly approved app that has not exchanged its code yet is neither signed
/// in nor expired — showing it as "expired" was a lie.
enum ConnectedAppSessionState: String, Hashable, Sendable {
    /// At least one live access or refresh token.
    case active
    /// Approved, code still valid, no tokens exchanged yet.
    case awaitingSignIn
    /// Approved once; every token has lapsed.
    case expired

    /// Listing order: what works, then what is mid-flight, then what lapsed.
    var sortRank: Int {
        switch self {
        case .active: 0
        case .awaitingSignIn: 1
        case .expired: 2
        }
    }
}

struct ConnectedClient: Identifiable, Hashable, Sendable {
    let id: String
    let trustID: String
    let name: String
    let redirectURIs: [String]
    let issuer: String?
    let resource: String?
    let scopes: [String]
    let createdAt: Date
    let lastAuthorizedAt: Date
    let activeAccessTokens: Int
    let activeRefreshTokens: Int
    let authenticationMethod: ConnectedAppAuthMethod
    let sessionState: ConnectedAppSessionState

    init(
        id: String,
        trustID: String,
        name: String,
        redirectURIs: [String],
        issuer: String?,
        resource: String?,
        scopes: [String],
        createdAt: Date,
        lastAuthorizedAt: Date,
        activeAccessTokens: Int,
        activeRefreshTokens: Int,
        authenticationMethod: ConnectedAppAuthMethod = .none,
        sessionState: ConnectedAppSessionState = .active
    ) {
        self.id = id
        self.trustID = trustID
        self.name = name
        self.redirectURIs = redirectURIs
        self.issuer = issuer
        self.resource = resource
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastAuthorizedAt = lastAuthorizedAt
        self.activeAccessTokens = activeAccessTokens
        self.activeRefreshTokens = activeRefreshTokens
        self.authenticationMethod = authenticationMethod
        self.sessionState = sessionState
    }
}

/// One argument of a tool call waiting for approval, complete and in the form
/// the tool will receive. The owner approves what is shown, so nothing here is
/// shortened; `displayValue` only makes invisible characters visible.
struct ToolCallApprovalArgument: Hashable, Sendable, Identifiable {
    let name: String
    let value: String

    var id: String { name }

    init(name: String, value: ToolArgumentValue) {
        self.name = name
        switch value {
        case .string(let string):
            self.value = string
        case .stringArray(let items):
            self.value = Self.commandLine(items)
        case .json(let json):
            let data = try? JSONSerialization.checkedData(
                withJSONObject: json.anyValue,
                options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            )
            self.value = data.map { String(decoding: $0, as: UTF8.self) } ?? "<unreadable value>"
        }
    }

    /// The value with control and invisible formatting characters written as
    /// `\u{...}` escapes, so a carriage return, a zero-width character, or a
    /// right-to-left override cannot disguise what will run. Line breaks and
    /// tabs stay as they are.
    var displayValue: String {
        var result = ""
        result.reserveCapacity(value.unicodeScalars.count)
        for scalar in value.unicodeScalars {
            let isLayout = scalar == "\n" || scalar == "\t"
            let isHidden: Bool
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned:
                isHidden = true
            default:
                isHidden = false
            }
            if isHidden && !isLayout {
                result += "\\u{" + String(scalar.value, radix: 16, uppercase: true) + "}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// A list of separate command-line items on one line. An item that is
    /// empty or contains anything beyond plain word characters is quoted, so
    /// `["a b"]` and `["a", "b"]` never look the same.
    static func commandLine(_ items: [String]) -> String {
        let plain = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        return items.map { item in
            if !item.isEmpty, item.unicodeScalars.allSatisfy(plain.contains) {
                return item
            }
            let data = try? JSONSerialization.checkedData(
                withJSONObject: item,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
            )
            return data.map { String(decoding: $0, as: UTF8.self) } ?? "\"\""
        }
        .joined(separator: " ")
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
    let clientID: String?
    let clientTrustID: String?
    let clientName: String?
    let toolID: String
    let toolName: String
    /// Exact tool authority presented when this approval was requested.
    /// OAuth/session identity is deliberately not part of this digest.
    let toolSecurityFingerprint: String
    let capability: ToolCapability
    let approvalPolicy: ToolApprovalPolicy
    /// True for a tool that passes any arguments through to its program. Its
    /// capability label then describes intent only, and the card says so.
    let isFlexibleCommand: Bool
    let arguments: [ToolCallApprovalArgument]
    let createdAt: Date
    var state: State

    init(
        id: UUID,
        clientID: String? = nil,
        clientTrustID: String? = nil,
        clientName: String? = nil,
        toolID: String,
        toolName: String,
        toolSecurityFingerprint: String = "",
        capability: ToolCapability,
        approvalPolicy: ToolApprovalPolicy = .standard,
        isFlexibleCommand: Bool = false,
        arguments: [ToolCallApprovalArgument] = [],
        createdAt: Date,
        state: State
    ) {
        self.id = id
        self.clientID = clientID
        self.clientTrustID = clientTrustID
        self.clientName = clientName
        self.toolID = toolID
        self.toolName = toolName
        self.toolSecurityFingerprint = toolSecurityFingerprint
        self.capability = capability
        self.approvalPolicy = approvalPolicy
        self.isFlexibleCommand = isFlexibleCommand
        self.arguments = arguments
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

    /// A one-line digest for history rows. Never the basis of an approval:
    /// the approval card shows `arguments` in full.
    var argumentsSummary: String {
        arguments
            .map { "\($0.name)=\($0.displayValue.replacing("\n", with: " "))" }
            .joined(separator: " ")
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

/// The result of actually trying to read protected data, never a guess at
/// System Settings rows (macOS does not let apps read that list).
enum FullDiskAccessTargetAccessState: Equatable, Sendable {
    /// Not probed yet.
    case unknown
    /// A probe read protected data successfully from this target's context.
    case working
    /// A probe ran and macOS denied the protected read.
    case blocked
}

/// Something the owner adds to Full Disk Access in System Settings. That is
/// MacRemote.app: macOS gives the tools it starts the same access.
struct FullDiskAccessTarget: Identifiable, Equatable, Sendable {
    var id: String { path }
    let title: String
    let path: String
    let subtitle: String
    var accessState: FullDiskAccessTargetAccessState

    init(
        title: String,
        path: String,
        subtitle: String,
        accessState: FullDiskAccessTargetAccessState = .unknown
    ) {
        self.title = title
        self.path = path
        self.subtitle = subtitle
        self.accessState = accessState
    }
}

struct FullDiskAccessReport: Equatable, Sendable {
    var state: FullDiskAccessState = .unknown
    var detail: String = "Check Full Disk Access before sharing tools that use protected local data."
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
        case manualCheck

        var title: String {
            "Full Disk Access needed"
        }

        var detail: String {
            switch self {
            case .serverStart:
                "Some shared tools need Full Disk Access before the server can start. Add MacRemote below, then relaunch and check again."
            case .manualCheck:
                "Some shared tools need Full Disk Access. MacRemote starts them, so add MacRemote below, then relaunch and check again."
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
    var detail: String = "Check Privacy Permissions before sharing tools that use protected app data."
    var checkedRequirements: [ToolPermissionRequirement] = []

    var isReady: Bool {
        state == .ready
    }
}

enum ReadinessStatus: String, Equatable, Sendable {
    case ready
    case checking
    case warning
    case blocked
    /// Not a problem — a step the user simply hasn't reached yet (server not
    /// started, tunnel not opened). Renders calm/neutral, never alarming red.
    case waiting

    var title: String {
        switch self {
        case .ready: "Ready"
        case .checking: "Checking"
        case .warning: "Warning"
        case .blocked: "Blocked"
        case .waiting: "Waiting"
        }
    }
}

/// One row of the Connection page's Readiness list.
struct ReadinessCheck: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let status: ReadinessStatus
    let detail: String
    /// False when no shared tool depends on this check, so "ready" means
    /// "nothing to do" rather than "access granted".
    var isNeeded = true
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
        // "Read-only" here means "runs without asking", which excludes a
        // Flexible Command whatever its label says.
        readOnly = tools.filter { !$0.asksBeforeRunning }.count
        write = tools.filter { $0.capability == .write }.count
        destructive = tools.filter { $0.capability == .destructive }.count
        builtIn = tools.filter { $0.origin == .builtIn }.count
        custom = tools.filter { $0.origin == .userDefined }.count
        genericAdapters = tools.filter(\.isGenericCLIAdapter).count
        nonReadOnlyToolNames = tools
            .filter(\.asksBeforeRunning)
            .map(\.name)
            .sorted()
    }

    var gatedToolCount: Int {
        total - readOnly
    }

    var capabilityDescription: String {
        "\(readOnly) read-only, \(gatedToolCount) \(gatedToolCount == 1 ? "asks" : "ask") first"
    }

    /// Canonical rewrite #1 (GUIDELINES §4.4) with live counts: what a public
    /// link exposes. Each caller appends its own closing sentence.
    var publicLinkSentence: String {
        "This creates a public link to your shared tools — not to your whole Mac. \(counted(total, "tool")) will be reachable: \(readOnly) read-only, \(gatedToolCount) that \(gatedToolCount == 1 ? "asks" : "ask") you before running."
    }
}

/// The Always Allow arithmetic behind one app card — badge, bulk verb, and the
/// consent copy that quotes counts. It lives here rather than inside the view so
/// tests can pin it: every number is derived from the tools passed in, and the
/// "asks every time" set follows each tool's own policy instead of a count
/// somebody typed into a string.
struct AppToolPolicySummary: Equatable, Sendable {
    let sharedCount: Int
    let allowedSharedCount: Int
    /// Shared tools the catalog marks every-call — the risky set, counted
    /// whether or not the owner has since granted them.
    let riskySharedCount: Int
    /// Shared tools that really do stop for approval on every run: marked
    /// every-call and holding no grant.
    let asksEveryTimeCount: Int

    init(sharedTools: [ToolDefinition], allowedToolIDs: Set<String>) {
        sharedCount = sharedTools.count
        allowedSharedCount = sharedTools.count { allowedToolIDs.contains($0.id) }
        let risky = sharedTools.filter { $0.approvalPolicy == .everyCall }
        riskySharedCount = risky.count
        asksEveryTimeCount = risky.count { !allowedToolIDs.contains($0.id) }
    }

    /// Every shared tool already carries a grant, so the bulk verb has nothing
    /// left to do and state takes its place. Reachable for any mix of policies —
    /// an every-call tool holding an explicit grant counts like any other.
    var allSharedToolsAllowed: Bool {
        sharedCount > 0 && allowedSharedCount == sharedCount
    }

    /// Chips may use "9/12" (GUIDELINES §4.1.11). The tail only appears while
    /// tools genuinely still ask, so granting them retires it.
    var badgeText: String {
        let allowed = "\(allowedSharedCount)/\(sharedCount) Always Allowed"
        guard asksEveryTimeCount > 0 else { return allowed }
        return "\(allowed) · \(asksEveryTimeCount) ask every time"
    }
}
