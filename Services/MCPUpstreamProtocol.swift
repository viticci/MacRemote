import Foundation

enum MCPMirroredHeaderValueType {
    case string
    case integer
    case boolean
}

struct MCPMirroredHeaderAnnotation {
    let parameterPath: [String]
    let headerName: String
    let valueType: MCPMirroredHeaderValueType
}

struct MCPMirroredHeaderSchemaInspection {
    static let maximumDepth = 64
    static let maximumNodes = 4_096

    enum Failure: Error, Equatable {
        case maximumDepthExceeded
        case maximumNodesExceeded

        var detail: String {
            switch self {
            case .maximumDepthExceeded:
                "inputSchema exceeds the maximum depth of \(maximumDepth)"
            case .maximumNodesExceeded:
                "inputSchema exceeds the maximum of \(maximumNodes) schema nodes"
            }
        }
    }

    let annotations: [MCPMirroredHeaderAnnotation]
    let annotationsAreValid: Bool

    private enum Node {
        case foundation(Any)
        case json(JSONValue)

        var object: [String: Node]? {
            switch self {
            case .foundation(let value):
                guard let object = value as? [String: Any] else { return nil }
                return object.mapValues(Node.foundation)
            case .json(.object(let object)):
                return object.mapValues(Node.json)
            case .json:
                return nil
            }
        }

        var array: [Node]? {
            switch self {
            case .foundation(let value):
                guard let array = value as? [Any] else { return nil }
                return array.map(Node.foundation)
            case .json(.array(let array)):
                return array.map(Node.json)
            case .json:
                return nil
            }
        }

        var string: String? {
            switch self {
            case .foundation(let value):
                return value as? String
            case .json(.string(let value)):
                return value
            case .json:
                return nil
            }
        }
    }

    private enum Reachability {
        case schema(path: [String], annotationEligible: Bool)
        case properties(parentPath: [String])
        case unreachable
    }

    private struct Budget {
        var nodes = 0

        mutating func visit(depth: Int) throws {
            guard depth <= MCPMirroredHeaderSchemaInspection.maximumDepth else {
                throw Failure.maximumDepthExceeded
            }
            nodes += 1
            guard nodes <= MCPMirroredHeaderSchemaInspection.maximumNodes else {
                throw Failure.maximumNodesExceeded
            }
        }
    }

    static func inspect(_ value: Any) throws -> MCPMirroredHeaderSchemaInspection {
        try inspect(.foundation(value))
    }

    static func inspect(_ value: JSONValue) throws -> MCPMirroredHeaderSchemaInspection {
        try inspect(.json(value))
    }

    private static func inspect(_ root: Node) throws -> MCPMirroredHeaderSchemaInspection {
        var budget = Budget()
        var annotations = [MCPMirroredHeaderAnnotation]()
        var headerNames = Set<String>()
        var annotationsAreValid = true
        try visit(
            root,
            depth: 0,
            reachability: .schema(path: [], annotationEligible: false),
            budget: &budget,
            annotations: &annotations,
            headerNames: &headerNames,
            annotationsAreValid: &annotationsAreValid
        )
        return MCPMirroredHeaderSchemaInspection(
            annotations: annotations,
            annotationsAreValid: annotationsAreValid
        )
    }

    private static func visit(
        _ node: Node,
        depth: Int,
        reachability: Reachability,
        budget: inout Budget,
        annotations: inout [MCPMirroredHeaderAnnotation],
        headerNames: inout Set<String>,
        annotationsAreValid: inout Bool
    ) throws {
        if let object = node.object {
            try budget.visit(depth: depth)

            if let rawHeaderName = object["x-mcp-header"] {
                guard case .schema(let path, annotationEligible: true) = reachability,
                      let headerName = rawHeaderName.string,
                      isHTTPFieldName(headerName),
                      headerNames.insert(headerName.lowercased()).inserted,
                      let valueType = mirroredHeaderValueType(for: object) else {
                    annotationsAreValid = false
                    try visitChildren(
                        object,
                        depth: depth,
                        reachability: reachability,
                        budget: &budget,
                        annotations: &annotations,
                        headerNames: &headerNames,
                        annotationsAreValid: &annotationsAreValid
                    )
                    return
                }
                annotations.append(MCPMirroredHeaderAnnotation(
                    parameterPath: path,
                    headerName: headerName,
                    valueType: valueType
                ))
            }

            try visitChildren(
                object,
                depth: depth,
                reachability: reachability,
                budget: &budget,
                annotations: &annotations,
                headerNames: &headerNames,
                annotationsAreValid: &annotationsAreValid
            )
            return
        }

        if let array = node.array {
            try budget.visit(depth: depth)
            for child in array {
                try visit(
                    child,
                    depth: depth + 1,
                    reachability: .unreachable,
                    budget: &budget,
                    annotations: &annotations,
                    headerNames: &headerNames,
                    annotationsAreValid: &annotationsAreValid
                )
            }
        }
    }

    private static func visitChildren(
        _ object: [String: Node],
        depth: Int,
        reachability: Reachability,
        budget: inout Budget,
        annotations: inout [MCPMirroredHeaderAnnotation],
        headerNames: inout Set<String>,
        annotationsAreValid: inout Bool
    ) throws {
        for key in object.keys.sorted() {
            guard let child = object[key] else { continue }
            let childReachability: Reachability
            switch reachability {
            case .schema(let path, _):
                childReachability = key == "properties"
                    ? .properties(parentPath: path)
                    : .unreachable
            case .properties(let parentPath):
                childReachability = .schema(
                    path: parentPath + [key],
                    annotationEligible: child.object != nil
                )
            case .unreachable:
                childReachability = .unreachable
            }
            try visit(
                child,
                depth: depth + 1,
                reachability: childReachability,
                budget: &budget,
                annotations: &annotations,
                headerNames: &headerNames,
                annotationsAreValid: &annotationsAreValid
            )
        }
    }

    private static func mirroredHeaderValueType(
        for object: [String: Node]
    ) -> MCPMirroredHeaderValueType? {
        switch object["type"]?.string {
        case "string":
            return .string
        case "integer":
            return .integer
        case "boolean":
            return .boolean
        default:
            return nil
        }
    }

    private static func isHTTPFieldName(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        let permitted = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return value.allSatisfy { permitted.contains($0) }
    }
}

/// What a `server/discover` response tells MacRemote to do next.
///
/// This replaces the older "result, or `nil` meaning fall back" convention
/// because a fallback now carries information: an upstream that answered with
/// its own supported-version list has told us which legacy revision to ask for,
/// and that version has to reach the call site that runs `initialize`.
enum MCPUpstreamDiscoverVerdict {
    /// The upstream speaks 2026-07-28; this is its validated discover result.
    case modern(result: [String: Any])
    /// Use the legacy initialize flow. `requestedVersion` is non-nil only when
    /// the upstream named a legacy revision MacRemote implements, in which case
    /// it replaces the configured/default version for this connection.
    case legacy(requestedVersion: String?)

    var modernResult: [String: Any]? {
        guard case .modern(let result) = self else { return nil }
        return result
    }

    var isModern: Bool {
        modernResult != nil
    }

    /// The legacy revision the upstream invited us down to, if it named one.
    var renegotiatedLegacyVersion: String? {
        guard case .legacy(let version) = self else { return nil }
        return version
    }
}

/// Shared wire construction for MacRemote acting as an MCP client.
///
/// Persisted bridge `protocolVersion` values describe the legacy initialize
/// fallback. Modern support is probed independently on every upstream
/// connection so existing tools and their security fingerprints do not change.
enum MCPUpstreamProtocol {
    static let modernVersion = "2026-07-28"

    /// Legacy MCP revisions the bridge's initialize flow can actually speak,
    /// newest first. The legacy wire shape MacRemote emits — `initialize`,
    /// `notifications/initialized`, then bare `tools/list` / `tools/call` with
    /// no `_meta` envelope and no mirrored headers — is identical across all
    /// three, so any of them is a real connection rather than an aspiration.
    /// It is the same set MacRemote's own server accepts, which keeps the two
    /// halves of the app honest about one list.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    static var clientInfo: [String: Any] {
        MacRemoteProductInfo.mcpClientInfo
    }

    static var clientCapabilities: [String: Any] {
        [:]
    }

    private static let unsupportedProtocolVersionCode = -32022
    private static let recognizedModernErrorCodes: Set<Int> = [
        -32020, // HeaderMismatch
        -32021, // MissingRequiredClientCapability
        unsupportedProtocolVersionCode
    ]

    static func modernRequest(
        id: String,
        method: String,
        params: [String: Any] = [:]
    ) -> [String: Any] {
        var requestParams = params
        var metadata = requestParams["_meta"] as? [String: Any] ?? [:]
        metadata["io.modelcontextprotocol/protocolVersion"] = modernVersion
        metadata["io.modelcontextprotocol/clientInfo"] = clientInfo
        metadata["io.modelcontextprotocol/clientCapabilities"] = clientCapabilities
        requestParams["_meta"] = metadata
        return [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": requestParams
        ]
    }

    static func modernHTTPHeaders(
        method: String,
        params: [String: Any]
    ) -> [String: String] {
        var headers = [
            "MCP-Protocol-Version": modernVersion,
            "Mcp-Method": method
        ]
        if let name = mirroredName(method: method, params: params) {
            headers["Mcp-Name"] = encodedHTTPMirrorValue(name)
        }
        return headers
    }

    static func modernToolCallHTTPHeaders(
        params: [String: Any],
        inputSchema: Any?
    ) throws -> [String: String] {
        var headers = modernHTTPHeaders(method: "tools/call", params: params)
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        for parameter in try mirroredParameters(in: inputSchema) {
            guard let value = value(at: parameter.parameterPath, in: arguments) else {
                continue
            }
            let stringValue = try mirroredParameterValue(
                value,
                type: parameter.valueType,
                path: parameter.parameterPath
            )
            headers["Mcp-Param-\(parameter.headerName)"] = encodedHTTPMirrorValue(stringValue)
        }
        return headers
    }

    static func isValidModernHTTPToolInputSchema(_ inputSchema: Any?) -> Bool {
        do {
            _ = try mirroredParameters(in: inputSchema)
            return true
        } catch {
            return false
        }
    }

    static func isValidModernHTTPToolInputSchema(_ inputSchema: JSONValue?) -> Bool {
        guard let inputSchema else {
            return true
        }
        guard case .object(let schema) = inputSchema,
              schema["type"] == .string("object") else {
            return false
        }
        do {
            return try MCPMirroredHeaderSchemaInspection.inspect(inputSchema).annotationsAreValid
        } catch {
            return false
        }
    }

    /// Decides, from one `server/discover` response, whether to run the modern
    /// flow, fall back to legacy initialize, or refuse to connect.
    ///
    /// The rule this file turns on: a reserved error code alone never
    /// downgrades, but a code that names what the server actually speaks is the
    /// server's own renegotiation invitation and is taken.
    ///
    /// - -32020 (header mismatch) and -32021 (missing client capability) prove
    ///   the upstream implements 2026-07-28 and is complaining about *our*
    ///   request. Downgrading there would paper over a client bug with a
    ///   silently weaker connection, so they still fail hard.
    /// - -32022 is different in kind. When it carries `data.supported` naming a
    ///   legacy revision the bridge implements, the upstream has answered the
    ///   question "then what do you speak?" — the same courtesy MacRemote's own
    ///   server extends to clients that name a version it does not implement
    ///   (decision D50). Taking it up is negotiation, not a downgrade.
    /// - A bare -32022, or one whose list shares nothing with `legacyVersions`,
    ///   still throws. There is no blind downgrade: an intersection has to
    ///   exist before anything falls back.
    ///
    /// A discover *result* that advertises only non-modern versions is the same
    /// situation stated as data rather than as an error, and is judged by the
    /// same rule.
    static func classifyDiscoverResponse(
        _ response: [String: Any]
    ) throws -> MCPUpstreamDiscoverVerdict {
        if let error = response["error"] as? [String: Any] {
            let code = error["code"] as? Int
            if let code, recognizedModernErrorCodes.contains(code) {
                if code == unsupportedProtocolVersionCode,
                   let version = negotiableLegacyVersion(from: advertisedVersions(in: error)) {
                    return .legacy(requestedVersion: version)
                }
                throw MCPUpstreamProtocolError.recognizedModernError(
                    code: code,
                    detail: serializedJSON(error)
                )
            }
            return .legacy(requestedVersion: nil)
        }

        guard let result = response["result"] as? [String: Any] else {
            return .legacy(requestedVersion: nil)
        }
        try validateCompleteResultType(result)
        guard let supportedVersions = result["supportedVersions"] as? [String] else {
            throw MCPUpstreamProtocolError.invalidDiscoverResult(
                "server/discover returned no supportedVersions array"
            )
        }
        guard supportedVersions.contains(modernVersion) else {
            if let version = negotiableLegacyVersion(from: supportedVersions) {
                return .legacy(requestedVersion: version)
            }
            throw MCPUpstreamProtocolError.unsupportedModernVersions(supportedVersions)
        }
        return .modern(result: result)
    }

    /// The newest revision named by both the upstream's list and
    /// `legacyVersions`. Preference order is ours, not the server's: we walk
    /// our own newest-first list so a server listing its versions in any order
    /// still gets the best connection we can hold up.
    static func negotiableLegacyVersion(from advertised: [String]?) -> String? {
        guard let advertised, !advertised.isEmpty else {
            return nil
        }
        let offered = Set(advertised)
        return legacyVersions.first(where: offered.contains)
    }

    /// The `data.supported` list an MCP server attaches to -32022. Read
    /// element-by-element so one non-string entry does not discard an otherwise
    /// usable list.
    private static func advertisedVersions(in error: [String: Any]) -> [String]? {
        guard let data = error["data"] as? [String: Any],
              let supported = data["supported"] as? [Any] else {
            return nil
        }
        let versions = supported.compactMap { $0 as? String }
        return versions.isEmpty ? nil : versions
    }

    static func completeResult(from response: [String: Any]) throws -> [String: Any] {
        guard let result = response["result"] as? [String: Any] else {
            throw MCPUpstreamProtocolError.invalidCompleteResult("response contained no result object")
        }
        try validateCompleteResultType(result)
        return result
    }

    static func serverInfo(fromDiscoverResult result: [String: Any]) -> [String: Any] {
        let meta = result["_meta"] as? [String: Any]
        return meta?["io.modelcontextprotocol/serverInfo"] as? [String: Any] ?? [:]
    }

    static func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.checkedData(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func mirroredName(method: String, params: [String: Any]) -> String? {
        switch method {
        case "tools/call", "prompts/get":
            return params["name"] as? String
        case "resources/read":
            return params["uri"] as? String
        default:
            return nil
        }
    }

    private static func mirroredParameters(
        in inputSchema: Any?
    ) throws -> [MCPMirroredHeaderAnnotation] {
        guard let inputSchema else {
            return []
        }
        guard let schema = inputSchema as? [String: Any],
              schema["type"] as? String == "object" else {
            throw MCPUpstreamProtocolError.invalidHTTPMirroredHeaderSchema(
                "inputSchema must have type object"
            )
        }
        let inspection: MCPMirroredHeaderSchemaInspection
        do {
            inspection = try MCPMirroredHeaderSchemaInspection.inspect(inputSchema)
        } catch let failure as MCPMirroredHeaderSchemaInspection.Failure {
            throw MCPUpstreamProtocolError.invalidHTTPMirroredHeaderSchema(failure.detail)
        }
        guard inspection.annotationsAreValid else {
            throw MCPUpstreamProtocolError.invalidHTTPMirroredHeaderSchema(
                "x-mcp-header annotations must be unique, primitive, and reachable only through properties"
            )
        }
        return inspection.annotations
    }

    private static func value(at path: [String], in object: [String: Any]) -> Any? {
        var current: Any = object
        for component in path {
            guard let dictionary = current as? [String: Any],
                  let next = dictionary[component] else {
                return nil
            }
            current = next
        }
        return current
    }

    private static func mirroredParameterValue(
        _ value: Any,
        type: MCPMirroredHeaderValueType,
        path: [String]
    ) throws -> String {
        switch type {
        case .string:
            guard let value = value as? String else {
                throw invalidMirroredParameterValue(path)
            }
            return value
        case .boolean:
            guard let value = value as? Bool else {
                throw invalidMirroredParameterValue(path)
            }
            return value ? "true" : "false"
        case .integer:
            guard !(value is Bool) else {
                throw invalidMirroredParameterValue(path)
            }
            let number: Double
            switch value {
            case let value as Int:
                number = Double(value)
            case let value as Int64:
                number = Double(value)
            case let value as Double:
                number = value
            case let value as NSNumber:
                number = value.doubleValue
            default:
                throw invalidMirroredParameterValue(path)
            }
            let maximumSafeInteger = 9_007_199_254_740_991.0
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  abs(number) <= maximumSafeInteger,
                  let integer = Int64(exactly: number) else {
                throw invalidMirroredParameterValue(path)
            }
            return String(integer)
        }
    }

    private static func invalidMirroredParameterValue(
        _ path: [String]
    ) -> MCPUpstreamProtocolError {
        .invalidHTTPMirroredHeaderArgument(
            "argument \(path.joined(separator: ".")) does not match its x-mcp-header primitive type"
        )
    }

    private static func encodedHTTPMirrorValue(_ value: String) -> String {
        let isPlainASCII = value == value.trimmingCharacters(in: .whitespaces)
            && value.utf8.allSatisfy { byte in
                byte == 0x09 || (0x20...0x7e).contains(byte)
            }
        let matchesSentinel = value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        guard isPlainASCII, !matchesSentinel else {
            return "=?base64?\(Data(value.utf8).base64EncodedString())?="
        }
        return value
    }

    private static func validateCompleteResultType(_ result: [String: Any]) throws {
        guard let resultType = result["resultType"] as? String else {
            throw MCPUpstreamProtocolError.invalidCompleteResult("missing resultType")
        }
        guard resultType == "complete" else {
            if resultType == "task" {
                throw MCPUpstreamProtocolError.taskResultUnsupported
            }
            throw MCPUpstreamProtocolError.invalidCompleteResult(
                "unknown resultType \(resultType)"
            )
        }
    }
}

enum MCPUpstreamProtocolError: LocalizedError {
    case recognizedModernError(code: Int, detail: String)
    case invalidDiscoverResult(String)
    case unsupportedModernVersions([String])
    case invalidCompleteResult(String)
    case invalidHTTPMirroredHeaderSchema(String)
    case invalidHTTPMirroredHeaderArgument(String)
    case taskResultUnsupported

    var errorDescription: String? {
        switch self {
        case .recognizedModernError(let code, let detail):
            if code == -32022 {
                // Only reachable once renegotiation has already been tried and
                // found nothing usable, so the message says exactly that.
                "Upstream MCP server rejected protocol \(MCPUpstreamProtocol.modernVersion) and named no version MacRemote can fall back to, so it cannot safely downgrade to legacy: \(detail)"
            } else {
                "Upstream MCP server returned current-protocol error \(code): \(detail)"
            }
        case .invalidDiscoverResult(let detail):
            "Invalid upstream MCP server/discover result: \(detail)."
        case .unsupportedModernVersions(let versions):
            "Upstream MCP server does not support \(MCPUpstreamProtocol.modernVersion); advertised: \(versions.joined(separator: ", "))."
        case .invalidCompleteResult(let detail):
            "Invalid upstream MCP complete result: \(detail)."
        case .invalidHTTPMirroredHeaderSchema(let detail):
            "Invalid upstream MCP x-mcp-header schema: \(detail)."
        case .invalidHTTPMirroredHeaderArgument(let detail):
            "Invalid upstream MCP mirrored-header argument: \(detail)."
        case .taskResultUnsupported:
            "Upstream MCP server returned a task result, but MacRemote bridge tools require a complete result."
        }
    }
}

/// Thrown when an upstream server's response is larger than MacRemote keeps.
struct MCPHTTPResponseTooLarge: LocalizedError {
    let maximumBytes: Int

    var errorDescription: String? {
        "The server sent more than \(ByteCountFormatter.string(fromByteCount: Int64(maximumBytes), countStyle: .binary)) in one response."
    }
}

/// Reads one JSON-RPC message out of an HTTP MCP response body.
enum MCPHTTPResponseBody {
    /// The most bytes MacRemote keeps from one upstream response: the same
    /// bound the stdio bridge puts on one message.
    static let maximumBytes = MCPStdioMessageInbox.maximumBufferedBytes

    /// Sends `request` and returns the whole response body, refusing one over
    /// `maximumBytes`. `URLSession.data(for:)` would hold in memory whatever
    /// the server chose to send. The request is cancelled on every way out,
    /// so an oversized or abandoned response stops arriving.
    static func data(
        for request: URLRequest,
        session: URLSession,
        maximumBytes: Int = maximumBytes
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            throw MCPHTTPResponseTooLarge(maximumBytes: maximumBytes)
        }
        var body = [UInt8]()
        body.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard body.count < maximumBytes else {
                throw MCPHTTPResponseTooLarge(maximumBytes: maximumBytes)
            }
            body.append(byte)
        }
        return (Data(body), response)
    }

    /// The body is either plain JSON or a Server-Sent Events stream whose last
    /// JSON `data:` payload is the message. Line endings are normalized first:
    /// SSE allows CRLF, and Swift treats "\r\n" as one character, so splitting
    /// on "\n" alone finds nothing in such a stream.
    static func jsonRPCMessage(from data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        let text = String(decoding: data, as: UTF8.self)
            .replacing("\r\n", with: "\n")
            .replacing("\r", with: "\n")
        for event in text.components(separatedBy: "\n\n").reversed() {
            let dataLines = event
                .split(separator: "\n", omittingEmptySubsequences: false)
                .compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
            guard !dataLines.isEmpty else { continue }
            let body = dataLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.hasPrefix("{"),
                  let eventData = body.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: eventData) as? [String: Any] else {
                continue
            }
            return object
        }
        return nil
    }
}
