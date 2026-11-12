import CoreFoundation
import Foundation

struct MCPBridgeJSONNumber: Equatable, Sendable {
    enum Storage: Equatable, Sendable {
        case signedInteger
        case unsignedInteger
        case decimal
        case floatingPoint
    }

    let text: String
    let storage: Storage

    var anyValue: Any {
        switch storage {
        case .signedInteger:
            return Int64(text)!
        case .unsignedInteger:
            return UInt64(text)!
        case .decimal:
            return NSDecimalNumber(
                string: text,
                locale: Locale(identifier: "en_US_POSIX")
            )
        case .floatingPoint:
            return Double(text)!
        }
    }
}

/// Bridge-only JSON storage that round-trips Foundation's parsed JSON without
/// converting NSNumber 0/1 into Bool or reducing 64-bit integers to Double.
enum MCPBridgeJSONValue: Equatable, Sendable {
    case object([String: MCPBridgeJSONValue])
    case array([MCPBridgeJSONValue])
    case string(String)
    case number(MCPBridgeJSONNumber)
    case bool(Bool)
    case null

    var anyValue: Any {
        switch self {
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .array(let value):
            return value.map(\.anyValue)
        case .string(let value):
            return value
        case .number(let value):
            return value.anyValue
        case .bool(let value):
            return value
        case .null:
            return NSNull()
        }
    }

    var objectValue: [String: MCPBridgeJSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    /// MCP content is assistant-visible unless it explicitly targets only the
    /// user. Keep this check on the lossless representation so audience hints
    /// survive normalization and artifact spill without a second lossy parse.
    var isUserOnlyMCPContent: Bool {
        guard let block = objectValue,
              let annotations = block["annotations"]?.objectValue,
              case .array(let audience)? = annotations["audience"] else {
            return false
        }
        let roles = Set(audience.compactMap { value -> String? in
            guard case .string(let role) = value else { return nil }
            return role
        })
        return roles.contains("user") && !roles.contains("assistant")
    }

    static func fromJSONObject(_ value: Any) -> MCPBridgeJSONValue? {
        switch value {
        case let object as [String: Any]:
            var result = [String: MCPBridgeJSONValue]()
            for (key, value) in object {
                guard let jsonValue = MCPBridgeJSONValue.fromJSONObject(value) else {
                    return nil
                }
                result[key] = jsonValue
            }
            return .object(result)
        case let array as [Any]:
            var result = [MCPBridgeJSONValue]()
            for value in array {
                guard let jsonValue = MCPBridgeJSONValue.fromJSONObject(value) else {
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
            let storage: MCPBridgeJSONNumber.Storage
            let objectType = String(cString: number.objCType)
            if number is NSDecimalNumber {
                storage = .decimal
            } else if ["C", "I", "S", "L", "Q"].contains(objectType) {
                storage = .unsignedInteger
            } else if ["c", "i", "s", "l", "q"].contains(objectType) {
                storage = .signedInteger
            } else {
                guard number.doubleValue.isFinite else { return nil }
                storage = .floatingPoint
            }
            return .number(MCPBridgeJSONNumber(text: number.stringValue, storage: storage))
        case _ as NSNull:
            return .null
        default:
            return nil
        }
    }
}

struct MCPBridgeUpstreamResultContext: Equatable, Sendable {
    /// Original MCP content blocks that carry information not already present
    /// in `stdout`. LocalMCPServer appends them as real CallToolResult content.
    let content: [MCPBridgeJSONValue]
    /// Original upstream result metadata. It is kept under a MacRemote
    /// namespace so upstream UI/resource keys cannot collide with MacRemote's.
    let meta: MCPBridgeJSONValue?
    /// Non-standard top-level result fields, preserved without teaching the
    /// bridge about any particular upstream server.
    let extensions: [String: MCPBridgeJSONValue]

    var isEmpty: Bool {
        content.isEmpty && meta == nil && extensions.isEmpty
    }

    var assistantVisibleContent: [MCPBridgeJSONValue] {
        content.filter { !$0.isUserOnlyMCPContent }
    }

    var userOnlyContent: [MCPBridgeJSONValue] {
        content.filter(\.isUserOnlyMCPContent)
    }

    var preservationJSONObject: [String: Any] {
        var object = [String: Any]()
        if !content.isEmpty {
            object["content"] = content.map(\.anyValue)
        }
        if let meta {
            object["_meta"] = meta.anyValue
        }
        if !extensions.isEmpty {
            object["extensions"] = extensions.mapValues(\.anyValue)
        }
        return object
    }

    var assistantVisiblePreservationJSONObject: [String: Any] {
        assistantVisibleContent.isEmpty
            ? [:]
            : ["content": assistantVisibleContent.map(\.anyValue)]
    }

    var userOnlyPreservationJSONObject: [String: Any] {
        userOnlyContent.isEmpty
            ? [:]
            : ["content": userOnlyContent.map(\.anyValue)]
    }

    var hiddenPreservationJSONObject: [String: Any] {
        var object = [String: Any]()
        if let meta {
            object["_meta"] = meta.anyValue
        }
        if !extensions.isEmpty {
            object["extensions"] = extensions.mapValues(\.anyValue)
        }
        return object
    }
}

struct MCPBridgeNormalizedToolResult: Equatable, Sendable {
    let stdout: String
    let isError: Bool
    let upstreamContext: MCPBridgeUpstreamResultContext?
    /// Encoded size of the normalized semantic payload plus its complete
    /// preservation context. Bridge clients enforce the tool's hard cap on it.
    let encodedByteCount: Int
}

/// Converts an upstream MCP CallToolResult into MacRemote's uniform execution
/// payload without making assumptions about any particular server or product.
enum MCPBridgeToolResultNormalizer {
    private static let standardResultKeys: Set<String> = [
        "content", "structuredContent", "isError", "_meta"
    ]

    static func normalize(_ result: [String: Any]) -> MCPBridgeNormalizedToolResult {
        let structuredContent = result["structuredContent"]
        let hasStructuredContent = result.keys.contains("structuredContent")
        let content = contentBlocks(in: result)
        // A user-only block may be rendered by the host for the person, but it
        // must never be copied into MacRemote's unannotated semantic stdout.
        let assistantVisibleContent = content.filter { !$0.isUserOnlyMCPContent }

        let stdout: String
        if hasStructuredContent,
           let serialized = serializedJSON(structuredContent ?? NSNull()) {
            // Keep the machine-readable payload directly addressable. Any
            // distinct human/multimodal fallback is carried alongside it as
            // standard MCP content rather than wrapping this in another result.
            stdout = serialized
        } else if let text = soleText(in: assistantVisibleContent) {
            stdout = text
        } else if !assistantVisibleContent.isEmpty,
                  let serialized = serializedJSON(assistantVisibleContent.map(\.anyValue)) {
            stdout = serialized
        } else {
            // A valid CallToolResult can have empty content and metadata only.
            // Never turn hidden `_meta` into model-visible stdout.
            stdout = ""
        }

        let passthroughContent = nonredundantContent(
            content,
            structuredContent: hasStructuredContent ? (structuredContent ?? NSNull()) : nil
        )
        let meta = result["_meta"].flatMap(MCPBridgeJSONValue.fromJSONObject)
        let extensions = result.reduce(into: [String: MCPBridgeJSONValue]()) { partial, entry in
            guard !standardResultKeys.contains(entry.key),
                  let value = MCPBridgeJSONValue.fromJSONObject(entry.value) else {
                return
            }
            partial[entry.key] = value
        }
        let context = MCPBridgeUpstreamResultContext(
            content: passthroughContent,
            meta: meta,
            extensions: extensions
        )

        let retainedContext = context.isEmpty ? nil : context
        let encodedByteCount: Int
        if let retainedContext {
            var encodedOutput: [String: Any] = ["stdout": stdout]
            encodedOutput["upstream"] = retainedContext.preservationJSONObject
            encodedByteCount = serializedJSON(encodedOutput)?.utf8.count
                ?? stdout.utf8.count
        } else {
            encodedByteCount = stdout.utf8.count
        }

        return MCPBridgeNormalizedToolResult(
            stdout: stdout,
            isError: result["isError"] as? Bool == true,
            upstreamContext: retainedContext,
            encodedByteCount: encodedByteCount
        )
    }

    static func hardCapDiagnostic(
        stdoutTruncated: Bool,
        preservationContextDropped: Bool
    ) -> String {
        guard preservationContextDropped else { return "" }
        if stdoutTruncated {
            return "Normalized stdout was truncated, and upstream MCP preservation context was omitted atomically because the result exceeded this tool's configured output limit. Increase the output limit and retry for the complete upstream result."
        }
        return "Normalized stdout is complete, but upstream MCP preservation context was omitted atomically because the combined result exceeded this tool's configured output limit. Increase the output limit and retry for the complete upstream result."
    }

    private static func contentBlocks(in result: [String: Any]) -> [MCPBridgeJSONValue] {
        guard let content = result["content"] as? [Any] else { return [] }
        return content.compactMap(MCPBridgeJSONValue.fromJSONObject)
    }

    private static func soleText(in content: [MCPBridgeJSONValue]) -> String? {
        guard content.count == 1,
              let block = content[0].objectValue,
              case .string("text")? = block["type"],
              case .string(let text)? = block["text"] else {
            return nil
        }
        return text
    }

    private static func nonredundantContent(
        _ content: [MCPBridgeJSONValue],
        structuredContent: Any?
    ) -> [MCPBridgeJSONValue] {
        guard !content.isEmpty else { return [] }

        if let structuredContent,
           content.count == 1,
           let block = content[0].objectValue,
           block.keys.count == 2,
           case .string("text")? = block["type"],
           case .string(let text)? = block["text"],
           textJSON(text, isEquivalentTo: structuredContent) {
            return []
        }

        // A sole bare text block is represented exactly by stdout when there
        // is no structured payload. Annotations or any additional block fields
        // make it nonredundant and therefore pass through.
        if structuredContent == nil,
           content.count == 1,
           let block = content[0].objectValue,
           block.keys.count == 2,
           case .string("text")? = block["type"],
           block["text"] != nil {
            return []
        }

        return content
    }

    private static func textJSON(_ text: String, isEquivalentTo value: Any) -> Bool {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
              ),
              let left = serializedJSON(parsed),
              let right = serializedJSON(value) else {
            return false
        }
        return left == right
    }

    private static func serializedJSON(_ value: Any) -> String? {
        guard let losslessValue = MCPBridgeJSONValue.fromJSONObject(value),
              let data = try? JSONSerialization.checkedData(
                withJSONObject: losslessValue.anyValue,
                options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
              ) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
