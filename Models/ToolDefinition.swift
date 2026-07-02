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
}

enum MCPBridgeHeaderValueSourceKind: String, Codable, Sendable {
    case environment
    case jsonFile
    case tomlFile
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
}

struct MCPBridgeConfiguration: Codable, Hashable, Sendable {
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
    case habits
    case podcasts
    case filesystem
    case utilities
    case imageProcessing
    case text
    case developer
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: "Reminders"
        case .habits: "Habits"
        case .podcasts: "Podcasts"
        case .filesystem: "Filesystem"
        case .utilities: "Utilities"
        // DL-12: retitle only — the raw value stays `imageProcessing` so persisted
        // tools.json needs zero migration.
        case .imageProcessing: "Media"
        case .text: "Text"
        case .developer: "Developer"
        case .ai: "AI & Agents"
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

    static var macOSPrivacyServices: [ToolPermissionRequirement] {
        allCases.filter { !$0.isFullDiskAccess }
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
}

enum ToolArgumentValue: Equatable, Sendable {
    case string(String)
    case stringArray([String])
    case json(JSONValue)

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .json(.string(let value)):
            return value
        case .json(.number(let value)) where value.rounded() == value:
            return String(Int(value))
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
        case let int as Int:
            return .json(.number(Double(int)))
        case let double as Double:
            guard double.isFinite else { return nil }
            return .json(.number(double))
        case let strings as [String]:
            return .stringArray(strings)
        case let array as [Any]:
            let values = array.compactMap { item -> String? in
                switch item {
                case let string as String:
                    return string
                case let int as Int:
                    return String(int)
                case let double as Double where double.rounded() == double:
                    return String(Int(double))
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
    let kind: ToolParameterKind
    let required: Bool
    let defaultValue: String?
    let maximumLength: Int?
    let integerRange: ClosedRange<Int>?

    enum CodingKeys: String, CodingKey {
        case name
        case title
        case kind
        case required
        case defaultValue
        case maximumLength
        case minimumInteger
        case maximumInteger
    }

    init(
        name: String,
        title: String,
        kind: ToolParameterKind,
        required: Bool = true,
        defaultValue: String? = nil,
        maximumLength: Int? = nil,
        integerRange: ClosedRange<Int>? = nil
    ) {
        self.name = name
        self.title = title
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.maximumLength = maximumLength
        self.integerRange = integerRange
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        title = try container.decode(String.self, forKey: .title)
        kind = try container.decode(ToolParameterKind.self, forKey: .kind)
        required = try container.decode(Bool.self, forKey: .required)
        defaultValue = try container.decodeIfPresent(String.self, forKey: .defaultValue)
        maximumLength = try container.decodeIfPresent(Int.self, forKey: .maximumLength)
        if let minimum = try container.decodeIfPresent(Int.self, forKey: .minimumInteger),
           let maximum = try container.decodeIfPresent(Int.self, forKey: .maximumInteger) {
            integerRange = minimum...maximum
        } else {
            integerRange = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(title, forKey: .title)
        try container.encode(kind, forKey: .kind)
        try container.encode(required, forKey: .required)
        try container.encodeIfPresent(defaultValue, forKey: .defaultValue)
        try container.encodeIfPresent(maximumLength, forKey: .maximumLength)
        try container.encodeIfPresent(integerRange?.lowerBound, forKey: .minimumInteger)
        try container.encodeIfPresent(integerRange?.upperBound, forKey: .maximumInteger)
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

struct ToolDefinition: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let executablePath: String
    let argumentPattern: [String]
    let parameters: [ToolParameter]
    let capability: ToolCapability
    let timeoutSeconds: TimeInterval
    let outputByteLimit: Int
    let origin: ToolOrigin
    let category: ToolCategory
    let permissionRequirements: [ToolPermissionRequirement]
    let backend: ToolBackend
    let mcpBridge: MCPBridgeConfiguration?
    let mcpStdioBridge: MCPStdioBridgeConfiguration?
    let provenance: ToolProvenance?

    func withCategory(_ category: ToolCategory) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            parameters: parameters,
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: outputByteLimit,
            origin: origin,
            category: category,
            permissionRequirements: permissionRequirements,
            backend: backend,
            mcpBridge: mcpBridge,
            mcpStdioBridge: mcpStdioBridge,
            provenance: provenance
        )
    }

    var preview: String {
        if let mcpBridge {
            return "\(mcpBridge.serverURL) → \(mcpBridge.toolName)"
        }
        if let mcpStdioBridge {
            return "\(([mcpStdioBridge.command] + mcpStdioBridge.args).joined(separator: " ")) → \(mcpStdioBridge.toolName)"
        }
        return ([executablePath] + argumentPattern).joined(separator: " ")
    }

    var isUserDefined: Bool {
        origin == .userDefined
    }

    var isGenericCLIAdapter: Bool {
        backend == .process && (argumentPattern == ["{args}"] || argumentPattern == ["{argv}"])
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

    var mcpBridgeToolName: String? {
        mcpBridge?.toolName ?? mcpStdioBridge?.toolName
    }

    var mcpBridgeToolTitle: String? {
        mcpBridge?.toolTitle ?? mcpStdioBridge?.toolTitle
    }

    var mcpBridgeToolDescription: String? {
        mcpBridge?.toolDescription ?? mcpStdioBridge?.toolDescription
    }

    var mcpBridgeInputSchema: JSONValue? {
        mcpBridge?.inputSchema ?? mcpStdioBridge?.inputSchema
    }

    var mcpBridgeAnnotations: JSONValue? {
        mcpBridge?.annotations ?? mcpStdioBridge?.annotations
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case summary
        case executablePath
        case argumentPattern
        case parameters
        case capability
        case timeoutSeconds
        case outputByteLimit
        case origin
        case category
        case permissionRequirements
        case backend
        case mcpBridge
        case mcpStdioBridge
        case provenance
    }

    init(
        id: String,
        name: String,
        summary: String,
        executablePath: String,
        argumentPattern: [String],
        parameters: [ToolParameter],
        capability: ToolCapability,
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        origin: ToolOrigin = .builtIn,
        category: ToolCategory = .utilities,
        permissionRequirements: [ToolPermissionRequirement] = [],
        backend: ToolBackend = .process,
        mcpBridge: MCPBridgeConfiguration? = nil,
        mcpStdioBridge: MCPStdioBridgeConfiguration? = nil,
        provenance: ToolProvenance? = nil
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.executablePath = executablePath
        self.argumentPattern = argumentPattern
        self.parameters = parameters
        self.capability = capability
        self.timeoutSeconds = timeoutSeconds
        self.outputByteLimit = outputByteLimit
        self.origin = origin
        self.category = category
        self.permissionRequirements = permissionRequirements
        self.backend = backend
        self.mcpBridge = mcpBridge
        self.mcpStdioBridge = mcpStdioBridge
        self.provenance = provenance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        summary = try container.decode(String.self, forKey: .summary)
        executablePath = try container.decode(String.self, forKey: .executablePath)
        argumentPattern = try container.decode([String].self, forKey: .argumentPattern)
        parameters = try container.decode([ToolParameter].self, forKey: .parameters)
        capability = try container.decode(ToolCapability.self, forKey: .capability)
        timeoutSeconds = try container.decode(TimeInterval.self, forKey: .timeoutSeconds)
        outputByteLimit = try container.decode(Int.self, forKey: .outputByteLimit)
        origin = try container.decodeIfPresent(ToolOrigin.self, forKey: .origin) ?? .userDefined
        category = try container.decodeIfPresent(ToolCategory.self, forKey: .category) ?? .utilities
        permissionRequirements = try container.decodeIfPresent([ToolPermissionRequirement].self, forKey: .permissionRequirements) ?? []
        backend = try container.decodeIfPresent(ToolBackend.self, forKey: .backend) ?? .process
        mcpBridge = try container.decodeIfPresent(MCPBridgeConfiguration.self, forKey: .mcpBridge)
        mcpStdioBridge = try container.decodeIfPresent(MCPStdioBridgeConfiguration.self, forKey: .mcpStdioBridge)
        provenance = try container.decodeIfPresent(ToolProvenance.self, forKey: .provenance)
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
    case invalidPlaceholder(String)
    case undefinedPlaceholder(String)
    case invalidTimeout
    case invalidOutputLimit
    case invalidMCPBridge(String)
    case missingParameter(String)
    case invalidInteger(String)
    case integerOutOfRange(String)
    case stringTooLong(String)
    case nulByte(String)
    case writeToolDisabled(String)
    case identityChanged(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let id): "Unknown tool: \(id)"
        case .emptyName: "Tool name is required."
        case .executableNotAbsolute: "Executable path must be absolute."
        case .executableUnavailable(let path): "Executable is not available: \(path)"
        case .blockedExecutable(let path): "Shell-style executable is blocked: \(path)"
        case .invalidArgument(let argument): "Invalid argument: \(argument)"
        case .tooManyArguments: "Tool has too many arguments."
        case .invalidPlaceholder(let placeholder): "Invalid placeholder: \(placeholder)"
        case .undefinedPlaceholder(let name): "Argument placeholder has no matching parameter: \(name)"
        case .invalidTimeout: "Timeout must be between 1 and 60 seconds."
        case .invalidOutputLimit: "Output limit must be between 1 KB and 5 MB."
        case .invalidMCPBridge(let detail): "Invalid MCP bridge: \(detail)"
        case .missingParameter(let name): "Missing parameter: \(name)"
        case .invalidInteger(let name): "Expected integer for parameter: \(name)"
        case .integerOutOfRange(let name): "Integer parameter out of range: \(name)"
        case .stringTooLong(let name): "String parameter too long: \(name)"
        case .nulByte(let name): "Parameter contains a NUL byte: \(name)"
        case .writeToolDisabled(let id): "Write-capable tool disabled: \(id)"
        case .identityChanged(let name): "\(name) changed publisher since you added it — review before sharing again."
        }
    }
}
