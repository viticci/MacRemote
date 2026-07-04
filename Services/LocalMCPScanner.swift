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
    let headers: [MCPBridgeHeader]
    let environment: [MCPStdioEnvironmentVariable]
    var probe: LocalMCPProbeResult?
    var probeError: String?
    var isNewSinceLastScan: Bool = false

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
}

struct LocalMCPProbeResult: Hashable, Sendable {
    let serverInfo: LocalMCPServerInfo
    let tools: [LocalMCPToolSummary]
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
    private let homeDirectory: URL
    private let urlSession: URLSession
    private let executablePath: @Sendable (String) -> String?
    private let processRunner: any ProcessRunning
    private let stdioBridgeClient: MCPStdioBridgeClient

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        urlSession: URLSession = .shared,
        executablePath: @escaping @Sendable (String) -> String? = { ExecutableLocator.executablePath(named: $0) },
        processRunner: any ProcessRunning = ProcessRunner(),
        stdioBridgeClient: MCPStdioBridgeClient = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
    ) {
        self.homeDirectory = homeDirectory
        self.urlSession = urlSession
        self.executablePath = executablePath
        self.processRunner = processRunner
        self.stdioBridgeClient = stdioBridgeClient
    }

    var scanHomeDirectory: URL { homeDirectory }

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

        // Probe concurrently (bounded) instead of serially: each probe launches
        // a server process or makes HTTP round-trips with multi-second timeouts,
        // and a Mac with a dozen configured servers left the scan spinner up
        // for minutes when probed one at a time.
        let snapshot = candidates
        let probeIndices = snapshot.indices.filter { snapshot[$0].bridgeable }
        let maxConcurrentProbes = 4
        let outcomes = await withTaskGroup(
            of: (Int, LocalMCPProbeResult?, String?).self,
            returning: [Int: (LocalMCPProbeResult?, String?)].self
        ) { group in
            var pending = probeIndices[...]
            var collected = [Int: (LocalMCPProbeResult?, String?)]()

            func addProbeTask(for index: Int) {
                group.addTask {
                    do {
                        // Bulk scan: cap each server's startup allowance so one
                        // slow server cannot dominate the scan. Import re-probes
                        // with the candidate's full configured timeout.
                        return (index, try await self.probe(candidate: snapshot[index], timeoutCapSeconds: 10), nil)
                    } catch {
                        return (index, nil, error.localizedDescription)
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
            candidates[index].probeError = outcome.1
        }
        return candidates
    }

    func probe(candidate: LocalMCPServerCandidate, timeoutCapSeconds: TimeInterval? = nil) async throws -> LocalMCPProbeResult {
        if candidate.transport == .stdio {
            guard let command = candidate.command else {
                throw LocalMCPScannerError.missingCommand
            }
            let configuredTimeout = candidate.startupTimeoutSeconds ?? 20
            return try await stdioBridgeClient.probe(
                command: try resolvedCommand(command),
                args: candidate.args,
                environmentVariables: candidate.environment,
                protocolVersion: "2025-06-18",
                timeoutSeconds: timeoutCapSeconds.map { min(configuredTimeout, $0) } ?? configuredTimeout
            )
        }

        guard let url = candidate.url else {
            throw LocalMCPScannerError.missingURL
        }

        var headers = try resolvedHeaders(for: candidate)
        headers["Content-Type"] = "application/json"
        headers["Accept"] = "application/json, text/event-stream"
        headers["MCP-Protocol-Version"] = "2025-06-18"

        let initializeResponse = try await postJSONRPC(
            url: url,
            headers: headers,
            payload: [
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "MacRemote",
                        "version": "0.1.0"
                    ]
                ]
            ]
        )
        if let error = initializeResponse.body["error"] {
            throw LocalMCPScannerError.jsonRPCError(serializedJSON(error))
        }

        let result = initializeResponse.body["result"] as? [String: Any] ?? [:]
        let protocolVersion = result["protocolVersion"] as? String ?? "2025-06-18"
        headers["MCP-Protocol-Version"] = protocolVersion
        if let sessionID = headerValue(named: "Mcp-Session-Id", in: initializeResponse.headers) {
            headers["Mcp-Session-Id"] = sessionID
        }

        _ = try? await postJSONRPC(
            url: url,
            headers: headers,
            payload: [
                "jsonrpc": "2.0",
                "method": "notifications/initialized",
                "params": [:]
            ],
            allowEmpty: true
        )

        let toolsResponse = try await postJSONRPC(
            url: url,
            headers: headers,
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
        let tools = (toolsResult["tools"] as? [[String: Any]] ?? []).compactMap(Self.toolSummary)
        return LocalMCPProbeResult(
            serverInfo: Self.serverInfo(from: result["serverInfo"] as? [String: Any] ?? [:]),
            tools: tools
        )
    }

    func bridgeTools(for candidate: LocalMCPServerCandidate) throws -> [ToolDefinition] {
        if candidate.transport == .http, candidate.url == nil {
            throw LocalMCPScannerError.missingURL
        }
        if candidate.transport == .stdio, candidate.command == nil {
            throw LocalMCPScannerError.missingCommand
        }
        guard let tools = candidate.probe?.tools, !tools.isEmpty else {
            throw LocalMCPScannerError.noTools
        }
        let command = candidate.command.flatMap { try? resolvedCommand($0) }

        return tools.map { upstreamTool in
            let inputSchema = upstreamTool.inputSchema ?? .object([
                "type": .string("object"),
                "properties": .object([:])
            ])
            let annotations = upstreamTool.annotations ?? .object([:])
            return ToolDefinition(
                id: "custom.\(Self.randomHex(bytes: 8))",
                name: "\(candidate.displayName): \(upstreamTool.displayTitle)",
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
                    serverName: candidate.displayName,
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
                    serverName: candidate.displayName,
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
    }

    private func scanConfiguredServers(includeRuntimeSources: Bool) async -> [LocalMCPServerCandidate] {
        var candidates = [LocalMCPServerCandidate]()
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
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates = [LocalMCPServerCandidate]()
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "manifest.json" {
            guard let object = jsonObject(from: fileURL),
                  let server = object["server"] as? [String: Any],
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
                    let commandReason = resolvedCommand == nil ? "Executable not found: \(commandConfig.command)." : nil
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

    private func resolvedHeaders(for candidate: LocalMCPServerCandidate) throws -> [String: String] {
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
        guard let endpoint = URL(string: url) else {
            throw LocalMCPScannerError.missingURL
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Probing a local server: 60s here compounded across three requests
        // per candidate and kept the scan spinner up for minutes.
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LocalMCPScannerError.invalidResponse("missing HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data.prefix(1024), as: UTF8.self)
            throw LocalMCPScannerError.httpStatus(http.statusCode, body)
        }
        if data.isEmpty, allowEmpty {
            return ([:], normalizedHeaders(from: http))
        }
        return (try parseMCPResponse(data), normalizedHeaders(from: http))
    }

    private func parseMCPResponse(_ data: Data) throws -> [String: Any] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        let text = String(decoding: data, as: UTF8.self)
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

        throw LocalMCPScannerError.invalidResponse("response was neither JSON nor JSON SSE")
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
        var seenKeys = Set<String>()
        var seenURLs = Set<String>()
        var result = [LocalMCPServerCandidate]()
        for candidate in candidates {
            if let url = candidate.url {
                guard seenURLs.insert(url).inserted else { continue }
            }
            let key = "\(candidate.source)\u{1f}\(candidate.name)\u{1f}\(candidate.url ?? candidate.command ?? "")"
            guard seenKeys.insert(key).inserted else { continue }
            result.append(candidate)
        }
        return result
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
            reason: "Could not read this file as \(format).",
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil
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

    private static func randomHex(bytes: Int) -> String {
        (0..<bytes)
            .map { _ in String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max)) }
            .joined()
    }

    private func serializedJSON(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private enum LocalMCPScannerError: LocalizedError {
    case missingURL
    case missingCommand
    case noTools
    case missingHeaderSource(String)
    case executableNotFound(String)
    case httpStatus(Int, String)
    case invalidResponse(String)
    case jsonRPCError(String)

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "MCP server URL is missing."
        case .missingCommand:
            "MCP stdio command is missing."
        case .noTools:
            "No upstream MCP tools have been probed for this server."
        case .missingHeaderSource(let header):
            "Could not resolve MCP header: \(header)"
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
