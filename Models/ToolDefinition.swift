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

enum ToolCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case reminders
    case podcasts
    case filesystem
    case utilities
    case imageProcessing
    case text
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .reminders: "Reminders"
        case .podcasts: "Podcasts"
        case .filesystem: "Filesystem"
        case .utilities: "Utilities"
        case .imageProcessing: "Image Processing"
        case .text: "Text"
        case .developer: "Developer"
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
        case .fullDiskAccess: "lock.shield"
        case .reminders: "checklist"
        case .calendars: "calendar"
        case .contacts: "person.crop.circle"
        case .photos: "photo"
        case .camera: "camera"
        case .microphone: "mic"
        case .speechRecognition: "waveform"
        case .location: "location"
        case .screenRecording: "rectangle.dashed"
        case .accessibility: "figure"
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

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var stringArrayValue: [String]? {
        if case .stringArray(let value) = self {
            return value
        }
        return nil
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

    var preview: String {
        ([executablePath] + argumentPattern).joined(separator: " ")
    }

    var isUserDefined: Bool {
        origin == .userDefined
    }

    var isGenericCLIAdapter: Bool {
        argumentPattern == ["{args}"] || argumentPattern == ["{argv}"]
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
        permissionRequirements: [ToolPermissionRequirement] = []
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
    case missingParameter(String)
    case invalidInteger(String)
    case integerOutOfRange(String)
    case stringTooLong(String)
    case nulByte(String)
    case writeToolDisabled(String)

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
        case .missingParameter(let name): "Missing parameter: \(name)"
        case .invalidInteger(let name): "Expected integer for parameter: \(name)"
        case .integerOutOfRange(let name): "Integer parameter out of range: \(name)"
        case .stringTooLong(let name): "String parameter too long: \(name)"
        case .nulByte(let name): "Parameter contains a NUL byte: \(name)"
        case .writeToolDisabled(let id): "Write-capable tool disabled: \(id)"
        }
    }
}
