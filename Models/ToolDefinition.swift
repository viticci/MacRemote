import Foundation

enum ToolCapability: String, Codable, CaseIterable, Sendable {
    case readOnly
    case write
    case destructive

    var title: String {
        switch self {
        case .readOnly: "Read-only"
        case .write: "Write"
        case .destructive: "Destructive"
        }
    }
}

enum ToolOrigin: String, Codable, Sendable {
    case builtIn
    case userDefined
}

enum ToolBackend: String, Codable, Sendable {
    case process
    case mcpHTTPBridge
    case mcpStdioBridge
    case native
}

enum NativeToolIdentifier: String, Codable, Sendable {
    case fsStat = "fs.stat"
    case fsListTree = "fs.list_tree"
    case fsFind = "fs.find"
    case fsReadFile = "fs.read_file"
    case fsWriteFile = "fs.write_file"
    case fsUploadFile = "fs.upload_file"
    case fsAppendFile = "fs.append_file"
    case fsReplaceInFile = "fs.replace_in_file"
    case fsDownloadFile = "fs.download_file"
    case fsDownloadZip = "fs.download_zip"
}

enum MCPBridgeHeaderValueSourceKind: String, Codable, Sendable {
    case environment
    case jsonFile
    case tomlFile
    /// MacRemote signed in to the upstream server itself (OAuth with PKCE and
    /// dynamic client registration). The token lives in the Keychain under the
    /// server URL and is never written to the tool registry.
    case oauth
}

struct MCPBridgeHeaderValueSource: Codable, Hashable, Sendable {
    let kind: MCPBridgeHeaderValueSourceKind
    let environmentKey: String?
    let filePath: String?
    let keyPath: [String]?
    let prefix: String?

    init(
        kind: MCPBridgeHeaderValueSourceKind,
        environmentKey: String? = nil,
        filePath: String? = nil,
        keyPath: [String]? = nil,
        prefix: String? = nil
    ) {
        self.kind = kind
        self.environmentKey = environmentKey
        self.filePath = filePath
        self.keyPath = keyPath
        self.prefix = prefix
    }
}

struct MCPBridgeHeader: Codable, Hashable, Sendable {
    let name: String
    let value: String?
    let valueSource: MCPBridgeHeaderValueSource?

    init(name: String, value: String? = nil, valueSource: MCPBridgeHeaderValueSource? = nil) {
        self.name = name
        self.value = value
        self.valueSource = valueSource
    }

    /// The `Authorization` header of a server MacRemote signed in to itself.
    static let upstreamOAuthAuthorization = MCPBridgeHeader(
        name: "Authorization",
        valueSource: MCPBridgeHeaderValueSource(kind: .oauth, prefix: "Bearer ")
    )

    var isUpstreamOAuth: Bool { valueSource?.kind == .oauth }
}

/// A credential-free record of one app config that declared an imported MCP
/// server. Multiple apps can own the same runtime; keeping every owner lets
/// reconciliation remove the tool family only after every readable config is
/// gone. `serverIdentity` is the scanner's legacy source-specific identity and
/// exists so pre-dedupe imports continue to match their original config.
struct MCPDiscoveryOwner: Codable, Hashable, Sendable {
    let serverIdentity: String
    let source: String
    let sourcePath: String
}

struct MCPBridgeConfiguration: Codable, Hashable, Sendable {
    /// Credential-safe canonical execution identity. Exact duplicate runtimes
    /// share it even when separate apps declared them.
    let serverIdentity: String?
    /// Scanner provenance used only to reconcile imported tools when their
    /// original configured server disappears. These values never contain
    /// credentials and do not affect execution or approval fingerprints.
    let discoverySource: String?
    let discoverySourcePath: String?
    let discoveryOwners: [MCPDiscoveryOwner]?
    let serverName: String
    let serverURL: String
    let toolName: String
    let toolTitle: String?
    let toolDescription: String?
    let inputSchema: JSONValue?
    let annotations: JSONValue?
    let protocolVersion: String
    let headers: [MCPBridgeHeader]

    init(
        serverIdentity: String? = nil,
        discoverySource: String? = nil,
        discoverySourcePath: String? = nil,
        discoveryOwners: [MCPDiscoveryOwner]? = nil,
        serverName: String,
        serverURL: String,
        toolName: String,
        toolTitle: String? = nil,
        toolDescription: String? = nil,
        inputSchema: JSONValue? = nil,
        annotations: JSONValue? = nil,
        protocolVersion: String = "2025-06-18",
        headers: [MCPBridgeHeader] = []
    ) {
        self.serverIdentity = serverIdentity
        self.discoverySource = discoverySource
        self.discoverySourcePath = discoverySourcePath
        self.discoveryOwners = discoveryOwners
        self.serverName = serverName
        self.serverURL = serverURL
        self.toolName = toolName
        self.toolTitle = toolTitle
        self.toolDescription = toolDescription
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.protocolVersion = protocolVersion
        self.headers = headers
    }
}

struct MCPStdioEnvironmentVariable: Codable, Hashable, Sendable {
    let name: String
    let value: String?
    let valueSource: MCPBridgeHeaderValueSource?

    init(name: String, value: String? = nil, valueSource: MCPBridgeHeaderValueSource? = nil) {
        self.name = name
        self.value = value
        self.valueSource = valueSource
    }
}

struct MCPStdioBridgeConfiguration: Codable, Hashable, Sendable {
    let serverIdentity: String?
    let discoverySource: String?
    let discoverySourcePath: String?
    let discoveryOwners: [MCPDiscoveryOwner]?
    let serverName: String
    let command: String
    let args: [String]
    let startupTimeoutSeconds: TimeInterval?
    let toolName: String
    let toolTitle: String?
    let toolDescription: String?
    let inputSchema: JSONValue?
    let annotations: JSONValue?
    let protocolVersion: String
    let environment: [MCPStdioEnvironmentVariable]

    init(
        serverIdentity: String? = nil,
        discoverySource: String? = nil,
        discoverySourcePath: String? = nil,
        discoveryOwners: [MCPDiscoveryOwner]? = nil,
        serverName: String,
        command: String,
        args: [String] = [],
        startupTimeoutSeconds: TimeInterval? = nil,
        toolName: String,
        toolTitle: String? = nil,
        toolDescription: String? = nil,
        inputSchema: JSONValue? = nil,
        annotations: JSONValue? = nil,
        protocolVersion: String = "2025-06-18",
        environment: [MCPStdioEnvironmentVariable] = []
    ) {
        self.serverIdentity = serverIdentity
        self.discoverySource = discoverySource
        self.discoverySourcePath = discoverySourcePath
        self.discoveryOwners = discoveryOwners
        self.serverName = serverName
        self.command = command
        self.args = args
        self.startupTimeoutSeconds = startupTimeoutSeconds
        self.toolName = toolName
        self.toolTitle = toolTitle
        self.toolDescription = toolDescription
        self.inputSchema = inputSchema
        self.annotations = annotations
        self.protocolVersion = protocolVersion
        self.environment = environment
    }
}

enum ToolCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case reminders
    case notes
    case mail
    case habits
    case podcasts
    case music
    case readLater
    case filesystem
    case utilities
    case imageProcessing
    case text
    case developer
    case ai
    case iphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: "Reminders"
        case .notes: "Notes"
        case .mail: "Mail"
        case .habits: "Habits"
        case .podcasts: "Podcasts"
        case .music: "Music"
        case .readLater: "Read Later"
        case .filesystem: "Filesystem"
        case .utilities: "Utilities"
        // DL-12: retitle only — the raw value stays `imageProcessing` so persisted
        // tools.json needs zero migration.
        case .imageProcessing: "Media"
        case .text: "Text"
        case .developer: "Developer"
        case .ai: "AI & Agents"
        case .iphone: "iPhone"
        }
    }
}

enum ToolPermissionRequirement: String, Codable, Hashable, CaseIterable, Sendable {
    case fullDiskAccess
    case reminders
    case calendars
    case contacts
    case photos
    case camera
    case microphone
    case speechRecognition
    case location
    case screenRecording
    case accessibility
    case automation
    case localNetwork

    var title: String {
        switch self {
        case .fullDiskAccess: "Full Disk Access"
        case .reminders: "Reminders"
        case .calendars: "Calendars"
        case .contacts: "Contacts"
        case .photos: "Photos"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .location: "Location"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        case .automation: "Automation"
        case .localNetwork: "Local Network"
        }
    }

    var systemImage: String {
        switch self {
        case .fullDiskAccess: "internaldrive"
        case .reminders: "checklist"
        case .calendars: "calendar"
        case .contacts: "person.crop.circle"
        case .photos: "photo"
        case .camera: "camera"
        case .microphone: "mic"
        case .speechRecognition: "waveform"
        case .location: "location"
        case .screenRecording: "rectangle.dashed.badge.record"
        case .accessibility: "accessibility"
        case .automation: "gearshape.2"
        case .localNetwork: "network"
        }
    }

    var isFullDiskAccess: Bool {
        self == .fullDiskAccess
    }

    static func normalized(_ requirements: [ToolPermissionRequirement]) -> [ToolPermissionRequirement] {
        let uniqueRequirements = Set(requirements)
        return allCases.filter { uniqueRequirements.contains($0) }
    }
}

enum ToolParameterKind: String, Codable, Sendable {
    case string
    case integer
    case stringArray
    case boolean
    case number
    case json
}

enum ToolArgumentValue: Equatable, Sendable {
    case string(String)
    case stringArray([String])
    case json(JSONValue)

    /// Decimal string for a JSON number only when it is a finite integer representable as `Int`.
    /// Out-of-range, non-integral, infinity, and NaN values return `nil` so callers surface
    /// `invalidInteger` instead of trapping on `Int(_:)`.
    static func integerString(from number: Double) -> String? {
        guard number.isFinite, let integer = Int(exactly: number) else {
            return nil
        }
        return String(integer)
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .json(.string(let value)):
            return value
        case .json(.number(let value)):
            return Self.integerString(from: value)
        default:
            return nil
        }
    }

    var stringArrayValue: [String]? {
        switch self {
        case .stringArray(let value):
            return value
        case .json(.array(let values)):
            let strings = values.compactMap { value -> String? in
                if case .string(let string) = value {
                    return string
                }
                return nil
            }
            return strings.count == values.count ? strings : nil
        default:
            return nil
        }
    }

    var booleanValue: Bool? {
        guard case .json(.bool(let value)) = self else { return nil }
        return value
    }

    var numberValue: Double? {
        switch self {
        case .json(.number(let value)):
            return value.isFinite ? value : nil
        case .string(let value):
            return Double(value).flatMap { $0.isFinite ? $0 : nil }
        default:
            return nil
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .string(let value):
            return .string(value)
        case .stringArray(let value):
            return .array(value.map(JSONValue.string))
        case .json(let value):
            return value
        }
    }

    static func fromJSONObject(_ value: Any) -> ToolArgumentValue? {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return JSONValue.fromJSONObject(number).map(ToolArgumentValue.json)
        case let strings as [String]:
            return .stringArray(strings)
        case let array as [Any]:
            let values = array.compactMap { item -> String? in
                switch item {
                case let string as String:
                    return string
                case let number as NSNumber:
                    guard case .number(let value)? = JSONValue.fromJSONObject(number) else {
                        return nil
                    }
                    return Self.integerString(from: value)
                default:
                    return nil
                }
            }
            if values.count == array.count {
                return .stringArray(values)
            }
            return JSONValue.fromJSONObject(value).map(ToolArgumentValue.json)
        default:
            return JSONValue.fromJSONObject(value).map(ToolArgumentValue.json)
        }
    }
}

struct ToolParameter: Identifiable, Codable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let title: String
    let description: String?
    let kind: ToolParameterKind
    let required: Bool
    let defaultValue: String?
    let maximumLength: Int?
    let integerRange: ClosedRange<Int>?
    let numberRange: ClosedRange<Double>?
    let allowedValues: [String]?
    let stringFormat: String?
    let jsonSchema: JSONValue?

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case description
        case kind
        case required
        case defaultValue
        case maximumLength
        case minimumInteger
        case maximumInteger
        case minimumNumber
        case maximumNumber
        case allowedValues
        case stringFormat
        case jsonSchema
    }

    init(
        name: String,
        title: String,
        description: String? = nil,
        kind: ToolParameterKind,
        required: Bool = true,
        defaultValue: String? = nil,
        maximumLength: Int? = nil,
        integerRange: ClosedRange<Int>? = nil,
        numberRange: ClosedRange<Double>? = nil,
        allowedValues: [String]? = nil,
        stringFormat: String? = nil,
        jsonSchema: JSONValue? = nil
    ) {
        self.name = name
        self.title = title
        self.description = description
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.maximumLength = maximumLength
        self.integerRange = integerRange
        self.numberRange = numberRange
        self.allowedValues = allowedValues
        self.stringFormat = stringFormat
        self.jsonSchema = jsonSchema
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decode(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        kind = try container.decode(ToolParameterKind.self, forKey: .kind)
        required = try container.decode(Bool.self, forKey: .required)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        maximumLength = try container.decodeIfPresent(Int.self, forKey: .maximumLength)
        // Reversed or non-finite bounds must fail as unreadable data. Building
        // the range from them traps, which no catch can stop, so one bad row
        // in the saved tools file would end the app at every launch.
        if let minimum = try container.decodeIfPresent(Int.self, forKey: .minimumInteger),
           let maximum = try container.decodeIfPresent(Int.self, forKey: .maximumInteger) {
            guard minimum <= maximum else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minimumInteger, in: container,
                    debugDescription: "minimumInteger is greater than maximumInteger."
                )
            }
            integerRange = minimum...maximum
        } else {
            integerRange = nil
        }
        if let minimum = try container.decodeIfPresent(Double.self, forKey: .minimumNumber),
           let maximum = try container.decodeIfPresent(Double.self, forKey: .maximumNumber) {
            guard minimum <= maximum else {
                throw DecodingError.dataCorruptedError(
                    forKey: .minimumNumber, in: container,
                    debugDescription: "minimumNumber is not a valid lower bound for maximumNumber."
                )
            }
            numberRange = minimum...maximum
        } else {
            numberRange = nil
        }
        allowedValues = try container.decodeIfPresent([String].self, forKey: .allowedValues)
        stringFormat = try container.decodeIfPresent(String.self, forKey: .stringFormat)
        jsonSchema = try container.decodeIfPresent(JSONValue.self, forKey: .jsonSchema)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(kind, forKey: .kind)
        try container.encode(required, forKey: .required)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(maximumLength, forKey: .maximumLength)
        try container.encodeIfPresent(integerRange?.lowerBound, forKey: .minimumInteger)
        try container.encodeIfPresent(integerRange?.upperBound, forKey: .maximumInteger)
        try container.encodeIfPresent(numberRange?.lowerBound, forKey: .minimumNumber)
        try container.encodeIfPresent(numberRange?.upperBound, forKey: .maximumNumber)
        try container.encodeIfPresent(allowedValues, forKey: .allowedValues)
        try container.encodeIfPresent(stringFormat, forKey: .stringFormat)
        try container.encodeIfPresent(jsonSchema, forKey: .jsonSchema)
    }
}

enum ProcessArgumentRuleKind: String, Codable, Sendable {
    case literal
    case value
    case option
    case flag
    case repeatedOption
    case choice
    case json
}

/// A declarative, persisted exact-argv recipe. Catalog tools use these rules to
/// expose semantic inputs without hiding CLI-specific code in the executor.
struct ProcessArgumentRule: Codable, Hashable, Sendable {
    let kind: ProcessArgumentRuleKind
    let parameter: String?
    let literal: String?
    let option: String?
    let choices: [String: [String]]?

    static func literal(_ value: String) -> Self {
        Self(kind: .literal, parameter: nil, literal: value, option: nil, choices: nil)
    }

    static func value(_ parameter: String) -> Self {
        Self(kind: .value, parameter: parameter, literal: nil, option: nil, choices: nil)
    }

    static func option(_ option: String, _ parameter: String) -> Self {
        Self(kind: .option, parameter: parameter, literal: nil, option: option, choices: nil)
    }

    static func flag(_ option: String, _ parameter: String) -> Self {
        Self(kind: .flag, parameter: parameter, literal: nil, option: option, choices: nil)
    }

    static func repeatedOption(_ option: String, _ parameter: String) -> Self {
        Self(kind: .repeatedOption, parameter: parameter, literal: nil, option: option, choices: nil)
    }

    static func choice(_ parameter: String, _ choices: [String: [String]]) -> Self {
        Self(kind: .choice, parameter: parameter, literal: nil, option: nil, choices: choices)
    }

    static func json(_ parameter: String) -> Self {
        Self(kind: .json, parameter: parameter, literal: nil, option: nil, choices: nil)
    }
}

enum ProcessInvocationConstraintKind: String, Codable, Sendable {
    case atLeastOne
    case exactlyOne
    case mutuallyExclusive
}

struct ProcessInvocationConstraint: Codable, Hashable, Sendable {
    let kind: ProcessInvocationConstraintKind
    let parameters: [String]

    static func atLeastOne(_ parameters: [String]) -> Self {
        Self(kind: .atLeastOne, parameters: parameters)
    }

    static func exactlyOne(_ parameters: [String]) -> Self {
        Self(kind: .exactlyOne, parameters: parameters)
    }

    static func mutuallyExclusive(_ parameters: [String]) -> Self {
        Self(kind: .mutuallyExclusive, parameters: parameters)
    }
}

struct ProcessInvocation: Codable, Hashable, Sendable {
    let arguments: [ProcessArgumentRule]
    let constraints: [ProcessInvocationConstraint]
    /// Extra argv used for a safe preflight before the real invocation. The
    /// executor runs the same resolved arguments plus these suffix items and
    /// proceeds only after a zero exit status.
    let preflightSuffix: [String]?
    /// Exact literal tokens removed from the real argv before adding the
    /// preflight suffix (for example, remove `--yes` before `--dry-run`).
    let preflightRemovingArguments: [String]?

    init(
        arguments: [ProcessArgumentRule],
        constraints: [ProcessInvocationConstraint] = [],
        preflightSuffix: [String]? = nil,
        preflightRemovingArguments: [String]? = nil
    ) {
        self.arguments = arguments
        self.constraints = constraints
        self.preflightSuffix = preflightSuffix
        self.preflightRemovingArguments = preflightRemovingArguments
    }
}

enum ToolApprovalPolicy: String, Codable, Sendable {
    case standard
    case everyCall
}

struct ToolAnnotationOverrides: Codable, Hashable, Sendable {
    let idempotentHint: Bool?
    let openWorldHint: Bool?

    init(idempotentHint: Bool? = nil, openWorldHint: Bool? = nil) {
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

/// R15 — the permanent record of where a scan-added tool came from and what its
/// binary looked like at add time. Presence of `provenance` is what marks a tool
/// as "Found on This Mac" (origin stays `.userDefined`).
struct ToolProvenance: Codable, Hashable, Sendable {
    let sourceKind: DiscoveredCLICandidate.Source
    let packageName: String?
    let packageVersion: String?
    let addedDate: Date
    let resolvedPathAtAdd: String
    let signingIdentityAtAdd: String     // "Developer ID: <team>" | "ad-hoc" | "unsigned"
    let contentSHA256AtAdd: String
    let wasQuarantinedAtAdd: Bool
    var summaryIsHarvested: Bool         // cleared when the user edits the summary (R11)
    var summaryOrigin: String?           // "Homebrew" / "npm" / … — drives the provenance chip + MCP frame

    /// The canonical string form a signing identity takes inside a provenance
    /// record — the value R16 compares against on revalidation.
    static func signingIdentityDescription(for trust: DiscoveredCLICandidate.SignatureTrust) -> String {
        switch trust {
        case .developerID(let team, _): "Developer ID: \(team)"
        case .adhoc: "ad-hoc"
        case .unsigned, .unchecked: "unsigned"
        case .invalid: "invalid"
        }
    }
}

/// A UI affordance a client widget may render for this tool's results —
/// pure data, no tool-specific code paths. The widget substitutes `{field}`
/// placeholders from the acted-on row's JSON object and calls `toolID`
/// through the host. Every such call re-enters the server's normal
/// capability gating and approval flow: an action is a shortcut to a tool
/// call, never a bypass.
/// A user-supplied input an action collects before firing (e.g. the new due
/// date for a reschedule). The widget renders an inline field; templates
/// reference the value as `{input.<name>}`.
struct ToolUIActionInput: Codable, Hashable, Sendable {
    let name: String
    let title: String
    let placeholder: String?
    /// Row field whose value prefills the input (e.g. the current title).
    let prefillField: String?

    init(name: String, title: String, placeholder: String? = nil, prefillField: String? = nil) {
        self.name = name
        self.title = title
        self.placeholder = placeholder
        self.prefillField = prefillField
    }
}

struct ToolUIAction: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Leading completion circle on table rows (Reminders-style).
        case checkOff
        /// Trailing button on table rows.
        case rowButton
    }

    enum Style: String, Codable, Sendable {
        case normal
        /// The widget arms a two-step confirm before firing.
        case destructive
    }

    let id: String
    let title: String
    let kind: Kind
    /// Target by the stable semantic tool ID used by persistence and MCP.
    let toolID: String?
    /// Alternative target: the first shared flexible-command adapter whose
    /// executable basename matches. This remains useful when an action is
    /// intentionally defined for any user-created adapter of that executable.
    let targetExecutableBasename: String?
    /// Arguments for the target; string leaves may contain `{field}` (row)
    /// and `{input.<name>}` (collected input) placeholders.
    let arguments: JSONValue
    /// The action appears only on rows containing all of these fields.
    let requiredRowFields: [String]
    /// For `.checkOff`: the row field marking "already done" — truthiness by
    /// default, string equality when `completedWhenEquals` is set (e.g.
    /// a row's `status == "completed"`).
    let completedWhenField: String?
    let completedWhenEquals: String?
    let style: Style?
    let inputs: [ToolUIActionInput]?

    init(
        id: String,
        title: String,
        kind: Kind,
        toolID: String? = nil,
        targetExecutableBasename: String? = nil,
        arguments: JSONValue,
        requiredRowFields: [String] = [],
        completedWhenField: String? = nil,
        completedWhenEquals: String? = nil,
        style: Style? = nil,
        inputs: [ToolUIActionInput]? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.toolID = toolID
        self.targetExecutableBasename = targetExecutableBasename
        self.arguments = arguments
        self.requiredRowFields = requiredRowFields
        self.completedWhenField = completedWhenField
        self.completedWhenEquals = completedWhenEquals
        self.style = style
        self.inputs = inputs
    }
}

/// Semantic presentation for the shared MCP Apps widget.
///
/// This is intentionally small and typed. `semanticResult` is the safe default
/// for tools without curated metadata; the other profiles name domain shapes
/// the generic renderer understands. Accent and rootPath are presentation
/// overrides, not executable identity or authorization state. The widget still
/// receives only generic columns/groups/document/change hints from the server.
struct ToolWidgetPresentation: Codable, Hashable, Sendable {
    enum Profile: String, Codable, Hashable, Sendable {
        case semanticResult
        case reminderRows
        case noteRows

        /// A saved tool can name a profile MacRemote no longer has
        /// (`episodeRows` and `habitRows` left with their catalogs, SPEC
        /// D88). It decodes as the safe default rather than failing the row.
        init(from decoder: Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Profile(rawValue: rawValue) ?? .semanticResult
        }
    }

    let profile: Profile
    let accent: String?
    let rootPath: String?
    /// Explicit opt-out for intermediate lookups and diagnostics. Missing means
    /// render, preserving existing catalogs and user-authored tools.
    let automatic: Bool?

    init(profile: Profile, accent: String? = nil, rootPath: String? = nil, automatic: Bool? = nil) {
        self.profile = profile
        self.accent = accent
        self.rootPath = rootPath
        self.automatic = automatic
    }
}

struct ToolDefinition: Identifiable, Codable, Hashable, Sendable {
    let id: String
    /// Permission-generation nonce. This is persisted so an Always Allow grant
    /// survives restarts and safe edits, but a deleted-and-recreated tool cannot
    /// inherit the old grant even when its semantic ID and definition match.
    /// It is local authorization state, never an MCP-visible tool identifier.
    let permissionEpoch: String
    let name: String
    let summary: String
    let executablePath: String
    let argumentPattern: [String]
    let parameters: [ToolParameter]
    let processInvocation: ProcessInvocation?
    let capability: ToolCapability
    let timeoutSeconds: TimeInterval
    let outputByteLimit: Int
    let origin: ToolOrigin
    let category: ToolCategory
    let permissionRequirements: [ToolPermissionRequirement]
    let backend: ToolBackend
    let mcpBridge: MCPBridgeConfiguration?
    let mcpStdioBridge: MCPStdioBridgeConfiguration?
    let nativeToolID: NativeToolIdentifier?
    let approvalPolicy: ToolApprovalPolicy
    let annotationOverrides: ToolAnnotationOverrides?
    let provenance: ToolProvenance?
    /// Optional widget affordances (MCP Apps): catalog/user data, never code.
    let uiActions: [ToolUIAction]?
    /// Optional typed MCP Apps presentation, authored by a catalog provider.
    let widgetPresentation: ToolWidgetPresentation?

    var preview: String {
        if let mcpBridge {
            return "\(mcpBridge.serverURL) → \(mcpBridge.toolName)"
        }
        if let mcpStdioBridge {
            return "\(([mcpStdioBridge.command] + mcpStdioBridge.args).joined(separator: " ")) → \(mcpStdioBridge.toolName)"
        }
        if backend == .native, let nativeToolID {
            return "native → \(nativeToolID.rawValue)"
        }
        if processInvocation != nil {
            return "\(executablePath) → dedicated workflow"
        }
        return ([executablePath] + argumentPattern).joined(separator: " ")
    }

    var isUserDefined: Bool {
        origin == .userDefined
    }

    var isGenericCLIAdapter: Bool {
        backend == .process && (argumentPattern == ["{args}"] || argumentPattern == ["{argv}"])
    }

    /// Whether a call needs the owner's approval, unless Always Allowed.
    /// Read-only tools run without asking, with one exception: a Flexible
    /// Command passes any arguments through, so nothing can check that it only
    /// reads. A Read-only label on one would mean "runs anything, unasked".
    var asksBeforeRunning: Bool {
        capability != .readOnly || isGenericCLIAdapter
    }

    var isMCPBridge: Bool {
        (backend == .mcpHTTPBridge && mcpBridge != nil) ||
            (backend == .mcpStdioBridge && mcpStdioBridge != nil)
    }

    var mcpBridgeIdentity: String? {
        if let mcpBridge {
            return "http:\(mcpBridge.serverURL)"
        }
        if let mcpStdioBridge {
            return "stdio:\(([mcpStdioBridge.command] + mcpStdioBridge.args).joined(separator: "\u{1f}"))"
        }
        return nil
    }

    var mcpBridgeServerName: String? {
        mcpBridge?.serverName ?? mcpStdioBridge?.serverName
    }

    var mcpBridgeServerIdentity: String? {
        mcpBridge?.serverIdentity ?? mcpStdioBridge?.serverIdentity
    }

    var mcpBridgeDiscoverySource: String? {
        mcpBridge?.discoverySource ?? mcpStdioBridge?.discoverySource
    }

    var mcpBridgeDiscoverySourcePath: String? {
        mcpBridge?.discoverySourcePath ?? mcpStdioBridge?.discoverySourcePath
    }

    var mcpBridgeDiscoveryOwners: [MCPDiscoveryOwner] {
        if let owners = mcpBridge?.discoveryOwners ?? mcpStdioBridge?.discoveryOwners,
           !owners.isEmpty {
            return owners
        }
        guard let serverIdentity = mcpBridgeServerIdentity,
              let source = mcpBridgeDiscoverySource,
              let sourcePath = mcpBridgeDiscoverySourcePath,
              !sourcePath.isEmpty else {
            return []
        }
        return [MCPDiscoveryOwner(
            serverIdentity: serverIdentity,
            source: source,
            sourcePath: sourcePath
        )]
    }

    var mcpBridgeToolName: String? {
        mcpBridge?.toolName ?? mcpStdioBridge?.toolName
    }

    var mcpBridgeInputSchema: JSONValue? {
        mcpBridge?.inputSchema ?? mcpStdioBridge?.inputSchema
    }

    var mcpBridgeAnnotations: JSONValue? {
        mcpBridge?.annotations ?? mcpStdioBridge?.annotations
    }

    enum CodingKeys: String, CodingKey {
        case id
        case permissionEpoch
        case name
        case summary
        case executablePath
        case argumentPattern
        case parameters
        case processInvocation
        case capability
        case timeoutSeconds
        case outputByteLimit
        case origin
        case category
        case permissionRequirements
        case backend
        case mcpBridge
        case mcpStdioBridge
        case nativeToolID
        case approvalPolicy
        case annotationOverrides
        case provenance
        case uiActions
        case widgetPresentation
    }

    init(
        id: String,
        permissionEpoch: String? = nil,
        name: String,
        summary: String,
        executablePath: String,
        argumentPattern: [String],
        parameters: [ToolParameter],
        processInvocation: ProcessInvocation? = nil,
        capability: ToolCapability,
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        origin: ToolOrigin = .builtIn,
        category: ToolCategory = .utilities,
        permissionRequirements: [ToolPermissionRequirement] = [],
        backend: ToolBackend = .process,
        mcpBridge: MCPBridgeConfiguration? = nil,
        mcpStdioBridge: MCPStdioBridgeConfiguration? = nil,
        nativeToolID: NativeToolIdentifier? = nil,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotationOverrides: ToolAnnotationOverrides? = nil,
        provenance: ToolProvenance? = nil,
        uiActions: [ToolUIAction]? = nil,
        widgetPresentation: ToolWidgetPresentation? = nil
    ) {
        self.id = id
        self.permissionEpoch = permissionEpoch ?? Self.defaultPermissionEpoch(
            toolID: id,
            origin: origin
        )
        self.name = name
        self.summary = summary
        self.executablePath = executablePath
        self.argumentPattern = argumentPattern
        self.parameters = parameters
        self.processInvocation = processInvocation
        self.capability = capability
        self.timeoutSeconds = timeoutSeconds
        self.outputByteLimit = outputByteLimit
        self.origin = origin
        self.category = category
        self.permissionRequirements = permissionRequirements
        self.backend = backend
        self.mcpBridge = mcpBridge
        self.mcpStdioBridge = mcpStdioBridge
        self.nativeToolID = nativeToolID
        self.approvalPolicy = approvalPolicy
        self.annotationOverrides = annotationOverrides
        self.provenance = provenance
        self.uiActions = uiActions
        self.widgetPresentation = widgetPresentation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        origin = try container.decodeIfPresent(ToolOrigin.self, forKey: .origin) ?? .userDefined
        let decodedPermissionEpoch = try container.decodeIfPresent(String.self, forKey: .permissionEpoch)
        permissionEpoch = decodedPermissionEpoch.flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.defaultPermissionEpoch(toolID: id, origin: origin)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        argumentPattern = try container.decode([String].self, forKey: .argumentPattern)
        parameters = try container.decode([ToolParameter].self, forKey: .parameters)
        processInvocation = try container.decodeIfPresent(ProcessInvocation.self, forKey: .processInvocation)
        capability = try container.decode(ToolCapability.self, forKey: .capability)
        timeoutSeconds = try container.decode(TimeInterval.self, forKey: .timeoutSeconds)
        outputByteLimit = try container.decode(Int.self, forKey: .outputByteLimit)
        category = try container.decodeIfPresent(ToolCategory.self, forKey: .category) ?? .utilities
        permissionRequirements = try container.decodeIfPresent([ToolPermissionRequirement].self, forKey: .permissionRequirements) ?? []
        backend = try container.decodeIfPresent(ToolBackend.self, forKey: .backend) ?? .process
        mcpBridge = try container.decodeIfPresent(MCPBridgeConfiguration.self, forKey: .mcpBridge)
        mcpStdioBridge = try container.decodeIfPresent(MCPStdioBridgeConfiguration.self, forKey: .mcpStdioBridge)
        nativeToolID = try container.decodeIfPresent(NativeToolIdentifier.self, forKey: .nativeToolID)
        approvalPolicy = try container.decodeIfPresent(ToolApprovalPolicy.self, forKey: .approvalPolicy) ?? .standard
        annotationOverrides = try container.decodeIfPresent(ToolAnnotationOverrides.self, forKey: .annotationOverrides)
        provenance = try container.decodeIfPresent(ToolProvenance.self, forKey: .provenance)
        uiActions = try container.decodeIfPresent([ToolUIAction].self, forKey: .uiActions)
        widgetPresentation = try container.decodeIfPresent(
            ToolWidgetPresentation.self,
            forKey: .widgetPresentation
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(permissionEpoch, forKey: .permissionEpoch)
        try container.encode(name, forKey: .name)
        try container.encode(summary, forKey: .summary)
        try container.encode(executablePath, forKey: .executablePath)
        try container.encode(argumentPattern, forKey: .argumentPattern)
        try container.encode(parameters, forKey: .parameters)
        try container.encodeIfPresent(processInvocation, forKey: .processInvocation)
        try container.encode(capability, forKey: .capability)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(outputByteLimit, forKey: .outputByteLimit)
        try container.encode(origin, forKey: .origin)
        try container.encode(category, forKey: .category)
        try container.encode(permissionRequirements, forKey: .permissionRequirements)
        try container.encode(backend, forKey: .backend)
        try container.encodeIfPresent(mcpBridge, forKey: .mcpBridge)
        try container.encodeIfPresent(mcpStdioBridge, forKey: .mcpStdioBridge)
        try container.encodeIfPresent(nativeToolID, forKey: .nativeToolID)
        try container.encode(approvalPolicy, forKey: .approvalPolicy)
        try container.encodeIfPresent(annotationOverrides, forKey: .annotationOverrides)
        try container.encodeIfPresent(provenance, forKey: .provenance)
        try container.encodeIfPresent(uiActions, forKey: .uiActions)
        try container.encodeIfPresent(widgetPresentation, forKey: .widgetPresentation)
    }

    /// New persisted tools receive a fresh grant generation. The value is not
    /// secret; unpredictability only prevents accidental approval inheritance.
    static func newPermissionEpoch() -> String {
        UUID().uuidString.lowercased()
    }

    func withPermissionEpoch(_ permissionEpoch: String) -> ToolDefinition {
        copy(permissionEpoch: permissionEpoch, capability: capability)
    }

    func withCapability(_ capability: ToolCapability) -> ToolDefinition {
        copy(permissionEpoch: permissionEpoch, capability: capability)
    }

    func withProvenance(_ provenance: ToolProvenance?) -> ToolDefinition {
        copy(permissionEpoch: permissionEpoch, capability: capability, provenance: provenance)
    }

    private func copy(
        permissionEpoch: String,
        capability: ToolCapability,
        provenance: ToolProvenance?? = nil
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            permissionEpoch: permissionEpoch,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            parameters: parameters,
            processInvocation: processInvocation,
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: outputByteLimit,
            origin: origin,
            category: category,
            permissionRequirements: permissionRequirements,
            backend: backend,
            mcpBridge: mcpBridge,
            mcpStdioBridge: mcpStdioBridge,
            nativeToolID: nativeToolID,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotationOverrides,
            provenance: provenance ?? self.provenance,
            uiActions: uiActions,
            widgetPresentation: widgetPresentation
        )
    }

    private static func defaultPermissionEpoch(toolID: String, origin: ToolOrigin) -> String {
        switch origin {
        case .builtIn:
            // Code-defined tools are not persisted, so their revision must be
            // deterministic. Bump explicitly at the initializer when a native
            // implementation's authority changes without changing its fields.
            return "builtin-v1:\(toolID)"
        case .userDefined:
            return newPermissionEpoch()
        }
    }
}

enum ToolValidationError: LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case emptyName
    case executableNotAbsolute
    case executableUnavailable(String)
    case blockedExecutable(String)
    case invalidArgument(String)
    case tooManyArguments
    case argumentsTooLarge
    case invalidPlaceholder(String)
    case undefinedPlaceholder(String)
    case invalidTimeout
    case invalidOutputLimit
    case invalidMCPBridge(String)
    case invalidNativeTool(String)
    case missingParameter(String)
    case invalidInteger(String)
    case integerOutOfRange(String)
    case invalidBoolean(String)
    case invalidNumber(String)
    case numberOutOfRange(String)
    case invalidJSON(String)
    case valueNotAllowed(String)
    case invalidFormat(String)
    case constraintViolation(String)
    case restrictedFlexibleCommand(String)
    case stringTooLong(String)
    case nulByte(String)
    case optionLikeValue(String)
    case writeToolDisabled(String)
    case identityChanged(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let id): "Unknown tool: \(id)"
        case .emptyName: "Tool name is required."
        case .executableNotAbsolute: "Executable path must be absolute."
        case .executableUnavailable:
            "The command this tool needs is not installed or is no longer available on this Mac."
        case .blockedExecutable(let path): "Shell-style executable is blocked: \(path)"
        case .invalidArgument(let argument): "Invalid argument: \(argument)"
        case .tooManyArguments: "Tool has too many arguments."
        case .argumentsTooLarge: "Resolved arguments and standard input exceed the maximum byte size."
        case .invalidPlaceholder(let placeholder): "Invalid placeholder: \(placeholder)"
        case .undefinedPlaceholder(let name): "Argument placeholder has no matching parameter: \(name)"
        case .invalidTimeout: "Timeout must be between 1 second and 24 hours."
        case .invalidOutputLimit: "Output limit must be between 1 KB and 64 MiB."
        case .invalidMCPBridge(let detail): "Invalid MCP bridge: \(detail)"
        case .invalidNativeTool(let detail): "Invalid native tool: \(detail)"
        case .missingParameter(let name): "Missing parameter: \(name)"
        case .invalidInteger(let name): "Expected integer for parameter: \(name)"
        case .integerOutOfRange(let name): "Integer parameter out of range: \(name)"
        case .invalidBoolean(let name): "Expected boolean for parameter: \(name)"
        case .invalidNumber(let name): "Expected finite number for parameter: \(name)"
        case .numberOutOfRange(let name): "Number parameter out of range: \(name)"
        case .invalidJSON(let name): "Expected structured JSON for parameter: \(name)"
        case .valueNotAllowed(let name): "Parameter value is not allowed: \(name)"
        case .invalidFormat(let name): "Parameter format is invalid: \(name)"
        case .constraintViolation(let detail): detail
        case .restrictedFlexibleCommand: "This command is blocked from remote Flexible Commands and must be run locally on this Mac."
        case .stringTooLong(let name): "String parameter too long: \(name)"
        case .nulByte(let name): "Parameter contains a NUL byte: \(name)"
        case .optionLikeValue(let name): "Parameter value can't start with a dash: \(name)"
        case .writeToolDisabled(let id): "Write-capable tool disabled: \(id)"
        case .identityChanged(let name): "\(name) changed publisher since you added it — review before sharing again."
        }
    }

    /// Actionable MCP tool-call failure text for `CallToolResult` content.
    func callToolMessage(tool: ToolDefinition?, arguments: [String: ToolArgumentValue]) -> String {
        switch self {
        case .unknownTool(let id):
            return "Unknown tool: \(id)"
        case .emptyName:
            return "Tool name is required."
        case .executableNotAbsolute:
            return "Executable path must be absolute."
        case .executableUnavailable:
            return "The command this tool needs is not installed or is no longer available on this Mac. Install or restore it, then try again."
        case .blockedExecutable(let path):
            return "Shell-style executable is blocked: \(path)"
        case .invalidArgument(let argument):
            if let got = Self.formattedArgumentValue(arguments[argument]) {
                return "Parameter '\(argument)' is invalid; got \(got)."
            }
            return "Invalid argument: \(argument)"
        case .tooManyArguments:
            return "Too many arguments were provided; reduce the number of items and try again."
        case .argumentsTooLarge:
            return "The resolved arguments and standard input exceed the maximum byte size; use smaller inline input or an absolute file path and try again."
        case .invalidPlaceholder(let placeholder):
            return "Invalid argument placeholder: \(placeholder)"
        case .undefinedPlaceholder(let name):
            return "Argument placeholder '\(name)' has no matching parameter on this tool."
        case .invalidTimeout:
            return "Timeout must be between 1 second and 24 hours."
        case .invalidOutputLimit:
            return "Output limit must be between 1 KB and 64 MiB."
        case .invalidMCPBridge(let detail):
            return "Invalid MCP bridge configuration: \(detail)"
        case .invalidNativeTool(let detail):
            return "Invalid native tool configuration: \(detail)"
        case .missingParameter(let name):
            return "Missing required parameter '\(name)'."
        case .invalidInteger(let name):
            if let got = Self.formattedArgumentValue(arguments[name]) {
                return "Parameter '\(name)' must be an integer; got \(got)."
            }
            return "Parameter '\(name)' must be an integer."
        case .integerOutOfRange(let name):
            let constraint = Self.integerConstraintDescription(for: name, in: tool) ?? "within the allowed range"
            if let got = Self.formattedArgumentValue(arguments[name]) {
                return "Parameter '\(name)' must be an integer \(constraint); got \(got)."
            }
            return "Parameter '\(name)' must be an integer \(constraint)."
        case .invalidBoolean(let name):
            return "Parameter '\(name)' must be a boolean."
        case .invalidNumber(let name):
            return "Parameter '\(name)' must be a finite number."
        case .numberOutOfRange(let name):
            return "Parameter '\(name)' is outside the allowed numeric range."
        case .invalidJSON(let name):
            return "Parameter '\(name)' must be a JSON object or array matching its schema."
        case .valueNotAllowed(let name):
            let values = tool?.parameters.first(where: { $0.name == name })?.allowedValues ?? []
            return "Parameter '\(name)' must be one of: \(values.joined(separator: ", "))."
        case .invalidFormat(let name):
            return "Parameter '\(name)' does not match the required \(tool?.parameters.first(where: { $0.name == name })?.stringFormat ?? "value") format."
        case .constraintViolation(let detail):
            return detail
        case .restrictedFlexibleCommand:
            return "This command is blocked from remote Flexible Commands and must be run locally on this Mac."
        case .stringTooLong(let name):
            let maximumLength = tool?.parameters.first(where: { $0.name == name })?.maximumLength
            if let value = arguments[name]?.stringValue, let maximumLength {
                return "Parameter '\(name)' must be at most \(maximumLength) characters; got \(value.count) characters."
            }
            return "Parameter '\(name)' exceeds the maximum allowed length."
        case .nulByte(let name):
            return "Parameter '\(name)' must not contain a NUL byte."
        case .optionLikeValue(let name):
            return "Parameter '\(name)' can't start with a dash: the command would read it as an option instead of as \(name)."
        case .writeToolDisabled(let id):
            return "Write-capable tool disabled: \(id)"
        case .identityChanged(let name):
            return "\(name) changed publisher since you added it — review before sharing again."
        }
    }

    var callToolReason: String {
        switch self {
        case .executableUnavailable, .blockedExecutable, .writeToolDisabled, .identityChanged:
            return "unavailable"
        default:
            return "invalid_argument"
        }
    }

    private static func formattedArgumentValue(_ value: ToolArgumentValue?) -> String? {
        guard let value else { return nil }
        if let string = value.stringValue {
            return "'\(string)'"
        }
        switch value {
        case .stringArray(let values):
            return "'\(values.joined(separator: ", "))'"
        case .json, .string:
            return nil
        }
    }

    private static func integerConstraintDescription(for name: String, in tool: ToolDefinition?) -> String? {
        guard let parameter = tool?.parameters.first(where: { $0.name == name }),
              let range = parameter.integerRange else {
            return nil
        }
        if range.lowerBound == range.upperBound {
            return "equal to \(range.lowerBound)"
        }
        return "between \(range.lowerBound) and \(range.upperBound)"
    }
}
