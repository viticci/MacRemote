import CoreFoundation
import Darwin
import Foundation
import Network

struct MCPRequestProtocolContext: Sendable {
    enum Era: Sendable {
        case modern
        case legacy
    }

    let era: Era
    let version: String
    let method: String
    let baseURL: String
    let clientCapabilities: JSONValue

    var isModern: Bool {
        era == .modern
    }
}

private final class LegacyMCPClientCapabilityStore: @unchecked Sendable {
    private let lock = NSLock()
    private var capabilitiesByClientID = [String: JSONValue]()

    func capabilities(for clientID: String) -> JSONValue {
        lock.withLock {
            capabilitiesByClientID[clientID] ?? .object([:])
        }
    }

    func update(_ capabilities: JSONValue, for clientID: String) {
        lock.withLock {
            capabilitiesByClientID[clientID] = capabilities
        }
    }
}

/// Icons an app attached to its own `clientInfo`, kept per client for the life
/// of the process — same shape and lifetime as the capability store above.
///
/// In memory only, deliberately: these are bytes a client chose, so writing them
/// to disk would turn a cosmetic nicety into persistent attacker-controlled
/// state. Losing them on relaunch costs nothing — the next handshake resends.
private final class MCPClientSuppliedIconStore: @unchecked Sendable {
    private let lock = NSLock()
    private var iconsByClientID = [String: ClientSuppliedIconSet]()
    private var reportedRejectionClientIDs = Set<String>()
    private var fingerprintsByClientID = [String: Int]()

    /// Write-only from the server's side: the UI reads its copy from `AppModel`,
    /// which is kept current by `clientSuppliedIconsChanged`. What is held here
    /// is the last published value, so an unchanged set is not republished.
    ///
    /// `true` when this actually changed what is stored.
    func update(_ icons: ClientSuppliedIconSet, for clientID: String) -> Bool {
        lock.withLock {
            guard iconsByClientID[clientID] != icons else { return false }
            iconsByClientID[clientID] = icons
            return true
        }
    }

    /// A refused icon is worth saying once. Clients send `clientInfo` on every
    /// request, so logging each refusal would bury the log under one client's
    /// bad `src`.
    func shouldReportRejection(for clientID: String) -> Bool {
        lock.withLock {
            reportedRejectionClientIDs.insert(clientID).inserted
        }
    }

    /// Clients repeat `clientInfo` on every request, and base64-decoding up to a
    /// megabyte per call to arrive at the same answer would be a real cost on the
    /// hot path. A fingerprint of the raw `src` strings short-circuits that. A
    /// collision would mean a changed icon is not picked up, which is cosmetic.
    func isFingerprintUnchanged(_ fingerprint: Int, for clientID: String) -> Bool {
        lock.withLock {
            guard fingerprintsByClientID[clientID] == fingerprint else {
                fingerprintsByClientID[clientID] = fingerprint
                return false
            }
            return true
        }
    }
}

/// `tools/call` requests still running, by the calling app's client ID and the
/// request's JSON-RPC id, so the app's `notifications/cancelled` can stop its
/// own call. A notice from any other app finds nothing.
private final class InFlightToolCallStore: @unchecked Sendable {
    private struct Key: Hashable {
        let clientID: String
        let requestID: String
    }

    private let lock = NSLock()
    private var calls = [Key: (token: UUID, task: Task<Data, Never>)]()

    /// Waits for `task`, which can be cancelled by its id while it runs.
    func track(_ task: Task<Data, Never>, clientID: String, requestID: Any?) async -> Data {
        guard let requestID = Self.requestKey(requestID) else { return await task.value }
        let key = Key(clientID: clientID, requestID: requestID)
        let token = UUID()
        lock.withLock { calls[key] = (token, task) }
        defer {
            lock.withLock {
                if calls[key]?.token == token { calls[key] = nil }
            }
        }
        return await task.value
    }

    func cancel(clientID: String, requestID: Any?) {
        guard let requestID = Self.requestKey(requestID) else { return }
        let task = lock.withLock { calls[Key(clientID: clientID, requestID: requestID)]?.task }
        task?.cancel()
    }

    /// A JSON-RPC id is a string or a number, and `"1"` is not `1`.
    private static func requestKey(_ id: Any?) -> String? {
        switch id {
        case let string as String:
            return "s:" + string
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return "n:" + number.stringValue
        default:
            return nil
        }
    }
}

enum LocalMCPServerEvent: Sendable {
    case log(AppLogEntry.Level, String)
    case approvalsChanged([ApprovalRequest])
    case clientsChanged([ConnectedClient])
    /// An app supplied its own icons in an MCP handshake. Presentation only —
    /// see `Models/ClientSuppliedIcon.swift`.
    case clientSuppliedIconsChanged(clientID: String, icons: ClientSuppliedIconSet)
}

final class LocalMCPServer: @unchecked Sendable {
    typealias EventHandler = @Sendable (LocalMCPServerEvent) -> Void
    typealias ToolProvider = @Sendable () -> [ToolDefinition]
    /// Returns the host name of the public link while it is up, or nil. Asked
    /// on every request, so it must be cheap and safe to call from any thread.
    typealias PublicHostProvider = @Sendable () -> String?
    /// Returns the owner's result-card choice (SPEC D77). Asked once per
    /// tools/list and once per tool result, from any thread.
    typealias ResultCardPreferencesProvider = @Sendable () -> ResultCardPreferences

    private static let modernProtocolVersion = "2026-07-28"
    private static let latestLegacyProtocolVersion = "2025-11-25"
    private static let legacyProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private static let modernProtocolVersions = [modernProtocolVersion]
    private static let protocolVersionHeader = "MCP-Protocol-Version"
    private static let parameterHeaderPrefix = "Mcp-Param-"
    private static let serverInfoMetaKey = "io.modelcontextprotocol/serverInfo"
    private static let clientInfoMetaKey = "io.modelcontextprotocol/clientInfo"
    private static let modernCacheableMethods: Set<String> = [
        "server/discover",
        "tools/list",
        "prompts/list",
        "resources/list",
        "resources/read",
        "resources/templates/list"
    ]
    @TaskLocal private static var activeProtocolContext: MCPRequestProtocolContext?
    private static let trustedPublicClientOrigins: Set<String> = [
        "https://chatgpt.com",
        "https://chat.openai.com"
    ]
    private static let serverInstructions =
        "MacRemote exposes only tools the person shared from this Mac. Follow each description and typed schema exactly. Prefer a dedicated tool; use a Flexible Command only when no dedicated tool fits. Read-only tools may run directly; write and destructive tools, and every Flexible Command, require approval on the Mac unless Always Allowed. Tools marked every-call ask by default and are Always Allowed only after an extra confirmation, so treat an approval prompt as likely. Flexible Commands accept exact argv items, never shell syntax. Use supported batch inputs for several items. Reuse resolved list and section identifiers within the request. A successful write result is the receipt; do not read it back unless the result is incomplete, uncertain, or the user asks to see the updated collection. Do not retry a denial or non-idempotent write unless the user asks."
    /// The fixed guidance plus how far the tools that run without asking can
    /// reach right now, so a model knows the boundary before its first call
    /// instead of finding it by failing.
    private static var currentInstructions: String {
        serverInstructions + " Tools that run without asking can read files in: "
            + FileTransferPathPolicy().allowedFoldersDescription
            + ". Keys, keychains, and saved credentials are never reachable. To find a file, use filesystem_find when it is shared."
    }
    private static let connectorIconPath = "/macremote-icon.png"
    private static let connectorIconFileName = "MacRemoteConnectorIcon.png"
    private static let connectorIcon128Path = "/macremote-icon-128.png"
    private static let connectorIcon128FileName = "MacRemoteConnectorIcon128.png"
    /// 256 px and under 10 KB: the largest icon ChatGPT's "Add custom MCP
    /// server" form accepts as an upload.
    private static let connectorIcon256Path = "/macremote-icon-256.png"
    private static let connectorIcon256FileName = "MacRemoteConnectorIcon256.png"
    private static let connectorIcon64FileName = "MacRemoteConnectorIcon64.png"
    private static let faviconICOPath = "/favicon.ico"
    private static let faviconICOFileName = "Favicon.ico"
    private static let faviconPNGPath = "/favicon.png"
    private static let faviconPNGFileName = "Favicon.png"
    private static let artifactPathPrefix = "/artifact/"

    // Claude.ai resolves connector icons through Google's favicon service today and may
    // adopt SEP-973 serverInfo.icons later; the data: entry needs no fetch at all.
    // Built once because it embeds ~9 KB of base64.
    private static let connectorIconDataURI: String? = {
        guard let data = staticResourceData(fileName: connectorIcon64FileName) else { return nil }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }()

    private let queue = DispatchQueue(label: "com.macremote.local-server")
    private let lifecycleLock = NSLock()
    private var listener: NWListener?
    private var activePort: UInt16?
    private var shutdownTask: Task<Void, Never>?
    private let instanceID: String
    private let toolProvider: ToolProvider
    private let publicHost: PublicHostProvider
    private let resultCardPreferences: ResultCardPreferencesProvider
    private let authCoordinator: OAuthCoordinator
    private let legacyClientCapabilityStore = LegacyMCPClientCapabilityStore()
    private let clientSuppliedIconStore = MCPClientSuppliedIconStore()
    private let inFlightToolCalls = InFlightToolCallStore()
    private let toolCallApprovalCoordinator: ToolCallApprovalCoordinator?
    private let toolExecutor: any ToolExecuting
    private let clientToolPermissionStore: ClientToolPermissionStore?
    private let approvalDecisionLog: ApprovalDecisionLog?
    private let artifactStore: ArtifactStore
    private let eventHandler: EventHandler?
    private let publicRateLimiter = PublicRequestRateLimiter()
    private let toolExecutionLimiter: ToolExecutionLimiter
    private let catalogSnapshotCache = CatalogSnapshotCache()

    init(
        instanceID: String,
        tools: [ToolDefinition],
        publicHost: @escaping PublicHostProvider = { nil },
        resultCardPreferences: @escaping ResultCardPreferencesProvider = { .everyTool },
        authCoordinator: OAuthCoordinator,
        toolCallApprovalCoordinator: ToolCallApprovalCoordinator? = nil,
        toolExecutor: any ToolExecuting,
        clientToolPermissionStore: ClientToolPermissionStore? = nil,
        approvalDecisionLog: ApprovalDecisionLog? = nil,
        artifactStore: ArtifactStore = ArtifactStore(),
        toolExecutionLimiter: ToolExecutionLimiter? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.toolProvider = { tools }
        self.publicHost = publicHost
        self.resultCardPreferences = resultCardPreferences
        self.authCoordinator = authCoordinator
        self.toolCallApprovalCoordinator = toolCallApprovalCoordinator
        self.toolExecutor = toolExecutor
        self.clientToolPermissionStore = clientToolPermissionStore
        self.approvalDecisionLog = approvalDecisionLog
        self.artifactStore = artifactStore
        self.toolExecutionLimiter = toolExecutionLimiter ?? ToolExecutionLimiter()
        self.eventHandler = eventHandler
    }

    init(
        instanceID: String,
        toolProvider: @escaping ToolProvider,
        publicHost: @escaping PublicHostProvider = { nil },
        resultCardPreferences: @escaping ResultCardPreferencesProvider = { .everyTool },
        authCoordinator: OAuthCoordinator,
        toolCallApprovalCoordinator: ToolCallApprovalCoordinator? = nil,
        toolExecutor: any ToolExecuting,
        clientToolPermissionStore: ClientToolPermissionStore? = nil,
        approvalDecisionLog: ApprovalDecisionLog? = nil,
        artifactStore: ArtifactStore = ArtifactStore(),
        toolExecutionLimiter: ToolExecutionLimiter? = nil,
        eventHandler: EventHandler? = nil
    ) {
        self.instanceID = instanceID
        self.toolProvider = toolProvider
        self.publicHost = publicHost
        self.resultCardPreferences = resultCardPreferences
        self.authCoordinator = authCoordinator
        self.toolCallApprovalCoordinator = toolCallApprovalCoordinator
        self.toolExecutor = toolExecutor
        self.clientToolPermissionStore = clientToolPermissionStore
        self.approvalDecisionLog = approvalDecisionLog
        self.artifactStore = artifactStore
        self.toolExecutionLimiter = toolExecutionLimiter ?? ToolExecutionLimiter()
        self.eventHandler = eventHandler
    }

    /// Starts listening on this Mac only and returns the port. A deployed
    /// Your Domain names the port it was deployed with in Cloudflare's copy of
    /// its settings, so that port is tried first when it is free; otherwise,
    /// and by default, the port is a random free one. A preferred port
    /// outside the range the server picks from is ignored: it comes from
    /// saved preferences, and no saved value may move the server elsewhere.
    func start(preferredPort: UInt16? = nil) throws -> UInt16 {
        // availablePort() probes with a throwaway socket that closes before
        // NWListener binds, so another process can win the port in between
        // (TOCTOU) — and NWListener reports EADDRINUSE only asynchronously,
        // which used to leave a silently dead listener behind (flaky under
        // parallel test startup). Verify each bind and retry on a fresh port.
        var lastError: Error = LocalMCPServerError.portUnavailable
        for attempt in 0..<8 {
            let selectedPort: UInt16
            if attempt == 0, let preferredPort,
               Self.portRange.contains(preferredPort), Self.canBind(port: preferredPort) {
                selectedPort = preferredPort
            } else {
                selectedPort = try Self.availablePort()
            }
            guard let nwPort = NWEndpoint.Port(rawValue: selectedPort) else {
                throw LocalMCPServerError.portUnavailable
            }

            let listener = try NWListener(
                using: Self.loopbackListenerParameters(on: nwPort)
            )
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

    /// Network.framework otherwise listens on every interface. Keep this
    /// internal so the loopback-only product boundary has a direct regression
    /// test instead of relying on the advertised URL or a preflight socket.
    static func loopbackListenerParameters(on port: NWEndpoint.Port) -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1",
            port: port
        )
        return parameters
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

    @discardableResult
    func stop() -> Task<Void, Never> {
        listener?.cancel()
        listener = nil
        activePort = nil
        return lifecycleLock.withLock {
            if let shutdownTask {
                return shutdownTask
            }
            let artifactStore = artifactStore
            let task = Task.detached {
                artifactStore.purgeAll()
            }
            shutdownTask = task
            return task
        }
    }

    func approveAuthorizationRequest(id: UUID) -> Bool {
        authCoordinator.approve(requestID: id)
    }

    func denyAuthorizationRequest(id: UUID) -> Bool {
        authCoordinator.deny(requestID: id)
    }

    /// Connections open at once. Each one is a file descriptor, and a process
    /// has a few hundred; idle sockets must not be able to use them all.
    static let maximumConnections = 96
    /// How long a client has to deliver one complete request.
    static let requestReadTimeout: TimeInterval = 30

    /// Per-connection bookkeeping. Touched only on `queue`, which is what
    /// makes it safe to hand to the queue's callbacks.
    private final class ConnectionState: @unchecked Sendable {
        var requestReceived = false
    }
    private var openConnections = 0

    private func handle(_ connection: NWConnection) {
        // Runs on `queue`, as do the state and receive callbacks below.
        guard openConnections < Self.maximumConnections else {
            connection.cancel()
            return
        }
        openConnections += 1
        let state = ConnectionState()
        connection.stateUpdateHandler = { [weak self] newState in
            switch newState {
            case .cancelled, .failed:
                connection.stateUpdateHandler = nil
                self?.openConnections -= 1
            default:
                break
            }
        }
        connection.start(queue: queue)
        // A client that connects and sends nothing, or trickles a request,
        // would otherwise hold its connection forever.
        queue.asyncAfter(deadline: .now() + Self.requestReadTimeout) {
            if !state.requestReceived {
                connection.cancel()
            }
        }
        receiveRequest(on: connection, buffer: Data(), state: state)
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data, state: ConnectionState) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, peerClosed, error in
            guard let self else {
                connection.cancel()
                return
            }
            guard error == nil else {
                connection.cancel()
                return
            }

            var nextBuffer = buffer
            if let data {
                nextBuffer.append(data)
            }

            guard nextBuffer.count <= HTTPRequestFraming.maximumByteCount else {
                connection.send(
                    content: HTTPResponse(status: .badRequest, body: "{\"error\":\"request_too_large\"}").data,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            }

            switch HTTPRequestFraming.state(data: nextBuffer) {
            case .incomplete:
                guard !peerClosed else {
                    connection.send(
                        content: HTTPResponse(status: .badRequest, body: "{\"error\":\"incomplete_request\"}").data,
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                    return
                }
                self.receiveRequest(on: connection, buffer: nextBuffer, state: state)
                return
            case .invalid:
                connection.send(
                    content: HTTPResponse(status: .badRequest, body: "{\"error\":\"invalid_request_framing\"}").data,
                    completion: .contentProcessed { _ in connection.cancel() }
                )
                return
            case .complete:
                break
            }

            state.requestReceived = true
            guard let request = HTTPRequest(data: nextBuffer) else {
                connection.cancel()
                return
            }
            let work = Task {
                var fileBody: FileBody?
                let response = await self.response(for: request, fileBody: &fileBody)
                let responseWithCORS = self.responseByAddingCORSHeaders(response, for: request)
                Self.send(responseWithCORS, followedBy: fileBody, on: connection)
            }
            // One request per connection, so anything further here means the
            // client went away. Nobody is waiting for the answer: cancel the
            // work, so an abandoned call does not stay approvable on the Mac
            // or run with its result going nowhere.
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, peerClosed, error in
                if peerClosed || error != nil {
                    work.cancel()
                }
            }
        }
    }

    /// A staged download that follows a response's headers. It is sent in
    /// pieces so that a 512 MiB file never sits in memory whole. Touched only
    /// on the connection's queue once it is handed to `send`.
    private final class FileBody: @unchecked Sendable {
        static let pieceByteCount = 256 * 1024

        let handle: FileHandle
        var remainingByteCount: Int

        init(handle: FileHandle, byteCount: Int) {
            self.handle = handle
            self.remainingByteCount = byteCount
        }
    }

    /// Sends a response, then the file that follows its headers if there is
    /// one, and closes the connection.
    private static func send(_ response: Data, followedBy fileBody: FileBody?, on connection: NWConnection) {
        connection.send(content: response, completion: .contentProcessed { error in
            guard let fileBody, error == nil else {
                try? fileBody?.handle.close()
                connection.cancel()
                return
            }
            sendNextPiece(of: fileBody, on: connection)
        })
    }

    /// Reads one piece of the file and sends it. The next piece is read only
    /// after the network took this one, so a slow reader holds one piece in
    /// memory, not the rest of the file. Never sends more than the length the
    /// headers promised; a short or failed read closes the connection early,
    /// which the client sees as an incomplete download.
    private static func sendNextPiece(of fileBody: FileBody, on connection: NWConnection) {
        let byteCount = min(fileBody.remainingByteCount, FileBody.pieceByteCount)
        guard byteCount > 0,
              let piece = try? fileBody.handle.read(upToCount: byteCount),
              !piece.isEmpty else {
            try? fileBody.handle.close()
            connection.cancel()
            return
        }
        fileBody.remainingByteCount -= piece.count
        connection.send(content: piece, completion: .contentProcessed { error in
            guard error == nil else {
                try? fileBody.handle.close()
                connection.cancel()
                return
            }
            sendNextPiece(of: fileBody, on: connection)
        })
    }

    /// Answers one request. A download leaves its file in `fileBody` instead
    /// of in the returned bytes, which then hold only the headers.
    private func response(for request: HTTPRequest, fileBody: inout FileBody?) async -> Data {
        guard let activePort else {
            return HTTPResponse(status: .internalServerError, body: "Server not ready").data
        }

        guard let base = servedBaseURL(for: request, activePort: activePort) else {
            return jsonErrorResponse(
                status: .misdirectedRequest,
                error: "misdirected_request",
                description: "This server does not serve the host named in the request."
            )
        }
        let isPublicRequest = base != localBaseURL(activePort: activePort)
        let mcpResourceURL = mcpResourceURL(base: base, isPublicRequest: isPublicRequest)
        guard isAllowedOrigin(for: request, base: base, activePort: activePort) else {
            return jsonErrorResponse(
                status: .forbidden,
                error: "forbidden_origin",
                description: "Invalid Origin header."
            )
        }

        if request.method == "OPTIONS",
           let response = preflightResponse(for: request) {
            return response
        }

        if let group = publicRateLimitGroup(for: request, isPublicRequest: isPublicRequest),
           let response = publicRateLimitResponseIfNeeded(for: group, request: request) {
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
        if request.method == "GET", request.path == Self.connectorIcon256Path {
            return staticIconResponse(fileName: Self.connectorIcon256FileName, contentType: "image/png")
        }

        if request.method == "GET", request.path == Self.faviconICOPath {
            return staticIconResponse(fileName: Self.faviconICOFileName, contentType: "image/x-icon")
        }

        if request.method == "GET", request.path == Self.faviconPNGPath {
            return staticIconResponse(fileName: Self.faviconPNGFileName, contentType: "image/png")
        }

        if request.method == "GET" || request.method == "HEAD",
           let token = artifactToken(from: request.path) {
            return artifactResponse(for: request, token: token, fileBody: &fileBody)
        }

        let allowAuthenticatedMCPAlias = isPublicRequest || request.bearerToken != nil
        if isMCPPath(
            request.path,
            allowLegacyPath: allowsLegacyMCPPath(base: base, activePort: activePort) || allowAuthenticatedMCPAlias
        ) {
            guard let client = authenticatedMCPClient(
                for: request,
                base: base
            ) else {
                return unauthorizedMCPResponse(
                    for: request,
                    base: base,
                    isPublicRequest: isPublicRequest
                )
            }

            switch request.method {
            case "POST":
                return await mcp(request: request, base: base, client: client)
            case "GET", "DELETE":
                return methodNotAllowedForMCP()
            default:
                return methodNotAllowedForMCP()
            }
        }

        switch (request.method, request.path) {
        case ("GET", "/"):
            // Google's favicon fetcher parses this page for <link rel="icon">; it is also
            // what a person sees when they open the bare public URL in a browser.
            return htmlResponse(landingPageHTML())
        case ("GET", "/health"):
            return jsonResponse(healthPayload(base: base, activePort: activePort))
        case ("GET", _) where isAuthorizationServerMetadataPath(request.path):
            return jsonResponse(
                authorizationServerMetadata(base: base),
                headers: ["Cache-Control": "no-store"]
            )
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
            // This compatibility metadata predates modern `server/discover`.
            // Keep it in the legacy era so bootstrap clients do not select a
            // protocol whose per-request envelope they cannot produce.
            "mcp_protocol_version": Self.latestLegacyProtocolVersion,
            "mcp_protocol_versions_supported": Self.legacyProtocolVersions
        ]
    }

    private func authorizationServerMetadata(base: String) -> [String: Any] {
        var metadata: [String: Any] = [
            "issuer": base,
            "authorization_endpoint": "\(base)/authorize",
            "token_endpoint": "\(base)/token",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": authCoordinator.tokenEndpointAuthMethodsSupported(),
            "scopes_supported": ["mcp:tools"],
            "resource_indicators_supported": true,
            "authorization_response_iss_parameter_supported": true
        ]
        if authCoordinator.supportsDynamicClientRegistration() {
            metadata["registration_endpoint"] = "\(base)/register"
        }
        return metadata
    }

    private func isProtectedResourceMetadataPath(_ path: String) -> Bool {
        path == "/.well-known/oauth-protected-resource" ||
            path == "/.well-known/oauth-protected-resource/mcp" ||
            path == "/.well-known/oauth-protected-resource\(mcpEndpointPath)"
    }

    private func isAuthorizationServerMetadataPath(_ path: String) -> Bool {
        path == "/.well-known/oauth-authorization-server" ||
            path == "/.well-known/oauth-authorization-server/mcp"
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

    private func preflightResponse(for request: HTTPRequest) -> Data? {
        let allowedMethods: String
        switch request.path {
        case "/mcp", mcpEndpointPath:
            allowedMethods = "POST, GET, DELETE, OPTIONS"
        case "/.well-known/oauth-protected-resource",
             "/.well-known/oauth-protected-resource/mcp",
             "/.well-known/oauth-protected-resource\(mcpEndpointPath)",
             "/.well-known/oauth-authorization-server",
             "/.well-known/oauth-authorization-server/mcp",
             "/authorize",
             "/authorize/status":
            allowedMethods = "GET, OPTIONS"
        case "/register", "/token":
            allowedMethods = "POST, OPTIONS"
        default:
            return nil
        }

        var allowedHeaders = [
            "authorization",
            "content-type",
            "mcp-method",
            "mcp-name",
            "mcp-protocol-version",
            "mcp-session-id"
        ]
        if request.path == "/mcp" || request.path == mcpEndpointPath {
            allowedHeaders.append(contentsOf: request.requestedCORSHeaders.filter {
                $0.lowercased().hasPrefix(Self.parameterHeaderPrefix.lowercased())
                    && Self.isHTTPFieldName($0)
            })
        }

        var responseHeaders = [
            "Access-Control-Allow-Headers":
                Array(Set(allowedHeaders.map { $0.lowercased() })).sorted().joined(separator: ", "),
            "Access-Control-Allow-Methods": allowedMethods,
            "Access-Control-Max-Age": "600",
            "Allow": allowedMethods
        ]
        if request.requestedCORSHeaders.contains(where: {
            $0.lowercased().hasPrefix(Self.parameterHeaderPrefix.lowercased())
        }) {
            responseHeaders["Vary"] = "Access-Control-Request-Headers"
        }
        return HTTPResponse(
            status: .noContent,
            headers: responseHeaders,
            body: ""
        ).data
    }

    /// The base URL of the address this request was sent to, or nil when the
    /// request names a host this server does not serve.
    ///
    /// A web page can point its own host name at 127.0.0.1 (DNS rebinding) and
    /// then reach this port under that name. So only two kinds of Host are
    /// served: this Mac's own loopback address with the server's port, and the
    /// public link's host as the app reports it. The URL is built from those
    /// known values, never from a header, because it becomes the sign-in
    /// issuer that access tokens are bound to.
    private func servedBaseURL(for request: HTTPRequest, activePort: UInt16) -> String? {
        guard let host = request.hostHeader?.lowercased() else {
            return nil
        }
        if ["127.0.0.1:\(activePort)", "localhost:\(activePort)", "[::1]:\(activePort)"].contains(host) {
            return localBaseURL(activePort: activePort)
        }
        // Cloudflare's helper passes the caller's Host through unchanged, so
        // a request from the public link names the public host here.
        if let publicHost = publicHost()?.lowercased(), !publicHost.isEmpty,
           host == publicHost || host == "\(publicHost):443" {
            return "https://\(publicHost)"
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

        var allowedOrigins: Set<String> = [
            base,
            "http://127.0.0.1:\(activePort)",
            "http://localhost:\(activePort)"
        ]
        if base != localBaseURL(activePort: activePort) {
            allowedOrigins.formUnion(Self.trustedPublicClientOrigins)
        }
        return allowedOrigins.contains(normalizedOrigin)
    }

    private func responseByAddingCORSHeaders(_ response: Data, for request: HTTPRequest) -> Data {
        guard let activePort,
              let origin = request.originHeader,
              let normalizedOrigin = Self.normalizedOrigin(origin),
              let base = servedBaseURL(for: request, activePort: activePort),
              isAllowedOrigin(for: request, base: base, activePort: activePort) else {
            return response
        }

        return Self.response(
            response,
            addingHeaders: [
                "Access-Control-Allow-Origin": normalizedOrigin,
                "Access-Control-Expose-Headers": "WWW-Authenticate, MCP-Session-Id, MCP-Protocol-Version",
                "Vary": "Origin"
            ]
        )
    }

    private static func response(_ response: Data, addingHeaders headers: [String: String]) -> Data {
        let separator = Data("\r\n\r\n".utf8)
        guard let separatorRange = response.range(of: separator) else {
            return response
        }

        var head = Data(response[..<separatorRange.lowerBound])
        for key in headers.keys.sorted() {
            guard let value = headers[key] else { continue }
            head.append(Data("\r\n\(key): \(value)".utf8))
        }
        head.append(separator)
        head.append(response[separatorRange.upperBound...])
        return head
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
            payload["tool_count"] = tools.count
        }

        return payload
    }

    private static func isPocketCTLExecutableName(_ name: String) -> Bool {
        ["pocketctl", "pctl", "pocketcasts"].contains(name.lowercased())
    }

    private func publicRateLimitGroup(for request: HTTPRequest, isPublicRequest: Bool) -> PublicRateLimitGroup? {
        guard isPublicRequest else { return nil }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .health
        case ("GET", _) where isAuthorizationServerMetadataPath(request.path):
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

    private func publicRateLimitResponseIfNeeded(
        for group: PublicRateLimitGroup,
        request: HTTPRequest
    ) -> Data? {
        // Cloudflare sets this header at its edge and replaces any value the
        // caller sent, so behind the public link it identifies the caller.
        let caller = request.headers["cf-connecting-ip"] ?? "unknown"
        let decision = publicRateLimiter.check(group: group, caller: caller)
        guard !decision.allowed else { return nil }

        if decision.shouldLog {
            eventHandler?(.log(.warning, "Rate limiting public \(group.displayName) requests."))
        }
        return jsonErrorResponse(
            status: .tooManyRequests,
            error: "rate_limited",
            description: "Too many public requests. Try again later.",
            headers: ["Retry-After": String(decision.retryAfterSeconds)]
        )
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
        let noStoreHeaders = [
            "Cache-Control": "no-store",
            "Pragma": "no-cache"
        ]
        do {
            let object = try request.jsonObject()
            let response = try authCoordinator.registerClient(from: object)
            eventHandler?(.log(.info, "Registered OAuth client."))
            return jsonResponse(response, status: .created, headers: noStoreHeaders)
        } catch {
            eventHandler?(.log(.warning, "OAuth client registration rejected: \(singleLine(error.localizedDescription))"))
            return oauthErrorResponse(error, headers: noStoreHeaders)
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
            // The owner is not asked about a request that never started, so
            // Activity is the only place this Mac shows it.
            let reason = singleLine(error.localizedDescription)
            eventHandler?(.log(.warning, "Refused a sign-in request: \(reason)"))
            // A browser shows this to the person connecting; anything else
            // gets the standard OAuth error.
            guard request.headers["accept"]?.lowercased().contains("text/html") == true else {
                return oauthErrorResponse(error)
            }
            return HTTPResponse(
                status: .badRequest,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: signInRefusedPageHTML(reason: reason)
            ).data
        }
    }

    private func signInRefusedPageHTML(reason: String) -> String {
        webShellPage(bodyContent: """
            <p><strong>This sign-in can’t start.</strong></p>
            <p>MacRemote couldn’t accept the request from the app you’re connecting. In that app, remove MacRemote and add it again. If it asks how to identify itself, choose the option that registers automatically.</p>
            <footer>Details: <code>\(reason.htmlEscaped)</code></footer>
        """)
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
        let noStoreHeaders = [
            "Cache-Control": "no-store",
            "Pragma": "no-cache"
        ]
        do {
            let tokenRequest = try request.tokenFormURLEncodedBody()
            let response = try authCoordinator.exchangeToken(
                form: tokenRequest.form,
                clientAuthenticationSource: tokenRequest.clientAuthenticationSource,
                issuer: issuer,
                resource: resource
            )
            eventHandler?(.log(.info, "OAuth token issued after host approval."))
            eventHandler?(.clientsChanged(authCoordinator.connectedClientSnapshot()))
            return jsonResponse(response, headers: noStoreHeaders)
        } catch {
            eventHandler?(.log(.warning, "OAuth token exchange rejected: \(singleLine(error.localizedDescription))"))
            return oauthErrorResponse(error, headers: noStoreHeaders)
        }
    }

    private func authenticatedMCPClient(
        for request: HTTPRequest,
        base: String
    ) -> AuthenticatedClientContext? {
        guard let bearerToken = request.bearerToken else { return nil }
        return authCoordinator.clientContext(
            forAccessToken: bearerToken,
            issuer: base,
            acceptedResources: mcpResourceAliases(base: base)
        )
    }

    private func unauthorizedMCPResponse(
        for request: HTTPRequest,
        base: String,
        isPublicRequest: Bool
    ) -> Data {
        if isPublicRequest,
           let response = publicRateLimitResponseIfNeeded(for: .unauthorizedMCP, request: request) {
            return response
        }

        // RFC 6750 §3.1: a present-but-rejected token gets error="invalid_token"
        // so clients refresh instead of restarting authorization.
        //
        // Invariant: `Bearer` must stay the FIRST scheme in this challenge. The
        // official TypeScript MCP SDK's challenge parser (embedded in Claude
        // Code) splits on the first token and returns nothing when it is not
        // "Bearer", silently losing the resource_metadata discovery URL. Any
        // future scheme (e.g. a DPoP advertisement per RFC 9449) may only be
        // appended after the Bearer challenge, and only once it is backed by a
        // real implementation.
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

    private func mcp(
        request: HTTPRequest,
        base: String,
        client: AuthenticatedClientContext
    ) async -> Data {
        do {
            let object = try request.jsonObject()
            guard let message = object as? [String: Any],
                  message["jsonrpc"] as? String == "2.0",
                  let method = message["method"] as? String else {
                let context = protocolErrorContext(request: request, method: "<invalid>", base: base)
                return Self.$activeProtocolContext.withValue(context) {
                    jsonRPCError(
                        id: nil,
                        code: -32600,
                        message: "Invalid JSON-RPC request.",
                        status: context.isModern ? .badRequest : .ok
                    )
                }
            }

            let id = message["id"]
            // Answered before era routing so the reply is about the version and
            // nothing else. No protocol context is installed on purpose: the
            // response then advertises the latest legacy version in its header
            // rather than echoing the version we just refused.
            if let failure = unsupportedProtocolVersionFailure(
                request: request,
                message: message
            ) {
                return jsonRPCError(
                    id: id,
                    code: failure.code,
                    message: failure.message,
                    data: failure.data,
                    status: .badRequest
                )
            }
            if isModernRequest(request: request, message: message) {
                let errorContext = MCPRequestProtocolContext(
                    era: .modern,
                    version: Self.modernProtocolVersion,
                    method: method,
                    baseURL: base,
                    clientCapabilities: .object([:])
                )
                switch validateModernRequest(request: request, message: message, method: method, base: base) {
                case .failure(let failure):
                    return Self.$activeProtocolContext.withValue(errorContext) {
                        jsonRPCError(
                            id: id,
                            code: failure.code,
                            message: failure.message,
                            data: failure.data,
                            status: .badRequest
                        )
                    }
                case .success(let context):
                    return await Self.$activeProtocolContext.withValue(context) {
                        await dispatchMCP(
                            id: id,
                            method: method,
                            message: message,
                            client: client,
                            base: base
                        )
                    }
                }
            }

            let context = legacyProtocolContext(
                request: request,
                message: message,
                method: method,
                base: base,
                client: client
            )
            return await Self.$activeProtocolContext.withValue(context) {
                await dispatchMCP(
                    id: id,
                    method: method,
                    message: message,
                    client: client,
                    base: base
                )
            }
        } catch {
            let context = protocolErrorContext(request: request, method: "<parse>", base: base)
            return Self.$activeProtocolContext.withValue(context) {
                jsonRPCError(
                    id: nil,
                    code: -32700,
                    message: "Invalid JSON body.",
                    status: context.isModern ? .badRequest : .ok
                )
            }
        }
    }

    private func dispatchMCP(
        id: Any?,
        method: String,
        message: [String: Any],
        client: AuthenticatedClientContext,
        base: String
    ) async -> Data {
        let context = Self.activeProtocolContext
        recordClientSuppliedIcons(message: message, client: client)
        switch method {
        case "server/discover" where context?.isModern == true:
            return jsonRPCResult(id: id, result: [
                "supportedVersions": Self.modernProtocolVersions,
                "capabilities": modernServerCapabilities(),
                "instructions": Self.currentInstructions
            ])
        case "initialize" where context?.isModern != true:
            if let context {
                legacyClientCapabilityStore.update(
                    context.clientCapabilities,
                    for: client.clientID
                )
            }
            return jsonRPCResult(id: id, result: [
                "protocolVersion": context?.version ?? Self.latestLegacyProtocolVersion,
                "capabilities": legacyServerCapabilities(),
                "serverInfo": serverInfo(base: base),
                "instructions": Self.currentInstructions
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
        case "notifications/cancelled":
            let params = message["params"] as? [String: Any]
            inFlightToolCalls.cancel(clientID: client.clientID, requestID: params?["requestId"])
            return HTTPResponse(status: .accepted, headers: mcpResponseHeaders(), body: "").data
        case "notifications/initialized":
            return HTTPResponse(status: .accepted, headers: mcpResponseHeaders(), body: "").data
        default:
            if method.hasPrefix("notifications/") {
                return HTTPResponse(status: .accepted, headers: mcpResponseHeaders(), body: "").data
            }
            return jsonRPCError(
                id: id,
                code: -32601,
                message: "Method not found.",
                status: context?.isModern == true ? .notFound : .ok
            )
        }
    }

    private func negotiatedLegacyProtocolVersion(_ requestedVersion: String?) -> String {
        guard let requestedVersion,
              Self.legacyProtocolVersions.contains(requestedVersion) else {
            return Self.latestLegacyProtocolVersion
        }
        return requestedVersion
    }

    private func legacyServerCapabilities() -> [String: Any] {
        var capabilities: [String: Any] = [
            "tools": ["listChanged": false],
            "resources": ["listChanged": false]
        ]
        if let context = Self.activeProtocolContext,
           MCPAppsMetadata.clientSupportsHTMLApp(
            capabilities: context.clientCapabilities.anyValue as? [String: Any]
           ) {
            capabilities["extensions"] = MCPAppsMetadata.serverExtensionCapability
        }
        return capabilities
    }

    private func modernServerCapabilities() -> [String: Any] {
        [
            "tools": ["listChanged": false],
            "resources": ["listChanged": false],
            "extensions": MCPAppsMetadata.serverExtensionCapability
        ]
    }

    private struct MCPProtocolValidationFailure: Error, @unchecked Sendable {
        let code: Int
        let message: String
        let data: [String: Any]?

        init(code: Int, message: String, data: [String: Any]? = nil) {
            self.code = code
            self.message = message
            self.data = data
        }
    }

    private struct MCPMirroredHeaderSchema {
        let schema: [String: Any]
        let annotations: [MCPMirroredHeaderAnnotation]
    }

    /// Accept the icons an app hangs off its own `clientInfo` (MCP 2026-07-28:
    /// `Implementation` extends `Icons`). Both eras are read — the modern
    /// per-request `_meta["io.modelcontextprotocol/clientInfo"]` and legacy
    /// `initialize`'s `params.clientInfo` — because a client that only ever
    /// speaks one of them should not be the one to miss out.
    ///
    /// The specification says of that field: servers "SHOULD NOT use it to
    /// change their behavior, and SHOULD NOT rely on it for security decisions."
    /// Nothing here does. The parsed result reaches one presentation-only store
    /// and one picture; it is the lowest of the three artwork tiers, so a
    /// curated mark always wins over whatever an app sends about itself.
    private func recordClientSuppliedIcons(
        message: [String: Any],
        client: AuthenticatedClientContext
    ) {
        guard let params = message["params"] as? [String: Any] else { return }
        let candidate = (params["_meta"] as? [String: Any])?[Self.clientInfoMetaKey]
            ?? params["clientInfo"]
        guard let clientInfo = candidate as? [String: Any],
              let rawIcons = clientInfo["icons"] else {
            return
        }

        // Same payload as last request: nothing to decode, nothing to publish.
        var hasher = Hasher()
        for entry in (rawIcons as? [[String: Any]] ?? []) {
            hasher.combine(entry["src"] as? String ?? "")
            hasher.combine(entry["theme"] as? String ?? "")
        }
        guard !clientSuppliedIconStore.isFingerprintUnchanged(
            hasher.finalize(),
            for: client.clientID
        ) else {
            return
        }

        var rejections: [ClientSuppliedIcon.RejectionReason] = []
        let parsed = ClientSuppliedIconSet.parse(
            clientInfoIcons: rawIcons,
            rejections: &rejections
        )
        if let first = rejections.first,
           clientSuppliedIconStore.shouldReportRejection(for: client.clientID) {
            eventHandler?(.log(
                .info,
                "Ignored an icon an app sent about itself: \(Self.describe(first))."
            ))
        }
        guard let parsed,
              clientSuppliedIconStore.update(parsed, for: client.clientID) else {
            return
        }
        eventHandler?(.clientSuppliedIconsChanged(clientID: client.clientID, icons: parsed))
    }

    private static func describe(_ reason: ClientSuppliedIcon.RejectionReason) -> String {
        switch reason {
        case .notADataURI(let scheme):
            "only data: icons are accepted, and this one was \(scheme):"
        case .malformedDataURI:
            "the data: URI was not readable base64"
        case .unsupportedImageFormat(let declared):
            "the bytes are not PNG or JPEG (declared \(declared))"
        case .tooLarge(let bytes):
            "\(bytes) bytes exceeds the \(ClientSuppliedIcon.maximumImageByteCount)-byte limit"
        }
    }

    /// Which era's rules a request is judged by.
    ///
    /// Era routing follows an explicit protocol-version claim. Modern clients
    /// claim 2026-07-28 in both the HTTP header and request `_meta`; legacy
    /// clients negotiate through `initialize`. A capability object on its own
    /// is not a version claim. ChatGPT currently adds that one modern-shaped
    /// field to otherwise legacy requests, including requests carrying the
    /// explicit 2025-11-25 header. Treating the field as a modern claim rejects
    /// a valid legacy tool call before dispatch.
    ///
    /// The narrow compatibility rule is therefore: the exact modern header or
    /// the namespaced protocolVersion key selects modern validation. A complete
    /// modern envelope necessarily contains that key. A bare `server/discover`
    /// remains legacy and receives Method not found, allowing dual-era clients
    /// to fall back to `initialize` as the official SDK does.
    private func isModernRequest(
        request: HTTPRequest,
        message: [String: Any]
    ) -> Bool {
        request.mcpProtocolVersionHeader == Self.modernProtocolVersion
            || carriesModernProtocolClaim(message: message)
    }

    private func carriesModernProtocolClaim(message: [String: Any]) -> Bool {
        guard let params = message["params"] as? [String: Any],
              let meta = params["_meta"] as? [String: Any] else {
            return false
        }
        return meta["io.modelcontextprotocol/protocolVersion"] != nil
    }

    /// The renegotiation hint stays within the request's era. Mixing the modern
    /// and legacy lists caused legacy ChatGPT to select 2026-07-28 even though
    /// it does not send that version's required envelope.
    private static func unsupportedProtocolVersion(
        requested: String,
        supported: [String]
    ) -> MCPProtocolValidationFailure {
        MCPProtocolValidationFailure(
            code: -32022,
            message: "Unsupported protocol version.",
            data: [
                "supported": supported,
                "requested": requested
            ]
        )
    }

    /// Rejects a header version we do not speak before any era-specific
    /// validation runs.
    ///
    /// This fires for both directions of mismatch — too old ("2024-11-05") and
    /// unknown-future ("2027-01-01") — because in either case the only useful
    /// answer is the list of versions this server implements. Requests that
    /// carry a modern version claim are left alone: they route to
    /// `validateModernRequest`, which returns a modern-only counter-offer.
    private func unsupportedProtocolVersionFailure(
        request: HTTPRequest,
        message: [String: Any]
    ) -> MCPProtocolValidationFailure? {
        guard let version = request.mcpProtocolVersionHeader,
              version != Self.modernProtocolVersion,
              !Self.legacyProtocolVersions.contains(version) else {
            return nil
        }
        if carriesModernProtocolClaim(message: message) {
            return nil
        }
        return Self.unsupportedProtocolVersion(
            requested: version,
            supported: Self.legacyProtocolVersions
        )
    }

    private func protocolErrorContext(
        request: HTTPRequest,
        method: String,
        base: String
    ) -> MCPRequestProtocolContext {
        // A malformed body cannot expose a trustworthy `_meta` claim, so only
        // the exact modern header can select a modern parse-error shape.
        let modern = request.mcpProtocolVersionHeader == Self.modernProtocolVersion
        return MCPRequestProtocolContext(
            era: modern ? .modern : .legacy,
            version: modern
                ? Self.modernProtocolVersion
                : (request.mcpProtocolVersionHeader ?? "2025-03-26"),
            method: method,
            baseURL: base,
            clientCapabilities: .object([:])
        )
    }

    private func legacyProtocolContext(
        request: HTTPRequest,
        message: [String: Any],
        method: String,
        base: String,
        client: AuthenticatedClientContext
    ) -> MCPRequestProtocolContext {
        let params = message["params"] as? [String: Any]
        let version: String
        if method == "initialize" {
            version = negotiatedLegacyProtocolVersion(params?["protocolVersion"] as? String)
        } else {
            version = request.mcpProtocolVersionHeader ?? "2025-03-26"
        }
        let capabilities: JSONValue
        if method == "initialize" {
            capabilities = params?["capabilities"].flatMap(JSONValue.fromJSONObject) ?? .object([:])
        } else {
            capabilities = legacyClientCapabilityStore.capabilities(for: client.clientID)
        }
        return MCPRequestProtocolContext(
            era: .legacy,
            version: version,
            method: method,
            baseURL: base,
            clientCapabilities: capabilities
        )
    }

    private func validateModernRequest(
        request: HTTPRequest,
        message: [String: Any],
        method: String,
        base: String
    ) -> Result<MCPRequestProtocolContext, MCPProtocolValidationFailure> {
        // Version before envelope, always. Demanding the 2026-07-28 metadata
        // from a client that named a version we do not implement is a dead end:
        // it cannot produce the envelope, and -32602 tells it nothing about what
        // would work. Answering -32022 with the modern list first gives the
        // client an era-correct retry. A conforming `server/discover` carries
        // this same envelope and header.
        if let protocolHeader = request.mcpProtocolVersionHeader,
           protocolHeader != Self.modernProtocolVersion,
           !Self.legacyProtocolVersions.contains(protocolHeader) {
            return .failure(Self.unsupportedProtocolVersion(
                requested: protocolHeader,
                supported: Self.modernProtocolVersions
            ))
        }

        guard let params = message["params"] as? [String: Any],
              let meta = params["_meta"] as? [String: Any],
              let requestedVersion = meta["io.modelcontextprotocol/protocolVersion"] as? String,
              !requestedVersion.isEmpty,
              let capabilitiesObject = meta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any],
              let capabilities = JSONValue.fromJSONObject(capabilitiesObject) else {
            // Reached only after an explicit modern version claim. Do not
            // manufacture the missing capability set or silently downgrade.
            return .failure(MCPProtocolValidationFailure(
                code: -32602,
                message: "Modern MCP requests require protocolVersion and clientCapabilities metadata.",
                data: ["supported": Self.modernProtocolVersions]
            ))
        }

        guard let protocolHeader = request.mcpProtocolVersionHeader else {
            return .failure(headerMismatch("Missing MCP-Protocol-Version header."))
        }
        guard protocolHeader == requestedVersion else {
            return .failure(headerMismatch(
                "MCP-Protocol-Version header does not match request metadata."
            ))
        }
        guard requestedVersion == Self.modernProtocolVersion else {
            return .failure(Self.unsupportedProtocolVersion(
                requested: requestedVersion,
                supported: Self.modernProtocolVersions
            ))
        }

        guard let methodHeader = request.mcpMethodHeader,
              Self.isPlainHTTPHeaderValue(methodHeader),
              methodHeader == method else {
            return .failure(headerMismatch("Mcp-Method header is missing, malformed, or mismatched."))
        }

        if let sourceName = mirroredNameSource(method: method, params: params) {
            guard let encodedName = request.mcpNameHeader,
                  let decodedName = Self.decodedMirroredHeaderValue(encodedName),
                  decodedName == sourceName else {
                return .failure(headerMismatch("Mcp-Name header is missing, malformed, or mismatched."))
            }
        } else if Self.methodsRequiringNameHeader.contains(method) {
            return .failure(headerMismatch("Mcp-Name header is required for this method."))
        }

        if method == "tools/call",
           let failure = validateToolParameterHeaders(request: request, params: params) {
            return .failure(failure)
        }

        return .success(MCPRequestProtocolContext(
            era: .modern,
            version: requestedVersion,
            method: method,
            baseURL: base,
            clientCapabilities: capabilities
        ))
    }

    private static let methodsRequiringNameHeader: Set<String> = [
        "tools/call",
        "resources/read",
        "prompts/get"
    ]

    private func mirroredNameSource(method: String, params: [String: Any]) -> String? {
        switch method {
        case "tools/call", "prompts/get":
            return params["name"] as? String
        case "resources/read":
            return params["uri"] as? String
        default:
            return nil
        }
    }

    private func headerMismatch(_ message: String) -> MCPProtocolValidationFailure {
        MCPProtocolValidationFailure(code: -32020, message: message)
    }

    private func validateToolParameterHeaders(
        request: HTTPRequest,
        params: [String: Any]
    ) -> MCPProtocolValidationFailure? {
        guard let toolName = params["name"] as? String,
              let tool = toolProvider().first(where: { $0.id == toolName }) else {
            return nil
        }
        let mirroredSchema = mirroredHeaderSchema(for: inputSchema(for: tool))
        guard !mirroredSchema.annotations.isEmpty else {
            return nil
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        for annotation in mirroredSchema.annotations {
            let headerKey = "\(Self.parameterHeaderPrefix)\(annotation.headerName)".lowercased()
            let headerValue = request.headers[headerKey]
            let argumentValue = Self.value(at: annotation.parameterPath, in: arguments)

            if argumentValue == nil || argumentValue is NSNull {
                if headerValue != nil {
                    return headerMismatch(
                        "\(Self.parameterHeaderPrefix)\(annotation.headerName) must be omitted when its parameter is absent or null."
                    )
                }
                continue
            }

            guard let headerValue,
                  let decodedHeaderValue = Self.decodedMirroredHeaderValue(headerValue),
                  Self.mirroredHeaderValue(
                    decodedHeaderValue,
                    matches: argumentValue,
                    type: annotation.valueType
                  ) else {
                return headerMismatch(
                    "\(Self.parameterHeaderPrefix)\(annotation.headerName) is missing, malformed, or mismatched."
                )
            }
        }
        return nil
    }

    private func mirroredHeaderSchema(for schema: [String: Any]) -> MCPMirroredHeaderSchema {
        let inspection: MCPMirroredHeaderSchemaInspection
        do {
            inspection = try MCPMirroredHeaderSchemaInspection.inspect(schema)
        } catch {
            return MCPMirroredHeaderSchema(
                schema: [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false
                ],
                annotations: []
            )
        }
        guard inspection.annotationsAreValid else {
            return MCPMirroredHeaderSchema(
                schema: Self.removingMCPHeaderAnnotations(from: schema) as? [String: Any] ?? schema,
                annotations: []
            )
        }
        return MCPMirroredHeaderSchema(
            schema: schema,
            annotations: inspection.annotations
        )
    }

    private static func removingMCPHeaderAnnotations(from value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.reduce(into: [String: Any]()) { result, item in
                guard item.key != "x-mcp-header" else { return }
                result[item.key] = removingMCPHeaderAnnotations(from: item.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(removingMCPHeaderAnnotations)
        }
        return value
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

    private static func mirroredHeaderValue(
        _ headerValue: String,
        matches bodyValue: Any?,
        type: MCPMirroredHeaderValueType
    ) -> Bool {
        switch type {
        case .string:
            return (bodyValue as? String) == headerValue
        case .boolean:
            guard let value = bodyValue as? NSNumber,
                  CFGetTypeID(value) == CFBooleanGetTypeID() else {
                return false
            }
            return headerValue == (value.boolValue ? "true" : "false")
        case .integer:
            // Decimal(string:) stops at the first non-digit ("12abc" reads as
            // 12), so the header must be a plain integer before it is parsed.
            guard headerValue.wholeMatch(of: /-?(0|[1-9][0-9]*)/) != nil,
                  let headerNumber = Decimal(string: headerValue, locale: Locale(identifier: "en_US_POSIX")),
                  let bodyNumber = safeIntegerDecimal(from: bodyValue) else {
                return false
            }
            return headerNumber == bodyNumber
        }
    }

    private static func safeIntegerDecimal(from value: Any?) -> Decimal? {
        let maximumSafeInteger = 9_007_199_254_740_991.0
        let double: Double
        switch value {
        case let value as NSNumber:
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else {
                return nil
            }
            double = value.doubleValue
        case let value as Int:
            double = Double(value)
        case let value as Int64:
            double = Double(value)
        case let value as Double:
            double = value
        default:
            return nil
        }
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              abs(double) <= maximumSafeInteger else {
            return nil
        }
        return Decimal(double)
    }

    private static func decodedMirroredHeaderValue(_ value: String) -> String? {
        let prefix = "=?base64?"
        let suffix = "?="
        // The length check matters: in "=?base64?=" the prefix and suffix
        // overlap, and slicing between them would trap.
        if value.count >= prefix.count + suffix.count, value.hasPrefix(prefix), value.hasSuffix(suffix) {
            let payloadStart = value.index(value.startIndex, offsetBy: prefix.count)
            let payloadEnd = value.index(value.endIndex, offsetBy: -suffix.count)
            let payload = String(value[payloadStart..<payloadEnd])
            guard !payload.isEmpty,
                  let data = Data(base64Encoded: payload),
                  data.base64EncodedString() == payload,
                  let decoded = String(data: data, encoding: .utf8) else {
                return nil
            }
            return decoded
        }
        guard isPlainHTTPHeaderValue(value) else {
            return nil
        }
        return value
    }

    private static func isPlainHTTPHeaderValue(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !(value.hasPrefix("=?base64?") && value.hasSuffix("?=")) else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            $0.value == 0x09 || (0x20...0x7E).contains($0.value)
        }
    }

    private static func isHTTPFieldName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let permitted = Set("!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        return value.allSatisfy { permitted.contains($0) }
    }

    private var requestSupportsStandardUI: Bool {
        guard let context = Self.activeProtocolContext else {
            return false
        }
        return MCPAppsMetadata.clientSupportsHTMLApp(
            capabilities: context.clientCapabilities.anyValue as? [String: Any]
        )
    }

    private var requestAllowsWidgetCompatibility: Bool {
        requestSupportsStandardUI || Self.activeProtocolContext?.isModern != true
    }

    private func widgetLinkMetadata(merging existing: [String: Any]) -> [String: Any] {
        if requestSupportsStandardUI {
            return MCPAppsMetadata.toolMetadata(merging: existing)
        }
        guard Self.activeProtocolContext?.isModern != true else {
            return existing
        }
        var metadata = existing
        metadata[MCPAppsMetadata.deprecatedResourceURIKey] = Self.widgetResourceURI
        metadata[MCPAppsMetadata.openAIOutputTemplateKey] = Self.widgetResourceURI
        metadata[MCPAppsMetadata.openAIWidgetAccessibleKey] = true
        return metadata
    }

    /// The widget's sandbox policy goes to every client on every negotiation
    /// path, whether or not it declared the Apps capability.
    ///
    /// This used to be gated: a client that never declared the capability got
    /// `_meta.ui` stripped. That was the wrong trade. `_meta` is ignorable by
    /// contract, so a client that does not understand `ui` simply drops it —
    /// sending it cannot break anyone. Withholding it does break things:
    /// `ui.csp` is where the widget's image allowlist lives, and a host that
    /// receives no `csp` falls back to the spec default (`img-src 'self'
    /// data:`), which blocks the Pocket Casts artwork. claude.ai on the web
    /// negotiates as a legacy client whose cached capability is lost on every
    /// relaunch, so it reliably landed on the stripping branch and reliably
    /// rendered the widget with every piece of artwork missing.
    private var widgetContentMetadata: [String: Any] {
        MCPAppsMetadata.resourceContentMetadata
    }

    private enum ToolCallLogicalResult {
        case result([String: Any])
        case jsonRPCError(code: Int, message: String, data: [String: Any]?)
    }

    /// A parsed JSON-RPC request. Nothing changes it after parsing, so it can
    /// be handed to the task that runs the call.
    private struct ParsedRequest: @unchecked Sendable {
        let id: Any?
        let message: [String: Any]
    }

    /// Runs the call in its own task, so the app's `notifications/cancelled`
    /// stops it the same way a closed connection does: a waiting approval
    /// expires and a running tool is stopped.
    private func callTool(
        id: Any?,
        message: [String: Any],
        client: AuthenticatedClientContext,
        base: String
    ) async -> Data {
        let request = ParsedRequest(id: id, message: message)
        let call = Task {
            await self.runToolCall(id: request.id, message: request.message, client: client, base: base)
        }
        return await withTaskCancellationHandler {
            await inFlightToolCalls.track(call, clientID: client.clientID, requestID: request.id)
        } onCancel: {
            call.cancel()
        }
    }

    private func runToolCall(
        id: Any?,
        message: [String: Any],
        client: AuthenticatedClientContext,
        base: String
    ) async -> Data {
        do {
            switch try await executeToolCall(message: message, client: client, base: base) {
            case .result(let result):
                return jsonRPCResult(id: id, result: result)
            case .jsonRPCError(let code, let message, let data):
                return jsonRPCError(id: id, code: code, message: message, data: data)
            }
        } catch is CancellationError {
            return jsonRPCError(id: id, code: -32603, message: "Tool call was cancelled.")
        } catch {
            return jsonRPCError(id: id, code: -32603, message: "Internal error.")
        }
    }

    private func executeToolCall(
        message: [String: Any],
        client: AuthenticatedClientContext,
        base: String
    ) async throws -> ToolCallLogicalResult {
        guard let params = message["params"] as? [String: Any],
              let name = params["name"] as? String else {
            return .jsonRPCError(code: -32602, message: "Missing tool name.", data: nil)
        }

        let rawArguments = params["arguments"] as? [String: Any] ?? [:]
        let arguments = rawArguments.compactMapValues(ToolArgumentValue.fromJSONObject)

        let tools = toolProvider()
        var resolvedTool: ToolDefinition?
        do {
            guard let tool = tools.first(where: { $0.id == name }) else {
                throw ToolValidationError.unknownTool(name)
            }
            resolvedTool = tool

            // Before the approval gate: the owner should only ever be asked
            // about a call that can actually run.
            try toolExecutor.validate(toolID: tool.id, parameters: arguments)

            if tool.asksBeforeRunning {
                // An explicit Always Allow grant is the owner's decision and is
                // honored for any tool, including the every-call ones. The grant
                // is bound to the exact security fingerprint, so a tool whose
                // contract changed still stops here.
                if clientToolPermissionStore?.isAllowed(
                    clientTrustID: client.clientTrustID,
                    tool: tool
                ) == true {
                    approvalDecisionLog?.record(
                        tool: tool,
                        clientTrustID: client.clientTrustID,
                        source: .alwaysAllowGrant,
                        grantStoreHit: true
                    )
                    eventHandler?(.log(.info, "\(tool.name) allowed by \(client.clientName)'s client policy."))
                } else {
                    guard let toolCallApprovalCoordinator else {
                        approvalDecisionLog?.record(
                            tool: tool,
                            clientTrustID: client.clientTrustID,
                            source: .gateUnavailable,
                            grantStoreHit: false
                        )
                        eventHandler?(.log(.warning, "Blocked \(tool.name): host approval gate is unavailable."))
                        return toolExecutionError(
                            tool: tool,
                            reason: "unavailable",
                            message: "Host approval is required for this tool."
                        )
                    }

                    eventHandler?(.log(.warning, "\(tool.name) is waiting for host approval before execution."))
                    let approved = try await toolCallApprovalCoordinator.requestApproval(
                        tool: tool,
                        parameters: arguments,
                        client: client
                    )
                    approvalDecisionLog?.record(
                        tool: tool,
                        clientTrustID: client.clientTrustID,
                        source: approved ? .userApproved : .userDenied,
                        grantStoreHit: false
                    )
                    guard approved else {
                        eventHandler?(.log(.warning, "\(tool.name) was denied or expired before execution."))
                        return toolExecutionError(
                            tool: tool,
                            reason: "not_approved",
                            message: "Tool call was not approved on the host Mac."
                        )
                    }
                    eventHandler?(.log(.info, "\(tool.name) approved on host Mac."))
                }
            } else {
                approvalDecisionLog?.record(
                    tool: tool,
                    clientTrustID: client.clientTrustID,
                    source: .readOnly,
                    grantStoreHit: false
                )
            }

            guard let outcome = try await toolExecutionLimiter.withSlot({
                try await toolExecutor.execute(
                    toolID: tool.id,
                    parameters: arguments,
                    expectedSecurityFingerprint: tool.securityFingerprint
                )
            }) else {
                eventHandler?(.log(.warning, "\(tool.name) was not executed: execution concurrency limit reached."))
                return toolExecutionError(
                    tool: tool,
                    reason: "unavailable",
                    message: "Server is busy; too many tool calls in progress. Retry shortly."
                )
            }
            try Task.checkCancellation()
            let stdoutRegistration = registerStdoutArtifact(for: outcome)
            let stdoutArtifact = stdoutRegistration.handle
            let stdoutPreservationFailed = stdoutRegistration.preservationError != nil
            var structuredContent = structuredContent(
                for: outcome,
                stdoutArtifact: stdoutArtifact,
                stdoutPreservationFailed: stdoutPreservationFailed
            )
            // Download links are built only for the built-in File Transfer
            // tools, which mint the artifact themselves. Any other tool's
            // output is untrusted text: read for link fields, it could put a
            // MacRemote-authored download link to any address in the result.
            let producesArtifacts = tool.backend == .native
            if producesArtifacts {
                structuredContent = augmentStructuredContentWithArtifactDownloadURL(structuredContent, base: base)
            }
            eventHandler?(.log(
                outcome.succeeded && !stdoutPreservationFailed ? .info : .warning,
                stdoutPreservationFailed
                    ? "\(outcome.toolName) exited \(outcome.exitCode), but complete stdout could not be preserved: \(stdoutRegistration.preservationError ?? "unknown error")"
                    : "\(outcome.toolName) MCP call exited \(outcome.exitCode) in \(outcome.duration.formattedDuration)."
            ))
            var contentItems: [[String: Any]] = [
                [
                    "type": "text",
                    "text": serializedJSON(structuredContent)
                ]
            ]
            if producesArtifacts,
               outcome.succeeded,
               let payload = stdoutJSONPayload(from: structuredContent),
               let artifactLink = artifactResourceLinkItem(payload: payload, base: base) {
                contentItems.append(artifactLink)
            }
            if let stdoutArtifact {
                let spillItems = stdoutArtifactContentItems(
                    handle: stdoutArtifact,
                    outcome: outcome,
                    base: base
                )
                contentItems.append(contentsOf: spillItems)
            }
            var result: [String: Any] = [
                "structuredContent": structuredContent,
                "content": contentItems,
                "isError": !outcome.succeeded || stdoutPreservationFailed
            ]
            if requestAllowsWidgetCompatibility,
               let uiMeta = resultUIMeta(for: tool, tools: tools) {
                result["_meta"] = widgetLinkMetadata(merging: [
                    Self.resultUIMetaKey: uiMeta
                ])
            }
            let upstreamEnrichment = enrichResultWithUpstreamMCPContext(
                result,
                id: nil,
                outcome: outcome,
                base: base
            )
            result = upstreamEnrichment.result
            return .result(boundedToolCallResult(
                result: result,
                stdoutPreservedExternally: stdoutArtifact != nil,
                stdoutPreservationFailed: stdoutPreservationFailed
                    || upstreamEnrichment.preservationFailed
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch ToolValidationError.unknownTool(let unknownName) {
            // A tool can disappear while a call waits for approval. Recovery
            // metadata must describe the current catalog in that case.
            let snapshot = catalogSnapshot()
            let displayedName = String(unknownName.prefix(128))
            return .jsonRPCError(
                code: -32602,
                message: "Unknown tool: \(displayedName). Refresh tools/list before retrying.",
                data: [
                    "reason": "unknown_tool",
                    "refreshRequired": true,
                    "catalogRevision": snapshot.revision,
                    "catalogResourceUri": MCPCatalogMetadata.resourceURI,
                    "suggestedTools": MCPCatalogMetadata.suggestions(
                        for: unknownName,
                        tools: snapshot.tools
                    )
                ]
            )
        } catch let error as ToolValidationError {
            return toolExecutionError(
                tool: resolvedTool,
                reason: error.callToolReason,
                message: error.callToolMessage(tool: resolvedTool, arguments: arguments)
            )
        } catch ToolSecurityFingerprintError.changed {
            return toolExecutionError(
                tool: resolvedTool,
                reason: "not_approved",
                message: "The tool changed after approval. Refresh tools/list and approve its current definition."
            )
        } catch ToolCallApprovalError.tooManyPending {
            eventHandler?(.log(.warning, "\(resolvedTool?.name ?? name) was not queued: too many calls are already waiting for approval."))
            return toolExecutionError(
                tool: resolvedTool,
                reason: "unavailable",
                message: "Too many calls are already waiting for approval on the Mac. Wait for the person to respond before sending more."
            )
        } catch {
            return .jsonRPCError(code: -32603, message: "Internal error.", data: nil)
        }
    }

    private func toolExecutionError(
        tool: ToolDefinition?,
        reason: String,
        message: String
    ) -> ToolCallLogicalResult {
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
        var result: [String: Any] = [
            "structuredContent": structuredContent,
            "content": [
                [
                    "type": "text",
                    "text": serializedJSON(structuredContent)
                ]
            ],
            "isError": true
        ]
        if requestAllowsWidgetCompatibility,
           let tool,
           let uiMeta = resultUIMeta(for: tool, tools: toolProvider()) {
            result["_meta"] = widgetLinkMetadata(merging: [
                Self.resultUIMetaKey: uiMeta
            ])
        }
        return .result(result)
    }

    /// Results above ~150 KB are diverted by Claude's code-execution
    /// sandbox to a file: the model gets a pointer and the widget never
    /// hydrates. Keep a byte-bounded head in the envelope and link the complete
    /// bounded stdout as an artifact. `outputByteLimit` remains the hard cap.
    static let mcpStdoutByteLimit = 48_000
    // Compatibility name for existing callers and tests; the limit is bytes.
    static let mcpStdoutCharacterLimit = mcpStdoutByteLimit
    static let mcpStderrCharacterLimit = 16_000
    static let mcpCallToolResultByteLimit = 120_000
    private static let stdoutArtifactEncodedByteThreshold = 36_000
    private static let maximumJSONValidationBytes = 64 * 1024 * 1024
    private static let stdoutPreservationFailureMessage =
        "MacRemote could not preserve complete stdout after the command finished. The exit code is authoritative; do not retry solely because of this output error."

    private func structuredContent(
        for outcome: ToolExecutionOutcome,
        stdoutArtifact: ArtifactHandle?,
        stdoutPreservationFailed: Bool = false
    ) -> [String: Any] {
        let stdoutHead = utf8Prefix(outcome.stdout, maximumBytes: Self.mcpStdoutByteLimit)
        let stdout = stdoutHead.value
        var stderr = utf8Prefix(outcome.stderr, maximumBytes: Self.mcpStderrCharacterLimit).value
        if stdoutPreservationFailed {
            if !stderr.isEmpty, !stderr.hasSuffix("\n") {
                stderr += "\n"
            }
            stderr += Self.stdoutPreservationFailureMessage
        }
        let inlineStdoutTruncated = stdoutHead.truncated
            || (stdoutArtifact != nil && !outcome.stdoutBytesAreValidUTF8)
            || stdoutPreservationFailed
        // Keep the field literal: stdout contains a head when an artifact is
        // linked. The reason code separately distinguishes preserved output
        // from data lost at the configured hard cap.
        let truncatedStdout = outcome.truncatedStdout || inlineStdoutTruncated
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
                unpreservedStdoutClip: stdoutHead.truncated && stdoutArtifact == nil,
                truncatedStderr: truncatedStderr,
                stdoutPreservationFailed: stdoutPreservationFailed
            )
        )
    }

    private func utf8Prefix(_ value: String, maximumBytes: Int) -> (value: String, truncated: Bool) {
        let data = Data(value.utf8)
        guard data.count > maximumBytes else {
            return (value, false)
        }

        var end = maximumBytes
        while end > 0 {
            if let prefix = String(data: data.prefix(end), encoding: .utf8) {
                return (prefix, true)
            }
            end -= 1
        }
        return ("", true)
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
        unpreservedStdoutClip: Bool,
        truncatedStderr: Bool,
        stdoutPreservationFailed: Bool = false
    ) -> String {
        if outcome.timedOut {
            return "timeout"
        }
        if outcome.terminationSignal != nil {
            return "killed"
        }
        if stdoutPreservationFailed {
            return "internal_error"
        }
        if outcome.truncatedStdout || unpreservedStdoutClip || truncatedStderr {
            return "output_limit"
        }
        if outcome.succeeded {
            return "ok"
        }
        return "nonzero_exit"
    }

    /// `structuredContent.stdout` is mirrored in the text fallback. Bound the
    /// serialized response itself, not just the source string: JSON escaping
    /// can expand control characters and the fallback adds another layer.
    private func boundedToolCallResult(
        result: [String: Any],
        stdoutPreservedExternally: Bool,
        stdoutPreservationFailed: Bool
    ) -> [String: Any] {
        let unbounded = jsonRPCResult(id: nil, result: result)
        guard unbounded.count > Self.mcpCallToolResultByteLimit,
              let structured = result["structuredContent"] as? [String: Any],
              let originalStdout = structured["stdout"] as? String,
              !originalStdout.isEmpty,
              let content = result["content"] as? [[String: Any]],
              !content.isEmpty else {
            return result
        }

        let maximumBytes = Data(originalStdout.utf8).count
        var lowerBound = 0
        var upperBound = maximumBytes
        var bestResult: [String: Any]?

        while lowerBound <= upperBound {
            let candidateLimit = lowerBound + (upperBound - lowerBound) / 2
            let candidatePrefix = utf8Prefix(originalStdout, maximumBytes: candidateLimit)
            var candidateStructured = structured
            candidateStructured["stdout"] = candidatePrefix.value
            if candidatePrefix.truncated {
                candidateStructured["truncatedStdout"] = true
                if !stdoutPreservedExternally && !stdoutPreservationFailed {
                    candidateStructured["reason"] = "output_limit"
                }
            }

            var candidateContent = content
            candidateContent[0]["text"] = serializedJSON(candidateStructured)
            var candidateResult = result
            candidateResult["structuredContent"] = candidateStructured
            candidateResult["content"] = candidateContent
            let candidateResponse = jsonRPCResult(id: nil, result: candidateResult)

            if candidateResponse.count <= Self.mcpCallToolResultByteLimit {
                bestResult = candidateResult
                lowerBound = candidateLimit + 1
            } else {
                upperBound = candidateLimit - 1
            }
        }

        return bestResult ?? result
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
        guard let updatedData = try? JSONSerialization.checkedData(
            withJSONObject: payload,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ),
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

    static func mimeType(forFilename filename: String) -> String {
        let lowercased = filename.lowercased()
        if lowercased.hasSuffix(".zip") {
            return "application/zip"
        }
        if lowercased.hasSuffix(".json") {
            return "application/json"
        }
        if lowercased.hasSuffix(".svg") {
            return "image/svg+xml"
        }
        if lowercased.hasSuffix(".html") || lowercased.hasSuffix(".htm") {
            return "text/html"
        }
        if lowercased.hasSuffix(".md") || lowercased.hasSuffix(".markdown") {
            return "text/markdown"
        }
        if lowercased.hasSuffix(".png") {
            return "image/png"
        }
        if lowercased.hasSuffix(".jpg") || lowercased.hasSuffix(".jpeg") {
            return "image/jpeg"
        }
        if lowercased.hasSuffix(".heic") {
            return "image/heic"
        }
        if lowercased.hasSuffix(".pdf") {
            return "application/pdf"
        }
        if lowercased.hasSuffix(".m4a") {
            return "audio/mp4"
        }
        if lowercased.hasSuffix(".mp4") {
            return "video/mp4"
        }
        if lowercased.hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if lowercased.hasSuffix(".wav") {
            return "audio/wav"
        }
        if lowercased.hasSuffix(".mov") {
            return "video/quicktime"
        }
        if lowercased.hasSuffix(".bin") {
            return "application/octet-stream"
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
            "mimeType": Self.mimeType(forFilename: filename),
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

    private struct UpstreamResultEnrichment {
        let result: [String: Any]
        let preservationFailed: Bool
    }

    /// Keeps the normalized semantic payload in `structuredContent.stdout`
    /// while forwarding nonredundant upstream content as real MCP blocks and
    /// preserving upstream metadata under collision-safe MacRemote keys.
    /// The preservation context is all-inline or all-artifact; it is never
    /// partially clipped to make the outer response fit.
    private func enrichResultWithUpstreamMCPContext(
        _ result: [String: Any],
        id: Any?,
        outcome: ToolExecutionOutcome,
        base: String
    ) -> UpstreamResultEnrichment {
        guard let context = outcome.upstreamMCPResult, !context.isEmpty else {
            return UpstreamResultEnrichment(result: result, preservationFailed: false)
        }

        var inlineResult = result
        if !context.content.isEmpty,
           var contentItems = inlineResult["content"] as? [[String: Any]] {
            let upstreamBlocks = context.content.compactMap { $0.anyValue as? [String: Any] }
            contentItems.insert(contentsOf: upstreamBlocks, at: min(1, contentItems.count))
            inlineResult["content"] = contentItems
        }
        var inlineMeta = inlineResult["_meta"] as? [String: Any] ?? [:]
        if let meta = context.meta {
            inlineMeta[Self.upstreamResultMetaKey] = meta.anyValue
        }
        if !context.extensions.isEmpty {
            inlineMeta[Self.upstreamExtensionsMetaKey] = context.extensions.mapValues(\.anyValue)
        }
        if !inlineMeta.isEmpty {
            inlineResult["_meta"] = inlineMeta
        }

        if jsonRPCResult(id: id, result: inlineResult).count <= Self.mcpCallToolResultByteLimit {
            return UpstreamResultEnrichment(result: inlineResult, preservationFailed: false)
        }

        do {
            let assistantContentHandle = try registerUpstreamPreservationArtifact(
                object: context.assistantVisiblePreservationJSONObject,
                suggestedFilename: "\(outcome.toolName)-upstream-assistant-content.json"
            )
            let userContentHandle = try registerUpstreamPreservationArtifact(
                object: context.userOnlyPreservationJSONObject,
                suggestedFilename: "\(outcome.toolName)-upstream-user-content.json"
            )
            let metadataHandle = try registerUpstreamPreservationArtifact(
                object: context.hiddenPreservationJSONObject,
                suggestedFilename: "\(outcome.toolName)-upstream-metadata.json"
            )
            var spilledResult = result
            var spilledContent = spilledResult["content"] as? [[String: Any]] ?? []
            if let assistantContentHandle {
                spilledContent.append(contentsOf: upstreamPreservationContentItems(
                    handle: assistantContentHandle,
                    base: base,
                    audience: "assistant",
                    label: "assistant-visible"
                ))
            }
            if let userContentHandle {
                spilledContent.append(contentsOf: upstreamPreservationContentItems(
                    handle: userContentHandle,
                    base: base,
                    audience: "user",
                    label: "user-only"
                ))
            }
            spilledResult["content"] = spilledContent
            var spilledMeta = spilledResult["_meta"] as? [String: Any] ?? [:]
            var preservation = [String: Any]()
            if let assistantContentHandle {
                preservation["assistantContent"] = upstreamPreservationDescriptor(
                    handle: assistantContentHandle,
                    base: base
                )
            }
            if let userContentHandle {
                preservation["userContent"] = upstreamPreservationDescriptor(
                    handle: userContentHandle,
                    base: base
                )
            }
            if let metadataHandle {
                // This pointer stays inside result `_meta`; unlike `content`,
                // ChatGPT does not expose this channel to the model.
                preservation["metadata"] = upstreamPreservationDescriptor(
                    handle: metadataHandle,
                    base: base
                )
            }
            if !preservation.isEmpty {
                spilledMeta[Self.upstreamPreservationMetaKey] = preservation
            }
            spilledResult["_meta"] = spilledMeta
            return UpstreamResultEnrichment(result: spilledResult, preservationFailed: false)
        } catch {
            eventHandler?(.log(
                .warning,
                "\(outcome.toolName) completed, but upstream MCP content could not be preserved: \(error.localizedDescription)"
            ))
            return UpstreamResultEnrichment(
                result: upstreamPreservationFailureResult(from: result),
                preservationFailed: true
            )
        }
    }

    private func registerUpstreamPreservationArtifact(
        object: [String: Any],
        suggestedFilename: String
    ) throws -> ArtifactHandle? {
        guard !object.isEmpty else { return nil }
        let data = try JSONSerialization.checkedData(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try artifactStore.register(
            data: data,
            suggestedFilename: suggestedFilename
        )
    }

    private func upstreamPreservationDescriptor(
        handle: ArtifactHandle,
        base: String
    ) -> [String: Any] {
        [
            "uri": base + handle.artifactPath,
            "sizeBytes": handle.sizeBytes,
            "sha256": handle.sha256,
            "expiresInSeconds": handle.expiresInSeconds,
            "downloadsAllowed": handle.downloadsAllowed
        ]
    }

    private func upstreamPreservationContentItems(
        handle: ArtifactHandle,
        base: String,
        audience: String,
        label: String
    ) -> [[String: Any]] {
        let annotations: [String: Any] = ["audience": [audience]]
        return [
            [
                "type": "resource_link",
                "uri": base + handle.artifactPath,
                "name": handle.filename,
                "mimeType": "application/json",
                "description": "Complete \(label) upstream MCP content (expires in \(handle.expiresInSeconds)s, \(handle.sizeBytes) bytes).",
                "annotations": annotations
            ],
            [
                "type": "text",
                "text": "Complete \(label) upstream MCP content (\(handle.sizeBytes) bytes, SHA-256 \(handle.sha256)) is available at the linked artifact.",
                "annotations": annotations
            ]
        ]
    }

    private func upstreamPreservationFailureResult(from result: [String: Any]) -> [String: Any] {
        let message = "MacRemote could not preserve complete upstream MCP content after the tool finished. The exit code is authoritative; do not retry solely because of this output error."
        var failed = result
        if var structured = failed["structuredContent"] as? [String: Any] {
            var stderr = structured["stderr"] as? String ?? ""
            if !stderr.isEmpty, !stderr.hasSuffix("\n") {
                stderr += "\n"
            }
            stderr += message
            structured["stderr"] = stderr
            structured["reason"] = "internal_error"
            failed["structuredContent"] = structured
            if var content = failed["content"] as? [[String: Any]], !content.isEmpty {
                content[0]["text"] = serializedJSON(structured)
                failed["content"] = content
            }
        }
        failed["isError"] = true
        return failed
    }

    private struct StdoutArtifactRegistration {
        let handle: ArtifactHandle?
        let preservationError: String?
    }

    private func registerStdoutArtifact(
        for outcome: ToolExecutionOutcome
    ) -> StdoutArtifactRegistration {
        if let preservationError = outcome.stdoutPreservationError {
            return StdoutArtifactRegistration(handle: nil, preservationError: preservationError)
        }

        let presentation = stdoutArtifactPresentation(for: outcome)
        if let spool = outcome.stdoutSpool {
            defer { spool.remove() }
            do {
                let handle = try artifactStore.register(
                    fileURL: spool.fileURL,
                    suggestedFilename: presentation.filename
                )
                return StdoutArtifactRegistration(handle: handle, preservationError: nil)
            } catch {
                return StdoutArtifactRegistration(
                    handle: nil,
                    preservationError: error.localizedDescription
                )
            }
        }

        let data = Data(outcome.stdout.utf8)
        let encodedByteCount = (try? JSONSerialization.checkedData(
            withJSONObject: [outcome.stdout],
            options: [.withoutEscapingSlashes]
        ).count)
            ?? data.count
        guard data.count > Self.mcpStdoutByteLimit
                || encodedByteCount > Self.stdoutArtifactEncodedByteThreshold else {
            return StdoutArtifactRegistration(handle: nil, preservationError: nil)
        }
        do {
            let handle = try artifactStore.register(
                data: data,
                suggestedFilename: presentation.filename
            )
            return StdoutArtifactRegistration(handle: handle, preservationError: nil)
        } catch {
            return StdoutArtifactRegistration(
                handle: nil,
                preservationError: error.localizedDescription
            )
        }
    }

    private func stdoutArtifactContentItems(
        handle: ArtifactHandle,
        outcome: ToolExecutionOutcome,
        base: String
    ) -> [[String: Any]] {
        let completeness = outcome.truncatedStdout
            ? "Captured tool output up to the configured limit"
            : "Full tool output"
        let resourceLink: [String: Any] = [
            "type": "resource_link",
            "uri": base + handle.artifactPath,
            "name": handle.filename,
            "mimeType": Self.mimeType(forFilename: handle.filename),
            "description": "\(completeness) (expires in \(handle.expiresInSeconds)s, \(handle.sizeBytes) bytes)."
        ]
        let note: [String: Any] = [
            "type": "text",
            "text": "\(completeness) (\(handle.sizeBytes) bytes, SHA-256 \(handle.sha256)) is available at the linked artifact."
        ]
        return [resourceLink, note]
    }

    private func stdoutArtifactPresentation(
        for outcome: ToolExecutionOutcome
    ) -> (filename: String, mimeType: String) {
        let trimmed = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercasedPrefix = String(trimmed.prefix(1024)).lowercased()
        let identity = "\(outcome.toolID) \(outcome.toolName)".lowercased()

        let fileExtension: String
        let mimeType: String
        if !outcome.stdoutBytesAreValidUTF8 {
            fileExtension = "bin"
            mimeType = "application/octet-stream"
        } else if (lowercasedPrefix.hasPrefix("{") || lowercasedPrefix.hasPrefix("["))
            && stdoutIsValidJSON(outcome)
        {
            fileExtension = "json"
            mimeType = "application/json"
        } else if lowercasedPrefix.hasPrefix("<svg")
            || (lowercasedPrefix.hasPrefix("<?xml") && lowercasedPrefix.contains("<svg"))
        {
            fileExtension = "svg"
            mimeType = "image/svg+xml"
        } else if lowercasedPrefix.hasPrefix("<!doctype html")
            || lowercasedPrefix.hasPrefix("<html")
        {
            fileExtension = "html"
            mimeType = "text/html"
        } else if lowercasedPrefix.hasPrefix("# ")
            || lowercasedPrefix.hasPrefix("## ")
            || lowercasedPrefix.hasPrefix("```")
        {
            fileExtension = "md"
            mimeType = "text/markdown"
        } else if identity.contains("svg") {
            fileExtension = "svg"
            mimeType = "image/svg+xml"
        } else if identity.contains("html") {
            fileExtension = "html"
            mimeType = "text/html"
        } else if identity.contains("markdown") {
            fileExtension = "md"
            mimeType = "text/markdown"
        } else {
            fileExtension = "txt"
            mimeType = "text/plain"
        }

        let filename = ArtifactStore.sanitizedFilename(
            "\(outcome.toolName)-output.\(fileExtension)"
        )
        return (filename, mimeType)
    }

    private func stdoutIsValidJSON(_ outcome: ToolExecutionOutcome) -> Bool {
        guard outcome.stdoutBytesAreValidUTF8 else { return false }

        if let spool = outcome.stdoutSpool {
            guard spool.sizeBytes <= Self.maximumJSONValidationBytes,
                  let stream = InputStream(url: spool.fileURL) else {
                return false
            }
            stream.open()
            defer { stream.close() }
            return (try? JSONSerialization.jsonObject(with: stream)) != nil
        }

        let data = Data(outcome.stdout.utf8)
        guard data.count <= Self.maximumJSONValidationBytes else { return false }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private func artifactToken(from path: String) -> String? {
        guard path.hasPrefix(Self.artifactPathPrefix) else { return nil }
        let token = String(path.dropFirst(Self.artifactPathPrefix.count))
        guard !token.isEmpty, !token.contains("/") else { return nil }
        return token
    }

    /// Answers GET or HEAD for a download link. HEAD describes the file and
    /// leaves the download count alone; GET uses one download and hands the
    /// open file back in `fileBody`, to be sent after these headers.
    private func artifactResponse(for request: HTTPRequest, token: String, fileBody: inout FileBody?) -> Data {
        let notFound = jsonErrorResponse(status: .notFound, error: "not_found", description: "Artifact not found.")
        let isHead = request.method == "HEAD"

        guard let resolved = isHead ? artifactStore.resolve(token: token) : artifactStore.consume(token: token),
              let attributes = try? FileManager.default.attributesOfItem(atPath: resolved.fileURL.path),
              let fileSize = (attributes[.size] as? NSNumber)?.intValue else {
            return notFound
        }

        if !isHead {
            guard let handle = try? FileHandle(forReadingFrom: resolved.fileURL) else {
                return notFound
            }
            fileBody = FileBody(handle: handle, byteCount: fileSize)
        }

        let contentType = Self.mimeType(forFilename: resolved.filename)
        let sanitizedFilename = ArtifactStore.sanitizedFilename(resolved.filename)

        return HTTPResponse(
            status: .ok,
            headers: [
                "Content-Type": contentType,
                "Content-Disposition": "attachment; filename=\"\(sanitizedFilename)\"",
                "Cache-Control": "no-store",
                "Content-Length": String(fileSize)
            ],
            body: ""
        ).data
    }

    private func serializedJSON(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.checkedData(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - MCP Apps (SEP-1865) shared widget

    /// One adaptive widget renders the uniform result envelope for every tool
    /// command. A safe semantic profile handles uncurated output, while explicit
    /// presentation metadata can refine rows, documents, accents, and actions
    /// without putting provider vocabulary in the shared HTML. Modern clients
    /// without the exact Apps capability get no widget linkage; legacy no-cap
    /// clients get compatibility aliases only. Every path keeps the meaningful
    /// text and structured fallback.
    static let widgetResourceURI = MCPAppsMetadata.resourceURI
    static let readableWidgetResourceURIs = MCPAppsMetadata.readableResourceURIs
    static let widgetMIMEType = MCPAppsMetadata.resourceMIMEType
    /// Namespaced `_meta` key on CallToolResult carrying MacRemote's render
    /// hints (declared UI actions, display metadata) to the widget.
    static let resultUIMetaKey = "net.viticci.macremote/ui"
    static let upstreamResultMetaKey = "net.viticci.macremote/upstream"
    static let upstreamExtensionsMetaKey = "net.viticci.macremote/upstream-extensions"
    static let upstreamPreservationMetaKey = "net.viticci.macremote/upstream-preservation"

    static let widgetHTML: String? = {
        guard let url = Bundle.module.url(forResource: "MacRemoteWidget", withExtension: "html") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    private var widgetAvailable: Bool { Self.widgetHTML != nil }

    private func widgetResourceDescriptor() -> [String: Any] {
        MCPAppsMetadata.resourceDescriptor
    }

    private func catalogResourceDescriptor() -> [String: Any] {
        [
            "uri": MCPCatalogMetadata.resourceURI,
            "name": "macremote-catalog",
            "title": "MacRemote Tool Catalog",
            "description": "Compact names, titles, capabilities, sources, and schema revisions for the shared MacRemote tools.",
            "mimeType": MCPCatalogMetadata.resourceMIMEType
        ]
    }

    private func resourcesList(id: Any?) -> Data {
        var resources = [catalogResourceDescriptor()]
        if widgetAvailable, requestAllowsWidgetCompatibility {
            resources.append(widgetResourceDescriptor())
        }
        return jsonRPCResult(id: id, result: [
            "resources": resources
        ])
    }

    private func resourcesRead(id: Any?, message: [String: Any]) -> Data {
        guard let uri = (message["params"] as? [String: Any])?["uri"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing resource uri.")
        }
        if uri == MCPCatalogMetadata.resourceURI {
            let snapshot = catalogSnapshot()
            let manifest = MCPCatalogMetadata.manifest(
                tools: snapshot.tools,
                descriptors: snapshot.descriptors
            )
            return jsonRPCResult(id: id, result: [
                "contents": [
                    [
                        "uri": uri,
                        "mimeType": MCPCatalogMetadata.resourceMIMEType,
                        "text": serializedJSON(manifest)
                    ]
                ]
            ])
        }
        guard Self.readableWidgetResourceURIs.contains(uri),
              let html = Self.widgetHTML else {
            return jsonRPCError(
                id: id,
                code: Self.activeProtocolContext?.isModern == true ? -32602 : -32002,
                message: "Unknown resource: \(uri)"
            )
        }
        return jsonRPCResult(id: id, result: [
            "contents": [
                [
                    "uri": uri,
                    "mimeType": Self.widgetMIMEType,
                    "text": html,
                    // SEP-1865 sandbox hints: the widget makes no fetch/XHR
                    // calls (connect stays empty), and loads images from
                    // exactly one origin — Pocket Casts episode artwork.
                    "_meta": widgetContentMetadata
                ]
            ]
        ])
    }

    /// Catalog-authored metadata is authoritative. The three historical
    /// category defaults preserve richer rendering for already-installed
    /// reminder, podcast, and habit tools that predate the typed field.
    /// Everything else receives the schema-free semantic result profile. No
    /// executable or semantic-id matching happens here.
    private static func widgetPresentation(
        for tool: ToolDefinition
    ) -> ToolWidgetPresentation? {
        if let presentation = tool.widgetPresentation {
            return presentation.automatic == false ? nil : presentation
        }
        // Flexible Commands can return any payload their app supports, so they
        // use only the schema-free semantic renderer. They never inherit a
        // category's legacy row assumptions accidentally.
        if tool.isGenericCLIAdapter {
            return ToolWidgetPresentation(profile: .semanticResult)
        }
        switch tool.category {
        case .reminders:
            return ToolWidgetPresentation(profile: .reminderRows, accent: "#8b5cf6")
        case .podcasts:
            return ToolWidgetPresentation(profile: .episodeRows, accent: "#f43e37")
        case .habits:
            return ToolWidgetPresentation(profile: .habitRows, accent: "#2a9df4")
        default:
            return ToolWidgetPresentation(profile: .semanticResult)
        }
    }

    static func widgetEligible(tool: ToolDefinition) -> Bool {
        widgetPresentation(for: tool) != nil
    }

    /// Render hints attached to CallToolResult._meta. Stable semantic tool ids
    /// are also the public MCP names used by widget calls through the host.
    /// Nil when the tool shows no card, so the result carries no UI linkage.
    private func resultUIMeta(for tool: ToolDefinition, tools: [ToolDefinition]) -> [String: Any]? {
        guard widgetAvailable,
              resultCardPreferences().allowsCard(for: tool),
              let presentation = Self.widgetPresentation(for: tool) else { return nil }
        var payload: [String: Any] = [
            "version": 1,
            "profile": presentation.profile.rawValue,
            "toolTitle": tool.name,
            "toolName": tool.id,
            "capability": tool.capability.rawValue,
            "category": tool.category.title
        ]
        if let accent = Self.widgetAccent(for: presentation) {
            payload["accent"] = accent
        }
        payload["table"] = Self.widgetTableHints(for: presentation)
        if let actions = tool.uiActions, !actions.isEmpty {
            let encodedActions: [[String: Any]] = actions.compactMap { action in
                guard let targetTool = resolveActionTarget(action, in: tools),
                      let encoded = try? JSONEncoder().encode(action),
                      var json = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
                    return nil
                }
                json["toolName"] = targetTool.id
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

    /// Per-presentation accent. Two tools in one broad category can still read
    /// as different apps: Pocket Casts red and Overcast orange coexist here.
    private static func widgetAccent(for presentation: ToolWidgetPresentation) -> String? {
        if let accent = presentation.accent, !accent.isEmpty {
            return accent
        }
        switch presentation.profile {
        case .semanticResult: return nil
        case .reminderRows: return "#8b5cf6"
        case .episodeRows: return "#f43e37"
        case .habitRows: return "#2a9df4"
        case .noteRows: return "#d99a00"
        }
    }

    /// Podcast artwork endpoint (Pocket Casts CDN, keyed by podcast UUID).
    /// Must stay in sync with the widget resource's CSP `resourceDomains`.
    static let podcastArtworkURLTemplate = "https://static.pocketcasts.com/discover/images/webp/200/{value}.webp"

    /// Per-category table hints: a curated column set (keeps the trailing
    /// action buttons on-screen), derived presentation-only columns, and which
    /// raw columns to drop. The widget falls back to auto columns without this.
    /// Every curated category also curates `change`: a write confirmation
    /// keyed by the command's own action name (`status` for remctl, `action`
    /// for pocketctl and habitctl), which is what turns a bare
    /// `{status, id, title}` answer into a sentence instead of a key/value
    /// tree. Podcasts additionally curate `groups` (ordered sections for a
    /// payload carrying several row arrays). Both are consumed generically by
    /// the widget — no CLI-specific code paths there.
    private static func widgetTableHints(
        for presentation: ToolWidgetPresentation
    ) -> [String: Any] {
        var hints = widgetTableHints(for: presentation.profile)
        if let rootPath = presentation.rootPath, !rootPath.isEmpty {
            hints["rootPath"] = rootPath
        }
        return hints
    }

    private static func widgetTableHints(
        for profile: ToolWidgetPresentation.Profile
    ) -> [String: Any] {
        switch profile {
        case .semanticResult:
            // Deliberately empty. The shared widget derives a safe human
            // summary without assuming a provider schema or exposing wire data.
            return [:]
        case .reminderRows:
            return [
                // Leading check circle + trailing actions are added by the
                // widget; these are the visible data columns, in order.
                "columns": [
                    ["key": "when", "title": "When", "derive": "datetime",
                     "sourceKey": ["displayDate", "dueDate"], "allDayKey": "allDay"],
                    ["key": "title", "title": "Task", "primary": true],
                    ["key": "list", "title": "List", "subtitleKey": "section"],
                    ["key": "recurrence", "title": "Repeats", "derive": "recurrence",
                     "sourceKey": "recurrence"],
                    ["key": "flag", "title": "Flag", "derive": "booleanLabel",
                     "sourceKey": ["flagged", "isFlagged"], "trueLabel": "Flagged"]
                ],
                // Explicitly dropped if a row shape forces auto columns:
                // identity/state fields already represented by controls or
                // derived columns, plus recurrence's nested wire object.
                "hiddenColumns": [
                    "id", "completed", "recurrence", "flagged", "isFlagged"
                ],
                // remctl answers a write with `{status, id, title, …}` — a
                // status, not rows — which used to land in the raw key/value
                // tree. `titles` is the recognition set as well as the copy,
                // so a payload whose status is absent from it (an error, an
                // unknown future status) falls through untouched. `title` is
                // the only human-readable field remctl echoes, so it carries
                // the dim line under the headline. `unchanged` is remctl's
                // structured no-op result (edit with nothing to change): a
                // real outcome, worth a neutral line instead of a tree.
                "change": [
                    // No `countKey`/`countNoun`: remctl writes answer about one
                    // reminder and carry no collection to count.
                    "actionKey": "status",
                    "titleKey": "title",
                    "warningsKey": "warnings",
                    "warningActions": ["partial"],
                    "errorKey": "error.message",
                    "detailKeys": ["list", "section", "resolvedList.title"],
                    "batch": [
                        "rowsKey": "results", "statusKey": "status", "titleKey": "title",
                        "idKey": "id", "messageKey": "message", "operationKey": "operation",
                        "succeededKey": "succeeded", "uncertainKey": "uncertain",
                        "titles": ["done": "Marked done", "undone": "Marked not done", "delete": "Deleted"]
                    ],
                    "titles": [
                        "created": "Reminder created",
                        "updated": "Reminder updated",
                        "completed": "Marked done",
                        "uncompleted": "Marked not done",
                        "deleted": "Reminder deleted",
                        "flagged": "Reminder flagged",
                        "unflagged": "Reminder unflagged",
                        "restored": "Reminder restored",
                        "already_restored": "Reminder already restored",
                        "moved": "Reminder moved",
                        "partial": "Created, but one step failed",
                        "unchanged": "No changes"
                    ]
                ]
            ]
        case .episodeRows:
            return [
                // Failed writes can require reconciliation with the upstream
                // service. Do not encourage an automatic retry from the
                // result card; the model-facing error still carries the
                // provider's exact recovery guidance.
                "retryOnError": false,
                // One semantic episode profile covers flat and enveloped
                // podcast tools. Fallback paths let each row keep only facts
                // it actually supplies; the renderer drops absent columns.
                "columns": [
                    ["key": "artwork", "title": "", "derive": "artwork",
                     "sourceKey": ["podcastUuid", "podcast"], "altKey": "podcastTitle",
                     "urlTemplate": podcastArtworkURLTemplate],
                    ["key": "title", "title": "Episode", "primary": true,
                     "subtitleKey": ["podcastTitle", "subtitle", "author"]],
                    ["key": "tier", "title": "Tier", "derive": "text",
                     "sourceKey": "ranking.tier"],
                    ["key": "left", "title": "Left", "derive": "duration",
                     "sourceKey": ["timeLeftSeconds", "timeRemaining"]],
                    ["key": "duration", "title": "Duration", "derive": "duration",
                     "sourceKey": ["durationSeconds", "duration"]],
                    ["key": "progress", "title": "Played", "derive": "progress",
                     "sourceKey": ["playedUpTo", "progressSeconds", "progress"],
                     "totalKey": ["durationSeconds", "duration"],
                     "format": "seconds"],
                    ["key": "url", "title": "Link", "derive": "link",
                     "sourceKey": ["url", "overcastURL", "linkURL"]],
                    ["key": "published", "title": "Published", "derive": "datetime",
                     "sourceKey": ["publishedAt", "published", "publishedDate"]]
                ],
                "hiddenColumns": ["uuid", "published", "fileType", "size",
                                  "podcastUuid", "podcast", "podcastTitle",
                                  "playingStatus", "episodeType",
                                  "episodeSeason", "isDeleted", "podcastSlug",
                                  "slug", "alternateEnclosures", "bookmarks",
                                  "type", "explicit", "hasVideoEpisodes",
                                  "publishedDate", "episodeID", "podcastID",
                                  "subtitle", "ranking", "progressSeconds",
                                  "durationSeconds", "timeLeftSeconds",
                                  "timeRemaining", "progressPercent",
                                  "cumulativeTimeLeftSeconds", "durationState",
                                  "publishedAtEpoch", "updatedAt", "updatedAtEpoch",
                                  "played", "inProgress", "starred", "userDeleted",
                                  "body", "summary", "extra", "feedURL", "webURL",
                                  "itunesID"],
                "groups": [
                    ["key": "now", "title": "Now Playing", "style": "card"],
                    ["key": "up_next", "title": "Up Next", "numbered": true],
                    ["key": "in_progress", "title": "In Progress"],
                    ["key": "new_releases", "title": "New Releases"],
                    ["key": "podcasts", "title": "Podcasts"],
                    ["key": "episodes", "title": "Episodes"],
                    ["key": "items", "title": "Up Next", "numbered": true]
                ],
                "document": [
                    "bodyKey": "text",
                    "titleKey": "title",
                    "fallbackTitle": "Transcript"
                ],
                // Absolute paths resolve against the complete raw value, even
                // when rootPath selects a nested record for presentation.
                "context": [
                    ["path": "meta.source", "title": "Source"],
                    ["path": "meta.live", "title": "Live"],
                    ["path": "data.provider", "title": "Provider"],
                    ["path": "data.format", "title": "Format"],
                    ["path": "data.verified", "title": "Read Back"],
                    ["path": "data.verificationConclusive", "title": "Conclusive"],
                    ["path": "data.receiptStored", "title": "Receipt Kept"]
                ],
                "change": [
                    "actionKey": "action",
                    "episodeKey": "episode",
                    "queueKey": "up_next",
                    "queueTitle": "Up Next",
                    "dryRunKey": ["dry_run", "dryRun"],
                    "countKey": "up_next_count",
                    "countNoun": "episode",
                    "countNounPlural": "episodes",
                    "outcomeKey": "status",
                    "outcomeTitles": [
                        "no_change": "End state already matched"
                    ],
                    "submittedKey": "submitted",
                    "verifiedKey": "verified",
                    "unverifiedWarning": "The write was not confirmed by read-back.",
                    "titleKey": "playlistTitle",
                    "titles": [
                        "play-now": "Playing now",
                        "play-next": "Queued to play next",
                        "play-last": "Added to the end of Up Next",
                        "remove-up-next": "Removed from Up Next",
                        "episode-done": "Marked played",
                        "episode-unplayed": "Marked unplayed",
                        "episode-star": "Starred",
                        "episode-unstar": "Unstarred",
                        "episode-archive": "Archived",
                        "episode-unarchive": "Unarchived",
                        "episode-progress": "Playback position set",
                        "episode-mark-played": "Updated playback",
                        "queue-add": "Added to Queue",
                        "queue-remove": "Removed from Queue",
                        "queue-reorder": "Queue reordered",
                        "done": "Marked played",
                        "unplayed": "Marked unplayed",
                        "star": "Starred",
                        "unstar": "Unstarred",
                        "save": "Saved",
                        "progress": "Playback position set",
                        "archive": "Archived",
                        "restore": "Restored"
                    ]
                ]
            ]
        case .habitRows:
            return [
                // Habit-shaped rows (habitctl today/journal/habits). The
                // leading check circle comes from the checkOff action
                // (`habitctl_record_result`, filled when status ==
                // "completed"); streak and goal read the nested habitctl
                // fields via dot-paths. Goal renders the count fraction
                // ("1/1", "3/8") — habit goals are reps, not seconds.
                // The last two columns belong to habitctl's OTHER shape: a
                // habit DEFINITION (`habitctl show`/`search`) has no streak and
                // no daily progress, and a journal row has no goals array or
                // start date. The widget drops curated columns whose source
                // fields are absent, so one curation covers both shapes —
                // journal rows keep Streak/Goal, definitions keep
                // Target/Started, and neither falls back to raw JSON columns.
                "columns": [
                    ["key": "name", "title": "Habit", "primary": true,
                     "subtitleKey": "description"],
                    ["key": "streak", "title": "Streak", "derive": "quantity",
                     "sourceKey": "currentStreak.length",
                     "unitKey": "currentStreak.unit"],
                    ["key": "goal", "title": "Goal", "derive": "progress",
                     "sourceKey": "progress.current",
                     "totalKey": "progress.target",
                     "unitKey": "progress.unit"],
                    // Dot-paths index arrays too: `goals.0` is the definition's
                    // first (and, for every habit habitctl emits, only) goal.
                    ["key": "target", "title": "Target", "derive": "quantity",
                     "sourceKey": "goals.0.value",
                     "unitKey": "goals.0.unit"],
                    // habitctl serializes the start DAY as a full ISO
                    // timestamp, so without `allDay` the cell would read
                    // "Jan 4, 12:00 AM" — a midnight that means nothing.
                    ["key": "startDate", "title": "Started", "derive": "datetime",
                     "sourceKey": "startDate", "allDay": true]
                ],
                // Definition-shape noise on top of the journal-row noise:
                // nested objects/arrays that would print as raw JSON, plus the
                // fields already shown by a curated column (goals, description).
                "hiddenColumns": ["id", "status", "color", "iconNamed",
                                  "timeOfDayIds", "type", "logInfo",
                                  "colorHex", "icon", "logMethod", "createdAt",
                                  "occurrence", "reminders", "timeOfDays",
                                  "goals", "customUnitName", "isArchived",
                                  "description"],
                // habitctl's real writes answer with the action it performed
                // and the resolved habit name (`_emit_write`), never rows. The
                // five keys are habitctl's own intent actions; a write outside
                // them (a dry-run preview of another command, an error) falls
                // through to the other states untouched.
                "change": [
                    "actionKey": "action",
                    "titleKey": "habit",
                    "dryRunKey": "dry_run",
                    "titles": [
                        "complete": "Checked off",
                        "failed": "Marked failed",
                        "skipped": "Skipped",
                        "undo": "Check-off undone",
                        "log": "Logged"
                    ]
                ]
            ]
        case .noteRows:
            return [
                "columns": [
                    ["key": "title", "title": "Note", "primary": true,
                     "subtitleKey": "bodyPreview"],
                    ["key": "modified", "title": "Modified", "derive": "datetime",
                     "sourceKey": "modified"],
                    ["key": "folder", "title": "Folder"],
                    ["key": "account", "title": "Account"],
                    ["key": "attachments", "title": "Attachments", "derive": "quantity",
                     "sourceKey": "attachmentCount", "unit": "attachment"],
                    ["key": "pinned", "title": "Pinned", "derive": "booleanLabel",
                     "sourceKey": ["pinned", "isPinned"], "trueLabel": "Pinned"],
                    ["key": "locked", "title": "Locked", "derive": "booleanLabel",
                     "sourceKey": ["isLocked", "locked"], "trueLabel": "Locked"]
                ],
                "hiddenColumns": [
                    "id", "identifier", "titleSource", "folderId", "accountId",
                    "created", "modifiedCheckpoint", "pinned", "isPinned",
                    "isLocked", "locked", "hasChecklist",
                    "hasEmphasis", "isSystemPaper", "attachmentCount", "bodyPreview",
                    "textDecoded", "wordCount", "body", "decodedStrings"
                ],
                "document": [
                    "bodyKey": ["markdown", "transcript"],
                    "titleFromFirstHeading": true,
                    "fallbackTitle": "Note"
                ],
                "groups": [
                    [
                        "key": "transcripts",
                        "title": "Transcripts",
                        "style": "documentList",
                        "bodyKey": ["transcript", "message"],
                        "statusKey": "status",
                        "statusTitles": ["ok": "Available", "error": "Error"],
                        "pendingKey": "needsTranscription",
                        "pendingTitle": "Pending",
                        "fallbackRowTitle": "Recording"
                    ]
                ],
                "context": [
                    ["path": "blocksApplied", "title": "Blocks Added"],
                    ["path": "blocksPlanned", "title": "Blocks Planned"],
                    ["path": "operationCount", "title": "Operations"],
                    ["path": "wouldChange", "title": "Would Change"],
                    ["path": "pushState", "title": "Sync"],
                    ["path": "syncDurability", "title": "Durability"]
                ],
                "change": [
                    "actionKey": "status",
                    "dryRunKey": "dryRun",
                    "warningsKey": "warnings",
                    "previewActions": ["planned"],
                    "titles": [
                        "planned": "Preview ready",
                        "created": "Note created",
                        "updated": "Note updated",
                        "deleted": "Moved to Recently Deleted",
                        "ok": "No changes"
                    ]
                ]
            ]
        }
    }

    /// Catalog actions primarily address stable semantic ids. A basename can
    /// still mean "the shared flexible adapter for this executable" when the
    /// action intentionally targets a user-created adapter. Unresolvable
    /// actions are dropped — the widget simply doesn't offer them.
    private func resolveActionTarget(_ action: ToolUIAction, in tools: [ToolDefinition]) -> ToolDefinition? {
        if let toolID = action.toolID {
            return tools.first { $0.id == toolID }
        }
        if let basename = action.targetExecutableBasename {
            let requestedBasename = basename.lowercased()
            return tools.first {
                guard $0.isGenericCLIAdapter else { return false }
                let actualBasename = URL(fileURLWithPath: $0.executablePath)
                    .lastPathComponent
                    .lowercased()
                if actualBasename == requestedBasename {
                    return true
                }
                return Self.isPocketCTLExecutableName(requestedBasename)
                    && Self.isPocketCTLExecutableName(actualBasename)
            }
        }
        return nil
    }

    private func toolsList(id: Any?, message: [String: Any]) -> Data {
        // Return the entire shared catalog in one response. MCP allows
        // paginating `tools/list` with an opaque cursor, but real clients
        // (Raycast, Minis, Claude.ai) fetch the first page and ignore
        // `nextCursor`, so paginating silently hid every tool past the first
        // page. The catalog is small enough to serve inline, and "feature
        // parity is sacred" (AGENTS.md) means every shared tool must be
        // discoverable. We never issue a cursor, so any `cursor` param a
        // client sends is stale/unsolicited and is ignored (spec: cursors are
        // opaque tokens the server hands out — we hand out none).
        let snapshot = catalogSnapshot()
        // The tool array was serialized once with the snapshot. A placeholder
        // holds its place while the small envelope is serialized, then the
        // bytes go in: the body is identical to serializing it whole.
        let result: [String: Any] = [
            "tools": Self.toolsPlaceholder,
            "_meta": [
                MCPCatalogMetadata.revisionMetaKey: snapshot.revision
            ]
        ]
        return jsonRPCResult(
            id: id,
            result: result,
            splicing: (placeholder: Self.toolsPlaceholder, json: snapshot.serializedDescriptors)
        )
    }

    /// Unguessable, so no client-supplied value (such as a request id) can
    /// match it.
    private static let toolsPlaceholder = "macremote-tools-" + UUID().uuidString

    private func catalogSnapshot(
        for suppliedTools: [ToolDefinition]? = nil
    ) -> CatalogSnapshot {
        let supplied = suppliedTools ?? toolProvider()
        let isModern = Self.activeProtocolContext?.isModern == true
        let cards = resultCardPreferences()
        let key = CatalogSnapshotCache.Key(
            tools: supplied,
            cards: cards,
            isModern: isModern,
            supportsStandardUI: requestSupportsStandardUI
        )
        return catalogSnapshotCache.snapshot(for: key) {
            let tools = isModern ? supplied.sorted { $0.id < $1.id } : supplied
            let descriptors = tools.map { toolJSON($0, cards: cards) }
            return CatalogSnapshot(
                tools: tools,
                descriptors: descriptors,
                revision: MCPCatalogMetadata.revision(for: descriptors),
                serializedDescriptors: (try? JSONSerialization.checkedData(
                    withJSONObject: descriptors,
                    options: [.sortedKeys, .withoutEscapingSlashes]
                )) ?? Data("[]".utf8)
            )
        }
    }

    /// Whether `tool` links the result card: the catalog allows one and the
    /// owner has cards on for its family (SPEC D77).
    private static func showsResultCard(for tool: ToolDefinition, cards: ResultCardPreferences) -> Bool {
        cards.allowsCard(for: tool) && widgetEligible(tool: tool)
    }

    private func toolJSON(_ tool: ToolDefinition, cards: ResultCardPreferences) -> [String: Any] {
        let securitySchemes: [[String: Any]] = [
            [
                "type": "oauth2",
                "scopes": ["mcp:tools"]
            ]
        ]
        let rawInputSchema = inputSchema(for: tool)
        let publishedInputSchema = Self.activeProtocolContext?.isModern == true
            ? mirroredHeaderSchema(for: rawInputSchema).schema
            : rawInputSchema
        var json: [String: Any] = [
            "name": tool.id,
            "title": tool.name,
            "description": toolDescription(for: tool),
            "inputSchema": publishedInputSchema,
            "outputSchema": outputSchema(),
            "annotations": annotations(for: tool),
            "securitySchemes": securitySchemes
        ]
        var meta: [String: Any] = ["securitySchemes": securitySchemes]
        if widgetAvailable,
           requestAllowsWidgetCompatibility,
           Self.showsResultCard(for: tool, cards: cards) {
            // Standard MCP Apps metadata stays primary. The flat MCP key and
            // OpenAI key are additive aliases for older host paths. A tool
            // without this linkage returns the same text and structured
            // result; the app just shows it as plain text.
            meta = widgetLinkMetadata(merging: meta)
        }
        json["_meta"] = meta
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
            parts.append("Bridged from the `\(bridge.serverName)` MCP server; forwards JSON to its `\(bridge.toolName)` tool. No shell or executable.")
        } else if let bridge = tool.mcpStdioBridge {
            parts.append("Bridged from the `\(bridge.serverName)` MCP server (stdio); forwards JSON to its `\(bridge.toolName)` tool. No shell.")
        } else if tool.isGenericCLIAdapter {
            parts.append("Pass exact argv items in `args` (optional `stdin`). No shell: absolute paths only; no `~`, `$HOME`, pipes, redirection, globs, substitution, or env assignments; one flag/value per argv item.")

            switch URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() {
            case "claude":
                parts.append("For Claude Code, prefer non-interactive MCP-safe calls using `--print` with `--output-format text`, `json`, or `stream-json`; pass the prompt as the final argv item or via `stdin` with `--input-format text`.")
                parts.append("Use explicit flags such as `--model`, `--permission-mode`, `--allowedTools`, `--disallowedTools`, `--add-dir`, `--mcp-config`, `--strict-mcp-config`, `--session-id`, and `--max-budget-usd` as separate argv items. Avoid bare interactive sessions, `auth login`, and `mcp login` unless the host Mac is attended.")
            case "codex":
                parts.append("For Codex, global options such as `--ask-for-approval` and `--sandbox` must appear before `exec`; options after `exec` are parsed by the exec subcommand.")
            default:
                break
            }
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
        var schema = parameter.jsonSchema?.anyValue as? [String: Any] ?? [
            "title": parameter.title,
            "description": parameterDescription(parameter, for: tool)
        ]
        schema["title"] = parameter.title
        schema["description"] = parameterDescription(parameter, for: tool)

        switch parameter.kind {
        case .string:
            schema["type"] = "string"
            if let format = parameter.stringFormat {
                schema["format"] = format
            }
            if let allowedValues = parameter.allowedValues {
                schema["enum"] = allowedValues
            }
            if parameter.name == "stdin" {
                schema["maxLength"] = min(
                    parameter.maximumLength ?? ToolArgumentResolver.maximumExecutionInputBytes,
                    ToolArgumentResolver.maximumExecutionInputBytes
                )
            } else if let maximumLength = parameter.maximumLength {
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
            var itemSchema: [String: Any] = [
                "type": "string",
                "maxLength": parameter.maximumLength
                    ?? ToolArgumentResolver.defaultStringArrayItemMaximumLength
            ]
            if let format = parameter.stringFormat {
                itemSchema["format"] = format
            }
            schema["items"] = itemSchema
            schema["maxItems"] = 64
        case .boolean:
            schema["type"] = "boolean"
        case .number:
            schema["type"] = "number"
            if let range = parameter.numberRange {
                schema["minimum"] = range.lowerBound
                schema["maximum"] = range.upperBound
            }
        case .json:
            if schema["type"] == nil {
                schema["type"] = "object"
            }
            if let maximumLength = parameter.maximumLength {
                schema["x-macremote-maxEncodedBytes"] = maximumLength
            }
        }

        if let defaultValue = parameter.defaultValue {
            switch parameter.kind {
            case .integer:
                // ToolParameter persists defaults as strings, but JSON Schema
                // defaults must use the type advertised by the schema.
                if let integer = Int(defaultValue) {
                    schema["default"] = integer
                }
            case .string:
                schema["default"] = defaultValue
            case .stringArray:
                // ToolParameter has no persisted array representation for a
                // schema default, so do not advertise an invented one.
                break
            case .boolean:
                if let boolean = Bool(defaultValue) {
                    schema["default"] = boolean
                }
            case .number:
                if let number = Double(defaultValue), number.isFinite {
                    schema["default"] = number
                }
            case .json:
                break
            }
        }
        return schema
    }

    private func parameterDescription(_ parameter: ToolParameter, for tool: ToolDefinition) -> String {
        switch parameter.name {
        case "args", "argv":
            switch URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() {
            case "pocketctl", "pctl", "pocketcasts":
                return "Exact PocketCTL argv items. No shell is used. Prefer `--json`; `open URL --json` resolves a share link without changing playback, while `open URL --seek` writes progress and should use `--dry-run --json` first. Use `--dry-run --json` before queue, playlist, bookmark, archive, progress, or played-state writes unless the user explicitly requested the write."
            case "habitctl":
                return "Exact HabitCTL argv items. No shell is used. Prefer `--json`; use `--dry-run --json` before creating, editing, deleting, checking, logging, archiving, or note writes when supported unless the user explicitly requested the write."
            case "goodlinksctl":
                return "Exact GoodLinksCTL argv items. No shell is used. Prefer `--json` for reads. Resolve exact link IDs with a fresh read, verify every write with `links get`, and run `links delete ID --dry-run` before `links delete ID --yes`."
            case "frames":
                return "Exact Apple Frames argv items. No shell is used. Prefer a leading `--json` when supported. `frame` and `video` write output files, `setup` changes downloaded assets, and `colors` is interactive."
            case "iris", "iphone":
                return "Exact Iris argv items. No shell is used. Always pass `--json`. Use `--dry-run --offline` to validate without the app or phone. `--confirm <action id>` is required by Iris itself for its 13 confirmation actions. Pairing, device authorization, and transport management stay blocked."
            default:
                return "Exact argv items to pass to the executable. No shell is used: do not include `~`, variables, pipes, redirection, globs, or combined command strings. Resolved argv plus standard input must fit within \(ToolArgumentResolver.maximumExecutionInputBytes / 1024) KiB of UTF-8 data."
            }
        case "stdin":
            return "Optional standard input passed directly to the process. Resolved argv plus standard input must fit within \(ToolArgumentResolver.maximumExecutionInputBytes / 1024) KiB of UTF-8 data."
        default:
            return parameter.description ?? parameter.title
        }
    }

    private func annotations(for tool: ToolDefinition) -> [String: Any] {
        var annotations = tool.mcpBridgeAnnotations?.anyValue as? [String: Any] ?? [:]
        annotations["title"] = tool.name
        annotations["readOnlyHint"] = !tool.asksBeforeRunning
        annotations["destructiveHint"] = tool.capability == .destructive
        if annotations["idempotentHint"] == nil {
            annotations["idempotentHint"] = tool.annotationOverrides?.idempotentHint
                ?? (tool.capability == .readOnly && !tool.isGenericCLIAdapter)
        }
        if annotations["openWorldHint"] == nil {
            annotations["openWorldHint"] = tool.annotationOverrides?.openWorldHint
                ?? (tool.isGenericCLIAdapter || tool.capability != .readOnly || tool.isMCPBridge)
        }
        return annotations
    }

    private func jsonRPCResult(
        id: Any?,
        result: [String: Any],
        status: HTTPResponse.Status = .ok,
        splicing splice: (placeholder: String, json: Data)? = nil
    ) -> Data {
        var result = result
        if let context = Self.activeProtocolContext, context.isModern {
            if result["resultType"] == nil {
                result["resultType"] = "complete"
            }
            if Self.modernCacheableMethods.contains(context.method) {
                result["ttlMs"] = 0
                result["cacheScope"] = "private"
            }
            var meta = result["_meta"] as? [String: Any] ?? [:]
            meta[Self.serverInfoMetaKey] = serverInfo(base: context.baseURL)
            result["_meta"] = meta
        }
        return jsonResponse([
            "jsonrpc": "2.0",
            "id": jsonID(id),
            "result": result
        ], status: status, headers: mcpResponseHeaders(), splicing: splice)
    }

    private func jsonRPCError(
        id: Any?,
        code: Int,
        message: String,
        data: [String: Any]? = nil,
        status: HTTPResponse.Status = .ok
    ) -> Data {
        var error: [String: Any] = [
            "code": code,
            "message": message
        ]
        if let data {
            error["data"] = data
        }
        return jsonResponse([
            "jsonrpc": "2.0",
            "id": jsonID(id),
            "error": error
        ], status: status, headers: mcpResponseHeaders())
    }

    private func mcpResponseHeaders() -> [String: String] {
        [
            Self.protocolVersionHeader:
                Self.activeProtocolContext?.version ?? Self.latestLegacyProtocolVersion
        ]
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

    private func oauthErrorResponse(_ error: Error, headers: [String: String] = [:]) -> Data {
        if let oauthError = error as? OAuthError {
            let status: HTTPResponse.Status = oauthError.errorCode == "invalid_client" ? .unauthorized : .badRequest
            return jsonErrorResponse(
                status: status,
                error: oauthError.errorCode,
                description: oauthError.localizedDescription,
                headers: headers
            )
        }

        return jsonErrorResponse(
            status: .badRequest,
            error: "invalid_request",
            description: error.localizedDescription,
            headers: headers
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

    /// `splice` replaces the JSON string `placeholder` in the serialized
    /// body with already-serialized JSON.
    private func jsonResponse(
        _ object: [String: Any],
        status: HTTPResponse.Status = .ok,
        headers: [String: String] = [:],
        splicing splice: (placeholder: String, json: Data)? = nil
    ) -> Data {
        var data = (try? JSONSerialization.checkedData(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        if let splice, let range = data.range(of: Data("\"\(splice.placeholder)\"".utf8)) {
            data.replaceSubrange(range, with: splice.json)
        }
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
            "name": MacRemoteProductInfo.name,
            "version": MacRemoteProductInfo.version,
            "title": MacRemoteProductInfo.name,
            "description": "Approved local CLI tools on this Mac, exposed over MCP.",
            "websiteUrl": MacRemoteProductInfo.websiteURL,
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
            <p>This Mac shares only the tools you choose. Apps use the selected sign-in method. Tools marked Asks First ask before running unless you choose Always Allow.</p>
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

    private static func staticResourceData(fileName: String) -> Data? {
        var candidateURLs = [Bundle.main.resourceURL?.appendingPathComponent(fileName)].compactMap { $0 }
        #if DEBUG
        // Development and test builds have no app bundle, so they read the
        // checkout. A release build must never look outside its own bundle:
        // the path below is the build machine's.
        candidateURLs.append(
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
                .appendingPathComponent(fileName)
        )
        #endif
        return candidateURLs.lazy.compactMap { try? Data(contentsOf: $0) }.first
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
                  // A refusal travels back only to a web address. Opening an
                  // app link here would happen with no decision by the owner.
                  if (status.redirect_uri && /^https?:/i.test(status.redirect_uri)) {
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
                <p>Code: <strong><code>\(ApprovalRequest.verificationCode(for: requestID).htmlEscaped)</code></strong><br>Approve on the Mac only if it shows this same code.</p>
                <footer>Request ID: <code>\(requestID.uuidString.htmlEscaped)</code></footer>
            """,
            extraStyle: waitingStyle,
            script: script
        )
    }

    private static let portRange: ClosedRange<UInt16> = 49_152...65_000

    private static func availablePort() throws -> UInt16 {
        let randomCandidates = (0..<128).map { _ in UInt16.random(in: portRange) }
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

/// One-shot rendezvous between NWListener's state queue and the thread
/// waiting in `start()`: first resolution wins, later state changes are
/// ignored (a listener can go `.ready` and later `.cancelled`).
/// The published tool list and its revision for one catalog.
struct CatalogSnapshot: @unchecked Sendable {
    let tools: [ToolDefinition]
    let descriptors: [[String: Any]]
    let revision: String
    /// `descriptors` as the JSON array tools/list sends.
    let serializedDescriptors: Data
}

/// Builds each tools/list catalog once. A descriptor depends only on the
/// tools, the owner's card choice, and the client's protocol era and MCP Apps
/// support, so those four values are the key; a change to any of them builds
/// a fresh snapshot on the very next request. Comparing the tool arrays is
/// cheap: the provider hands back the same stored array until it changes.
private final class CatalogSnapshotCache: @unchecked Sendable {
    struct Key: Equatable {
        let tools: [ToolDefinition]
        let cards: ResultCardPreferences
        let isModern: Bool
        let supportsStandardUI: Bool
    }

    /// One entry per client shape seen recently (legacy, modern, with or
    /// without MCP Apps).
    private static let capacity = 4
    private let lock = NSLock()
    private var entries: [(key: Key, snapshot: CatalogSnapshot)] = []

    func snapshot(for key: Key, build: () -> CatalogSnapshot) -> CatalogSnapshot {
        lock.lock()
        if let hit = entries.first(where: { $0.key == key }) {
            lock.unlock()
            return hit.snapshot
        }
        lock.unlock()
        let snapshot = build()
        lock.lock()
        entries.removeAll { $0.key.isModern == key.isModern && $0.key.supportsStandardUI == key.supportsStandardUI }
        entries.append((key, snapshot))
        if entries.count > Self.capacity { entries.removeFirst() }
        lock.unlock()
        return snapshot
    }
}

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
    /// True for the first refusal in a window, so a flood writes one Activity
    /// line instead of pushing everything else out of the log.
    var shouldLog = false
}

/// Limits unauthenticated public requests per caller, with a higher ceiling
/// for all callers together. One shared bucket per endpoint would let a single
/// stranger lock every legitimate app out of sign-in and token refresh.
private final class PublicRequestRateLimiter: @unchecked Sendable {
    private struct Key: Hashable {
        let group: PublicRateLimitGroup
        /// nil is the bucket for all callers together.
        let caller: String?
    }

    private static let totalMultiplier = 8
    private static let maximumTrackedBuckets = 4096

    private let lock = NSLock()
    private var buckets = [Key: [TimeInterval]]()
    private var lastLoggedRefusal = [PublicRateLimitGroup: TimeInterval]()

    func check(group: PublicRateLimitGroup, caller: String, now: Date = Date()) -> PublicRateLimitDecision {
        lock.lock()
        defer { lock.unlock() }

        let rule = group.rule
        let nowSeconds = now.timeIntervalSince1970
        let cutoff = nowSeconds - rule.windowSeconds
        let callerKey = Key(group: group, caller: caller)
        let totalKey = Key(group: group, caller: nil)
        let callerStamps = buckets[callerKey, default: []].filter { $0 > cutoff }
        let totalStamps = buckets[totalKey, default: []].filter { $0 > cutoff }

        let overCaller = callerStamps.count >= rule.maxRequests
        let overTotal = totalStamps.count >= rule.maxRequests * Self.totalMultiplier
        guard !overCaller, !overTotal else {
            buckets[callerKey] = callerStamps
            buckets[totalKey] = totalStamps
            let oldest = (overCaller ? callerStamps : totalStamps).first ?? nowSeconds
            let shouldLog = (lastLoggedRefusal[group] ?? 0) <= cutoff
            if shouldLog {
                lastLoggedRefusal[group] = nowSeconds
            }
            return PublicRateLimitDecision(
                allowed: false,
                retryAfterSeconds: max(1, Int(ceil(oldest + rule.windowSeconds - nowSeconds))),
                shouldLog: shouldLog
            )
        }

        if buckets.count >= Self.maximumTrackedBuckets {
            // Every window is a minute, so anything older is spent.
            buckets = buckets.filter { ($0.value.last ?? 0) > nowSeconds - 60 }
        }
        buckets[callerKey] = callerStamps + [nowSeconds]
        buckets[totalKey] = totalStamps + [nowSeconds]
        return PublicRateLimitDecision(allowed: true, retryAfterSeconds: 0)
    }
}

enum HTTPRequestFraming {
    static let maximumByteCount = 128 * 1024

    enum State: Equatable {
        case incomplete
        case complete
        case invalid
    }

    static func state(data: Data) -> State {
        guard data.count <= maximumByteCount else {
            return .invalid
        }

        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return .incomplete
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let bodyLength = contentLength(in: headerData) else {
            return .invalid
        }
        guard bodyLength <= maximumByteCount - headerRange.upperBound else {
            return .invalid
        }

        return data.count - headerRange.upperBound >= bodyLength ? .complete : .incomplete
    }

    static func contentLength(in headerData: Data.SubSequence) -> Int? {
        let headerText = String(decoding: headerData, as: UTF8.self)
        var contentLength: Int?

        for line in headerText.components(separatedBy: "\r\n").dropFirst() {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<separatorIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if name == "transfer-encoding" {
                return nil
            }
            guard name == "content-length" else { continue }
            guard contentLength == nil,
                  !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = Int(value) else {
                return nil
            }
            contentLength = parsed
        }

        return contentLength ?? 0
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

    var mcpMethodHeader: String? {
        headers["mcp-method"]
    }

    var mcpNameHeader: String? {
        headers["mcp-name"]
    }

    var requestedCORSHeaders: [String] {
        (headers["access-control-request-headers"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init?(data: Data) {
        let separator = Data("\r\n\r\n".utf8)
        let headerData: Data
        guard case .complete = HTTPRequestFraming.state(data: data),
              let range = data.range(of: separator),
              let contentLength = HTTPRequestFraming.contentLength(in: data[..<range.lowerBound]) else {
            return nil
        }
        headerData = data[..<range.lowerBound]
        body = data[range.upperBound..<(range.upperBound + contentLength)]

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

    /// Parses the request body, rejecting numbers JSON cannot represent.
    /// Foundation reads `-1e999` as negative infinity, which no response could
    /// echo back.
    func jsonObject() throws -> Any {
        let object = try JSONSerialization.jsonObject(with: body, options: [])
        let isContainer = object is NSArray || object is NSDictionary
        guard JSONSerialization.isValidJSONObject(isContainer ? object : [object]) else {
            throw InvalidJSONObjectError()
        }
        return object
    }

    func formURLEncodedBody() -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        return Self.parseQueryItems(text)
    }

    func tokenFormURLEncodedBody() throws -> OAuthTokenForm {
        var form = formURLEncodedBody()
        let bodyClientSecret = form["client_secret"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBodyClientSecret = bodyClientSecret?.isEmpty == false
        guard let basicCredentials = basicAuthorizationCredentials else {
            return OAuthTokenForm(
                form: form,
                clientAuthenticationSource: hasBodyClientSecret ? .clientSecretPost : .none
            )
        }

        let formClientID = form["client_id"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let formClientID, !formClientID.isEmpty, formClientID != basicCredentials.clientID {
            throw OAuthError.invalidRequest("Conflicting client_id credentials.")
        }
        if hasBodyClientSecret {
            throw OAuthError.invalidRequest("Multiple client authentication methods.")
        }

        form["client_id"] = basicCredentials.clientID
        form["client_secret"] = basicCredentials.clientSecret
        return OAuthTokenForm(
            form: form,
            clientAuthenticationSource: basicCredentials.clientSecret.isEmpty ? .none : .clientSecretBasic
        )
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
}

private struct OAuthTokenForm {
    let form: [String: String]
    let clientAuthenticationSource: OAuthTokenClientAuthenticationSource
}

private struct HTTPResponse {
    enum Status {
        case ok
        case noContent
        case accepted
        case created
        case badRequest
        case forbidden
        case methodNotAllowed
        case unauthorized
        case tooManyRequests
        case notFound
        case misdirectedRequest
        case internalServerError

        var line: String {
            switch self {
            case .ok: "200 OK"
            case .noContent: "204 No Content"
            case .accepted: "202 Accepted"
            case .created: "201 Created"
            case .badRequest: "400 Bad Request"
            case .forbidden: "403 Forbidden"
            case .methodNotAllowed: "405 Method Not Allowed"
            case .unauthorized: "401 Unauthorized"
            case .tooManyRequests: "429 Too Many Requests"
            case .notFound: "404 Not Found"
            case .misdirectedRequest: "421 Misdirected Request"
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
        responseHeaders["Connection"] = "close"
        switch status {
        case .noContent:
            responseHeaders.removeValue(forKey: "Content-Length")
            responseHeaders.removeValue(forKey: "Content-Type")
        default:
            if responseHeaders["Content-Length"] == nil {
                responseHeaders["Content-Length"] = String(bodyData.count)
            }
            if responseHeaders["Content-Type"] == nil {
                responseHeaders["Content-Type"] = "application/json; charset=utf-8"
            }
        }

        var head = "HTTP/1.1 \(status.line)\r\n"
        for key in responseHeaders.keys.sorted() {
            if let value = responseHeaders[key] {
                head += "\(key): \(value)\r\n"
            }
        }
        head += "\r\n"

        var data = Data(head.utf8)
        if case .noContent = status {
            return data
        }
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
