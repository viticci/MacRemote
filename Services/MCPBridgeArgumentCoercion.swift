import Foundation

/// Aligns bridged tool arguments with the upstream input schema's declared
/// scalar types before forwarding them.
///
/// Hosts and widgets often send every value as a string (`"32277"` for an
/// integer id, `"true"` for a boolean). A typed upstream server with
/// `additionalProperties: false` rejects those outright. This converts a
/// string to the one scalar type the schema declares when the conversion is
/// exact, and a number to a string when the schema wants a string. Anything
/// else passes through unchanged; this never invents or drops arguments.
enum MCPBridgeArgumentCoercion {
    static func coerce(
        _ arguments: [String: Any],
        toSchema schema: JSONValue?
    ) -> [String: Any] {
        guard case .object(let root)? = schema,
              case .object(let properties)? = root["properties"] else {
            return arguments
        }
        var coerced = arguments
        for (name, value) in arguments {
            guard case .object(let property)? = properties[name],
                  let type = declaredScalarType(property) else { continue }
            coerced[name] = coerce(value, to: type)
        }
        return coerced
    }

    private enum ScalarType {
        case integer
        case number
        case boolean
        case string
    }

    private static func declaredScalarType(_ property: [String: JSONValue]) -> ScalarType? {
        guard case .string(let type)? = property["type"] else { return nil }
        switch type {
        case "integer": return .integer
        case "number": return .number
        case "boolean": return .boolean
        case "string": return .string
        default: return nil
        }
    }

    private static func coerce(_ value: Any, to type: ScalarType) -> Any {
        switch (type, value) {
        case (.integer, let string as String):
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            return Int64(trimmed).map { $0 as Any } ?? value
        case (.number, let string as String):
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if let integer = Int64(trimmed) { return integer }
            return Double(trimmed).flatMap { $0.isFinite ? $0 : nil } ?? value
        case (.boolean, let string as String):
            switch string.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true": return true
            case "false": return false
            default: return value
            }
        case (.string, let number as NSNumber):
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return value }
            return number.stringValue
        default:
            return value
        }
    }
}
