import CryptoKit
import Foundation

/// A versioned digest of the parts of a tool definition that determine what an
/// Always Allow grant authorizes. Authentication/session state deliberately
/// never enters this material: OAuth access-token refresh, refresh-token
/// rotation, reconnects, and DCR client-ID churn cannot change a tool digest.
enum ToolSecurityFingerprint {
    static let formatVersion = 2

    static func make(for tool: ToolDefinition) -> String {
        var material = CanonicalMaterial()
        material.add("domain", "macremote-tool-security")
        material.add("version", formatVersion)
        material.add("toolID", tool.id)
        material.add("permissionEpoch", tool.permissionEpoch)
        material.add("backend", tool.backend.rawValue)
        material.add("capability", tool.capability.rawValue)
        material.add("approvalPolicy", tool.approvalPolicy.rawValue)
        material.add("timeoutSeconds.bitPattern", String(tool.timeoutSeconds.bitPattern, radix: 16))
        material.add("outputByteLimit", tool.outputByteLimit)

        let requirements = Set(tool.permissionRequirements.map(\.rawValue)).sorted()
        material.add("permissionRequirements.count", requirements.count)
        for requirement in requirements {
            material.add("permissionRequirement", requirement)
        }

        // Argument order is executable behavior. Parameter order is retained as
        // well because validation currently resolves the first matching name.
        material.add("argumentPattern.count", tool.argumentPattern.count)
        for argument in tool.argumentPattern {
            material.add("argument", argument)
        }
        material.add("parameters.count", tool.parameters.count)
        for parameter in tool.parameters {
            material.add("parameter.name", parameter.name)
            material.add("parameter.kind", parameter.kind.rawValue)
            material.add("parameter.required", parameter.required)
            material.add("parameter.default", parameter.defaultValue)
            material.add("parameter.maximumLength", parameter.maximumLength)
            material.add("parameter.integerMinimum", parameter.integerRange?.lowerBound)
            material.add("parameter.integerMaximum", parameter.integerRange?.upperBound)
            material.add("parameter.numberMinimum", parameter.numberRange.map { String($0.lowerBound) })
            material.add("parameter.numberMaximum", parameter.numberRange.map { String($0.upperBound) })
            material.add("parameter.allowedValues.count", parameter.allowedValues?.count)
            for value in parameter.allowedValues ?? [] {
                material.add("parameter.allowedValue", value)
            }
            material.add("parameter.stringFormat", parameter.stringFormat)
            material.add("parameter.jsonSchema", parameter.jsonSchema)
        }
        material.add("processInvocation", canonicalJSON(tool.processInvocation))

        switch tool.backend {
        case .process:
            material.add("process.executablePath", tool.executablePath)
            addProvenance(tool.provenance, to: &material)
        case .mcpHTTPBridge:
            addHTTPBridge(tool.mcpBridge, to: &material)
        case .mcpStdioBridge:
            addStdioBridge(tool.mcpStdioBridge, to: &material)
        case .native:
            material.add("native.toolID", tool.nativeToolID?.rawValue)
        }

        return sha256Hex(material.data)
    }

    private static func canonicalJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func addProvenance(_ provenance: ToolProvenance?, to material: inout CanonicalMaterial) {
        guard let provenance else {
            material.add("provenance", Optional<String>.none)
            return
        }
        material.add("provenance", "present")
        material.add("provenance.sourceKind", provenance.sourceKind.rawValue)
        material.add("provenance.packageName", provenance.packageName)
        material.add("provenance.resolvedPathAtAdd", provenance.resolvedPathAtAdd)
        material.add("provenance.signingIdentityAtAdd", provenance.signingIdentityAtAdd)
        material.add("provenance.contentSHA256AtAdd", provenance.contentSHA256AtAdd)
        material.add("provenance.wasQuarantinedAtAdd", provenance.wasQuarantinedAtAdd)
    }

    private static func addHTTPBridge(
        _ bridge: MCPBridgeConfiguration?,
        to material: inout CanonicalMaterial
    ) {
        guard let bridge else {
            material.add("httpBridge", Optional<String>.none)
            return
        }
        material.add("httpBridge", "present")
        material.add("httpBridge.serverURL", bridge.serverURL)
        material.add("httpBridge.toolName", bridge.toolName)
        material.add("httpBridge.protocolVersion", bridge.protocolVersion)
        material.add("httpBridge.inputSchema", bridge.inputSchema)
        material.add("httpBridge.headers.count", bridge.headers.count)
        for header in bridge.headers.sorted(by: { lhs, rhs in
            let leftName = lhs.name.lowercased()
            let rightName = rhs.name.lowercased()
            if leftName != rightName { return leftName < rightName }
            return secretBindingSortKey(literal: lhs.value, source: lhs.valueSource) <
                secretBindingSortKey(literal: rhs.value, source: rhs.valueSource)
        }) {
            material.add("httpBridge.header.name", header.name.lowercased())
            addSecretBinding(
                literal: header.value,
                source: header.valueSource,
                namespace: "httpBridge.header",
                to: &material
            )
        }
    }

    private static func addStdioBridge(
        _ bridge: MCPStdioBridgeConfiguration?,
        to material: inout CanonicalMaterial
    ) {
        guard let bridge else {
            material.add("stdioBridge", Optional<String>.none)
            return
        }
        material.add("stdioBridge", "present")
        material.add("stdioBridge.command", bridge.command)
        material.add(
            "stdioBridge.startupTimeoutSeconds.bitPattern",
            bridge.startupTimeoutSeconds.map { String($0.bitPattern, radix: 16) }
        )
        material.add("stdioBridge.args.count", bridge.args.count)
        for argument in bridge.args {
            material.add("stdioBridge.arg", argument)
        }
        material.add("stdioBridge.toolName", bridge.toolName)
        material.add("stdioBridge.protocolVersion", bridge.protocolVersion)
        material.add("stdioBridge.inputSchema", bridge.inputSchema)
        material.add("stdioBridge.environment.count", bridge.environment.count)
        for variable in bridge.environment.sorted(by: { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return secretBindingSortKey(literal: lhs.value, source: lhs.valueSource) <
                secretBindingSortKey(literal: rhs.value, source: rhs.valueSource)
        }) {
            material.add("stdioBridge.environment.name", variable.name)
            addSecretBinding(
                literal: variable.value,
                source: variable.valueSource,
                namespace: "stdioBridge.environment",
                to: &material
            )
        }
    }

    /// Source-backed credentials bind the grant to the stable secret locator,
    /// not to a rotating token fetched from it. Literal credentials have no
    /// stable principal, so changing one intentionally invalidates the grant.
    private static func addSecretBinding(
        literal: String?,
        source: MCPBridgeHeaderValueSource?,
        namespace: String,
        to material: inout CanonicalMaterial
    ) {
        if let literal {
            material.add("\(namespace).binding", "literal")
            material.add("\(namespace).literalSHA256", sha256Hex(Data(literal.utf8)))
            return
        }
        guard let source else {
            material.add("\(namespace).binding", Optional<String>.none)
            return
        }
        material.add("\(namespace).binding", "source")
        material.add("\(namespace).source.kind", source.kind.rawValue)
        material.add("\(namespace).source.environmentKey", source.environmentKey)
        material.add("\(namespace).source.filePath", source.filePath)
        material.add("\(namespace).source.keyPath.count", source.keyPath?.count)
        for component in source.keyPath ?? [] {
            material.add("\(namespace).source.keyPath", component)
        }
        material.add("\(namespace).source.prefix", source.prefix)
    }

    private static func secretBindingSortKey(
        literal: String?,
        source: MCPBridgeHeaderValueSource?
    ) -> String {
        if let literal {
            return "literal:\(sha256Hex(Data(literal.utf8)))"
        }
        guard let source else { return "none" }
        return [
            "source",
            source.kind.rawValue,
            source.environmentKey ?? "",
            source.filePath ?? "",
            (source.keyPath ?? []).joined(separator: "\u{1f}"),
            source.prefix ?? ""
        ].joined(separator: "\u{1e}")
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension ToolDefinition {
    var securityFingerprint: String {
        ToolSecurityFingerprint.make(for: self)
    }
}

enum ToolSecurityFingerprintError: LocalizedError, Equatable, Sendable {
    case changed

    var errorDescription: String? {
        "The tool's security contract changed after it was approved. Refresh the tool list and approve the new definition."
    }
}

/// Unambiguous, deterministic length-prefixed material. JSON objects are sorted
/// recursively; arrays remain ordered. OAuth/client fields have no API here by
/// design, making accidental inclusion difficult during future maintenance.
private struct CanonicalMaterial {
    private(set) var data = Data()

    mutating func add(_ key: String, _ value: String) {
        append(key)
        data.append(1)
        append(value)
    }

    mutating func add(_ key: String, _ value: String?) {
        append(key)
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        append(value)
    }

    mutating func add(_ key: String, _ value: Int) {
        add(key, String(value))
    }

    mutating func add(_ key: String, _ value: Int?) {
        add(key, value.map { String($0) })
    }

    mutating func add(_ key: String, _ value: Bool) {
        add(key, value ? "true" : "false")
    }

    mutating func add(_ key: String, _ value: JSONValue?) {
        append(key)
        guard let value else {
            data.append(0)
            return
        }
        data.append(1)
        appendJSON(value)
    }

    private mutating func append(_ value: String) {
        let bytes = Data(value.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(bytes)
    }

    private mutating func appendJSON(_ value: JSONValue) {
        switch value {
        case .object(let object):
            data.append(1)
            append(String(object.count))
            for key in object.keys.sorted() {
                append(key)
                appendJSON(object[key] ?? .null)
            }
        case .array(let array):
            data.append(2)
            append(String(array.count))
            for element in array {
                appendJSON(element)
            }
        case .string(let string):
            data.append(3)
            append(string)
        case .number(let number):
            data.append(4)
            append(String(number.bitPattern, radix: 16))
        case .bool(let bool):
            data.append(5)
            data.append(bool ? 1 : 0)
        case .null:
            data.append(6)
        }
    }
}
