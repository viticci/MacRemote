import CoreFoundation
import Foundation

enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var anyValue: Any {
        switch self {
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .array(let value):
            return value.map(\.anyValue)
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    static func fromJSONObject(_ value: Any) -> JSONValue? {
        switch value {
        case let object as [String: Any]:
            var result = [String: JSONValue]()
            for (key, value) in object {
                guard let jsonValue = JSONValue.fromJSONObject(value) else {
                    return nil
                }
                result[key] = jsonValue
            }
            return .object(result)
        case let array as [Any]:
            var result = [JSONValue]()
            for value in array {
                guard let jsonValue = JSONValue.fromJSONObject(value) else {
                    return nil
                }
                result.append(jsonValue)
            }
            return .array(result)
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            guard number.doubleValue.isFinite else { return nil }
            return .number(number.doubleValue)
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

struct InvalidJSONObjectError: Error {}

extension JSONSerialization {
    /// Serializes like `data(withJSONObject:)`, but throws for an object that is
    /// not valid JSON. Foundation raises an Objective-C exception there, which
    /// Swift cannot catch and which ends the process. Client requests and tool
    /// output both reach serialization, and Foundation itself parses `-1e999`
    /// to an infinity it then refuses to write, so every write is checked.
    static func checkedData(withJSONObject object: Any, options: WritingOptions = []) throws -> Data {
        let isContainer = object is NSArray || object is NSDictionary
        guard isValidJSONObject(isContainer ? object : [object]) else {
            throw InvalidJSONObjectError()
        }
        return try data(withJSONObject: object, options: options)
    }
}
