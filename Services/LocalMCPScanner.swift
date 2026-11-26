import CryptoKit
import Foundation

struct LocalMCPServerCandidate: Identifiable, Hashable, Sendable {
    enum Transport: String, Codable, Hashable, Sendable {
        case http
        case stdio
    }

    let id: String
    let source: String
    let sourcePath: String
    let name: String
    let displayName: String
    let transport: Transport
    let url: String?
    let command: String?
    let args: [String]
    let startupTimeoutSeconds: TimeInterval?
    let isLocal: Bool
    let bridgeable: Bool
    let reason: String?
    /// Mutable only so a sign-in can swap a dead `Authorization` binding for
    /// MacRemote's own; nothing else rewrites a discovered header.
    var headers: [MCPBridgeHeader]
    let environment: [MCPStdioEnvironmentVariable]
    /// Every config row that declared this runtime. Scan dedupe merges this
    /// list instead of throwing away the second app's reconciliation owner.
    var discoveryOwners: [MCPDiscoveryOwner] = []
    var probe: LocalMCPProbeResult?
    var probeError: String?
    /// The last check got HTTP 401 and the server publishes OAuth metadata,
    /// so signing in from Tools is the fix. Never persisted.
    var needsSignIn: Bool = false
    var isNewSinceLastScan: Bool = false
    /// A config file or directory subtree that could not be read. Ownership
    /// reconciliation treats this as unknown, never as proof of deletion.
    var sourceReadFailureScopePath: String? = nil

    /// True when MacRemote's own sign-in supplies this server's `Authorization`.
    var usesUpstreamOAuth: Bool {
        headers.contains(where: \.isUpstreamOAuth)
    }

    /// The same server, authorized by MacRemote's own sign-in instead of any
    /// header a config file declared. A stale extension-manifest token or an
    /// empty config row both become one Keychain-backed binding.
    func signedInWithMacRemote() -> LocalMCPServerCandidate {
        var copy = self
        copy.headers = headers.filter { $0.name.caseInsensitiveCompare("Authorization") != .orderedSame }
            + [.upstreamOAuthAuthorization]
        copy.needsSignIn = false
        copy.probeError = nil
        return copy
    }

    var redactedURL: String? {
        guard let url,
              var components = URLComponents(string: url) else {
            return url
        }
        components.path = components.path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in
                LocalMCPScanner.isSecretLikeURLSegment(String(segment)) ? "<redacted>" : String(segment)
            }
            .joined(separator: "/")
        if components.query != nil {
            components.percentEncodedQuery = "<redacted>"
        }
        return components.string ?? url
    }

    var displayEndpoint: String {
        if let redactedURL {
            return redactedURL
        }
        return ([command].compactMap { $0 } + args).joined(separator: " ")
    }

    var bridgeIdentity: String? {
        if let url {
            return "http:\(url)"
        }
        if let command {
            return "stdio:\(([command] + args).joined(separator: "\u{1f}"))"
        }
        return nil
    }

    /// Credential-safe runtime identity used for dedupe and persistence. It
    /// covers the complete execution contract: transport, endpoint or exact
    /// command+argv, timeout, and header/environment bindings. Literal secret
    /// values and token-bearing URLs contribute only through the final digest.
    var canonicalRuntimeIdentity: String? {
        guard bridgeIdentity != nil else { return nil }
        var components = [transport.rawValue]
        switch transport {
        case .http:
            guard let url else { return nil }
            components.append(Self.secretDigest(url))
            for header in headers.sorted(by: Self.bridgeHeaderSort) {
                components.append(header.name.lowercased())
                components.append(Self.secretBindingIdentity(
                    literal: header.value,
                    source: header.valueSource
                ))
            }
        case .stdio:
            guard let command else { return nil }
            components.append(command)
            components.append(contentsOf: args)
            components.append(startupTimeoutSeconds.map { String($0.bitPattern, radix: 16) } ?? "")
            for variable in environment.sorted(by: Self.environmentVariableSort) {
                components.append(variable.name)
                components.append(Self.secretBindingIdentity(
                    literal: variable.value,
                    source: variable.valueSource
                ))
            }
        }
        return "runtime.\(Self.digestComponents(components))"
    }

    /// Stable persistence identity for refresh matching. Equivalent Codex and
    /// Claude rows share this identity; source-specific owner identities remain
    /// available through `configurationOwners` for legacy imports and deletion.
    var persistedServerIdentity: String {
        canonicalRuntimeIdentity ?? configurationOwners.first?.serverIdentity ?? legacyOwnerIdentity
    }

    var configurationOwners: [MCPDiscoveryOwner] {
        if !discoveryOwners.isEmpty {
            return discoveryOwners
        }
        return [MCPDiscoveryOwner(
            serverIdentity: legacyOwnerIdentity,
            source: source,
            sourcePath: sourcePath
        )]
    }

    func matchesPersistedServerIdentity(_ identity: String?) -> Bool {
        guard let identity else { return false }
        return identity == persistedServerIdentity ||
            configurationOwners.contains { $0.serverIdentity == identity }
    }

    private var legacyOwnerIdentity: String {
        let seed = [source, sourcePath, name, id].joined(separator: "\u{1f}")
        let hash = SHA256.hash(data: Data(seed.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return "\(source).\(name).\(hash)"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func digestComponents(_ values: [String]) -> String {
        let encoder = JSONEncoder()
        // Python's canonical json.dumps encoding leaves path separators
        // unescaped. Keep the Swift byte stream identical so the app and CLI
        // assign the same runtime identity to one MCP execution contract.
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = (try? encoder.encode(values)) ?? Data()
        return SHA256.hash(data: data)
            .prefix(16)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func secretDigest(_ value: String) -> String {
        "sha256:\(digest(value))"
    }

    private static func secretBindingIdentity(
        literal: String?,
        source: MCPBridgeHeaderValueSource?
    ) -> String {
        if let literal {
            return "literal:\(secretDigest(literal))"
        }
        guard let source else { return "none" }
        return [
            "source",
            source.kind.rawValue,
            source.environmentKey ?? "",
            source.filePath ?? "",
            (source.keyPath ?? []).joined(separator: "\u{1f}"),
            source.prefix ?? ""
        ].joined(separator: "\u{1f}")
    }

    private static func bridgeHeaderSort(_ lhs: MCPBridgeHeader, _ rhs: MCPBridgeHeader) -> Bool {
        let left = lhs.name.lowercased() + secretBindingIdentity(literal: lhs.value, source: lhs.valueSource)
        let right = rhs.name.lowercased() + secretBindingIdentity(literal: rhs.value, source: rhs.valueSource)
        return left < right
    }

    private static func environmentVariableSort(
        _ lhs: MCPStdioEnvironmentVariable,
        _ rhs: MCPStdioEnvironmentVariable
    ) -> Bool {
        let left = lhs.name + secretBindingIdentity(literal: lhs.value, source: lhs.valueSource)
        let right = rhs.name + secretBindingIdentity(literal: rhs.value, source: rhs.valueSource)
        return left < right
    }
}

struct LocalMCPProbeResult: Hashable, Sendable {
    let serverInfo: LocalMCPServerInfo
    let tools: [LocalMCPToolSummary]
    /// Read when the server declares the Skills extension (SPEC D84).
    var skills: [MCPUpstreamSkill] = []
    /// Tools the server listed that MacRemote could not use (an input schema
    /// it cannot mirror). An import keeps the legacy row of such a tool
    /// instead of treating it as gone (D87).
    var skippedToolNames: [String] = []
}

struct LocalMCPServerInfo: Hashable, Sendable {
    let name: String?
    let title: String?
    let version: String?
    let description: String?
}

struct LocalMCPToolSummary: Identifiable, Hashable, Sendable {
    var id: String { name }

    let name: String
    let title: String?
    let description: String?
    let inputSchema: JSONValue?
    let annotations: JSONValue?

    var displayTitle: String {
        title ?? name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var capability: ToolCapability {
        guard let object = annotations?.objectValue else {
            return .write
        }
        if object["destructiveHint"] == .bool(true) {
            return .destructive
        }
        if object["readOnlyHint"] == .bool(true) {
            return .readOnly
        }
        return .write
    }
}

struct LocalMCPScanner: Sendable {
    typealias ClaudeExtensionEnumeration = (
        manifests: [URL],
        failedScopePaths: [URL]
    )

    /// The home folder scans read. Skills found on this Mac are read from the
    /// same one, so a test home covers both.
    let homeDirectory: URL
    private let urlSession: URLSession
    private let executablePath: @Sendable (String) -> String?
    private let processRunner: any ProcessRunning
    private let stdioBridgeClient: MCPStdioBridgeClient
    private let claudeExtensionEnumerator: @Sendable (URL) -> ClaudeExtensionEnumeration?
    private let oauth: MCPUpstreamOAuthClient

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        urlSession: URLSession = .shared,
        executablePath: @escaping @Sendable (String) -> String? = { ExecutableLocator.executablePath(named: $0) },
        processRunner: any ProcessRunning = ProcessRunner(),
        stdioBridgeClient: MCPStdioBridgeClient = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment),
        claudeExtensionEnumerator: @escaping @Sendable (URL) -> ClaudeExtensionEnumeration? = {
            Self.enumerateClaudeExtensionManifests(under: $0)
        },
        oauthStore: MCPUpstreamOAuthStore = .shared
    ) {
        self.homeDirectory = homeDirectory
        self.urlSession = urlSession
        self.executablePath = executablePath
        self.processRunner = processRunner
        self.stdioBridgeClient = stdioBridgeClient
        self.claudeExtensionEnumerator = claudeExtensionEnumerator
        // Scans only read a stored sign-in and ask whether one is possible;
        // the browser flow belongs to AppModel.
        self.oauth = MCPUpstreamOAuthClient(urlSession: urlSession, store: oauthStore, openURL: { _ in })
    }

    /// Config ownership view for AppModel reconciliation. Equivalent runtimes
    /// are folded into one candidate, but every declaring app/config remains in
    /// `configurationOwners`; unreadable sentinels are never folded away.
    func configuredCandidatesForReconciliation() async -> [LocalMCPServerCandidate] {
        deduplicated(await scanConfiguredServers(includeRuntimeSources: false))
    }

    func scan(
        includeRemote: Bool = false,
        probe shouldProbe: Bool = true,
        includeRuntimeSources: Bool = true
    ) async -> [LocalMCPServerCandidate] {
        var candidates = await scanConfiguredServers(includeRuntimeSources: includeRuntimeSources)
        candidates.sort { lhs, rhs in
            if lhs.bridgeable != rhs.bridgeable {
                return lhs.bridgeable && !rhs.bridgeable
            }
            if lhs.headers.isEmpty != rhs.headers.isEmpty {
                return !lhs.headers.isEmpty
            }
            if lhs.source != rhs.source {
                return lhs.source < rhs.source
            }
            return lhs.displayName < rhs.displayName
        }
        candidates = deduplicated(candidates.filter { includeRemote || $0.url == nil || $0.isLocal })

        guard shouldProbe else {
            return candidates
        }

        // A scan asks only servers that are already running (HTTP). A stdio
        // server is a command line from another app's config file; launching
        // every one of those because the owner pressed Scan would run code
        // they never chose, with MacRemote's own privacy grants. A stdio
        // server is launched when the owner imports or checks that server.
        //
        // Probes run concurrently (bounded): each makes HTTP round-trips with
        // multi-second timeouts.
        let snapshot = candidates
        let probeIndices = snapshot.indices.filter { snapshot[$0].bridgeable && snapshot[$0].url != nil }
        let maxConcurrentProbes = 4
        let outcomes = await withTaskGroup(
            of: (Int, LocalMCPProbeResult?, (any Error)?).self,
            returning: [Int: (LocalMCPProbeResult?, (any Error)?)].self
        ) { group in
            var pending = probeIndices[...]
            var collected = [Int: (LocalMCPProbeResult?, (any Error)?)]()

            func addProbeTask(for index: Int) {
                group.addTask {
                    do {
                        // Bulk scan: cap each server's startup allowance so one
                        // slow server cannot dominate the scan. Import re-probes
                        // with the candidate's full configured timeout.
                        return (index, try await self.probe(candidate: snapshot[index], timeoutCapSeconds: 10), nil)
                    } catch {
                        return (index, nil, error)
                    }
                }
            }

            for index in pending.prefix(maxConcurrentProbes) {
                addProbeTask(for: index)
            }
            pending = pending.dropFirst(maxConcurrentProbes)

            while let (index, result, failure) = await group.next() {
                collected[index] = (result, failure)
                if let next = pending.first {
                    pending = pending.dropFirst()
                    addProbeTask(for: next)
                }
            }
            return collected
        }

        for (index, outcome) in outcomes {
            candidates[index].probe = outcome.0
            candidates[index].probeError = outcome.1?.localizedDescription
            candidates[index].needsSignIn = Self.isSignInRequired(outcome.1)
        }
        return candidates
    }

    /// The one probe failure the Tools page turns into a Sign In button.
    static func isSignInRequired(_ error: (any Error)?) -> Bool {
        if case .signInRequired = error as? LocalMCPScannerError { return true }
        if case .signInRequired = error as? MCPUpstreamOAuthError { return true }
        return false
    }

    func probe(candidate: LocalMCPServerCandidate, timeoutCapSeconds: TimeInterval? = nil) async throws -> LocalMCPProbeResult {
        let configuredTimeout = candidate.startupTimeoutSeconds ?? 20
        let timeoutSeconds = timeoutCapSeconds.map { min(configuredTimeout, $0) } ?? configuredTimeout
        if candidate.transport == .stdio {
            guard let command = candidate.command else {
                throw LocalMCPScannerError.missingCommand
            }
            return try await stdioBridgeClient.probe(
                command: try resolvedCommand(command),
                args: candidate.args,
                environmentVariables: candidate.environment,
                protocolVersion: "2025-06-18",
                timeoutSeconds: timeoutSeconds
            )
        }

        guard let url = candidate.url else {
            throw LocalMCPScannerError.missingURL
        }
        // Each request has its own timeout, but that only limits the gap
        // between bytes. The deadline bounds the whole probe, so a server
        // that answers slowly without end cannot keep a scan running.
        var probed: HTTPProbe
        do {
            probed = try await withDeadline(seconds: timeoutSeconds) {
                try await self.probeHTTPServer(candidate: candidate, url: url)
            }
        } catch is DeadlineExceeded {
            throw LocalMCPScannerError.timedOut(timeoutSeconds)
        }
        // Skills are optional (SPEC D84): read after the tools, within their
        // own deadline, so a slow or failing skills read never costs the tools.
        if let skillHeaders = probed.skillHeaders {
            let skillsDeadline = min(timeoutSeconds, MCPUpstreamSkillCollector.readDeadlineSeconds)
            probed.result.skills = (try? await withDeadline(seconds: skillsDeadline) {
                await self.upstreamSkills(url: url, baseHeaders: skillHeaders)
            }) ?? []
        }
        return probed.result
    }

    /// A finished HTTP probe. `skillHeaders` is set when the server declared
    /// the Skills extension: the headers and sign-in to read them with.
    private struct HTTPProbe: Sendable {
        var result: LocalMCPProbeResult
        let skillHeaders: [String: String]?
    }

    /// Asks an HTTP server for its tools, turning a 401 from a server that
    /// offers a sign-in into "sign in first".
    private func probeHTTPServer(candidate: LocalMCPServerCandidate, url: String) async throws -> HTTPProbe {
        var baseHeaders = try await resolvedHeaders(for: candidate)
        baseHeaders["Content-Type"] = "application/json"
        baseHeaders["Accept"] = "application/json, text/event-stream"

        do {
            return try await probeHTTP(url: url, baseHeaders: baseHeaders)
        } catch LocalMCPScannerError.httpStatus(let status, let body) where status == 401 {
            // A server that publishes OAuth metadata is asking for a sign-in,
            // not reporting a broken config. A stored sign-in that gets 401 is
            // dead, so forget it and ask again.
            if candidate.usesUpstreamOAuth {
                oauth.forget(serverURL: url)
                throw LocalMCPScannerError.signInRequired(candidate.displayName)
            }
            if await oauth.supportsSignIn(serverURL: url) {
                throw LocalMCPScannerError.signInRequired(candidate.displayName)
            }
            throw LocalMCPScannerError.httpStatus(status, body)
        }
    }

    private func probeHTTP(url: String, baseHeaders: [String: String]) async throws -> HTTPProbe {
        let verdict = try await discoverUpstreamHTTPServer(
            url: url,
            baseHeaders: baseHeaders
        )
        if let discoverResult = verdict.modernResult {
            let params: [String: Any] = [:]
            let toolsResponse = try await postJSONRPC(
                url: url,
                headers: baseHeaders.merging(
                    MCPUpstreamProtocol.modernHTTPHeaders(
                        method: "tools/list",
                        params: params
                    )
                ) { _, protocolValue in protocolValue },
                payload: MCPUpstreamProtocol.modernRequest(
                    id: "tools",
                    method: "tools/list",
                    params: params
                )
            )
            if let error = toolsResponse.body["error"] {
                throw LocalMCPScannerError.jsonRPCError(serializedJSON(error))
            }

            let toolsResult = try MCPUpstreamProtocol.completeResult(from: toolsResponse.body)
            let tools = (toolsResult["tools"] as? [[String: Any]] ?? []).compactMap {
                object -> LocalMCPToolSummary? in
                guard MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(object["inputSchema"]) else {
                    return nil
                }
                return Self.toolSummary(from: object)
            }
            let declaresSkills = MCPUpstreamProtocol.declaredExtensions(fromDiscoverResult: discoverResult)
                .contains(MCPUpstreamSkillCollector.extensionIdentifier)
            return HTTPProbe(
                result: LocalMCPProbeResult(
                    serverInfo: Self.serverInfo(
                        from: MCPUpstreamProtocol.serverInfo(fromDiscoverResult: discoverResult)
                    ),
                    tools: tools
                ),
                skillHeaders: declaresSkills ? baseHeaders : nil
            )
        }

        // The scan's default legacy ask stays 2025-06-18 — that is what the
        // bridges this scan produces are configured with — unless discover came
        // back naming a revision we implement, in which case we ask for that.
        let legacyVersion = verdict.renegotiatedLegacyVersion ?? "2025-06-18"
        var legacyHeaders = baseHeaders
        legacyHeaders["MCP-Protocol-Version"] = legacyVersion
        let initializeResponse = try await postJSONRPC(
            url: url,
            headers: legacyHeaders,
            payload: [
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": [
                    "protocolVersion": legacyVersion,
                    "capabilities": [:],
                    "clientInfo": MCPUpstreamProtocol.clientInfo
                ]
            ]
        )
        if let error = initializeResponse.body["error"] {
            throw LocalMCPScannerError.jsonRPCError(serializedJSON(error))
        }

        let result = initializeResponse.body["result"] as? [String: Any] ?? [:]
        let protocolVersion = result["protocolVersion"] as? String ?? legacyVersion
        legacyHeaders["MCP-Protocol-Version"] = protocolVersion
        if let sessionID = headerValue(named: "Mcp-Session-Id", in: initializeResponse.headers) {
            legacyHeaders["Mcp-Session-Id"] = sessionID
        }

        _ = try? await postJSONRPC(
            url: url,
            headers: legacyHeaders,
            payload: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ],
            allowEmpty: true
        )

        let toolsResponse = try await postJSONRPC(
            url: url,
            headers: legacyHeaders,
            payload: [
                "jsonrpc": "2.0",
                "id": "tools",
                "method": "tools/list"
            ]
        )
        if let error = toolsResponse.body["error"] {
            throw LocalMCPScannerError.jsonRPCError(serializedJSON(error))
        }

        let toolsResult = toolsResponse.body["result"] as? [String: Any] ?? [:]
        let tools = (toolsResult["tools"] as? [[String: Any]] ?? []).compactMap {
            object -> LocalMCPToolSummary? in
            guard MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(object["inputSchema"]) else {
                return nil
            }
            return Self.toolSummary(from: object)
        }
        return HTTPProbe(
            result: LocalMCPProbeResult(
                serverInfo: Self.serverInfo(from: result["serverInfo"] as? [String: Any] ?? [:]),
                tools: tools
            ),
            skillHeaders: nil
        )
    }

    /// The skills of a server that declared the Skills extension (SPEC D84),
    /// read with the probe's own headers and sign-in. A failed read costs
    /// only the skills.
    private func upstreamSkills(url: String, baseHeaders: [String: String]) async -> [MCPUpstreamSkill] {
        var collector = MCPUpstreamSkillCollector()
        do {
            while let next = collector.nextRequest() {
                let response = try await postJSONRPC(
                    url: url,
                    headers: baseHeaders.merging(
                        MCPUpstreamProtocol.modernHTTPHeaders(method: next.method, params: next.params)
                    ) { _, protocolValue in protocolValue },
                    payload: MCPUpstreamProtocol.modernRequest(
                        id: "skills-\(UUID().uuidString)",
                        method: next.method,
                        params: next.params
                    )
                )
                try collector.receive(response.body)
            }
            return collector.skills
        } catch {
            return []
        }
    }

    /// Probes the candidate once and reports which flow the scan should run,
    /// carrying any legacy revision the upstream invited us down to.
    private func discoverUpstreamHTTPServer(
        url: String,
        baseHeaders: [String: String]
    ) async throws -> MCPUpstreamDiscoverVerdict {
        let params: [String: Any] = [:]
        let payload = MCPUpstreamProtocol.modernRequest(
            id: "discover",
            method: "server/discover",
            params: params
        )
        let headers = baseHeaders.merging(
            MCPUpstreamProtocol.modernHTTPHeaders(
                method: "server/discover",
                params: params
            )
        ) { _, protocolValue in protocolValue }

        let response: LocalMCPHTTPResponse
        do {
            response = try await sendJSONRPC(
                url: url,
                headers: headers,
                payload: payload
            )
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                return .legacy(requestedVersion: nil)
            }
            throw error
        }

        switch response.statusCode {
        case 200..<300:
            guard let body = response.body else {
                throw LocalMCPScannerError.invalidResponse(
                    "server/discover returned no JSON response"
                )
            }
            return try MCPUpstreamProtocol.classifyDiscoverResponse(body)
        case 400, 404, 405:
            guard let body = response.body else {
                return .legacy(requestedVersion: nil)
            }
            return try MCPUpstreamProtocol.classifyDiscoverResponse(body)
        default:
            throw LocalMCPScannerError.httpStatus(
                response.statusCode,
                String(decoding: response.data.prefix(1024), as: UTF8.self)
            )
        }
    }

    /// `preferredServerName` keeps a refreshed family's existing name (and so
    /// its tool titles) when the config row that now owns it spells the server
    /// differently, such as a `paste` key refreshing tools imported as "Paste".
    func bridgeTools(
        for candidate: LocalMCPServerCandidate,
        existingIDs: Set<String> = [],
        preferredIDsByUpstreamToolName: [String: String] = [:],
        preferredServerName: String? = nil
    ) throws -> [ToolDefinition] {
        let serverName = preferredServerName ?? candidate.displayName
        if candidate.transport == .http, candidate.url == nil {
            throw LocalMCPScannerError.missingURL
        }
        if candidate.transport == .stdio, candidate.command == nil {
            throw LocalMCPScannerError.missingCommand
        }
        guard let discoveredTools = candidate.probe?.tools else {
            throw LocalMCPScannerError.noTools
        }
        let tools = Self.bridgeableUpstreamTools(discoveredTools)
        guard !tools.isEmpty else {
            throw LocalMCPScannerError.noTools
        }
        let command = candidate.command.flatMap { try? resolvedCommand($0) }

        let baseIDs = tools.map { upstreamTool in
            ToolIdentifier.importedMCPToolID(
                serverName: serverName,
                upstreamToolName: upstreamTool.name
            )
        }
        let baseIDCounts = Dictionary(grouping: baseIDs, by: { $0 }).mapValues(\.count)
        // Curated IDs are reserved exactly. This keeps a genuinely distinct
        // tool such as `remctl_experimental_export` friendly while preventing
        // an imported `remctl_today` from colliding with the preset.
        var allocatedIDs = existingIDs.union(DefaultToolPresetCatalog.presets.map(\.toolID))
        let firstPartyProvider = FirstPartyMCPProviderCatalog.provider(
            forCandidateSource: candidate.source,
            name: candidate.name
        )

        let bridgeTools = try zip(tools, baseIDs).map { upstreamTool, baseID in
            let id: String
            if let preferredID = preferredIDsByUpstreamToolName[upstreamTool.name] {
                try ToolIdentifier.validate(preferredID)
                id = preferredID
            } else {
                id = ToolIdentifier.importedMCPToolID(
                    serverName: serverName,
                    upstreamToolName: upstreamTool.name,
                    existingIDs: allocatedIDs,
                    forceStableSuffix: (baseIDCounts[baseID] ?? 0) > 1
                )
            }
            guard allocatedIDs.insert(id).inserted else {
                throw ToolIdentifierError.duplicate(id)
            }
            let inputSchema = upstreamTool.inputSchema ?? .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
            let annotations = upstreamTool.annotations ?? .object([:])
            return ToolDefinition(
                id: id,
                name: "\(serverName): \(upstreamTool.displayTitle)",
                summary: String((upstreamTool.description ?? "Call upstream MCP tool \(upstreamTool.name).").prefix(600)),
                executablePath: "",
                argumentPattern: [],
                parameters: [],
                capability: upstreamTool.capability,
                timeoutSeconds: 60,
                outputByteLimit: 5 * 1024 * 1024,
                origin: .userDefined,
                category: .developer,
                permissionRequirements: [],
                backend: candidate.transport == .stdio ? .mcpStdioBridge : .mcpHTTPBridge,
                mcpBridge: candidate.transport == .http ? MCPBridgeConfiguration(
                    serverIdentity: candidate.persistedServerIdentity,
                    discoverySource: candidate.source,
                    discoverySourcePath: candidate.sourcePath,
                    discoveryOwners: candidate.configurationOwners,
                    serverName: serverName,
                    serverURL: candidate.url ?? "",
                    toolName: upstreamTool.name,
                    toolTitle: upstreamTool.title,
                    toolDescription: upstreamTool.description,
                    inputSchema: inputSchema,
                    annotations: annotations,
                    protocolVersion: "2025-06-18",
                    headers: candidate.headers
                ) : nil,
                mcpStdioBridge: candidate.transport == .stdio ? MCPStdioBridgeConfiguration(
                    serverIdentity: candidate.persistedServerIdentity,
                    discoverySource: candidate.source,
                    discoverySourcePath: candidate.sourcePath,
                    discoveryOwners: candidate.configurationOwners,
                    serverName: serverName,
                    command: command ?? "",
                    args: candidate.args,
                    startupTimeoutSeconds: candidate.startupTimeoutSeconds,
                    toolName: upstreamTool.name,
                    toolTitle: upstreamTool.title,
                    toolDescription: upstreamTool.description,
                    inputSchema: inputSchema,
                    annotations: annotations,
                    protocolVersion: "2025-06-18",
                    environment: candidate.environment
                ) : nil
            )
        }
        guard let firstPartyProvider else { return bridgeTools }
        return FirstPartyMCPProviderCatalog.applyPolicy(firstPartyProvider, to: bridgeTools)
    }

    /// The listed tools `bridgeTools` turns into MacRemote tools: those whose
    /// input schema MacRemote can mirror. The rest are skipped, not imported.
    static func bridgeableUpstreamTools(_ tools: [LocalMCPToolSummary]) -> [LocalMCPToolSummary] {
        tools.filter { MCPUpstreamProtocol.isValidModernHTTPToolInputSchema($0.inputSchema) }
    }

    /// Live filesystem fingerprint of every config the scanner reads plus the
    /// installed first-party executables, so a CLI install or upgrade counts
    /// as a config change for the quiet refresh. An executable is stat'ed
    /// where its symlink leads: an upgrade replaces the target, not the link.
    func configSnapshot() -> String {
        MCPConfigLocator.configSnapshot(
            homeDirectory: homeDirectory,
            additionalPaths: firstPartyExecutablePaths.values
                .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                .sorted()
        )
    }

    /// The first-party CLIs installed right now, each with the executable
    /// MacRemote would launch. Stats a few files; call it at a scan, a
    /// refresh, or when the Library opens, never from a view's body.
    func detectedFirstPartyProviders() -> [(provider: FirstPartyMCPProvider, executablePath: String)] {
        FirstPartyMCPProviderCatalog.detectedProviders(using: executablePath)
    }

    /// Every name `provider` goes by that is installed right now, as found.
    func installedExecutablePaths(of provider: FirstPartyMCPProvider) -> [String] {
        provider.executableNames.compactMap(executablePath)
    }

    /// Provider id → detected executable path for every installed first-party
    /// CLI that ships its own MCP server.
    private var firstPartyExecutablePaths: [String: String] {
        Dictionary(
            uniqueKeysWithValues: detectedFirstPartyProviders()
                .map { ($0.provider.id, $0.executablePath) }
        )
    }

    /// The synthesized candidate for one first-party CLI, or nil when that
    /// CLI is not installed.
    func firstPartyCandidate(for provider: FirstPartyMCPProvider) -> LocalMCPServerCandidate? {
        firstPartyCandidates().first { $0.name == provider.serverName }
    }

    /// One synthesized stdio candidate per installed first-party CLI. It is
    /// owned by the provider, not by any app's config file or by the path the
    /// CLI happens to live at, so it exists exactly as long as the CLI is
    /// installed and survives the CLI moving to another folder.
    private func firstPartyCandidates() -> [LocalMCPServerCandidate] {
        detectedFirstPartyProviders().map { detected in
            var candidate = Self.candidate(
                source: FirstPartyMCPProviderCatalog.discoverySource,
                name: detected.provider.serverName,
                displayName: detected.provider.name,
                sourcePath: detected.executablePath,
                transport: .stdio,
                command: detected.executablePath,
                args: detected.provider.serveArguments
            )
            candidate.discoveryOwners = [MCPDiscoveryOwner(
                serverIdentity: FirstPartyMCPProviderCatalog.ownerIdentity(for: detected.provider),
                source: FirstPartyMCPProviderCatalog.discoverySource,
                sourcePath: detected.executablePath
            )]
            return candidate
        }
    }

    private func scanConfiguredServers(includeRuntimeSources: Bool) async -> [LocalMCPServerCandidate] {
        var candidates = firstPartyCandidates()
        for target in MCPConfigLocator.fileTargets(homeDirectory: homeDirectory) {
            candidates.append(contentsOf: scanFileTarget(at: target.path))
        }
        candidates.append(contentsOf: scanClaudeExtensions())
        if includeRuntimeSources {
            candidates.append(contentsOf: await scanClaudeRuntimeMCPServers())
        }
        return candidates
    }

    private func scanFileTarget(at path: URL) -> [LocalMCPServerCandidate] {
        MCPConfigLocator.scanKinds(for: path).flatMap { kind in
            switch kind {
            case .toml(let source):
                return scanTOMLMCPFile(path, source: source)
            case .json(let source, let rootKey):
                return scanJSONMCPFile(path, source: source, rootKey: rootKey)
            case .claudeCodeProjects:
                return scanClaudeCodeProjectMCPServers()
            }
        }
    }

    private func scanClaudeCodeProjectMCPServers() -> [LocalMCPServerCandidate] {
        let path = homeDirectory.appendingPathComponent(".claude.json")
        guard case .success(let object) = readJSONObject(from: path),
              let projects = object["projects"] as? [String: Any] else {
            return []
        }

        var candidates = [LocalMCPServerCandidate]()
        for (projectPath, rawProject) in projects {
            guard let project = rawProject as? [String: Any],
                  let servers = project["mcpServers"] as? [String: Any] else {
                continue
            }
            let suffix = Self.projectPathSuffix(projectPath)
            candidates.append(contentsOf: self.candidates(
                from: servers,
                source: "claude_code",
                sourcePath: path.path,
                rootKey: "mcpServers",
                idSuffix: suffix,
                envKeyPathPrefix: { rawName in
                    ["projects", projectPath, "mcpServers", rawName]
                }
            ))
        }
        return candidates
    }

    private func scanClaudeExtensions() -> [LocalMCPServerCandidate] {
        let root = homeDirectory.appendingPathComponent("Library/Application Support/Claude/Claude Extensions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        guard let enumeration = claudeExtensionEnumerator(root) else {
            return [Self.unreadableSourceCandidate(
                path: root,
                source: "claude_extension",
                reason: "Could not read this extensions directory."
            )]
        }

        var candidates = [LocalMCPServerCandidate]()
        for failedPath in Set(enumeration.failedScopePaths.map(\.standardizedFileURL)) {
            candidates.append(Self.unreadableSourceCandidate(
                path: failedPath,
                source: "claude_extension",
                reason: "Could not read this extensions directory."
            ))
        }
        for fileURL in enumeration.manifests {
            guard let object = jsonObject(from: fileURL) else {
                candidates.append(Self.unreadableConfigCandidate(
                    path: fileURL,
                    source: "claude_extension",
                    format: "JSON"
                ))
                continue
            }
            guard let server = object["server"] as? [String: Any],
                  let mcpConfig = server["mcp_config"] as? [String: Any],
                  let env = mcpConfig["env"] as? [String: Any],
                  let url = env["MCP_URL"] as? String,
                  Self.looksLikeHTTPURL(url) else {
                continue
            }

            var headers = [MCPBridgeHeader]()
            if let token = env["MCP_TOKEN"] as? String, !token.isEmpty {
                headers.append(MCPBridgeHeader(
                    name: "Authorization",
                    valueSource: MCPBridgeHeaderValueSource(
                        kind: .jsonFile,
                        filePath: fileURL.path,
                        keyPath: ["server", "mcp_config", "env", "MCP_TOKEN"],
                        prefix: "Bearer "
                    )
                ))
            }

            let rawName = object["name"] as? String ?? fileURL.deletingLastPathComponent().lastPathComponent
            let displayName = object["display_name"] as? String ?? object["name"] as? String ?? rawName
            candidates.append(Self.candidate(
                source: "claude_extension",
                name: Self.stableSlug(rawName),
                displayName: displayName,
                sourcePath: fileURL.path,
                transport: .http,
                url: url,
                headers: headers
            ))
        }
        return candidates
    }

    private static func enumerateClaudeExtensionManifests(
        under root: URL
    ) -> ClaudeExtensionEnumeration? {
        var failedScopePaths = [URL]()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles],
            errorHandler: { url, _ in
                failedScopePaths.append(url)
                return true
            }
        ) else {
            return nil
        }
        var manifests = [URL]()
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "manifest.json" {
            manifests.append(fileURL)
        }
        return (manifests, failedScopePaths)
    }

    private func scanClaudeRuntimeMCPServers() async -> [LocalMCPServerCandidate] {
        guard let claude = executablePath("claude") else {
            return []
        }
        guard let result = try? await processRunner.run(
            executablePath: claude,
            arguments: ["mcp", "list"],
            timeoutSeconds: 8,
            outputByteLimit: 512 * 1024,
            environment: ExecutableLocator.toolEnvironment,
            standardInput: nil
        ) else {
            return []
        }

        let output = result.stdout + "\n" + result.stderr
        return output.split(whereSeparator: \.isNewline).compactMap { line -> LocalMCPServerCandidate? in
            let value = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let match = value.firstMatch(of: #"^(.+?):\s+(https?://\S+)\s+\(HTTP\)\s+-\s+(.+)$"#) else {
                return nil
            }
            let connected = match[3].contains("Connected")
            return Self.candidate(
                source: "claude_runtime",
                name: Self.stableSlug(match[1]),
                displayName: match[1].trimmingCharacters(in: .whitespacesAndNewlines),
                sourcePath: "claude mcp list",
                transport: .http,
                url: match[2],
                reason: connected ? nil : match[3].trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private static let rootKeyAliases = ["mcpServers", "servers", "context_servers", "mcp"]

    private func scanJSONMCPFile(_ path: URL, source: String, rootKey: String) -> [LocalMCPServerCandidate] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return []
        }
        switch readJSONObject(from: path) {
        case .success(let object):
            let (servers, actualRootKey) = Self.resolveRootServers(in: object, preferredKey: rootKey)
            return candidates(from: servers, source: source, sourcePath: path.path, rootKey: actualRootKey)
        case .failure:
            return [Self.unreadableConfigCandidate(path: path, source: source, format: "JSON")]
        }
    }

    private func scanTOMLMCPFile(_ path: URL, source: String) -> [LocalMCPServerCandidate] {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return []
        }
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return [Self.unreadableConfigCandidate(path: path, source: source, format: "TOML")]
        }

        var sections: [String: [String: String]] = [:]
        var currentName: String?
        var currentKeyPrefix = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                    let section = String(line.dropFirst("[mcp_servers.".count).dropLast())
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if section.contains(".tools.") {
                        currentName = nil
                        currentKeyPrefix = ""
                        continue
                    }
                    if section.hasSuffix(".env") {
                        currentName = String(section.dropLast(".env".count))
                        currentKeyPrefix = "env."
                    } else {
                        currentName = section
                        currentKeyPrefix = ""
                    }
                    if let currentName, sections[currentName] == nil {
                        sections[currentName] = [:]
                    }
                } else {
                    currentName = nil
                    currentKeyPrefix = ""
                }
                continue
            }
            guard let currentName,
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            sections[currentName]?[currentKeyPrefix + key] = value
        }

        let mapping: [String: Any] = sections.mapValues { values in
            var config: [String: Any] = [:]
            if let url = values["url"].flatMap(Self.unquotedString) {
                config["url"] = url
            }
            if let command = values["command"].flatMap(Self.unquotedString) {
                config["command"] = command
            }
            if let args = values["args"] {
                config["args"] = Self.stringArray(fromTOMLValue: args)
            }
            if let bearer = values["bearer_token_env_var"].flatMap(Self.unquotedString) {
                config["bearer_token_env_var"] = bearer
            }
            if let startupTimeout = values["startup_timeout_sec"].flatMap(Self.doubleValue) {
                config["startup_timeout_sec"] = startupTimeout
            }
            let envPrefix = "env."
            let environment = values
                .filter { $0.key.hasPrefix(envPrefix) }
                .reduce(into: [String: String]()) { partialResult, pair in
                    let key = String(pair.key.dropFirst(envPrefix.count))
                    partialResult[key] = Self.unquotedString(pair.value)
                }
            if !environment.isEmpty {
                config["env"] = environment
            }
            return config
        }
        return candidates(from: mapping, source: source, sourcePath: path.path, rootKey: "mcp_servers")
    }

    private func candidates(
        from servers: Any?,
        source: String,
        sourcePath: String,
        rootKey: String,
        idSuffix: String? = nil,
        envKeyPathPrefix: ((String) -> [String])? = nil
    ) -> [LocalMCPServerCandidate] {
        guard let servers = servers as? [String: Any] else {
            return []
        }

        return servers.compactMap { rawName, rawConfig in
            guard let config = rawConfig as? [String: Any] else {
                return nil
            }
            let name = Self.stableSlug(rawName)
            let displayName = rawName
            let envPrefix = envKeyPathPrefix?(rawName) ?? [rootKey, rawName]
            let envStorageKey = Self.environmentStorageKey(in: config)
            var reason = Self.primaryBlockedReason(from: config)

            let transport = Self.resolvedTransport(from: config)
            switch transport {
            case .http:
                if let url = Self.resolveHTTPURL(from: config) {
                    let headerResult = mcpHeaders(from: config)
                    if reason == nil {
                        reason = headerResult.blockedReason
                    }
                    return Self.candidate(
                        source: source,
                        name: name,
                        displayName: displayName,
                        sourcePath: sourcePath,
                        transport: .http,
                        url: url,
                        headers: headerResult.headers,
                        reason: reason,
                        idSuffix: idSuffix
                    )
                }
                if reason == nil {
                    reason = "No server URL is configured."
                }
                return Self.candidate(
                    source: source,
                    name: name,
                    displayName: displayName,
                    sourcePath: sourcePath,
                    transport: .http,
                    reason: reason,
                    idSuffix: idSuffix
                )
            case .stdio:
                if let commandConfig = Self.resolveCommandConfig(from: config) {
                    let resolvedCommand = resolvedCommandPath(commandConfig.command)
                    let commandReason = resolvedCommand == nil
                        ? "Executable not found: \(commandConfig.command)."
                        : Self.missingInterpreterEntrypointReason(
                            command: resolvedCommand ?? commandConfig.command,
                            args: commandConfig.args
                        )
                    if reason == nil {
                        reason = commandReason
                    }
                    let startupTimeout = Self.numericValue(config["startup_timeout_sec"] ?? config["startupTimeoutSeconds"])
                    return Self.candidate(
                        source: source,
                        name: name,
                        displayName: displayName,
                        sourcePath: sourcePath,
                        transport: .stdio,
                        command: resolvedCommand ?? commandConfig.command,
                        args: commandConfig.args,
                        startupTimeoutSeconds: startupTimeout,
                        reason: reason,
                        environment: mcpEnvironment(
                            from: config,
                            sourcePath: sourcePath,
                            envStorageKey: envStorageKey,
                            keyPathPrefix: envPrefix + [envStorageKey]
                        ),
                        idSuffix: idSuffix
                    )
                }
                if reason != nil {
                    return Self.candidate(
                        source: source,
                        name: name,
                        displayName: displayName,
                        sourcePath: sourcePath,
                        transport: .stdio,
                        reason: reason,
                        idSuffix: idSuffix
                    )
                }
                return nil
            case nil:
                if reason != nil {
                    return Self.candidate(
                        source: source,
                        name: name,
                        displayName: displayName,
                        sourcePath: sourcePath,
                        transport: .stdio,
                        reason: reason,
                        idSuffix: idSuffix
                    )
                }
                return nil
            }
        }
    }

    private func mcpEnvironment(
        from config: [String: Any],
        sourcePath: String,
        envStorageKey: String,
        keyPathPrefix: [String]
    ) -> [MCPStdioEnvironmentVariable] {
        guard let env = config[envStorageKey] as? [String: Any] else {
            return []
        }

        return env.compactMap { name, rawValue in
            guard let stringValue = rawValue as? String else {
                return nil
            }

            if sourcePath.hasSuffix(".toml") {
                return MCPStdioEnvironmentVariable(
                    name: name,
                    valueSource: MCPBridgeHeaderValueSource(
                        kind: .tomlFile,
                        filePath: sourcePath,
                        keyPath: keyPathPrefix + [name]
                    )
                )
            }

            if sourcePath.hasSuffix(".json") || sourcePath.hasSuffix(".jsonc") {
                return MCPStdioEnvironmentVariable(
                    name: name,
                    valueSource: MCPBridgeHeaderValueSource(
                        kind: .jsonFile,
                        filePath: sourcePath,
                        keyPath: keyPathPrefix + [name]
                    )
                )
            }

            return MCPStdioEnvironmentVariable(name: name, value: stringValue)
        }
    }

    /// Node/Python-style MCP configs launch an interpreter whose first argv
    /// item is the actual server program. Resolving only the interpreter made a
    /// deleted JavaScript entrypoint look importable until every call failed.
    private static func missingInterpreterEntrypointReason(
        command: String,
        args: [String]
    ) -> String? {
        let interpreter = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        let interpreters: Set<String> = [
            "node", "bun", "deno", "python", "python3", "python3.12", "python3.13", "python3.14"
        ]
        guard interpreters.contains(interpreter),
              let entrypoint = args.first,
              entrypoint.hasPrefix("/"),
              !FileManager.default.fileExists(atPath: entrypoint) else {
            return nil
        }
        return "Entrypoint not found: \(entrypoint)."
    }

    private func mcpHeaders(from config: [String: Any]) -> (headers: [MCPBridgeHeader], blockedReason: String?) {
        var headers = [MCPBridgeHeader]()
        if let bearer = config["bearer_token_env_var"] as? String, !bearer.isEmpty {
            headers.append(MCPBridgeHeader(
                name: "Authorization",
                valueSource: MCPBridgeHeaderValueSource(kind: .environment, environmentKey: bearer, prefix: "Bearer ")
            ))
        }

        let rawHeaders = (config["headers"] ?? config["http_headers"]) as? [String: Any] ?? [:]
        for (name, value) in rawHeaders {
            guard let stringValue = value as? String else { continue }
            if Self.looksSecretLike(name) || Self.looksSecretLike(stringValue) {
                return (headers, "Literal secret-looking headers are not imported; use an environment-backed header.")
            }
            headers.append(MCPBridgeHeader(name: name, value: stringValue))
        }
        return (headers, nil)
    }

    private func resolvedHeaders(for candidate: LocalMCPServerCandidate) async throws -> [String: String] {
        var resolved = [String: String]()
        for header in candidate.headers {
            if let value = header.value {
                resolved[header.name] = value
                continue
            }
            guard let source = header.valueSource else { continue }
            let value: String
            switch source.kind {
            case .environment:
                guard let key = source.environmentKey,
                      let envValue = ProcessInfo.processInfo.environment[key] else {
                    throw LocalMCPScannerError.missingHeaderSource(header.name)
                }
                value = envValue
            case .jsonFile:
                value = try jsonFileHeaderValue(source: source, headerName: header.name)
            case .tomlFile:
                value = try tomlFileValue(source: source, valueName: header.name)
            case .oauth:
                guard let url = candidate.url, let token = await oauth.accessToken(for: url) else {
                    throw LocalMCPScannerError.signInRequired(candidate.displayName)
                }
                value = token
            }
            resolved[header.name] = (source.prefix ?? "") + value
        }
        return resolved
    }

    private func jsonFileHeaderValue(source: MCPBridgeHeaderValueSource, headerName: String) throws -> String {
        guard let filePath = source.filePath,
              let keyPath = source.keyPath,
              let object = jsonObject(from: URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath)) else {
            throw LocalMCPScannerError.missingHeaderSource(headerName)
        }

        var cursor: Any = object
        for key in keyPath {
            guard let dictionary = cursor as? [String: Any],
                  let next = dictionary[key] else {
                throw LocalMCPScannerError.missingHeaderSource(headerName)
            }
            cursor = next
        }
        guard let value = cursor as? String, !value.isEmpty else {
            throw LocalMCPScannerError.missingHeaderSource(headerName)
        }
        return value
    }

    private func tomlFileValue(source: MCPBridgeHeaderValueSource, valueName: String) throws -> String {
        guard let filePath = source.filePath,
              let keyPath = source.keyPath,
              keyPath.count >= 2,
              let text = try? String(contentsOf: URL(fileURLWithPath: (filePath as NSString).expandingTildeInPath), encoding: .utf8) else {
            throw LocalMCPScannerError.missingHeaderSource(valueName)
        }

        let sectionName = keyPath.dropLast().joined(separator: ".")
        let targetKey = keyPath.last ?? ""
        var currentSection: String?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                continue
            }
            guard currentSection == sectionName,
                  let separator = line.firstIndex(of: "=") else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == targetKey else { continue }
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            if let unquoted = Self.unquotedString(value), !unquoted.isEmpty {
                return unquoted
            }
        }
        throw LocalMCPScannerError.missingHeaderSource(valueName)
    }

    private func resolvedCommand(_ command: String) throws -> String {
        guard let path = resolvedCommandPath(command) else {
            throw LocalMCPScannerError.executableNotFound(command)
        }
        return path
    }

    private func resolvedCommandPath(_ command: String) -> String? {
        if command.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: command) ? command : nil
        }
        return executablePath(command)
    }

    private func postJSONRPC(
        url: String,
        headers: [String: String],
        payload: [String: Any],
        allowEmpty: Bool = false
    ) async throws -> (body: [String: Any], headers: [String: String]) {
        let response = try await sendJSONRPC(
            url: url,
            headers: headers,
            payload: payload
        )
        guard (200..<300).contains(response.statusCode) else {
            let body = String(decoding: response.data.prefix(1024), as: UTF8.self)
            throw LocalMCPScannerError.httpStatus(response.statusCode, body)
        }
        if response.data.isEmpty, allowEmpty {
            return ([:], response.headers)
        }
        guard let body = response.body else {
            throw LocalMCPScannerError.invalidResponse("response was neither JSON nor JSON SSE")
        }
        return (body, response.headers)
    }

    private func sendJSONRPC(
        url: String,
        headers: [String: String],
        payload: [String: Any]
    ) async throws -> LocalMCPHTTPResponse {
        guard let endpoint = URL(string: url) else {
            throw LocalMCPScannerError.missingURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Probing a local server: 60s here compounded across three requests
        // per candidate and kept the scan spinner up for minutes.
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.checkedData(withJSONObject: payload)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await MCPHTTPResponseBody.data(for: request, session: urlSession)
        guard let http = response as? HTTPURLResponse else {
            throw LocalMCPScannerError.invalidResponse("missing HTTP response")
        }
        return LocalMCPHTTPResponse(
            statusCode: http.statusCode,
            data: data,
            headers: normalizedHeaders(from: http),
            body: try? parseMCPResponse(data)
        )
    }

    private func parseMCPResponse(_ data: Data) throws -> [String: Any] {
        guard let object = MCPHTTPResponseBody.jsonRPCMessage(from: data) else {
            throw LocalMCPScannerError.invalidResponse("response was neither JSON nor JSON SSE")
        }
        return object
    }

    private enum JSONReadResult {
        case success([String: Any])
        case failure
    }

    private func readJSONObject(from url: URL) -> JSONReadResult {
        guard let data = try? Data(contentsOf: url) else {
            return .failure
        }
        let text = String(decoding: data, as: UTF8.self)
        let prepared = Self.prepareJSONC(text)
        guard let jsonData = prepared.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return .failure
        }
        return .success(object)
    }

    private func jsonObject(from url: URL) -> [String: Any]? {
        guard case .success(let object) = readJSONObject(from: url) else {
            return nil
        }
        return object
    }

    private func normalizedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers = [String: String]()
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key)] = String(describing: value)
        }
        return headers
    }

    private func headerValue(named name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    private func deduplicated(_ candidates: [LocalMCPServerCandidate]) -> [LocalMCPServerCandidate] {
        var resultIndexByRuntime = [String: Int]()
        var resultIndexByProviderID = [String: Int]()
        var seenFallbackKeys = Set<String>()
        var result = [LocalMCPServerCandidate]()
        let detectedExecutablePaths = firstPartyExecutablePaths
        // First-party candidates go first so a config row that launches the
        // same CLI's server can fold into them regardless of scan order.
        let ordered = candidates.filter { $0.source == FirstPartyMCPProviderCatalog.discoverySource }
            + candidates.filter { $0.source != FirstPartyMCPProviderCatalog.discoverySource }
        for var candidate in ordered {
            if let provider = FirstPartyMCPProviderCatalog.provider(
                forCandidateSource: candidate.source,
                name: candidate.name
            ) {
                resultIndexByProviderID[provider.id] = result.count
            } else if candidate.transport == .stdio,
                      let command = candidate.command,
                      let provider = FirstPartyMCPProviderCatalog.provider(
                          launchedBy: command,
                          args: candidate.args,
                          environment: candidate.environment,
                          detectedExecutablePaths: detectedExecutablePaths
                      ),
                      let providerIndex = resultIndexByProviderID[provider.id] {
                // Claude Code, Codex, or Claude Desktop already launch this
                // CLI's own server. Same provider, one more owner, no second
                // tool family.
                result[providerIndex].discoveryOwners = Self.sortedOwners(
                    result[providerIndex].configurationOwners + candidate.configurationOwners
                )
                continue
            }
            if let identity = candidate.canonicalRuntimeIdentity {
                if let existingIndex = resultIndexByRuntime[identity] {
                    result[existingIndex].discoveryOwners = Self.sortedOwners(
                        result[existingIndex].configurationOwners + candidate.configurationOwners
                    )
                    continue
                }
                candidate.discoveryOwners = candidate.configurationOwners
                resultIndexByRuntime[identity] = result.count
                result.append(candidate)
                continue
            }
            let key = "\(candidate.source)\u{1f}\(candidate.name)\u{1f}\(candidate.url ?? candidate.command ?? "")"
            guard seenFallbackKeys.insert(key).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private static func sortedOwners(_ owners: [MCPDiscoveryOwner]) -> [MCPDiscoveryOwner] {
        Set(owners).sorted {
            if $0.source != $1.source { return $0.source < $1.source }
            if $0.sourcePath != $1.sourcePath { return $0.sourcePath < $1.sourcePath }
            return $0.serverIdentity < $1.serverIdentity
        }
    }

    private static func candidate(
        source: String,
        name: String,
        displayName: String,
        sourcePath: String,
        transport: LocalMCPServerCandidate.Transport,
        url: String? = nil,
        headers: [MCPBridgeHeader] = [],
        command: String? = nil,
        args: [String] = [],
        startupTimeoutSeconds: TimeInterval? = nil,
        reason: String? = nil,
        environment: [MCPStdioEnvironmentVariable] = [],
        idSuffix: String? = nil
    ) -> LocalMCPServerCandidate {
        let bridgeable = (transport == .http || transport == .stdio) && reason == nil
        let id = idSuffix.map { "\(source).\(name).\($0)" } ?? "\(source).\(name)"
        return LocalMCPServerCandidate(
            id: id,
            source: source,
            sourcePath: sourcePath,
            name: name,
            displayName: displayName,
            transport: transport,
            url: url,
            command: command,
            args: args,
            startupTimeoutSeconds: startupTimeoutSeconds,
            isLocal: url.map(isLoopbackMCPURL) ?? false,
            bridgeable: bridgeable,
            reason: reason,
            headers: headers,
            environment: environment,
            probe: nil,
            probeError: nil
        )
    }

    private static func serverInfo(from object: [String: Any]) -> LocalMCPServerInfo {
        LocalMCPServerInfo(
            name: object["name"] as? String,
            title: object["title"] as? String,
            version: object["version"] as? String,
            description: object["description"] as? String
        )
    }

    private static func toolSummary(from object: [String: Any]) -> LocalMCPToolSummary? {
        guard let name = object["name"] as? String, !name.isEmpty else {
            return nil
        }
        return LocalMCPToolSummary(
            name: name,
            title: object["title"] as? String,
            description: object["description"] as? String,
            inputSchema: JSONValue.fromJSONObject(object["inputSchema"] ?? [:]),
            annotations: JSONValue.fromJSONObject(object["annotations"] ?? [:])
        )
    }

    private static func resolveRootServers(in object: [String: Any], preferredKey: String) -> (Any?, String) {
        if let servers = object[preferredKey] {
            return (servers, preferredKey)
        }
        for alias in rootKeyAliases where alias != preferredKey {
            if let servers = object[alias] {
                return (servers, alias)
            }
        }
        return (nil, preferredKey)
    }

    private static func unreadableConfigCandidate(path: URL, source: String, format: String) -> LocalMCPServerCandidate {
        unreadableSourceCandidate(
            path: path,
            source: source,
            reason: "Could not read this file as \(format)."
        )
    }

    private static func unreadableSourceCandidate(
        path: URL,
        source: String,
        reason: String
    ) -> LocalMCPServerCandidate {
        let fileName = path.lastPathComponent
        let name = stableSlug(fileName)
        return LocalMCPServerCandidate(
            id: "\(source).\(name)",
            source: source,
            sourcePath: path.path,
            name: name,
            displayName: fileName,
            transport: .stdio,
            url: nil,
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: false,
            bridgeable: false,
            reason: reason,
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil,
            sourceReadFailureScopePath: path.standardizedFileURL.path
        )
    }

    private static func projectPathSuffix(_ projectPath: String) -> String {
        let hash = SHA256.hash(data: Data(projectPath.utf8))
        return hash.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func disabledReason(from config: [String: Any]) -> String? {
        if config["disabled"] as? Bool == true {
            return "Disabled in the source app's settings."
        }
        if config["enabled"] as? Bool == false {
            return "Disabled in the source app's settings."
        }
        return nil
    }

    private static func primaryBlockedReason(from config: [String: Any]) -> String? {
        if config["envFile"] != nil {
            return "This server loads secrets from an env file; add the values in the source app before importing."
        }
        return disabledReason(from: config)
    }

    private static func environmentStorageKey(in config: [String: Any]) -> String {
        if config["environment"] != nil {
            return "environment"
        }
        return "env"
    }

    private static func normalizedTypeName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func resolvedTransport(from config: [String: Any]) -> LocalMCPServerCandidate.Transport? {
        if let type = config["type"] as? String {
            switch normalizedTypeName(type) {
            case "stdio", "local":
                return .stdio
            case "http", "streamablehttp", "sse", "remote":
                return .http
            default:
                break
            }
        }
        if resolveHTTPURL(from: config) != nil {
            return .http
        }
        if resolveCommandConfig(from: config) != nil {
            return .stdio
        }
        return nil
    }

    private static let urlConfigKeys = ["httpUrl", "serverUrl", "url", "endpoint"]

    private static func resolveHTTPURL(from config: [String: Any]) -> String? {
        for key in urlConfigKeys {
            if let url = config[key] as? String, looksLikeHTTPURL(url) {
                return url
            }
        }
        return nil
    }

    private static func resolveCommandConfig(from config: [String: Any]) -> (command: String, args: [String])? {
        if let commandArray = config["command"] as? [Any] {
            let strings = commandArray.map { String(describing: $0) }
            guard let executable = strings.first, !executable.isEmpty else {
                return nil
            }
            let leadingArgs = Array(strings.dropFirst())
            let extraArgs = (config["args"] as? [Any] ?? []).map { String(describing: $0) }
            return (executable, leadingArgs + extraArgs)
        }
        if let command = config["command"] as? String, !command.isEmpty {
            let args = (config["args"] as? [Any] ?? []).map { String(describing: $0) }
            return (command, args)
        }
        return nil
    }

    static func prepareJSONC(_ text: String) -> String {
        removeJSONTrailingCommas(from: stripJSONCComments(from: text))
    }

    private static func stripJSONCComments(from text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]

            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "/" {
                let next = text.index(after: index)
                if next < text.endIndex {
                    let nextCharacter = text[next]
                    if nextCharacter == "/" {
                        index = text.index(after: next)
                        while index < text.endIndex, text[index] != "\n" {
                            index = text.index(after: index)
                        }
                        continue
                    }
                    if nextCharacter == "*" {
                        index = text.index(after: next)
                        while index < text.endIndex {
                            if text[index] == "*",
                               text.index(after: index) < text.endIndex,
                               text[text.index(after: index)] == "/" {
                                index = text.index(index, offsetBy: 2)
                                break
                            }
                            index = text.index(after: index)
                        }
                        continue
                    }
                }
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func removeJSONTrailingCommas(from text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)

        var index = text.startIndex
        var inString = false
        var escaped = false

        while index < text.endIndex {
            let character = text[index]

            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                inString = true
                result.append(character)
                index = text.index(after: index)
                continue
            }

            if character == "," {
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex, text[lookahead].isWhitespace {
                    lookahead = text.index(after: lookahead)
                }
                if lookahead < text.endIndex, text[lookahead] == "}" || text[lookahead] == "]" {
                    index = text.index(after: index)
                    continue
                }
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func looksLikeHTTPURL(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else {
            return false
        }
        return (components.scheme == "http" || components.scheme == "https") && components.host != nil
    }

    private static func isLoopbackMCPURL(_ value: String) -> Bool {
        guard let host = URLComponents(string: value)?.host else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    static func isSecretLikeURLSegment(_ segment: String) -> Bool {
        segment.count >= 24 && segment.range(of: #"^[A-Za-z0-9._~+=-]+$"#, options: .regularExpression) != nil
    }

    private static func looksSecretLike(_ value: String) -> Bool {
        value.range(of: #"(?i)(token|secret|password|bearer|api[_-]?key)"#, options: .regularExpression) != nil
    }

    private static func stableSlug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9_]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return slug.isEmpty ? "mcp" : slug
    }

    private static func unquotedString(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) ||
            (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            return String(trimmed.dropFirst().dropLast())
        }
        return nil
    }

    private static func stringArray(fromTOMLValue value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              trimmed.hasSuffix("]") else {
            return []
        }
        let inner = trimmed.dropFirst().dropLast()
        return inner
            .split(separator: ",")
            .compactMap { unquotedString(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func doubleValue(_ value: String) -> Double? {
        Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func numericValue(_ value: Any?) -> Double? {
        switch value {
        case let double as Double:
            double
        case let int as Int:
            Double(int)
        case let string as String:
            doubleValue(string)
        default:
            nil
        }
    }

    private func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.checkedData(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private struct LocalMCPHTTPResponse {
    let statusCode: Int
    let data: Data
    let headers: [String: String]
    let body: [String: Any]?
}

private enum LocalMCPScannerError: LocalizedError {
    case missingURL
    case missingCommand
    case noTools
    case missingHeaderSource(String)
    case signInRequired(String)
    case executableNotFound(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case jsonRPCError(String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .timedOut(let seconds):
            "The MCP server did not finish answering within the \(seconds.formatted())-second limit."
        case .missingURL:
            "MCP server URL is missing."
        case .missingCommand:
            "MCP stdio command is missing."
        case .noTools:
            "No upstream MCP tools have been probed for this server."
        case .missingHeaderSource(let header):
            "Could not resolve MCP header: \(header)"
        case .signInRequired(let name):
            "Sign in to \(name) in MacRemote › Tools to use its tools."
        case .executableNotFound(let command):
            "MCP stdio executable is not available: \(command)"
        case .httpStatus(let status, let body):
            body.isEmpty ? "Upstream MCP server returned HTTP \(status)." : "Upstream MCP server returned HTTP \(status): \(body)"
        case .invalidResponse(let detail):
            "Invalid MCP response: \(detail)"
        case .jsonRPCError(let detail):
            "MCP JSON-RPC error: \(detail)"
        }
    }
}

private extension String {
    func firstMatch(of pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range) else {
            return nil
        }
        return (0..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: self) else {
                return nil
            }
            return String(self[range])
        }
    }
}
