import Foundation

/// Protocol configuration for test-only MCP clients.
///
/// `baseURL` passed to ``MCPTestClient`` is the complete MCP HTTP endpoint,
/// including its `/mcp/<instance>` path.
struct MCPTestProtocolMode: @unchecked Sendable {
    enum Kind: Sendable {
        case modern
        case legacy
    }

    let kind: Kind
    let protocolVersion: String
    let clientInfo: [String: Any]
    let clientCapabilities: [String: Any]

    static func modern(
        protocolVersion: String = "2026-07-28",
        clientInfo: [String: Any] = [
            "name": "MacRemote Tests",
            "version": "1.0"
        ],
        clientCapabilities: [String: Any] = [:]
    ) -> Self {
        Self(
            kind: .modern,
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities
        )
    }

    static func legacy(
        protocolVersion: String = "2025-11-25",
        clientInfo: [String: Any] = [
            "name": "MacRemote Tests",
            "version": "1.0"
        ],
        clientCapabilities: [String: Any] = [:]
    ) -> Self {
        Self(
            kind: .legacy,
            protocolVersion: protocolVersion,
            clientInfo: clientInfo,
            clientCapabilities: clientCapabilities
        )
    }
}

struct MCPTestPreparedRequest: @unchecked Sendable {
    let body: [String: Any]
    let headers: [String: String]
}

struct MCPTestHTTPResponse: @unchecked Sendable {
    let statusCode: Int
    let json: [String: Any]
    let headers: [String: String]
    let data: Data

    var result: [String: Any]? {
        json["result"] as? [String: Any]
    }

    var error: [String: Any]? {
        json["error"] as? [String: Any]
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

enum MCPTestClientError: Error {
    case nonHTTPResponse
    case nonObjectJSON
}

enum MCPTestRequestBuilder {
    static let protocolVersionMetaKey = "io.modelcontextprotocol/protocolVersion"
    static let clientInfoMetaKey = "io.modelcontextprotocol/clientInfo"
    static let clientCapabilitiesMetaKey = "io.modelcontextprotocol/clientCapabilities"

    static func prepare(
        method: String,
        params: [String: Any]? = nil,
        id: Any? = UUID().uuidString,
        mode: MCPTestProtocolMode,
        sessionHeaders: [String: String] = [:],
        notification: Bool = false
    ) -> MCPTestPreparedRequest {
        var body: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method
        ]
        if !notification {
            body["id"] = id ?? NSNull()
        }

        var requestParams = params ?? [:]
        if mode.kind == .modern {
            var metadata = requestParams["_meta"] as? [String: Any] ?? [:]
            metadata[protocolVersionMetaKey] = mode.protocolVersion
            metadata[clientInfoMetaKey] = mode.clientInfo
            metadata[clientCapabilitiesMetaKey] = mode.clientCapabilities
            requestParams["_meta"] = metadata
        }
        if params != nil || !requestParams.isEmpty || mode.kind == .modern {
            body["params"] = requestParams
        }

        var headers = sessionHeaders
        headers["MCP-Protocol-Version"] = mode.protocolVersion
        if mode.kind == .modern {
            headers["Mcp-Method"] = method
            if let name = mirroredName(method: method, params: requestParams) {
                headers["Mcp-Name"] = encodeHeaderValue(name)
            }
        }
        return MCPTestPreparedRequest(body: body, headers: headers)
    }

    static func encodeHeaderValue(_ value: String) -> String {
        let utf8 = Array(value.utf8)
        let isVisibleASCII = utf8.allSatisfy { byte in
            byte == 0x09 || (0x20...0x7e).contains(byte)
        }
        let hasEdgeWhitespace =
            value.first == " " || value.first == "\t" ||
            value.last == " " || value.last == "\t"
        let matchesSentinel =
            value.hasPrefix("=?base64?") && value.hasSuffix("?=")
        if isVisibleASCII && !hasEdgeWhitespace && !matchesSentinel {
            return value
        }
        return "=?base64?\(Data(value.utf8).base64EncodedString())?="
    }

    private static func mirroredName(
        method: String,
        params: [String: Any]
    ) -> String? {
        switch method {
        case "tools/call", "prompts/get":
            return params["name"] as? String
        case "resources/read":
            return params["uri"] as? String
        default:
            return nil
        }
    }
}

final class MCPTestClient: @unchecked Sendable {
    let baseURL: URL
    let bearerToken: String

    private let mode: MCPTestProtocolMode
    private let session: URLSession
    private let stateLock = NSLock()
    private var sessionHeaders: [String: String] = [:]
    private var negotiatedLegacyVersion: String?

    init(
        baseURL: URL,
        bearerToken: String,
        mode: MCPTestProtocolMode = .modern(),
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.bearerToken = bearerToken
        self.mode = mode
        self.session = session
    }

    func send(
        method: String,
        params: [String: Any]? = nil,
        id: String = UUID().uuidString
    ) async throws -> MCPTestHTTPResponse {
        let requestMode = currentMode()
        let prepared = MCPTestRequestBuilder.prepare(
            method: method,
            params: params,
            id: id,
            mode: requestMode,
            sessionHeaders: currentSessionHeaders()
        )
        return try await perform(prepared)
    }

    func sendNotification(
        method: String,
        params: [String: Any]? = nil
    ) async throws -> MCPTestHTTPResponse {
        let prepared = MCPTestRequestBuilder.prepare(
            method: method,
            params: params,
            id: nil,
            mode: currentMode(),
            sessionHeaders: currentSessionHeaders(),
            notification: true
        )
        return try await perform(prepared)
    }

    @discardableResult
    func initializeLegacy() async throws -> MCPTestHTTPResponse {
        let response = try await send(
            method: "initialize",
            params: [
                "protocolVersion": currentMode().protocolVersion,
                "capabilities": mode.clientCapabilities,
                "clientInfo": mode.clientInfo
            ],
            id: "initialize"
        )
        stateLock.withLock {
            if let sessionID = response.header("Mcp-Session-Id") {
                sessionHeaders["Mcp-Session-Id"] = sessionID
            }
            if let version = response.result?["protocolVersion"] as? String {
                negotiatedLegacyVersion = version
            }
        }
        _ = try await sendNotification(method: "notifications/initialized")
        return response
    }

    func discover() async throws -> MCPTestHTTPResponse {
        try await send(method: "server/discover", params: [:])
    }

    func listTools(cursor: String? = nil) async throws -> MCPTestHTTPResponse {
        var params: [String: Any] = [:]
        if let cursor {
            params["cursor"] = cursor
        }
        return try await send(method: "tools/list", params: params)
    }

    func callTool(
        _ name: String,
        arguments: [String: Any] = [:]
    ) async throws -> MCPTestHTTPResponse {
        try await send(
            method: "tools/call",
            params: [
                "name": name,
                "arguments": arguments
            ]
        )
    }

    private func perform(
        _ prepared: MCPTestPreparedRequest
    ) async throws -> MCPTestHTTPResponse {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in prepared.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: prepared.body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPTestClientError.nonHTTPResponse
        }
        let json: [String: Any]
        if data.isEmpty {
            json = [:]
        } else {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MCPTestClientError.nonObjectJSON
            }
            json = object
        }
        return MCPTestHTTPResponse(
            statusCode: http.statusCode,
            json: json,
            headers: http.allHeaderFields.reduce(into: [:]) { result, item in
                result[String(describing: item.key)] = String(describing: item.value)
            },
            data: data
        )
    }

    private func currentMode() -> MCPTestProtocolMode {
        stateLock.withLock {
            guard mode.kind == .legacy, let negotiatedLegacyVersion else {
                return mode
            }
            return .legacy(
                protocolVersion: negotiatedLegacyVersion,
                clientInfo: mode.clientInfo,
                clientCapabilities: mode.clientCapabilities
            )
        }
    }

    private func currentSessionHeaders() -> [String: String] {
        stateLock.withLock { sessionHeaders }
    }
}
