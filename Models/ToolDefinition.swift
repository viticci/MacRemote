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

enum ToolParameterKind: String, Codable, Sendable {
    case string
    case integer
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

    var preview: String {
        ([executablePath] + argumentPattern).joined(separator: " ")
    }
}

enum ToolValidationError: LocalizedError, Equatable, Sendable {
    case unknownTool(String)
    case missingParameter(String)
    case invalidInteger(String)
    case integerOutOfRange(String)
    case stringTooLong(String)
    case nulByte(String)
    case writeToolDisabled(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let id): "Unknown tool: \(id)"
        case .missingParameter(let name): "Missing parameter: \(name)"
        case .invalidInteger(let name): "Expected integer for parameter: \(name)"
        case .integerOutOfRange(let name): "Integer parameter out of range: \(name)"
        case .stringTooLong(let name): "String parameter too long: \(name)"
        case .nulByte(let name): "Parameter contains a NUL byte: \(name)"
        case .writeToolDisabled(let id): "Write-capable tool disabled: \(id)"
        }
    }
}
