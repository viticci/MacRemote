import Darwin
import Foundation
import Network

enum LocalMCPServerEvent: Sendable {
    case log(AppLogEntry.Level, String)
    case approvalsChanged([ApprovalRequest])
}

final class LocalMCPServer: @unchecked Sendable {
    typealias EventHandler = @Sendable (LocalMCPServerEvent) -> Void

    private static let latestProtocolVersion = "2025-11-25"
    private static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let protocolVersionHeader = "MCP-Protocol-Version"

    private let queue = DispatchQueue(label: "com.macremote.local-server")
    private var listener: NWListener?
    private var activePort: UInt16?
    private let instanceID: String
    private let tools: [ToolDefinition]
    private let authCoordinator: OAuthCoordinator
    private let toolExecutor: any ToolExecuting
    private let eventHandler: EventHandler?

    init(
        instanceID: String,
        tools: [ToolDefinition],
        authCoordinator: OAuthCoordinator,
        toolExecutor: any ToolExecuting,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.tools = tools
        self.authCoordinator = authCoordinator
        self.toolExecutor = toolExecutor
        self.eventHandler = eventHandler
    }

    func start() throws -> UInt16 {
        let selectedPort = try Self.availablePort()
        guard let nwPort = NWEndpoint.Port(rawValue: selectedPort) else {
            throw LocalMCPServerError.portUnavailable
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.service = nil
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        self.listener = listener
        self.activePort = selectedPort
        return selectedPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
    }

    func approveAuthorizationRequest(id: UUID) -> Bool {
        authCoordinator.approve(requestID: id)
    }

    func denyAuthorizationRequest(id: UUID) -> Bool {
        authCoordinator.deny(requestID: id)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard nextBuffer.count <= 128 * 1024 else {
                connection.send(
                    content: HTTPResponse(status: .badRequest, body: "{\"error\":\"request_too_large\"}").data,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }

            guard HTTPRequest.isComplete(data: nextBuffer) else {
                self.receiveRequest(on: connection, buffer: nextBuffer)
                return
            }

            let request = HTTPRequest(data: nextBuffer)
            Task {
                let response = await self.response(for: request)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
    }

    private func response(for request: HTTPRequest) async -> Data {
        guard let activePort else {
            return HTTPResponse(status: .internalServerError, body: "Server not ready").data
        }

        let base = baseURL(for: request, activePort: activePort)
        let mcpResourceURL = "\(base)\(mcpEndpointPath)"
        guard isAllowedOrigin(for: request, base: base, activePort: activePort) else {
            return jsonErrorResponse(
                status: .forbidden,
                error: "forbidden_origin",
                description: "Invalid Origin header."
            )
        }

        if isMCPPath(request.path) {
            switch request.method {
            case "POST":
                return await mcp(request: request, base: base)
            case "GET", "DELETE":
                return methodNotAllowedForMCP()
            default:
                return methodNotAllowedForMCP()
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return jsonResponse([
                "ok": true,
                "service": "MacRemote",
                "instance_id": instanceID,
                "tool_profile": "remctl-readonly",
                "tool_count": tools.count,
                "auth": "host-approved-oauth-pkce"
            ])
        case ("GET", "/.well-known/oauth-protected-resource"):
            return jsonResponse([
                "resource": mcpResourceURL,
                "authorization_servers": [base],
                "scopes_supported": ["mcp:tools"],
                "bearer_methods_supported": ["header"],
                "resource_type": "mcp-server",
                "mcp_protocol_version": Self.latestProtocolVersion,
                "mcp_protocol_versions_supported": Self.supportedProtocolVersions
            ])
        case ("GET", "/.well-known/oauth-authorization-server"):
            return jsonResponse([
                "issuer": base,
                "authorization_endpoint": "\(base)/authorize",
                "token_endpoint": "\(base)/token",
                "registration_endpoint": "\(base)/register",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": ["mcp:tools"]
            ])
        case ("POST", "/register"):
            return registerClient(request)
        case ("GET", "/authorize"):
            return beginAuthorization(request: request, issuer: base)
        case ("GET", "/authorize/status"):
            return authorizationStatus(request)
        case ("POST", "/token"):
            return token(request)
        default:
            return jsonErrorResponse(status: .notFound, error: "not_found", description: "Route not found.")
        }
    }

    private var mcpEndpointPath: String {
        "/mcp/\(instanceID)"
    }

    private func isMCPPath(_ path: String) -> Bool {
        path == "/mcp" || path == mcpEndpointPath
    }

    private func methodNotAllowedForMCP() -> Data {
        jsonResponse(
            [
                "error": "method_not_allowed",
                "error_description": "This MacRemote build supports JSON responses over POST /mcp only."
            ],
            status: .methodNotAllowed,
            headers: ["Allow": "POST"]
        )
    }

    private func baseURL(for request: HTTPRequest, activePort: UInt16) -> String {
        let localBase = "http://127.0.0.1:\(activePort)"

        guard let publicHost = request.forwardedHost ?? request.hostHeader,
              let normalizedHost = Self.normalizedHost(publicHost),
              !Self.isLoopbackHost(normalizedHost) else {
            return localBase
        }

        let scheme = request.forwardedScheme ?? "https"
        guard scheme == "https" else {
            return localBase
        }

        return "\(scheme)://\(normalizedHost)"
    }

    private func isAllowedOrigin(for request: HTTPRequest, base: String, activePort: UInt16) -> Bool {
        guard let origin = request.originHeader else {
            return true
        }

        guard let normalizedOrigin = Self.normalizedOrigin(origin) else {
            return false
        }

        let allowedOrigins: Set<String> = [
            base,
            "http://127.0.0.1:\(activePort)",
            "http://localhost:\(activePort)"
        ]
        return allowedOrigins.contains(normalizedOrigin)
    }

    private static func normalizedHost(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              trimmed.count <= 253,
              trimmed.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines) == nil,
              !trimmed.contains("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("@") else {
            return nil
        }

        guard let components = URLComponents(string: "https://\(trimmed)"),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        if let port = components.port {
            return "\(host):\(port)"
        }
        return host
    }

    private static func isLoopbackHost(_ normalizedHost: String) -> Bool {
        if normalizedHost == "::1" || normalizedHost.hasPrefix("::1:") {
            return true
        }

        let host = normalizedHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? normalizedHost

        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private static func normalizedOrigin(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              scheme == "http" || scheme == "https",
              let host = components.host,
              components.user == nil,
              components.password == nil,
              components.path.isEmpty,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        let formattedHost = host.contains(":") ? "[\(host)]" : host
        if let port = components.port {
            return "\(scheme)://\(formattedHost):\(port)"
        }
        return "\(scheme)://\(formattedHost)"
    }

    private func registerClient(_ request: HTTPRequest) -> Data {
        do {
            let object = try request.jsonObject()
            let response = try authCoordinator.registerClient(from: object)
            eventHandler?(.log(.info, "Registered OAuth client."))
            return jsonResponse(response, status: .created)
        } catch {
            return oauthErrorResponse(error)
        }
    }

    private func beginAuthorization(request: HTTPRequest, issuer: String) -> Data {
        do {
            let requestID = try authCoordinator.beginAuthorization(
                queryItems: request.queryItems,
                issuer: issuer
            )
            eventHandler?(.approvalsChanged(authCoordinator.approvalSnapshot()))
            eventHandler?(.log(.info, "Authorization request created for host approval."))
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: authorizationPageHTML(requestID: requestID)
            ).data
        } catch {
            return oauthErrorResponse(error)
        }
    }

    private func authorizationStatus(_ request: HTTPRequest) -> Data {
        guard let rawID = request.queryItems["request_id"], let requestID = UUID(uuidString: rawID) else {
            return jsonErrorResponse(status: .badRequest, error: "invalid_request", description: "Missing request_id.")
        }

        let status = authCoordinator.authorizationStatus(requestID: requestID)
        eventHandler?(.approvalsChanged(authCoordinator.approvalSnapshot()))
        return jsonResponse(status)
    }

    private func token(_ request: HTTPRequest) -> Data {
        do {
            let response = try authCoordinator.exchangeToken(form: request.formURLEncodedBody())
            eventHandler?(.log(.info, "OAuth token issued after host approval."))
            return jsonResponse(response)
        } catch {
            return oauthErrorResponse(error)
        }
    }

    private func mcp(request: HTTPRequest, base: String) async -> Data {
        guard isSupportedProtocolVersionHeader(request) else {
            return jsonRPCError(
                id: nil,
                code: -32000,
                message: "Unsupported MCP-Protocol-Version.",
                status: .badRequest
            )
        }

        guard let bearerToken = request.bearerToken,
              authCoordinator.validateAccessToken(bearerToken) else {
            return HTTPResponse(
                status: .unauthorized,
                headers: [
                    "WWW-Authenticate": "Bearer realm=\"mcp\", resource_metadata=\"\(base)/.well-known/oauth-protected-resource\""
                ],
                body: "{\"ok\":false,\"error\":\"authorization_required\"}"
            ).data
        }

        do {
            let object = try request.jsonObject()
            guard let message = object as? [String: Any],
                  message["jsonrpc"] as? String == "2.0",
                  let method = message["method"] as? String else {
                return jsonRPCError(id: nil, code: -32600, message: "Invalid JSON-RPC request.")
            }

            let id = message["id"]
            switch method {
            case "initialize":
                let requestedVersion = (message["params"] as? [String: Any])?["protocolVersion"] as? String
                return jsonRPCResult(id: id, result: [
                    "protocolVersion": negotiatedProtocolVersion(requestedVersion),
                    "capabilities": [
                        "tools": [
                            "listChanged": false
                        ]
                    ],
                    "serverInfo": [
                        "name": "MacRemote",
                        "version": "0.1.0"
                    ]
                ])
            case "ping":
                return jsonRPCResult(id: id, result: [:])
            case "tools/list":
                return jsonRPCResult(id: id, result: [
                    "tools": tools.map(toolJSON)
                ])
            case "tools/call":
                return await callTool(id: id, message: message)
            case "notifications/initialized":
                return HTTPResponse(status: .accepted, headers: mcpResponseHeaders(), body: "").data
            default:
                return jsonRPCError(id: id, code: -32601, message: "Method not found.")
            }
        } catch {
            return jsonRPCError(id: nil, code: -32700, message: "Invalid JSON body.")
        }
    }

    private func isSupportedProtocolVersionHeader(_ request: HTTPRequest) -> Bool {
        guard let version = request.mcpProtocolVersionHeader else {
            return true
        }
        return Self.supportedProtocolVersions.contains(version)
    }

    private func negotiatedProtocolVersion(_ requestedVersion: String?) -> String {
        guard let requestedVersion,
              Self.supportedProtocolVersions.contains(requestedVersion) else {
            return Self.latestProtocolVersion
        }
        return requestedVersion
    }

    private func callTool(id: Any?, message: [String: Any]) async -> Data {
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing tool name.")
        }

        let rawArguments = params["arguments"] as? [String: Any] ?? [:]
        let arguments = rawArguments.compactMapValues { value -> ToolArgumentValue? in
            switch value {
            case let string as String:
                return .string(string)
            case let int as Int:
                return .string(String(int))
            case let double as Double where double.rounded() == double:
                return .string(String(Int(double)))
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
                return values.count == array.count ? .stringArray(values) : nil
            default:
                return nil
            }
        }

        do {
            let outcome = try await toolExecutor.execute(toolID: name, parameters: arguments)
            let structuredContent = structuredContent(for: outcome)
            eventHandler?(.log(
                outcome.succeeded ? .info : .warning,
                "\(outcome.toolName) MCP call exited \(outcome.exitCode) in \(outcome.duration.formattedDuration)."
            ))
            return jsonRPCResult(id: id, result: [
                "structuredContent": structuredContent,
                "content": [
                    [
                        "type": "text",
                        "text": serializedJSON(structuredContent)
                    ]
                ],
                "isError": !outcome.succeeded
            ])
        } catch let error as ToolValidationError {
            return jsonRPCError(id: id, code: -32602, message: error.localizedDescription)
        } catch {
            return jsonRPCError(id: id, code: -32000, message: error.localizedDescription)
        }
    }

    private func structuredContent(for outcome: ToolExecutionOutcome) -> [String: Any] {
        [
            "toolID": outcome.toolID,
            "toolName": outcome.toolName,
            "exitCode": Int(outcome.exitCode),
            "succeeded": outcome.succeeded,
            "stdout": outcome.stdout,
            "stderr": outcome.stderr,
            "durationSeconds": outcome.duration,
            "timedOut": outcome.timedOut,
            "truncatedStdout": outcome.truncatedStdout,
            "truncatedStderr": outcome.truncatedStderr
        ]
    }

    private func serializedJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func toolJSON(_ tool: ToolDefinition) -> [String: Any] {
        [
            "name": tool.id,
            "title": tool.name,
            "description": tool.summary,
            "inputSchema": inputSchema(for: tool),
            "outputSchema": outputSchema(),
            "annotations": [
                "title": tool.name,
                "readOnlyHint": tool.capability == .readOnly,
                "destructiveHint": tool.capability == .destructive,
                "idempotentHint": tool.capability == .readOnly && !tool.isGenericCLIAdapter,
                "openWorldHint": tool.isGenericCLIAdapter
            ]
        ]
    }

    private func outputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "toolID": ["type": "string"],
                "toolName": ["type": "string"],
                "exitCode": ["type": "integer"],
                "succeeded": ["type": "boolean"],
                "stdout": ["type": "string"],
                "stderr": ["type": "string"],
                "durationSeconds": ["type": "number"],
                "timedOut": ["type": "boolean"],
                "truncatedStdout": ["type": "boolean"],
                "truncatedStderr": ["type": "boolean"]
            ],
            "required": [
                "toolID",
                "toolName",
                "exitCode",
                "succeeded",
                "stdout",
                "stderr",
                "durationSeconds",
                "timedOut",
                "truncatedStdout",
                "truncatedStderr"
            ],
            "additionalProperties": false
        ]
    }

    private func inputSchema(for tool: ToolDefinition) -> [String: Any] {
        var properties = [String: Any]()
        var required = [String]()

        for parameter in tool.parameters {
            properties[parameter.name] = parameterSchema(parameter)
            if parameter.required {
                required.append(parameter.name)
            }
        }

        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }

    private func parameterSchema(_ parameter: ToolParameter) -> [String: Any] {
        var schema: [String: Any] = [
            "title": parameter.title
        ]

        switch parameter.kind {
        case .string:
            schema["type"] = "string"
            if let maximumLength = parameter.maximumLength {
                schema["maxLength"] = maximumLength
            }
        case .integer:
            schema["type"] = "integer"
            if let range = parameter.integerRange {
                schema["minimum"] = range.lowerBound
                schema["maximum"] = range.upperBound
            }
        case .stringArray:
            schema["type"] = "array"
            schema["items"] = ["type": "string"]
            schema["maxItems"] = 64
        }

        if let defaultValue = parameter.defaultValue {
            schema["default"] = defaultValue
        }
        return schema
    }

    private func jsonRPCResult(id: Any?, result: [String: Any], status: HTTPResponse.Status = .ok) -> Data {
        jsonResponse([
            "jsonrpc": "2.0",
            "id": jsonID(id),
            "result": result
        ], status: status, headers: mcpResponseHeaders())
    }

    private func jsonRPCError(
        id: Any?,
        code: Int,
        message: String,
        status: HTTPResponse.Status = .ok
    ) -> Data {
        jsonResponse([
            "jsonrpc": "2.0",
            "id": jsonID(id),
            "error": [
                "code": code,
                "message": message
            ]
        ], status: status, headers: mcpResponseHeaders())
    }

    private func mcpResponseHeaders() -> [String: String] {
        [Self.protocolVersionHeader: Self.latestProtocolVersion]
    }

    private func jsonID(_ id: Any?) -> Any {
        switch id {
        case let string as String:
            return string
        case let int as Int:
            return int
        case let double as Double:
            return double
        default:
            return NSNull()
        }
    }

    private func oauthErrorResponse(_ error: Error) -> Data {
        if let oauthError = error as? OAuthError {
            return jsonErrorResponse(
                status: .badRequest,
                error: oauthError.errorCode,
                description: oauthError.localizedDescription
            )
        }

        return jsonErrorResponse(
            status: .badRequest,
            error: "invalid_request",
            description: error.localizedDescription
        )
    }

    private func jsonErrorResponse(status: HTTPResponse.Status, error: String, description: String) -> Data {
        jsonResponse([
            "error": error,
            "error_description": description
        ], status: status)
    }

    private func jsonResponse(
        _ object: [String: Any],
        status: HTTPResponse.Status = .ok,
        headers: [String: String] = [:]
    ) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        var responseHeaders = headers
        responseHeaders["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(
            status: status,
            headers: responseHeaders,
            bodyData: data
        ).data
    }

    private func authorizationPageHTML(requestID: UUID) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>MacRemote Approval</title>
          <style>
            body { font: -apple-system-body; margin: 42px; max-width: 680px; color: #1d1d1f; }
            code { background: #f5f5f7; padding: 2px 5px; border-radius: 5px; }
          </style>
        </head>
        <body>
          <h1>Host approval required</h1>
          <p>Open MacRemote on this Mac and approve this request. This page will redirect after approval.</p>
          <p>Request <code>\(requestID.uuidString.htmlEscaped)</code></p>
          <script>
            async function poll() {
              const response = await fetch('/authorize/status?request_id=\(requestID.uuidString)');
              const status = await response.json();
              if (status.redirect_uri) {
                window.location.href = status.redirect_uri;
                return;
              }
              setTimeout(poll, 1200);
            }
            poll();
          </script>
        </body>
        </html>
        """
    }

    private static func availablePort() throws -> UInt16 {
        let range: ClosedRange<UInt16> = 49_152...65_000
        let randomCandidates = (0..<128).map { _ in UInt16.random(in: range) }
        let deterministicCandidates = stride(from: UInt16(49_152), through: UInt16(49_300), by: 1)
        for port in randomCandidates + deterministicCandidates {
            if canBind(port: port) {
                return port
            }
        }
        throw LocalMCPServerError.portUnavailable
    }

    private static func canBind(port: UInt16) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var value: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

enum LocalMCPServerError: LocalizedError {
    case portUnavailable

    var errorDescription: String? {
        switch self {
        case .portUnavailable: "Could not allocate a local server port."
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let queryItems: [String: String]
    let headers: [String: String]
    let body: Data

    var hostHeader: String? {
        headers["host"]
    }

    var forwardedHost: String? {
        firstForwardedValue(headers["x-forwarded-host"])
    }

    var forwardedScheme: String? {
        if let proto = firstForwardedValue(headers["x-forwarded-proto"])?.lowercased(),
           proto == "https" || proto == "http" {
            return proto
        }

        if let visitor = headers["cf-visitor"]?.lowercased(),
           visitor.contains("\"scheme\":\"https\"") {
            return "https"
        }

        return nil
    }

    var bearerToken: String? {
        guard let authorization = headers["authorization"] else { return nil }
        let prefix = "Bearer "
        guard authorization.hasPrefix(prefix) else { return nil }
        return String(authorization.dropFirst(prefix.count))
    }

    var originHeader: String? {
        guard let origin = headers["origin"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !origin.isEmpty else {
            return nil
        }
        return origin
    }

    var mcpProtocolVersionHeader: String? {
        guard let version = headers["mcp-protocol-version"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !version.isEmpty else {
            return nil
        }
        return version
    }

    init(data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let headerData: Data
        if let range = data.range(of: separator) {
            headerData = data[..<range.lowerBound]
            body = data[range.upperBound...]
        } else {
            headerData = data
            body = Data()
        }

        let headerText = String(decoding: headerData, as: UTF8.self)
        let lines = headerText.components(separatedBy: "\r\n")
        let firstLineParts = (lines.first ?? "").split(separator: " ")
        method = firstLineParts.indices.contains(0) ? String(firstLineParts[0]) : ""

        let rawPath = firstLineParts.indices.contains(1) ? String(firstLineParts[1]) : ""
        let parsed = Self.parsePath(rawPath)
        path = parsed.path
        queryItems = parsed.queryItems

        var parsedHeaders = [String: String]()
        for line in lines.dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            parsedHeaders[name] = value
        }
        headers = parsedHeaders
    }

    func jsonObject() throws -> Any {
        try JSONSerialization.jsonObject(with: body, options: [])
    }

    func formURLEncodedBody() -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        return Self.parseQueryItems(text)
    }

    private static func parsePath(_ rawPath: String) -> (path: String, queryItems: [String: String]) {
        let pieces = rawPath.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = pieces.indices.contains(0) ? String(pieces[0]) : rawPath
        let query = pieces.indices.contains(1) ? String(pieces[1]) : ""
        return (path, parseQueryItems(query))
    }

    private static func parseQueryItems(_ query: String) -> [String: String] {
        var result = [String: String]()
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let name = parts.first?.removingPercentEncoding else { continue }
            let value = parts.indices.contains(1) ? String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? "" : ""
            result[name] = value
        }
        return result
    }

    static func isComplete(data: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return false
        }

        let headerData = data[..<headerRange.lowerBound]
        let headerText = String(decoding: headerData, as: UTF8.self)
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .dropFirst()
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { line -> Int? in
                guard let separatorIndex = line.firstIndex(of: ":") else { return nil }
                return Int(line[line.index(after: separatorIndex)...].trimmingCharacters(in: .whitespacesAndNewlines))
            } ?? 0

        return data.count >= headerRange.upperBound + contentLength
    }

    private func firstForwardedValue(_ value: String?) -> String? {
        value?
            .split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}

private struct HTTPResponse {
    enum Status {
        case ok
        case accepted
        case created
        case badRequest
        case forbidden
        case methodNotAllowed
        case unauthorized
        case notFound
        case internalServerError

        var line: String {
            switch self {
            case .ok: "200 OK"
            case .accepted: "202 Accepted"
            case .created: "201 Created"
            case .badRequest: "400 Bad Request"
            case .forbidden: "403 Forbidden"
            case .methodNotAllowed: "405 Method Not Allowed"
            case .unauthorized: "401 Unauthorized"
            case .notFound: "404 Not Found"
            case .internalServerError: "500 Internal Server Error"
            }
        }
    }

    let status: Status
    let headers: [String: String]
    let bodyData: Data

    init(status: Status, headers: [String: String] = [:], body: String) {
        self.status = status
        self.headers = headers
        self.bodyData = Data(body.utf8)
    }

    init(status: Status, headers: [String: String] = [:], bodyData: Data) {
        self.status = status
        self.headers = headers
        self.bodyData = bodyData
    }

    var data: Data {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(bodyData.count)
        responseHeaders["Connection"] = "close"
        if responseHeaders["Content-Type"] == nil {
            responseHeaders["Content-Type"] = "application/json; charset=utf-8"
        }

        var head = "HTTP/1.1 \(status.line)\r\n"
        for key in responseHeaders.keys.sorted() {
            if let value = responseHeaders[key] {
                head += "\(key): \(value)\r\n"
            }
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(bodyData)
        return data
    }
}

private extension String {
    var htmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
