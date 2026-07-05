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
    private static let connectorIconPath = "/macremote-icon.png"
    private static let connectorIconFileName = "MacRemoteConnectorIcon.png"
    private static let connectorIcon128Path = "/macremote-icon-128.png"
    private static let connectorIcon128FileName = "MacRemoteConnectorIcon128.png"
    private static let connectorIcon64FileName = "MacRemoteConnectorIcon64.png"
    private static let faviconICOPath = "/favicon.ico"
    private static let faviconICOFileName = "Favicon.ico"
    private static let faviconPNGPath = "/favicon.png"
    private static let faviconPNGFileName = "Favicon.png"
    private static let artifactPathPrefix = "/artifact/"
    static let toolsListPageSize = 60

    // Claude.ai resolves connector icons through Google's favicon service today and may
    // adopt SEP-973 serverInfo.icons later; the data: entry needs no fetch at all.
    // Built once because it embeds ~9 KB of base64.
    private static let connectorIconDataURI: String? = {
        guard let data = staticResourceData(fileName: connectorIcon64FileName) else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }()

    private let queue = DispatchQueue(label: "com.macremote.local-server")
    private var listener: NWListener?
    private var activePort: UInt16?
    private let instanceID: String
    private let toolProvider: ToolProvider
    private let authCoordinator: OAuthCoordinator
    private let toolCallApprovalCoordinator: ToolCallApprovalCoordinator?
    private let toolExecutor: any ToolExecuting
    private let clientToolPermissionStore: ClientToolPermissionStore?
    private let artifactStore: ArtifactStore
    private let eventHandler: EventHandler?
    private let publicRateLimiter = PublicRequestRateLimiter()
    private let toolExecutionLimiter: ToolExecutionLimiter

    init(
        instanceID: String,
        tools: [ToolDefinition],
        authCoordinator: OAuthCoordinator,
        toolCallApprovalCoordinator: ToolCallApprovalCoordinator? = nil,
        toolExecutor: any ToolExecuting,
        clientToolPermissionStore: ClientToolPermissionStore? = nil,
        artifactStore: ArtifactStore = ArtifactStore(),
        toolExecutionLimiter: ToolExecutionLimiter? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.toolProvider = { tools }
        self.authCoordinator = authCoordinator
        self.toolCallApprovalCoordinator = toolCallApprovalCoordinator
        self.toolExecutor = toolExecutor
        self.clientToolPermissionStore = clientToolPermissionStore
        self.artifactStore = artifactStore
        self.toolExecutionLimiter = toolExecutionLimiter ?? ToolExecutionLimiter()
        self.eventHandler = eventHandler
    }

    init(
        instanceID: String,
        toolProvider: @escaping ToolProvider,
        authCoordinator: OAuthCoordinator,
        toolCallApprovalCoordinator: ToolCallApprovalCoordinator? = nil,
        toolExecutor: any ToolExecuting,
        clientToolPermissionStore: ClientToolPermissionStore? = nil,
        artifactStore: ArtifactStore = ArtifactStore(),
        toolExecutionLimiter: ToolExecutionLimiter? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.toolProvider = toolProvider
        self.authCoordinator = authCoordinator
        self.toolCallApprovalCoordinator = toolCallApprovalCoordinator
        self.toolExecutor = toolExecutor
        self.clientToolPermissionStore = clientToolPermissionStore
        self.artifactStore = artifactStore
        self.toolExecutionLimiter = toolExecutionLimiter ?? ToolExecutionLimiter()
        self.eventHandler = eventHandler
    }

    func start() throws -> UInt16 {
        // availablePort() probes with a throwaway socket that closes before
        // NWListener binds, so another process can win the port in between
        // (TOCTOU) — and NWListener reports EADDRINUSE only asynchronously,
        // which used to leave a silently dead listener behind (flaky under
        // parallel test startup). Verify each bind and retry on a fresh port.
        var lastError: Error = LocalMCPServerError.portUnavailable
        for _ in 0..<8 {
            let selectedPort = try Self.availablePort()
            guard let nwPort = NWEndpoint.Port(rawValue: selectedPort) else {
                throw LocalMCPServerError.portUnavailable
            }

            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.service = nil
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            switch Self.startAndAwaitReady(listener, queue: queue) {
            case .success:
                self.listener = listener
                self.activePort = selectedPort
                return selectedPort
            case .failure(let error):
                listener.cancel()
                lastError = error
            }
        }
        throw lastError
    }

    /// Starts the listener and blocks until Network.framework reports
    /// `.ready` or `.failed`, so callers never receive a port nobody is
    /// actually listening on. Readiness is normally a few milliseconds; the
    /// timeout only guards against a wedged network stack.
    private static func startAndAwaitReady(
        _ listener: NWListener,
        queue: DispatchQueue
    ) -> Result<Void, Error> {
        let gate = ListenerReadyGate()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                gate.resolve(.ready)
            case .failed(let error):
                gate.resolve(.failed(error))
            case .cancelled:
                gate.resolve(.failed(NWError.posix(.ECANCELED)))
            default:
                break
            }
        }
        listener.start(queue: queue)
        let outcome = gate.awaitOutcome(timeout: 5)
        listener.stateUpdateHandler = nil
        switch outcome {
        case .ready:
            return .success(())
        case .failed(let error):
            return .failure(error)
        case nil:
            return .failure(LocalMCPServerError.portUnavailable)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
        artifactStore.purgeAll()
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
        let isPublicRequest = base != localBaseURL(activePort: activePort)
        let mcpResourceURL = mcpResourceURL(base: base, isPublicRequest: isPublicRequest)
        guard isAllowedOrigin(for: request, base: base, activePort: activePort) else {
            return jsonErrorResponse(
                status: .forbidden,
                error: "forbidden_origin",
                description: "Invalid Origin header."
            )
        }

        if let group = publicRateLimitGroup(for: request, isPublicRequest: isPublicRequest),
           let response = publicRateLimitResponseIfNeeded(for: group) {
            return response
        }

        if request.method == "GET", isProtectedResourceMetadataPath(request.path) {
            return jsonResponse(protectedResourceMetadata(base: base, isPublicRequest: isPublicRequest))
        }

        if request.method == "GET", request.path == Self.connectorIconPath {
            return staticIconResponse(fileName: Self.connectorIconFileName, contentType: "image/png")
        }

        if request.method == "GET", request.path == Self.connectorIcon128Path {
            return staticIconResponse(fileName: Self.connectorIcon128FileName, contentType: "image/png")
        }

        if request.method == "GET", request.path == Self.faviconICOPath {
            return staticIconResponse(fileName: Self.faviconICOFileName, contentType: "image/x-icon")
        }

        if request.method == "GET", request.path == Self.faviconPNGPath {
            return staticIconResponse(fileName: Self.faviconPNGFileName, contentType: "image/png")
        }

        if request.method == "GET" || request.method == "HEAD",
           let token = artifactToken(from: request.path) {
            return artifactResponse(for: request, token: token)
        }

        let allowAuthenticatedMCPAlias = isPublicRequest || request.bearerToken != nil
        if isMCPPath(
            request.path,
            allowLegacyPath: allowsLegacyMCPPath(base: base, activePort: activePort) || allowAuthenticatedMCPAlias
        ) {
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
        case ("GET", "/"):
            // Google's favicon fetcher parses this page for <link rel="icon">; it is also
            // what a person sees when they open the bare tunnel URL in a browser.
            return htmlResponse(landingPageHTML())
        case ("GET", "/health"):
            return jsonResponse(healthPayload(base: base, activePort: activePort))
        case ("GET", "/.well-known/oauth-authorization-server"):
            var metadata: [String: Any] = [
                "issuer": base,
                "authorization_endpoint": "\(base)/authorize",
                "token_endpoint": "\(base)/token",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": authCoordinator.tokenEndpointAuthMethodsSupported(),
                "scopes_supported": ["mcp:tools"],
                "resource_indicators_supported": true
            ]
            if authCoordinator.supportsDynamicClientRegistration() {
                metadata["registration_endpoint"] = "\(base)/register"
            }
            return jsonResponse(metadata)
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

    private func mcpResourceURL(base: String, isPublicRequest: Bool = false) -> String {
        "\(base)\(isPublicRequest ? "/mcp" : mcpEndpointPath)"
    }

    private func mcpResourceAliases(base: String) -> [String] {
        [
            mcpResourceURL(base: base),
            "\(base)/mcp"
        ]
    }

    private func connectorIconURL(base: String) -> String {
        "\(base)\(Self.connectorIconPath)"
    }

    private func localBaseURL(activePort: UInt16) -> String {
        "http://127.0.0.1:\(activePort)"
    }

    private func protectedResourceMetadataURL(base: String) -> String {
        "\(base)/.well-known/oauth-protected-resource/mcp"
    }

    private func protectedResourceMetadata(base: String, isPublicRequest: Bool = false) -> [String: Any] {
        [
            "resource": mcpResourceURL(base: base, isPublicRequest: isPublicRequest),
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
            path == "/.well-known/oauth-protected-resource/mcp" ||
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

        if tools.allSatisfy(\.isMCPBridge) {
            return "mcp-bridge"
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
        case ("GET", _) where request.path.hasPrefix(Self.artifactPathPrefix):
            return .artifact
        case ("HEAD", _) where request.path.hasPrefix(Self.artifactPathPrefix):
            return .artifact
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
                form: request.tokenFormURLEncodedBody(),
                issuer: issuer,
                resource: resource
            )
            eventHandler?(.log(.info, "OAuth token issued after host approval."))
            eventHandler?(.clientsChanged(authCoordinator.connectedClientSnapshot()))
            return jsonResponse(response)
        } catch {
            eventHandler?(.log(.warning, "OAuth token exchange rejected: \(singleLine(error.localizedDescription))"))
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
                acceptedResources: mcpResourceAliases(base: base)
              ) else {
            if isPublicRequest,
               let response = publicRateLimitResponseIfNeeded(for: .unauthorizedMCP) {
                return response
            }

            // RFC 6750 §3.1: a present-but-rejected token gets error="invalid_token"
            // so clients refresh instead of restarting authorization.
            var challenge = "Bearer realm=\"mcp\""
            if request.bearerToken != nil {
                eventHandler?(.log(.warning, "Rejected MCP bearer token for \(request.path) on \(base)."))
                challenge += ", error=\"invalid_token\""
            }
            challenge += ", resource_metadata=\"\(protectedResourceMetadataURL(base: base))\", scope=\"mcp:tools\""

            return HTTPResponse(
                status: .unauthorized,
                headers: ["WWW-Authenticate": challenge],
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
                var capabilities: [String: Any] = [
                    "tools": [
                        "listChanged": false
                    ]
                ]
                if widgetAvailable {
                    // MCP Apps (SEP-1865): the widget resource rides the
                    // standard resources capability.
                    capabilities["resources"] = ["listChanged": false]
                }
                return jsonRPCResult(id: id, result: [
                    "protocolVersion": negotiatedProtocolVersion(requestedVersion),
                    "capabilities": capabilities,
                    "serverInfo": serverInfo(base: base)
                ])
            case "ping":
                return jsonRPCResult(id: id, result: [:])
            case "resources/list":
                return resourcesList(id: id)
            case "resources/read":
                return resourcesRead(id: id, message: message)
            case "resources/templates/list":
                return jsonRPCResult(id: id, result: ["resourceTemplates": []])
            case "tools/list":
                return toolsList(id: id, message: message)
            case "tools/call":
                return await callTool(id: id, message: message, client: client, base: base)
            case "notifications/initialized", "notifications/cancelled":
                return HTTPResponse(status: .accepted, headers: mcpResponseHeaders(), body: "").data
            default:
                if method.hasPrefix("notifications/") {
                    return HTTPResponse(status: .accepted, headers: mcpResponseHeaders(), body: "").data
                }
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

    private func callTool(
        id: Any?,
        message: [String: Any],
        client: AuthenticatedClientContext,
        base: String
    ) async -> Data {
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing tool name.")
        }

        let rawArguments = params["arguments"] as? [String: Any] ?? [:]
        let arguments = rawArguments.compactMapValues(ToolArgumentValue.fromJSONObject)

        var resolvedTool: ToolDefinition?
        do {
            let tools = toolProvider()
            guard let tool = MCPToolNameMapper.resolve(name, in: tools) else {
                throw ToolValidationError.unknownTool(name)
            }
            resolvedTool = tool

            if tool.capability != .readOnly {
                if clientToolPermissionStore?.isAllowed(
                    clientID: client.clientID,
                    clientTrustID: client.clientTrustID,
                    toolID: tool.id
                ) == true {
                    eventHandler?(.log(.info, "\(tool.name) allowed by \(client.clientName)'s client policy."))
                } else {
                    guard let toolCallApprovalCoordinator else {
                        eventHandler?(.log(.warning, "Blocked \(tool.name): host approval gate is unavailable."))
                        return toolExecutionErrorResult(
                            id: id,
                            tool: tool,
                            reason: "unavailable",
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
                            reason: "not_approved",
                            message: "Tool call was not approved on the host Mac."
                        )
                    }
                    eventHandler?(.log(.info, "\(tool.name) approved on host Mac."))
                }
            }

            guard let outcome = try await toolExecutionLimiter.withSlot({
                try await toolExecutor.execute(toolID: tool.id, parameters: arguments)
            }) else {
                eventHandler?(.log(.warning, "\(tool.name) was not executed: execution concurrency limit reached."))
                return toolExecutionErrorResult(
                    id: id,
                    tool: tool,
                    reason: "unavailable",
                    message: "Server is busy; too many tool calls in progress. Retry shortly."
                )
            }
            var structuredContent = structuredContent(for: outcome)
            structuredContent = augmentStructuredContentWithArtifactDownloadURL(structuredContent, base: base)
            eventHandler?(.log(
                outcome.succeeded ? .info : .warning,
                "\(outcome.toolName) MCP call exited \(outcome.exitCode) in \(outcome.duration.formattedDuration)."
            ))
            var contentItems: [[String: Any]] = [
                [
                    "type": "text",
                    "text": serializedJSON(structuredContent)
                ]
            ]
            if outcome.succeeded,
               let payload = stdoutJSONPayload(from: structuredContent),
               let artifactLink = artifactResourceLinkItem(payload: payload, base: base) {
                contentItems.append(artifactLink)
            }
            if let spillItems = spillStdoutContentItems(outcome: outcome, base: base) {
                contentItems.append(contentsOf: spillItems)
            }
            var result: [String: Any] = [
                "structuredContent": structuredContent,
                "content": contentItems,
                "isError": !outcome.succeeded
            ]
            if let uiMeta = resultUIMeta(for: tool, tools: tools) {
                result["_meta"] = [
                    Self.resultUIMetaKey: uiMeta,
                    // Mirror the resource link on the result too — some host
                    // paths resolve the widget from CallToolResult._meta.
                    Self.toolUIMetaKey: ["resourceUri": Self.widgetResourceURI],
                    "ui/resourceUri": Self.widgetResourceURI
                ]
            }
            return jsonRPCResult(id: id, result: result)
        } catch ToolValidationError.unknownTool(let unknownName) {
            return jsonRPCError(id: id, code: -32602, message: "Unknown tool: \(unknownName)")
        } catch let error as ToolValidationError {
            return toolExecutionErrorResult(
                id: id,
                tool: resolvedTool,
                reason: error.callToolReason,
                message: error.callToolMessage(tool: resolvedTool, arguments: arguments)
            )
        } catch {
            return jsonRPCError(id: id, code: -32603, message: "Internal error.")
        }
    }

    private func toolExecutionErrorResult(
        id: Any?,
        tool: ToolDefinition?,
        reason: String,
        message: String
    ) -> Data {
        let structuredContent = makeStructuredContent(
            toolID: tool?.id ?? "",
            toolName: tool?.name ?? "",
            exitCode: -1,
            succeeded: false,
            stdout: "",
            stderr: message,
            durationSeconds: 0,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false,
            reason: reason
        )
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

    /// Results above ~150k characters are diverted by Claude's code-execution
    /// sandbox to a file: the model gets a pointer and the widget never
    /// hydrates. Cap the envelope's streams below that cliff; per-tool
    /// `outputByteLimit` still governs what the tool may produce, this only
    /// bounds what one MCP result carries inline.
    static let mcpStdoutCharacterLimit = 100_000
    static let mcpStderrCharacterLimit = 16_000

    private func structuredContent(for outcome: ToolExecutionOutcome) -> [String: Any] {
        let stdout = String(outcome.stdout.prefix(Self.mcpStdoutCharacterLimit))
        let stderr = String(outcome.stderr.prefix(Self.mcpStderrCharacterLimit))
        let truncatedStdout = outcome.truncatedStdout || stdout.count < outcome.stdout.count
        let truncatedStderr = outcome.truncatedStderr || stderr.count < outcome.stderr.count
        return makeStructuredContent(
            toolID: outcome.toolID,
            toolName: outcome.toolName,
            exitCode: Int(outcome.exitCode),
            succeeded: outcome.succeeded,
            stdout: stdout,
            stderr: stderr,
            durationSeconds: outcome.duration,
            timedOut: outcome.timedOut,
            truncatedStdout: truncatedStdout,
            truncatedStderr: truncatedStderr,
            reason: executionReason(
                for: outcome,
                truncatedStdout: truncatedStdout,
                truncatedStderr: truncatedStderr
            )
        )
    }

    private func makeStructuredContent(
        toolID: String,
        toolName: String,
        exitCode: Int,
        succeeded: Bool,
        stdout: String,
        stderr: String,
        durationSeconds: TimeInterval,
        timedOut: Bool,
        truncatedStdout: Bool,
        truncatedStderr: Bool,
        reason: String
    ) -> [String: Any] {
        [
            "toolID": toolID,
            "toolName": toolName,
            "exitCode": exitCode,
            "succeeded": succeeded,
            "stdout": stdout,
            "stderr": stderr,
            "durationSeconds": durationSeconds,
            "timedOut": timedOut,
            "truncatedStdout": truncatedStdout,
            "truncatedStderr": truncatedStderr,
            "reason": reason
        ]
    }

    private func executionReason(
        for outcome: ToolExecutionOutcome,
        truncatedStdout: Bool,
        truncatedStderr: Bool
    ) -> String {
        if outcome.timedOut {
            return "timeout"
        }
        if truncatedStdout || truncatedStderr {
            return "output_limit"
        }
        if outcome.succeeded {
            return "ok"
        }
        return "nonzero_exit"
    }

    private func augmentStructuredContentWithArtifactDownloadURL(
        _ structuredContent: [String: Any],
        base: String
    ) -> [String: Any] {
        guard structuredContent["succeeded"] as? Bool == true,
              let stdout = structuredContent["stdout"] as? String,
              let data = stdout.data(using: .utf8),
              var payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let artifactPath = payload["artifact_path"] as? String,
              artifactPath.hasPrefix(Self.artifactPathPrefix) else {
            return structuredContent
        }

        payload["download_url"] = base + artifactPath
        guard let updatedData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let updatedStdout = String(data: updatedData, encoding: .utf8) else {
            return structuredContent
        }

        var updated = structuredContent
        updated["stdout"] = updatedStdout
        return updated
    }

    private func stdoutJSONPayload(from structuredContent: [String: Any]) -> [String: Any]? {
        guard let stdout = structuredContent["stdout"] as? String,
              let data = stdout.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return payload
    }

    private func artifactDownloadURL(from payload: [String: Any], base: String) -> String? {
        if let url = payload["download_url"] as? String, !url.isEmpty {
            return url
        }
        guard let artifactPath = payload["artifact_path"] as? String,
              artifactPath.hasPrefix(Self.artifactPathPrefix) else {
            return nil
        }
        return base + artifactPath
    }

    private func mimeType(forFilename filename: String) -> String {
        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".zip") {
            return "application/zip"
        }
        if lowercased.hasSuffix(".txt") {
            return "text/plain"
        }
        return "application/octet-stream"
    }

    private func artifactResourceLinkItem(payload: [String: Any], base: String) -> [String: Any]? {
        guard let uri = artifactDownloadURL(from: payload, base: base) else { return nil }
        let filename = (payload["filename"] as? String).map(ArtifactStore.sanitizedFilename) ?? "download"
        let sizeBytes = payloadSizeBytes(payload)
        let expiresIn = payload["expires_in_seconds"] as? Int ?? Int(ArtifactStore.defaultExpiryInterval)
        return [
            "type": "resource_link",
            "uri": uri,
            "name": filename,
            "mimeType": mimeType(forFilename: filename),
            "description": "Downloadable artifact (expires in \(expiresIn)s, \(sizeBytes) bytes)."
        ]
    }

    private func payloadSizeBytes(_ payload: [String: Any]) -> Int64 {
        if let size = payload["size_bytes"] as? Int64 {
            return size
        }
        if let size = payload["size_bytes"] as? Int {
            return Int64(size)
        }
        if let size = payload["size_bytes"] as? NSNumber {
            return size.int64Value
        }
        return 0
    }

    private func spillStdoutContentItems(outcome: ToolExecutionOutcome, base: String) -> [[String: Any]]? {
        guard outcome.stdout.count > Self.mcpStdoutCharacterLimit,
              let data = outcome.stdout.data(using: .utf8) else {
            return nil
        }

        let filename = ArtifactStore.sanitizedFilename("\(outcome.toolName)-output.txt")
        let handle: ArtifactHandle
        do {
            handle = try artifactStore.register(data: data, suggestedFilename: filename)
        } catch {
            return nil
        }

        let resourceLink: [String: Any] = [
            "type": "resource_link",
            "uri": base + handle.artifactPath,
            "name": handle.filename,
            "mimeType": mimeType(forFilename: handle.filename),
            "description": "Full tool output (expires in \(handle.expiresInSeconds)s, \(handle.sizeBytes) bytes)."
        ]
        let note: [String: Any] = [
            "type": "text",
            "text": "Full output (\(handle.sizeBytes) bytes) available at the linked artifact."
        ]
        return [resourceLink, note]
    }

    private func artifactToken(from path: String) -> String? {
        guard path.hasPrefix(Self.artifactPathPrefix) else { return nil }
        let token = String(path.dropFirst(Self.artifactPathPrefix.count))
        guard !token.isEmpty, !token.contains("/") else { return nil }
        return token
    }

    private func artifactResponse(for request: HTTPRequest, token: String) -> Data {
        let resolved: (fileURL: URL, filename: String, remainingDownloads: Int)?
        if request.method == "HEAD" {
            resolved = artifactStore.resolve(token: token)
        } else {
            resolved = artifactStore.consume(token: token)
        }

        guard let resolved else {
            return jsonErrorResponse(status: .notFound, error: "not_found", description: "Artifact not found.")
        }

        let fileSize: Int
        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.fileURL.path),
           let size = attributes[.size] as? NSNumber {
            fileSize = size.intValue
        } else {
            return jsonErrorResponse(status: .notFound, error: "not_found", description: "Artifact not found.")
        }

        let fileData: Data
        if request.method == "HEAD" {
            fileData = Data()
        } else {
            guard let data = try? Data(contentsOf: resolved.fileURL) else {
                return jsonErrorResponse(status: .notFound, error: "not_found", description: "Artifact not found.")
            }
            fileData = data
        }

        let contentType = mimeType(forFilename: resolved.filename)
        let sanitizedFilename = ArtifactStore.sanitizedFilename(resolved.filename)

        return HTTPResponse(
            status: .ok,
            headers: [
                "Content-Type": contentType,
                "Content-Disposition": "attachment; filename=\"\(sanitizedFilename)\"",
                "Cache-Control": "no-store",
                "Content-Length": String(fileSize)
            ],
            bodyData: fileData
        ).data
    }

    private func serializedJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - MCP Apps (SEP-1865) selective widget

    /// One adaptive widget renders the uniform result envelope for every
    /// widget-eligible tool (see `widgetEligible(category:)` — categories
    /// with curated presentation only), so a single resource covers all of
    /// them. Ineligible tools return plain results and hosts render their
    /// native display. Hosts without the extension ignore `_meta` and keep
    /// the mandated text fallback.
    static let widgetResourceURI = "ui://macremote/output"
    static let widgetMIMEType = "text/html;profile=mcp-app"
    /// The `_meta` key on tools that links them to the widget (SEP-1865
    /// nested form; the flat "ui/resourceUri" form is deprecated).
    static let toolUIMetaKey = "ui"
    /// Namespaced `_meta` key on CallToolResult carrying MacRemote's render
    /// hints (declared UI actions, display metadata) to the widget.
    static let resultUIMetaKey = "net.viticci.macremote/ui"

    static let widgetHTML: String? = {
        guard let url = Bundle.module.url(forResource: "MacRemoteWidget", withExtension: "html") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private var widgetAvailable: Bool { Self.widgetHTML != nil }

    private func widgetResourceDescriptor() -> [String: Any] {
        [
            "uri": Self.widgetResourceURI,
            "name": "macremote-output",
            "title": "MacRemote Tool Output",
            "description": "Adaptive rendering of any MacRemote tool result: tables, trees, terminal output, and declared row actions.",
            "mimeType": Self.widgetMIMEType
        ]
    }

    private func resourcesList(id: Any?) -> Data {
        jsonRPCResult(id: id, result: [
            "resources": widgetAvailable ? [widgetResourceDescriptor()] : []
        ])
    }

    private func resourcesRead(id: Any?, message: [String: Any]) -> Data {
        guard let uri = (message["params"] as? [String: Any])?["uri"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing resource uri.")
        }
        guard uri == Self.widgetResourceURI, let html = Self.widgetHTML else {
            return jsonRPCError(id: id, code: -32002, message: "Unknown resource: \(uri)")
        }
        return jsonRPCResult(id: id, result: [
            "contents": [
                [
                    "uri": Self.widgetResourceURI,
                    "mimeType": Self.widgetMIMEType,
                    "text": html,
                    // SEP-1865 sandbox hints: the widget makes no fetch/XHR
                    // calls (connect stays empty), and loads images from
                    // exactly one origin — Pocket Casts episode artwork.
                    "_meta": [
                        "ui": [
                            "prefersBorder": true,
                            "csp": [
                                "connectDomains": [],
                                "resourceDomains": ["https://static.pocketcasts.com"]
                            ],
                            "permissions": [
                                "clipboardWrite": [:]
                            ]
                        ]
                    ]
                ]
            ]
        ])
    }

    /// The widget attaches selectively, not universally: only tools whose
    /// category has curated presentation hints (accent + table/card
    /// curation) opt into MCP UI — RemCTL reminders and PocketCTL podcasts
    /// today. Everything else returns the plain text/structured result so
    /// hosts render their own native display, which beats a generic JSON
    /// dump in the widget. Declared `uiActions` on ineligible tools are
    /// inert data until their category earns hints.
    static func widgetEligible(category: ToolCategory) -> Bool {
        widgetAccent(for: category) != nil || widgetTableHints(for: category) != nil
    }

    /// Render hints attached to CallToolResult._meta: declared actions with
    /// tool ids translated to public MCP names (the widget calls tools by
    /// public name through the host — same connection, same gating).
    private func resultUIMeta(for tool: ToolDefinition, tools: [ToolDefinition]) -> [String: Any]? {
        guard widgetAvailable, Self.widgetEligible(category: tool.category) else { return nil }
        let publicNames = MCPToolNameMapper.publicNames(for: tools)
        var payload: [String: Any] = [
            "version": 1,
            "toolTitle": tool.name,
            "toolName": publicNames[tool.id] ?? MCPToolNameMapper.publicName(for: tool.id),
            "capability": tool.capability.rawValue,
            "category": tool.category.title
        ]
        if let accent = Self.widgetAccent(for: tool.category) {
            payload["accent"] = accent
        }
        if let table = Self.widgetTableHints(for: tool.category) {
            payload["table"] = table
        }
        if let actions = tool.uiActions, !actions.isEmpty {
            let encodedActions: [[String: Any]] = actions.compactMap { action in
                guard let targetTool = resolveActionTarget(action, in: tools),
                      let encoded = try? JSONEncoder().encode(action),
                      var json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                    return nil
                }
                json["toolName"] = publicNames[targetTool.id] ?? MCPToolNameMapper.publicName(for: targetTool.id)
                json["toolCapability"] = targetTool.capability.rawValue
                // Internal addressing never leaves the server.
                json.removeValue(forKey: "toolID")
                json.removeValue(forKey: "targetExecutableBasename")
                return json
            }
            if !encodedActions.isEmpty {
                payload["actions"] = encodedActions
            }
        }
        return payload
    }

    /// Per-category widget accent (overrides the widget's default blue/green).
    /// Reminders read purple to distinguish RemCTL results at a glance;
    /// podcasts read Pocket Casts red; habits read Habitify blue.
    private static func widgetAccent(for category: ToolCategory) -> String? {
        switch category {
        case .reminders: return "#8b5cf6"   // purple
        case .podcasts: return "#f43e37"    // Pocket Casts red
        case .habits: return "#2a9df4"      // Habitify blue
        default: return nil
        }
    }

    /// Podcast artwork endpoint (Pocket Casts CDN, keyed by podcast UUID).
    /// Must stay in sync with the widget resource's CSP `resourceDomains`.
    static let podcastArtworkURLTemplate = "https://static.pocketcasts.com/discover/images/webp/200/{value}.webp"

    /// Per-category table hints: a curated column set (keeps the trailing
    /// action buttons on-screen), a renamed/derived "When" column, and which
    /// raw columns to drop. The widget falls back to auto columns without this.
    private static func widgetTableHints(for category: ToolCategory) -> [String: Any]? {
        switch category {
        case .reminders:
            return [
                // Leading check circle + trailing actions are added by the
                // widget; these are the visible data columns, in order.
                "columns": [
                    ["key": "when", "title": "When", "derive": "datetime",
                     "sourceKey": "dueDate", "allDayKey": "allDay"],
                    ["key": "title", "title": "Task", "primary": true],
                    ["key": "list", "title": "List"]
                ],
                // Explicitly dropped even if a curated set is ignored by an
                // older widget: id + completed (the check circle shows it).
                "hiddenColumns": ["id", "completed"]
            ]
        case .podcasts:
            return [
                // Episode-shaped rows (up-next / now / in-progress /
                // history). The widget drops curated columns whose source
                // fields are absent and falls back to auto columns when too
                // few survive, so podcast-shaped outputs (subscriptions,
                // playlists) aren't forced into this episode layout. A lone
                // episode object (pocketctl now) renders as a card instead
                // of a table. `sourceKey` arrays cover pocketctl's two
                // spellings of the podcast uuid (`podcastUuid` vs
                // `podcast`); the podcast name shows as a subtitle under
                // the episode title, not its own column.
                "columns": [
                    ["key": "artwork", "title": "", "derive": "artwork",
                     "sourceKey": ["podcastUuid", "podcast"], "altKey": "podcastTitle",
                     "urlTemplate": podcastArtworkURLTemplate],
                    ["key": "title", "title": "Episode", "primary": true,
                     "subtitleKey": "podcastTitle"],
                    ["key": "duration", "title": "Duration", "derive": "duration",
                     "sourceKey": "duration"],
                    ["key": "progress", "title": "Played", "derive": "progress",
                     "sourceKey": "playedUpTo", "totalKey": "duration",
                     "format": "seconds"],
                    ["key": "url", "title": "Link", "derive": "link",
                     "sourceKey": "url"]
                ],
                "hiddenColumns": ["uuid", "published", "fileType", "size",
                                  "podcastUuid", "podcast", "podcastTitle",
                                  "playingStatus", "episodeType",
                                  "episodeSeason", "isDeleted", "podcastSlug",
                                  "slug", "alternateEnclosures", "bookmarks"]
            ]
        case .habits:
            return [
                // Habit-shaped rows (habitctl today/journal/habits). The
                // leading check circle comes from the checkOff action
                // (`habitctl check <id>`, completed when status ==
                // "completed"); streak and goal read the nested habitctl
                // fields via dot-paths. Goal renders the count fraction
                // ("1/1", "3/8") — habit goals are reps, not seconds.
                "columns": [
                    ["key": "name", "title": "Habit", "primary": true],
                    ["key": "streak", "title": "Streak", "derive": "quantity",
                     "sourceKey": "currentStreak.length",
                     "unitKey": "currentStreak.unit"],
                    ["key": "goal", "title": "Goal", "derive": "progress",
                     "sourceKey": "progress.current",
                     "totalKey": "progress.target",
                     "unitKey": "progress.unit"]
                ],
                "hiddenColumns": ["id", "status", "color", "iconNamed",
                                  "timeOfDayIds", "type", "logInfo"]
            ]
        default:
            return nil
        }
    }

    /// Stable built-in catalogs address targets by id; preset-derived tools
    /// carry random ids, so catalog actions address "the shared flexible
    /// adapter for this executable" by basename. Unresolvable actions are
    /// dropped — the widget simply doesn't offer them.
    private func resolveActionTarget(_ action: ToolUIAction, in tools: [ToolDefinition]) -> ToolDefinition? {
        if let toolID = action.toolID {
            return tools.first { $0.id == toolID }
        }
        if let basename = action.targetExecutableBasename {
            return tools.first {
                $0.isGenericCLIAdapter &&
                URL(fileURLWithPath: $0.executablePath).lastPathComponent == basename
            }
        }
        return nil
    }

    private struct ToolsListCursor: Codable {
        let offset: Int
        let count: Int
    }

    private func toolsList(id: Any?, message: [String: Any]) -> Data {
        let tools = toolProvider()
        let totalCount = tools.count
        let params = message["params"] as? [String: Any]
        let rawCursor = params?["cursor"]
        let cursorString = rawCursor as? String

        // A present-but-non-string cursor is a malformed param, not "no cursor".
        if rawCursor != nil, !(rawCursor is NSNull), cursorString == nil {
            return jsonRPCError(id: id, code: -32602, message: "Invalid cursor.")
        }

        if let cursorString {
            guard let cursor = Self.decodeToolsListCursor(cursorString) else {
                return jsonRPCError(id: id, code: -32602, message: "Invalid cursor.")
            }
            let offset = min(cursor.offset, totalCount)
            let pageEnd = min(offset + Self.toolsListPageSize, totalCount)
            let pageTools = offset < totalCount ? Array(tools[offset..<pageEnd]) : []
            let nextCursor: String? = pageEnd < totalCount
                ? Self.encodeToolsListCursor(offset: pageEnd, count: totalCount)
                : nil
            return toolsListResult(id: id, tools: pageTools, nextCursor: nextCursor)
        }

        if totalCount <= Self.toolsListPageSize {
            return toolsListResult(id: id, tools: tools, nextCursor: nil)
        }

        let pageEnd = min(Self.toolsListPageSize, totalCount)
        let pageTools = Array(tools[0..<pageEnd])
        let nextCursor = Self.encodeToolsListCursor(offset: pageEnd, count: totalCount)
        return toolsListResult(id: id, tools: pageTools, nextCursor: nextCursor)
    }

    private func toolsListResult(id: Any?, tools: [ToolDefinition], nextCursor: String?) -> Data {
        let toolNames = MCPToolNameMapper.publicNames(for: tools)
        var result: [String: Any] = [
            "tools": tools.map { tool in
                toolJSON(tool, publicName: toolNames[tool.id] ?? MCPToolNameMapper.publicName(for: tool.id))
            }
        ]
        if let nextCursor {
            result["nextCursor"] = nextCursor
        }
        return jsonRPCResult(id: id, result: result)
    }

    private static func encodeToolsListCursor(offset: Int, count: Int) -> String {
        let payload = ToolsListCursor(offset: offset, count: count)
        let data = try! JSONEncoder().encode(payload)
        return data.base64EncodedString()
    }

    private static func decodeToolsListCursor(_ cursor: String) -> ToolsListCursor? {
        guard let data = Data(base64Encoded: cursor),
              let decoded = try? JSONDecoder().decode(ToolsListCursor.self, from: data),
              decoded.offset >= 0,
              decoded.count >= 0 else {
            return nil
        }
        return decoded
    }

    private func toolJSON(_ tool: ToolDefinition, publicName: String) -> [String: Any] {
        var json: [String: Any] = [
            "name": publicName,
            "title": tool.name,
            "description": toolDescription(for: tool),
            "inputSchema": inputSchema(for: tool),
            "outputSchema": outputSchema(),
            "annotations": annotations(for: tool)
        ]
        if widgetAvailable, Self.widgetEligible(category: tool.category) {
            // Both forms, like the official Apps SDK: the nested form is
            // normative, the flat form is the pre-GA key some hosts still
            // read. Belt and braces until the ecosystem settles.
            json["_meta"] = [
                Self.toolUIMetaKey: ["resourceUri": Self.widgetResourceURI],
                "ui/resourceUri": Self.widgetResourceURI
            ]
        }
        return json
    }

    private func toolDescription(for tool: ToolDefinition) -> String {
        // DL-10/R10: a harvested publisher summary is data, not guidance — it
        // composes last, quoted and provenance-labeled, after MacRemote's own
        // product-authored text. Curated, hand-written, and user-edited
        // summaries compose first, exactly as before.
        let harvestedFrame = harvestedSummaryFrame(for: tool)
        var parts = harvestedFrame == nil ? [tool.summary] : []

        if let bridge = tool.mcpBridge {
            parts.append("Bridged from MCP `\(bridge.serverName)` (\(bridge.serverURL)); forwards JSON to upstream `\(bridge.toolName)`. No shell or executable.")
        } else if let bridge = tool.mcpStdioBridge {
            parts.append("Bridged from MCP `\(bridge.serverName)` via `\(bridge.command)` (stdio JSON-RPC); forwards JSON to upstream `\(bridge.toolName)`. No shell.")
        } else if tool.isGenericCLIAdapter {
            parts.append("Pass exact argv items in `args` (optional `stdin`). No shell: absolute paths only; no `~`, `$HOME`, pipes, redirection, globs, substitution, or env assignments; one flag/value per argv item.")

            switch URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() {
            case "claude":
                parts.append("For Claude Code, prefer non-interactive MCP-safe calls using `--print` with `--output-format text`, `json`, or `stream-json`; pass the prompt as the final argv item or via `stdin` with `--input-format text`.")
                parts.append("Use explicit flags such as `--model`, `--permission-mode`, `--allowedTools`, `--disallowedTools`, `--add-dir`, `--mcp-config`, `--strict-mcp-config`, `--session-id`, and `--max-budget-usd` as separate argv items. Avoid bare interactive sessions, `auth login`, and `mcp login` unless the host Mac is attended.")
            case "codex":
                parts.append("For Codex, global options such as `--ask-for-approval` and `--sandbox` must appear before `exec`; options after `exec` are parsed by the exec subcommand.")
            case "remctl":
                parts.append("`upcoming N` starts today and extends N further days (`upcoming 1` → today and tomorrow; `upcoming 7` → today plus the next week).")
            default:
                break
            }
        }

        // remctl's `upcoming N` window starts today and spans N additional
        // days (N=1 → today and tomorrow). Models reliably guess N=2 for
        // "today and tomorrow" and get a third day, so spell the arithmetic
        // out on every tool whose argv template carries the command.
        if URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() == "remctl",
           tool.argumentPattern.contains("upcoming") {
            parts.append("The `days` window starts today and extends `days` further: days=1 returns today and tomorrow; days=7 returns today plus the next week.")
        }

        switch tool.capability {
        case .readOnly:
            parts.append("Read-only.")
        case .write:
            parts.append("Write-capable: requires host approval.")
        case .destructive:
            parts.append("Destructive or broad CLI access: requires host approval.")
        }

        if tool.permissionRequirements.contains(.fullDiskAccess) {
            parts.append("Requires Full Disk Access on the host Mac.")
        }
        let privacyRequirements = tool.permissionRequirements.filter { !$0.isFullDiskAccess }
        if !privacyRequirements.isEmpty {
            let names = privacyRequirements.map(\.title).joined(separator: ", ")
            parts.append("May require macOS privacy permission for \(names); macOS can attribute child CLI access to MacRemote as the host app.")
        }

        if let harvestedFrame {
            parts.append(harvestedFrame)
        }

        return parts.joined(separator: " ")
    }

    private func harvestedSummaryFrame(for tool: ToolDefinition) -> String? {
        guard let provenance = tool.provenance,
              provenance.summaryIsHarvested,
              !tool.summary.isEmpty else {
            return nil
        }
        let origin = provenance.summaryOrigin ?? provenance.sourceKind.displayName
        return "Publisher's description (\(origin), unverified): \"\(tool.summary)\""
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
                "truncatedStderr": ["type": "boolean"],
                "reason": [
                    "type": "string",
                    "enum": [
                        "ok",
                        "nonzero_exit",
                        "timeout",
                        "output_limit",
                        "killed",
                        "invalid_argument",
                        "not_approved",
                        "unavailable",
                        "internal_error"
                    ]
                ]
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
                "truncatedStderr",
                "reason"
            ],
            "additionalProperties": false
        ]
    }

    private func inputSchema(for tool: ToolDefinition) -> [String: Any] {
        if let schema = tool.mcpBridgeInputSchema?.anyValue as? [String: Any] {
            return schema
        }

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
            switch URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() {
            case "remctl":
                return "Exact RemCTL argv items. No shell is used. Use numeric reminder IDs from the `id` JSON field, not UUIDs from `deepLink`. Use `--private --url` for synced rich URL attachments, `edit --private --set-tags` / `--clear-tags` / `--remove-tag` for tag replacement or removal, plain `add -f` / `add --flag` for real flag writes on new reminders, and `edit --private --flagged` / `--no-flagged` for editing private flag state. Private section, list, group, smart-list, and template commands also require `--private`; ordinary due dates, recurrence, and EventKit alarms do not."
            case "pocketctl":
                return "Exact PocketCTL argv items. No shell is used. Prefer `--json`; use `--dry-run --json` before queue, playlist, bookmark, archive, progress, or played-state writes unless the user explicitly requested the write."
            case "habitctl":
                return "Exact HabitCTL argv items. No shell is used. Prefer `--json`; use `--dry-run --json` before creating, editing, deleting, checking, logging, archiving, or note writes when supported unless the user explicitly requested the write."
            default:
                return "Exact argv items to pass to the executable. No shell is used: do not include `~`, variables, pipes, redirection, globs, or combined command strings."
            }
        case "stdin":
            return "Optional standard input passed directly to the process."
        default:
            return parameter.title
        }
    }

    private func annotations(for tool: ToolDefinition) -> [String: Any] {
        var annotations = tool.mcpBridgeAnnotations?.anyValue as? [String: Any] ?? [:]
        annotations["title"] = tool.name
        annotations["readOnlyHint"] = tool.capability == .readOnly
        annotations["destructiveHint"] = tool.capability == .destructive
        if annotations["idempotentHint"] == nil {
            annotations["idempotentHint"] = tool.capability == .readOnly && !tool.isGenericCLIAdapter
        }
        if annotations["openWorldHint"] == nil {
            annotations["openWorldHint"] = tool.isGenericCLIAdapter || tool.capability != .readOnly || tool.isMCPBridge
        }
        return annotations
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
            let status: HTTPResponse.Status = oauthError.errorCode == "invalid_client" ? .unauthorized : .badRequest
            return jsonErrorResponse(
                status: status,
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

    private func singleLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func serverInfo(base: String) -> [String: Any] {
        var icons: [[String: Any]] = [
            [
                "src": "\(base)\(Self.connectorIcon128Path)",
                "mimeType": "image/png",
                "sizes": ["128x128"]
            ],
            [
                "src": connectorIconURL(base: base),
                "mimeType": "image/png",
                "sizes": ["512x512"]
            ]
        ]
        if let dataURI = Self.connectorIconDataURI {
            icons.append([
                "src": dataURI,
                "mimeType": "image/png",
                "sizes": ["64x64"]
            ])
        }
        return [
            "name": "MacRemote",
            "version": "0.1.0",
            "title": "MacRemote",
            "description": "Approved local CLI tools on this Mac, exposed over MCP.",
            "websiteUrl": base,
            "icons": icons
        ]
    }

    private func htmlResponse(_ html: String) -> Data {
        HTTPResponse(
            status: .ok,
            headers: [
                "Cache-Control": "public, max-age=3600",
                "Content-Type": "text/html; charset=utf-8"
            ],
            body: html
        ).data
    }

    // Shared web shell (spec §5.9): both public HTML pages render the same
    // centered mark + wordmark. Favicon markup must stay identical across pages —
    // Google's favicon fetcher (Claude.ai connector icons) parses it.
    private static let webShellStyle = """
        :root { color-scheme: light dark; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
          display: grid; place-items: center;
          min-height: 92vh; margin: 0; padding: 0 24px;
          color: #1d1d1f; background: #f5f5f7;
          text-align: center;
          -webkit-font-smoothing: antialiased;
        }
        @media (prefers-color-scheme: dark) {
          body { color: #f5f5f7; background: #1d1d1f; }
        }
        img.mark { width: 96px; height: 96px; border-radius: 22px; }
        h1 { font-size: 1.5em; font-weight: 600; margin: 0.7em 0 0.3em; }
        p { margin: 0.4em auto; max-width: 34em; line-height: 1.45; }
        footer { margin-top: 2.4em; font-size: 0.85em; opacity: 0.55; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: 0.95em; }
    """

    private func webShellPage(bodyContent: String, extraStyle: String = "", script: String = "") -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>MacRemote</title>
          <link rel="icon" href="/favicon.ico" sizes="any">
          <link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
          <link rel="apple-touch-icon" href="/macremote-icon.png">
          <style>
        \(Self.webShellStyle)
        \(extraStyle)
          </style>
        </head>
        <body>
          <main>
            <img class="mark" src="/macremote-icon-128.png" alt="MacRemote">
            <h1>MacRemote</h1>
        \(bodyContent)
          </main>
        \(script)
        </body>
        </html>
        """
    }

    private func landingPageHTML() -> String {
        webShellPage(bodyContent: """
            <p>This Mac shares approved tools with apps its owner authorizes. Connections require sign-in and the owner&rsquo;s approval.</p>
            <footer>MCP endpoint: <code>/mcp</code></footer>
        """)
    }

    private func staticIconResponse(fileName: String, contentType: String) -> Data {
        guard let data = Self.staticResourceData(fileName: fileName) else {
            return jsonErrorResponse(
                status: .notFound,
                error: "icon_not_found",
                description: "\(fileName) is missing."
            )
        }

        return HTTPResponse(
            status: .ok,
            headers: [
                "Cache-Control": "public, max-age=86400",
                "Content-Type": contentType
            ],
            bodyData: data
        ).data
    }

    // Internal (not private): CloudflareService reuses the same bundled
    // favicon assets for the apex-favicon Worker.
    static func staticResourceData(fileName: String) -> Data? {
        let fileManager = FileManager.default
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = URL(fileURLWithPath: fileName)
        let resourceName = url.deletingPathExtension().lastPathComponent
        let resourceExtension = url.pathExtension.isEmpty ? nil : url.pathExtension

        let candidateURLs = [
            Bundle.main.resourceURL?.appendingPathComponent(fileName),
            Bundle.main.url(forResource: resourceName, withExtension: resourceExtension),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources")
                .appendingPathComponent(fileName),
            sourceRoot
                .appendingPathComponent("Resources")
                .appendingPathComponent(fileName)
        ].compactMap { $0 }

        for url in candidateURLs where fileManager.fileExists(atPath: url.path) {
            return try? Data(contentsOf: url)
        }
        return nil
    }

    private func authorizationPageHTML(requestID: UUID) -> String {
        let waitingStyle = """
            .dots span {
              animation: dot-pulse 1.4s infinite ease-in-out;
              opacity: 0.2;
            }
            .dots span:nth-child(2) { animation-delay: 0.2s; }
            .dots span:nth-child(3) { animation-delay: 0.4s; }
            @keyframes dot-pulse {
              0%, 80%, 100% { opacity: 0.2; }
              40% { opacity: 1; }
            }
            @media (prefers-reduced-motion: reduce) {
              .dots span { animation: none; opacity: 0.6; }
            }
        """
        let script = """
          <script>
            const statusLine = document.getElementById('status');
            function setLine(text) { statusLine.textContent = text; }
            async function poll() {
              try {
                const response = await fetch('/authorize/status?request_id=\(requestID.uuidString)');
                const status = await response.json();
                if (status.status === 'approved' && status.redirect_uri) {
                  setLine('Approved \\u2014 redirecting\\u2026');
                  window.location.href = status.redirect_uri;
                  return;
                }
                if (status.status === 'denied' || status.status === 'expired' || status.status === 'not_found') {
                  setLine(status.status === 'denied'
                    ? 'Denied on the owner\\u2019s Mac.'
                    : 'This request expired. Try connecting again.');
                  if (status.redirect_uri) {
                    setTimeout(() => { window.location.href = status.redirect_uri; }, 1500);
                  }
                  return;
                }
              } catch (error) {}
              setTimeout(poll, 1200);
            }
            poll();
          </script>
        """
        return webShellPage(
            bodyContent: """
                <p id="status">Waiting for approval on the owner&rsquo;s Mac<span class="dots"><span>.</span><span>.</span><span>.</span></span></p>
                <footer>Request ID: <code>\(requestID.uuidString.htmlEscaped)</code></footer>
            """,
            extraStyle: waitingStyle,
            script: script
        )
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

/// One-shot rendezvous between NWListener's state queue and the thread
/// waiting in `start()`: first resolution wins, later state changes are
/// ignored (a listener can go `.ready` and later `.cancelled`).
private final class ListenerReadyGate: @unchecked Sendable {
    enum Outcome {
        case ready
        case failed(NWError)
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Outcome?

    func resolve(_ outcome: Outcome) {
        lock.lock()
        let isFirst = self.outcome == nil
        if isFirst { self.outcome = outcome }
        lock.unlock()
        if isFirst { semaphore.signal() }
    }

    func awaitOutcome(timeout: TimeInterval) -> Outcome? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return outcome
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
    case artifact

    var displayName: String {
        switch self {
        case .health: "health"
        case .metadata: "metadata"
        case .registration: "registration"
        case .authorization: "authorization"
        case .authorizationStatus: "authorization status"
        case .token: "token"
        case .unauthorizedMCP: "unauthorized MCP"
        case .artifact: "artifact"
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
        case .artifact:
            PublicRateLimitRule(maxRequests: 30, windowSeconds: 60)
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
        let trimmed = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return nil
        }

        let scheme = String(trimmed[..<separatorIndex])
        guard scheme.caseInsensitiveCompare("Bearer") == .orderedSame else {
            return nil
        }

        let tokenStart = trimmed.index(after: separatorIndex)
        let token = trimmed[tokenStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    var basicAuthorizationCredentials: (clientID: String, clientSecret: String)? {
        guard let authorization = headers["authorization"] else { return nil }
        let trimmed = authorization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let separatorIndex = trimmed.firstIndex(where: { $0.isWhitespace }) else {
            return nil
        }

        let scheme = String(trimmed[..<separatorIndex])
        guard scheme.caseInsensitiveCompare("Basic") == .orderedSame else {
            return nil
        }

        let credentialsStart = trimmed.index(after: separatorIndex)
        let encodedCredentials = trimmed[credentialsStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encodedCredentials),
              let credentials = String(data: data, encoding: .utf8) else {
            return nil
        }

        let username: String
        let password: String
        if let separator = credentials.firstIndex(of: ":") {
            username = String(credentials[..<separator])
            password = String(credentials[credentials.index(after: separator)...])
        } else {
            username = credentials
            password = ""
        }

        let clientID = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return clientID.isEmpty ? nil : (clientID, password)
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

    func tokenFormURLEncodedBody() throws -> [String: String] {
        var form = formURLEncodedBody()
        guard let basicCredentials = basicAuthorizationCredentials else {
            return form
        }

        let formClientID = form["client_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let formClientID, !formClientID.isEmpty, formClientID != basicCredentials.clientID {
            throw OAuthError.invalidRequest("Conflicting client_id credentials.")
        }
        let formClientSecret = form["client_secret"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let formClientSecret, !formClientSecret.isEmpty, formClientSecret != basicCredentials.clientSecret {
            throw OAuthError.invalidRequest("Conflicting client_secret credentials.")
        }

        form["client_id"] = basicCredentials.clientID
        form["client_secret"] = basicCredentials.clientSecret
        return form
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
        if responseHeaders["Content-Length"] == nil {
            responseHeaders["Content-Length"] = String(bodyData.count)
        }
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
