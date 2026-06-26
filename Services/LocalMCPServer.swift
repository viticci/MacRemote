import Darwin
import Foundation
import Network

enum LocalMCPServerEvent: Sendable {
    case log(AppLogEntry.Level, String)
    case approvalsChanged([ApprovalRequest])
    case clientsChanged([ConnectedClient])
}

final class LocalMCPServer: @unchecked Sendable {
    typealias EventHandler = @Sendable (LocalMCPServerEvent) -> Void
    typealias ToolProvider = @Sendable () -> [ToolDefinition]

    private static let latestProtocolVersion = "2025-11-25"
    private static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let protocolVersionHeader = "MCP-Protocol-Version"

    private let queue = DispatchQueue(label: "com.macremote.local-server")
    private var listener: NWListener?
    private var activePort: UInt16?
    private let instanceID: String
    private let toolProvider: ToolProvider
    private let authCoordinator: OAuthCoordinator
    private let toolCallApprovalCoordinator: ToolCallApprovalCoordinator?
    private let toolExecutor: any ToolExecuting
    private let clientToolPermissionStore: ClientToolPermissionStore?
    private let eventHandler: EventHandler?
    private let publicRateLimiter = PublicRequestRateLimiter()

    init(
        instanceID: String,
        tools: [ToolDefinition],
        authCoordinator: OAuthCoordinator,
        toolCallApprovalCoordinator: ToolCallApprovalCoordinator? = nil,
        toolExecutor: any ToolExecuting,
        clientToolPermissionStore: ClientToolPermissionStore? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.toolProvider = { tools }
        self.authCoordinator = authCoordinator
        self.toolCallApprovalCoordinator = toolCallApprovalCoordinator
        self.toolExecutor = toolExecutor
        self.clientToolPermissionStore = clientToolPermissionStore
        self.eventHandler = eventHandler
    }

    init(
        instanceID: String,
        toolProvider: @escaping ToolProvider,
        authCoordinator: OAuthCoordinator,
        toolCallApprovalCoordinator: ToolCallApprovalCoordinator? = nil,
        toolExecutor: any ToolExecuting,
        clientToolPermissionStore: ClientToolPermissionStore? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.toolProvider = toolProvider
        self.authCoordinator = authCoordinator
        self.toolCallApprovalCoordinator = toolCallApprovalCoordinator
        self.toolExecutor = toolExecutor
        self.clientToolPermissionStore = clientToolPermissionStore
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
        let mcpResourceURL = mcpResourceURL(base: base)
        guard isAllowedOrigin(for: request, base: base, activePort: activePort) else {
            return jsonErrorResponse(
                status: .forbidden,
                error: "forbidden_origin",
                description: "Invalid Origin header."
            )
        }

        let isPublicRequest = base != localBaseURL(activePort: activePort)
        if let group = publicRateLimitGroup(for: request, isPublicRequest: isPublicRequest),
           let response = publicRateLimitResponseIfNeeded(for: group) {
            return response
        }

        if request.method == "GET", isProtectedResourceMetadataPath(request.path) {
            return jsonResponse(protectedResourceMetadata(base: base))
        }

        if isMCPPath(request.path, allowLegacyPath: allowsLegacyMCPPath(base: base, activePort: activePort)) {
            switch request.method {
            case "POST":
                return await mcp(request: request, base: base, isPublicRequest: isPublicRequest)
            case "GET", "DELETE":
                return methodNotAllowedForMCP()
            default:
                return methodNotAllowedForMCP()
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return jsonResponse(healthPayload(base: base, activePort: activePort))
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
                "scopes_supported": ["mcp:tools"],
                "resource_indicators_supported": true
            ])
        case ("POST", "/register"):
            return registerClient(request)
        case ("GET", "/authorize"):
            return beginAuthorization(request: request, issuer: base, resource: mcpResourceURL)
        case ("GET", "/authorize/status"):
            return authorizationStatus(request)
        case ("POST", "/token"):
            return token(request, issuer: base, resource: mcpResourceURL)
        default:
            return jsonErrorResponse(status: .notFound, error: "not_found", description: "Route not found.")
        }
    }

    private var mcpEndpointPath: String {
        "/mcp/\(instanceID)"
    }

    private func mcpResourceURL(base: String) -> String {
        "\(base)\(mcpEndpointPath)"
    }

    private func localBaseURL(activePort: UInt16) -> String {
        "http://127.0.0.1:\(activePort)"
    }

    private func protectedResourceMetadataURL(base: String) -> String {
        "\(base)/.well-known/oauth-protected-resource\(mcpEndpointPath)"
    }

    private func protectedResourceMetadata(base: String) -> [String: Any] {
        [
            "resource": mcpResourceURL(base: base),
            "authorization_servers": [base],
            "scopes_supported": ["mcp:tools"],
            "bearer_methods_supported": ["header"],
            "resource_type": "mcp-server",
            "mcp_protocol_version": Self.latestProtocolVersion,
            "mcp_protocol_versions_supported": Self.supportedProtocolVersions
        ]
    }

    private func isProtectedResourceMetadataPath(_ path: String) -> Bool {
        path == "/.well-known/oauth-protected-resource" ||
            path == "/.well-known/oauth-protected-resource\(mcpEndpointPath)"
    }

    private func isMCPPath(_ path: String, allowLegacyPath: Bool) -> Bool {
        path == mcpEndpointPath || (allowLegacyPath && path == "/mcp")
    }

    private func allowsLegacyMCPPath(base: String, activePort: UInt16) -> Bool {
        base == localBaseURL(activePort: activePort)
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
        let localBase = localBaseURL(activePort: activePort)

        guard let normalizedHost = publicHost(for: request) else {
            return localBase
        }

        return "https://\(normalizedHost)"
    }

    private func publicHost(for request: HTTPRequest) -> String? {
        if let host = request.hostHeader,
           let normalizedHost = Self.normalizedHost(host),
           !Self.isLoopbackHost(normalizedHost) {
            return normalizedHost
        }

        if let forwardedHost = request.forwardedHost,
           let normalizedForwardedHost = Self.normalizedHost(forwardedHost),
           !Self.isLoopbackHost(normalizedForwardedHost) {
            return normalizedForwardedHost
        }

        return nil
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

    private func healthPayload(base: String, activePort: UInt16) -> [String: Any] {
        var payload: [String: Any] = [
            "ok": true,
            "service": "MacRemote",
            "auth": "host-approved-oauth-pkce",
            "public_metadata": base != localBaseURL(activePort: activePort)
        ]

        if base == localBaseURL(activePort: activePort) {
            let tools = toolProvider()
            payload["instance_id"] = instanceID
            payload["tool_profile"] = toolProfileName(for: tools)
            payload["tool_count"] = tools.count
        }

        return payload
    }

    private func toolProfileName(for tools: [ToolDefinition]) -> String {
        guard !tools.isEmpty else { return "empty" }

        let builtInCount = tools.filter { $0.origin == .builtIn }.count
        let customCount = tools.filter { $0.origin == .userDefined }.count

        if builtInCount == tools.count,
           tools.contains(where: { $0.id == "remctl.run" }) {
            return "remctl-full-cli"
        }

        if customCount == tools.count,
           tools.allSatisfy({ URL(fileURLWithPath: $0.executablePath).lastPathComponent == "pocketctl" }) {
            return "pocketctl-cli"
        }

        if customCount == tools.count {
            return "custom-cli"
        }

        return "mixed"
    }

    private func publicRateLimitGroup(for request: HTTPRequest, isPublicRequest: Bool) -> PublicRateLimitGroup? {
        guard isPublicRequest else { return nil }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .health
        case ("GET", "/.well-known/oauth-authorization-server"):
            return .metadata
        case ("GET", _) where isProtectedResourceMetadataPath(request.path):
            return .metadata
        case ("POST", "/register"):
            return .registration
        case ("GET", "/authorize"):
            return .authorization
        case ("GET", "/authorize/status"):
            return .authorizationStatus
        case ("POST", "/token"):
            return .token
        default:
            return nil
        }
    }

    private func publicRateLimitResponseIfNeeded(for group: PublicRateLimitGroup) -> Data? {
        let decision = publicRateLimiter.check(group: group)
        guard !decision.allowed else { return nil }

        eventHandler?(.log(.warning, "Rate limited public \(group.displayName) request."))
        return jsonErrorResponse(
            status: .tooManyRequests,
            error: "rate_limited",
            description: "Too many public requests. Try again later.",
            headers: ["Retry-After": String(decision.retryAfterSeconds)]
        )
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

    private func beginAuthorization(request: HTTPRequest, issuer: String, resource: String) -> Data {
        do {
            let requestID = try authCoordinator.beginAuthorization(
                queryItems: request.queryItems,
                issuer: issuer,
                resource: resource
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

    private func token(_ request: HTTPRequest, issuer: String, resource: String) -> Data {
        do {
            let response = try authCoordinator.exchangeToken(
                form: request.formURLEncodedBody(),
                issuer: issuer,
                resource: resource
            )
            eventHandler?(.log(.info, "OAuth token issued after host approval."))
            eventHandler?(.clientsChanged(authCoordinator.connectedClientSnapshot()))
            return jsonResponse(response)
        } catch {
            return oauthErrorResponse(error)
        }
    }

    private func mcp(request: HTTPRequest, base: String, isPublicRequest: Bool) async -> Data {
        guard isSupportedProtocolVersionHeader(request) else {
            return jsonRPCError(
                id: nil,
                code: -32000,
                message: "Unsupported MCP-Protocol-Version.",
                status: .badRequest
            )
        }

        guard let bearerToken = request.bearerToken,
              let client = authCoordinator.clientContext(
                forAccessToken: bearerToken,
                issuer: base,
                resource: mcpResourceURL(base: base)
              ) else {
            if isPublicRequest,
               let response = publicRateLimitResponseIfNeeded(for: .unauthorizedMCP) {
                return response
            }

            return HTTPResponse(
                status: .unauthorized,
                headers: [
                    "WWW-Authenticate": "Bearer realm=\"mcp\", resource_metadata=\"\(protectedResourceMetadataURL(base: base))\", scope=\"mcp:tools\""
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
                let tools = toolProvider()
                let toolNames = MCPToolNameMapper.publicNames(for: tools)
                return jsonRPCResult(id: id, result: [
                    "tools": tools.map { tool in
                        toolJSON(tool, publicName: toolNames[tool.id] ?? MCPToolNameMapper.publicName(for: tool.id))
                    }
                ])
            case "tools/call":
                return await callTool(id: id, message: message, client: client)
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

    private func callTool(id: Any?, message: [String: Any], client: AuthenticatedClientContext) async -> Data {
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
            let tools = toolProvider()
            guard let tool = MCPToolNameMapper.resolve(name, in: tools) else {
                throw ToolValidationError.unknownTool(name)
            }

            if tool.capability != .readOnly {
                if clientToolPermissionStore?.isAllowed(clientID: client.clientID, toolID: tool.id) == true {
                    eventHandler?(.log(.info, "\(tool.name) allowed by \(client.clientName)'s client policy."))
                } else {
                    guard let toolCallApprovalCoordinator else {
                        eventHandler?(.log(.warning, "Blocked \(tool.name): host approval gate is unavailable."))
                        return toolExecutionErrorResult(
                            id: id,
                            tool: tool,
                            message: "Host approval is required for this tool."
                        )
                    }

                    eventHandler?(.log(.warning, "\(tool.name) is waiting for host approval before execution."))
                    let approved = await toolCallApprovalCoordinator.requestApproval(
                        tool: tool,
                        parameters: arguments,
                        client: client
                    )
                    guard approved else {
                        eventHandler?(.log(.warning, "\(tool.name) was denied or expired before execution."))
                        return toolExecutionErrorResult(
                            id: id,
                            tool: tool,
                            message: "Tool call was not approved on the host Mac."
                        )
                    }
                    eventHandler?(.log(.info, "\(tool.name) approved on host Mac."))
                }
            }

            let outcome = try await toolExecutor.execute(toolID: tool.id, parameters: arguments)
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

    private func toolExecutionErrorResult(id: Any?, tool: ToolDefinition, message: String) -> Data {
        let structuredContent: [String: Any] = [
            "toolID": tool.id,
            "toolName": tool.name,
            "exitCode": -1,
            "succeeded": false,
            "stdout": "",
            "stderr": message,
            "durationSeconds": 0,
            "timedOut": false,
            "truncatedStdout": false,
            "truncatedStderr": false
        ]
        return jsonRPCResult(id: id, result: [
            "structuredContent": structuredContent,
            "content": [
                [
                    "type": "text",
                    "text": serializedJSON(structuredContent)
                ]
            ],
            "isError": true
        ])
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

    private func toolJSON(_ tool: ToolDefinition, publicName: String) -> [String: Any] {
        [
            "name": publicName,
            "title": tool.name,
            "description": toolDescription(for: tool),
            "inputSchema": inputSchema(for: tool),
            "outputSchema": outputSchema(),
            "annotations": [
                "title": tool.name,
                "readOnlyHint": tool.capability == .readOnly,
                "destructiveHint": tool.capability == .destructive,
                "idempotentHint": tool.capability == .readOnly && !tool.isGenericCLIAdapter,
                "openWorldHint": tool.isGenericCLIAdapter || tool.capability != .readOnly
            ]
        ]
    }

    private func toolDescription(for tool: ToolDefinition) -> String {
        var parts = [tool.summary]

        if tool.isGenericCLIAdapter {
            parts.append("Pass exact argv items as the `args` array; optional `stdin` is sent to standard input.")
            parts.append("MacRemote launches the executable directly without a shell: do not use `~`, `$HOME`, pipes, redirection, globs, command substitution, or environment assignments. Use absolute paths and separate every flag/value into its own argv item.")

            switch URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() {
            case "codex":
                parts.append("For Codex, global options such as `--ask-for-approval` and `--sandbox` must appear before `exec`; options after `exec` are parsed by the exec subcommand.")
            case "remctl":
                parts.append("For RemCTL, pass the numeric `id` field from JSON results to commands such as `edit`, `info`, `done`, `delete`, `flag`, and `unflag`; do not pass the UUID embedded in `deepLink`.")
                parts.append("Use `--private` only for private Reminders metadata such as sections, tags, subtasks, images, flags, urgency, assignment, or location alarms. Do not use `--private` for normal due dates or EventKit alarms; use `edit ID -d DATE --alarm DATE --json`.")
            default:
                break
            }
        } else if tool.parameters.isEmpty {
            parts.append("This command has no model-supplied arguments.")
        } else {
            parts.append("Only the documented schema parameters are accepted.")
        }

        switch tool.capability {
        case .readOnly:
            parts.append("Read-only: expected not to modify local state.")
        case .write:
            parts.append("Write-capable: requires host approval before execution.")
        case .destructive:
            parts.append("Destructive or broad CLI access: requires host approval before execution.")
        }

        if tool.permissionRequirements.contains(.fullDiskAccess) {
            parts.append("Requires Full Disk Access on the host Mac.")
        }
        let privacyRequirements = tool.permissionRequirements.filter { !$0.isFullDiskAccess }
        if !privacyRequirements.isEmpty {
            let names = privacyRequirements.map(\.title).joined(separator: ", ")
            parts.append("May require macOS privacy permission for \(names); macOS can attribute child CLI access to MacRemote as the host app.")
        }

        return parts.joined(separator: " ")
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
            properties[parameter.name] = parameterSchema(parameter, for: tool)
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

    private func parameterSchema(_ parameter: ToolParameter, for tool: ToolDefinition) -> [String: Any] {
        var schema: [String: Any] = [
            "title": parameter.title,
            "description": parameterDescription(parameter, for: tool)
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

    private func parameterDescription(_ parameter: ToolParameter, for tool: ToolDefinition) -> String {
        switch parameter.name {
        case "args", "argv":
            if URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() == "remctl" {
                return "Exact RemCTL argv items. No shell is used. Use numeric reminder IDs from the `id` JSON field, not UUIDs from `deepLink`. Do not use `--private` for ordinary `edit ID -d DATE` or `edit ID --alarm DATE` calls."
            }
            return "Exact argv items to pass to the executable. No shell is used: do not include `~`, variables, pipes, redirection, globs, or combined command strings."
        case "stdin":
            return "Optional standard input passed directly to the process."
        default:
            return parameter.title
        }
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

    private func jsonErrorResponse(
        status: HTTPResponse.Status,
        error: String,
        description: String,
        headers: [String: String] = [:]
    ) -> Data {
        jsonResponse([
            "error": error,
            "error_description": description
        ], status: status, headers: headers)
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

private enum MCPToolNameMapper {
    private static let maxLength = 64

    static func publicNames(for tools: [ToolDefinition]) -> [String: String] {
        var namesByID = [String: String]()
        var usedNames = Set<String>()

        for tool in tools {
            let baseName = publicName(for: tool.id)
            var candidate = baseName
            var collisionIndex = 0
            while usedNames.contains(candidate) {
                collisionIndex += 1
                candidate = publicName(
                    for: "\(tool.id)-\(collisionIndex)",
                    preferredPrefix: baseName,
                    forceSuffix: true
                )
            }
            namesByID[tool.id] = candidate
            usedNames.insert(candidate)
        }

        return namesByID
    }

    static func publicName(for id: String, preferredPrefix: String? = nil, forceSuffix: Bool = false) -> String {
        let sanitized = sanitize(preferredPrefix ?? id)
        let base = sanitized.isEmpty ? "tool" : sanitized
        guard forceSuffix || base.count > maxLength else {
            return base
        }

        let suffix = "_\(shortHash(id))"
        let prefixLength = max(1, maxLength - suffix.count)
        return String(base.prefix(prefixLength)) + suffix
    }

    static func resolve(_ name: String, in tools: [ToolDefinition]) -> ToolDefinition? {
        if let exactMatch = tools.first(where: { $0.id == name }) {
            return exactMatch
        }

        let namesByID = publicNames(for: tools)
        guard let internalID = namesByID.first(where: { $0.value == name })?.key else {
            return nil
        }
        return tools.first { $0.id == internalID }
    }

    private static func sanitize(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)

        for scalar in value.unicodeScalars {
            if isAllowed(scalar) {
                output.unicodeScalars.append(scalar)
            } else if output.last != "_" {
                output.append("_")
            }
        }

        return output.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    }

    private static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122:
            true
        case 45, 95:
            true
        default:
            false
        }
    }

    private static func shortHash(_ value: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%012llx", hash)
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

private enum PublicRateLimitGroup: String, Hashable {
    case health
    case metadata
    case registration
    case authorization
    case authorizationStatus
    case token
    case unauthorizedMCP

    var displayName: String {
        switch self {
        case .health: "health"
        case .metadata: "metadata"
        case .registration: "registration"
        case .authorization: "authorization"
        case .authorizationStatus: "authorization status"
        case .token: "token"
        case .unauthorizedMCP: "unauthorized MCP"
        }
    }

    var rule: PublicRateLimitRule {
        switch self {
        case .health:
            PublicRateLimitRule(maxRequests: 120, windowSeconds: 60)
        case .metadata:
            PublicRateLimitRule(maxRequests: 240, windowSeconds: 60)
        case .registration:
            PublicRateLimitRule(maxRequests: 20, windowSeconds: 60)
        case .authorization:
            PublicRateLimitRule(maxRequests: 20, windowSeconds: 60)
        case .authorizationStatus:
            PublicRateLimitRule(maxRequests: 300, windowSeconds: 60)
        case .token:
            PublicRateLimitRule(maxRequests: 60, windowSeconds: 60)
        case .unauthorizedMCP:
            PublicRateLimitRule(maxRequests: 60, windowSeconds: 60)
        }
    }
}

private struct PublicRateLimitRule: Sendable {
    let maxRequests: Int
    let windowSeconds: TimeInterval
}

private struct PublicRateLimitDecision: Sendable {
    let allowed: Bool
    let retryAfterSeconds: Int
}

private final class PublicRequestRateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var buckets = [PublicRateLimitGroup: [TimeInterval]]()

    func check(group: PublicRateLimitGroup, now: Date = Date()) -> PublicRateLimitDecision {
        lock.lock()
        defer { lock.unlock() }

        let rule = group.rule
        let nowSeconds = now.timeIntervalSince1970
        let cutoff = nowSeconds - rule.windowSeconds
        var timestamps = buckets[group, default: []].filter { $0 > cutoff }

        guard timestamps.count < rule.maxRequests else {
            buckets[group] = timestamps
            let oldest = timestamps.first ?? nowSeconds
            let retryAfter = max(1, Int(ceil(oldest + rule.windowSeconds - nowSeconds)))
            return PublicRateLimitDecision(allowed: false, retryAfterSeconds: retryAfter)
        }

        timestamps.append(nowSeconds)
        buckets[group] = timestamps
        return PublicRateLimitDecision(allowed: true, retryAfterSeconds: 0)
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
        case tooManyRequests
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
            case .tooManyRequests: "429 Too Many Requests"
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
