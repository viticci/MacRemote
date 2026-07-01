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
    private let processRunner: ProcessRunner
    private let stdioBridgeClient: MCPStdioBridgeClient

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        urlSession: URLSession = .shared,
        executablePath: @escaping @Sendable (String) -> String? = { ExecutableLocator.executablePath(named: $0) },
        processRunner: ProcessRunner = ProcessRunner(),
        stdioBridgeClient: MCPStdioBridgeClient = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
    ) {
        self.homeDirectory = homeDirectory
        self.urlSession = urlSession
        self.executablePath = executablePath
        self.processRunner = processRunner
        self.stdioBridgeClient = stdioBridgeClient
    }

    func scan(includeRemote: Bool = false, probe shouldProbe: Bool = true) async -> [LocalMCPServerCandidate] {
        var candidates = await scanConfiguredServers()
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

        for index in candidates.indices where candidates[index].bridgeable {
            do {
                candidates[index].probe = try await probe(candidate: candidates[index])
                candidates[index].probeError = nil
            } catch {
                candidates[index].probe = nil
                candidates[index].probeError = error.localizedDescription
            }
        }
        return candidates
    }

    func probe(candidate: LocalMCPServerCandidate) async throws -> LocalMCPProbeResult {
        if candidate.transport == .stdio {
            guard let command = candidate.command else {
                throw LocalMCPScannerError.missingCommand
            }
            return try await stdioBridgeClient.probe(
                command: try resolvedCommand(command),
                args: candidate.args,
                environmentVariables: candidate.environment,
                protocolVersion: "2025-06-18",
                timeoutSeconds: candidate.startupTimeoutSeconds ?? 20
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

    private func scanConfiguredServers() async -> [LocalMCPServerCandidate] {
        var candidates = [LocalMCPServerCandidate]()
        candidates.append(contentsOf: scanCodexMCPServers())
        candidates.append(contentsOf: scanClaudeDesktopMCPServers())
        candidates.append(contentsOf: scanClaudeCodeMCPServers())
        candidates.append(contentsOf: scanClaudeExtensions())
        candidates.append(contentsOf: await scanClaudeRuntimeMCPServers())
        candidates.append(contentsOf: scanJSONMCPFile(homeDirectory.appendingPathComponent(".cursor/mcp.json"), source: "cursor", rootKey: "mcpServers"))
        candidates.append(contentsOf: scanJSONMCPFile(homeDirectory.appendingPathComponent(".lmstudio/mcp.json"), source: "lmstudio", rootKey: "mcpServers"))
        candidates.append(contentsOf: scanJSONMCPFile(homeDirectory.appendingPathComponent("Library/Developer/Xcode/CodingAssistant/mcp-servers.json"), source: "xcode_coding_assistant", rootKey: "mcpServers"))
        candidates.append(contentsOf: scanGrokMCPServers())
        candidates.append(contentsOf: scanOpenCodeMCPServers())
        return candidates
    }

    private func scanCodexMCPServers() -> [LocalMCPServerCandidate] {
        scanTOMLMCPFile(homeDirectory.appendingPathComponent(".codex/config.toml"), source: "codex")
    }

    private func scanGrokMCPServers() -> [LocalMCPServerCandidate] {
        scanTOMLMCPFile(homeDirectory.appendingPathComponent(".grok/config.toml"), source: "grok") +
            scanTOMLMCPFile(homeDirectory.appendingPathComponent(".config/grok/config.toml"), source: "grok")
    }

    private func scanOpenCodeMCPServers() -> [LocalMCPServerCandidate] {
        scanJSONMCPFile(homeDirectory.appendingPathComponent(".config/opencode/opencode.json"), source: "opencode", rootKey: "mcp") +
            scanJSONMCPFile(homeDirectory.appendingPathComponent(".config/opencode/opencode.jsonc"), source: "opencode", rootKey: "mcp")
    }

    private func scanClaudeDesktopMCPServers() -> [LocalMCPServerCandidate] {
        scanJSONMCPFile(
            homeDirectory.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"),
            source: "claude_desktop",
            rootKey: "mcpServers"
        )
    }

    private func scanClaudeCodeMCPServers() -> [LocalMCPServerCandidate] {
        scanJSONMCPFile(homeDirectory.appendingPathComponent(".mcp.json"), source: "claude_code", rootKey: "mcpServers")
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
            environment: ExecutableLocator.toolEnvironment
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

    private func scanJSONMCPFile(_ path: URL, source: String, rootKey: String) -> [LocalMCPServerCandidate] {
        guard let object = jsonObject(from: path) else {
            return []
        }
        var actualRootKey = rootKey
        var servers = object[rootKey]
        if servers == nil, rootKey == "mcpServers" {
            servers = object["servers"]
            actualRootKey = "servers"
        }
        return candidates(from: servers, source: source, sourcePath: path.path, rootKey: actualRootKey)
    }

    private func scanTOMLMCPFile(_ path: URL, source: String) -> [LocalMCPServerCandidate] {
        guard let text = try? String(contentsOf: path, encoding: .utf8) else {
            return []
        }

        var sections: [String: [String: String]] = [:]
        var currentName: String?
        var currentKeyPrefix = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[mcp_servers."), line.hasSuffix("]") {
                let section = String(line.dropFirst("[mcp_servers.".count).dropLast())
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
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

    private func candidates(from servers: Any?, source: String, sourcePath: String, rootKey: String) -> [LocalMCPServerCandidate] {
        guard let servers = servers as? [String: Any] else {
            return []
        }

        return servers.compactMap { rawName, rawConfig in
            guard let config = rawConfig as? [String: Any] else {
                return nil
            }
            let name = Self.stableSlug(rawName)
            let displayName = rawName
            if let url = (config["url"] ?? config["endpoint"]) as? String,
               Self.looksLikeHTTPURL(url) {
                let headerResult = mcpHeaders(from: config)
                return Self.candidate(
                    source: source,
                    name: name,
                    displayName: displayName,
                    sourcePath: sourcePath,
                    transport: .http,
                    url: url,
                    headers: headerResult.headers,
                    reason: headerResult.blockedReason
                )
            }

            if let command = config["command"] as? String {
                let resolvedCommand = resolvedCommandPath(command)
                let commandReason = resolvedCommand == nil ? "Executable not found: \(command)." : nil
                let startupTimeout = Self.numericValue(config["startup_timeout_sec"] ?? config["startupTimeoutSeconds"])
                return Self.candidate(
                    source: source,
                    name: name,
                    displayName: displayName,
                    sourcePath: sourcePath,
                    transport: .stdio,
                    command: resolvedCommand ?? command,
                    args: (config["args"] as? [Any] ?? []).map { String(describing: $0) },
                    startupTimeoutSeconds: startupTimeout,
                    reason: commandReason,
                    environment: mcpEnvironment(from: config, rawName: rawName, sourcePath: sourcePath, rootKey: rootKey)
                )
            }
            return nil
        }
    }

    private func mcpEnvironment(from config: [String: Any], rawName: String, sourcePath: String, rootKey: String) -> [MCPStdioEnvironmentVariable] {
        guard let env = config["env"] as? [String: Any] else {
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
                        keyPath: ["mcp_servers", rawName, "env", name]
                    )
                )
            }

            if sourcePath.hasSuffix(".json") || sourcePath.hasSuffix(".jsonc") {
                return MCPStdioEnvironmentVariable(
                    name: name,
                    valueSource: MCPBridgeHeaderValueSource(
                        kind: .jsonFile,
                        filePath: sourcePath,
                        keyPath: [rootKey, rawName, "env", name]
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
        request.timeoutInterval = 60
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

    private func jsonObject(from url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
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
        environment: [MCPStdioEnvironmentVariable] = []
    ) -> LocalMCPServerCandidate {
        let bridgeable = (transport == .http || transport == .stdio) && reason == nil
        return LocalMCPServerCandidate(
            id: "\(source).\(name)",
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
