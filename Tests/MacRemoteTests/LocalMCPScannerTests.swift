import Foundation
import Testing
@testable import MacRemote

struct LocalMCPScannerTests {
    @Test func scansClaudeExtensionProbesToolsAndBuildsBridgeDefinitions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manifestURL = home
            .appendingPathComponent("Library/Application Support/Claude/Claude Extensions/local.mcpb.paste/manifest.json")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "name": "paste",
          "display_name": "Paste",
          "server": {
            "mcp_config": {
              "env": {
                "MCP_URL": "http://127.0.0.1:39725/mcp",
                "MCP_TOKEN": "secret-token"
              }
            }
          }
        }
        """.utf8).write(to: manifestURL)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMCPScannerURLProtocolMock.self]
        let session = URLSession(configuration: config)
        LocalMCPScannerURLProtocolMock.install([
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": "session-1"
                ],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"paste","title":"Paste","version":"1.0.0","description":"Clipboard history."},"capabilities":{}}}"#
            ),
            LocalMCPScannerMockResponse(statusCode: 202, headers: [:], body: ""),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: """
                event: message
                data: {"jsonrpc":"2.0","id":"tools","result":{"tools":[{"name":"search","title":"Search","description":"Search saved clips.","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"create_item","title":"Create Item","description":"Create a clip.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{}}]}}

                """
            )
        ])

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            urlSession: session,
            executablePath: { _ in nil }
        )
        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let candidate = try #require(candidates.first)

        #expect(candidate.id == "claude_extension.paste")
        #expect(candidate.displayName == "Paste")
        #expect(candidate.bridgeable)
        #expect(candidate.probe?.serverInfo.title == "Paste")
        #expect(candidate.probe?.tools.map(\.name) == ["search", "create_item"])

        let requests = LocalMCPScannerURLProtocolMock.requests()
        #expect(requests.map(\.method) == ["initialize", "notifications/initialized", "tools/list"])
        #expect(requests[0].headers["Authorization"] == "Bearer secret-token")
        #expect(requests[2].headers["Mcp-Session-Id"] == "session-1")

        let tools = try scanner.bridgeTools(for: candidate)
        #expect(tools.count == 2)
        #expect(tools[0].backend == .mcpHTTPBridge)
        #expect(tools[0].mcpBridge?.serverURL == "http://127.0.0.1:39725/mcp")
        #expect(tools[0].mcpBridge?.headers.first?.value == nil)
        #expect(tools[0].mcpBridge?.headers.first?.valueSource?.keyPath == ["server", "mcp_config", "env", "MCP_TOKEN"])
        #expect(tools[0].capability == .readOnly)
        #expect(tools[1].capability == .write)
    }

    @Test func scansUserScopedClaudeStdioServerFromClaudeJSON() async throws {
        // `claude mcp add --scope user` (e.g. the Safari MCP) writes a stdio
        // server at the top level of ~/.claude.json — not ~/.mcp.json — and it
        // never shows in `claude mcp list`'s HTTP-only output. The scanner must
        // read ~/.claude.json to surface it.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let serverURL = home.appendingPathComponent("mock-stdio-mcp")
        try Data(Self.mockStdioMCPServer.utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let claudeJSON: [String: Any] = [
            "mcpServers": [
                "safari-mcp-stp": [
                    "type": "stdio",
                    "command": serverURL.path,
                    "args": ["--fixture"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: home.appendingPathComponent(".claude.json"))

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let candidate = try #require(candidates.first { $0.displayName == "safari-mcp-stp" })
        #expect(candidate.transport == .stdio)
        #expect(candidate.bridgeable)
        #expect(candidate.command == serverURL.path)
        #expect(candidate.args == ["--fixture"])
        #expect(candidate.probe?.tools.map(\.name) == ["echo"])
    }

    @Test func scansCodexStdioServerProbesToolsAndBuildsBridgeDefinitions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let serverURL = home.appendingPathComponent("mock-stdio-mcp")
        try Data(Self.mockStdioMCPServer.utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.mock_stdio]
        command = "\(serverURL.path)"
        args = ["--fixture"]
        startup_timeout_sec = 30.0

        [mcp_servers.mock_stdio.env]
        MOCK_SECRET = "from-toml"
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let candidate = try #require(candidates.first)

        #expect(candidate.id == "codex.mock_stdio")
        #expect(candidate.transport == .stdio)
        #expect(candidate.bridgeable)
        #expect(candidate.probeError == nil)
        #expect(candidate.probe?.serverInfo.name == "mock-stdio")
        #expect(candidate.probe?.tools.map(\.name) == ["echo"])

        let tools = try scanner.bridgeTools(for: candidate)
        let tool = try #require(tools.first)
        #expect(tool.backend == .mcpStdioBridge)
        #expect(tool.mcpStdioBridge?.command == serverURL.path)
        #expect(tool.mcpStdioBridge?.args == ["--fixture"])
        #expect(tool.mcpStdioBridge?.startupTimeoutSeconds == 30)
        #expect(tool.mcpStdioBridge?.environment.first?.value == nil)
        #expect(tool.mcpStdioBridge?.environment.first?.valueSource?.kind == .tomlFile)
        #expect(tool.mcpStdioBridge?.environment.first?.valueSource?.keyPath == ["mcp_servers", "mock_stdio", "env", "MOCK_SECRET"])

        let client = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        let outcome = try await client.call(tool: tool, parameters: [
            "query": .string("hello")
        ])

        #expect(outcome.succeeded, Comment(rawValue: outcome.stderr))
        #expect(outcome.stdout.contains(#""secret":"from-toml""#), Comment(rawValue: outcome.stdout))
        #expect(outcome.stdout.contains(#""query":"hello""#), Comment(rawValue: outcome.stdout))
    }

    @Test func scansCodexStdioAuthProfilesAsSeparateBridges() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let publicURL = home.appendingPathComponent("public-mcp-wrapper")
        let accountURL = home.appendingPathComponent("account-mcp-wrapper")
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "public-search",
            toolName: "search_public_records",
            toolTitle: "Search Public Records"
        ).utf8).write(to: publicURL)
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "account-user",
            toolName: "get_account_bookmarks",
            toolTitle: "Get Account Bookmarks"
        ).utf8).write(to: accountURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountURL.path)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.public-search]
        command = "\(publicURL.path)"

        [mcp_servers.account-user]
        command = "\(accountURL.path)"
        startup_timeout_sec = 300.0

        [mcp_servers.public-docs]
        url = "https://docs.example.com/mcp"
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        #expect(candidates.map(\.id).sorted() == ["codex.account_user", "codex.public_search"])

        let publicProfile = try #require(candidates.first { $0.displayName == "public-search" })
        #expect(publicProfile.transport == .stdio)
        #expect(publicProfile.probe?.tools.map(\.name) == ["search_public_records"])

        let accountProfile = try #require(candidates.first { $0.displayName == "account-user" })
        #expect(accountProfile.transport == .stdio)
        #expect(accountProfile.startupTimeoutSeconds == 300)
        #expect(accountProfile.probe?.tools.map(\.name) == ["get_account_bookmarks"])

        let accountTool = try #require(scanner.bridgeTools(for: accountProfile).first)
        #expect(accountTool.backend == .mcpStdioBridge)
        #expect(accountTool.mcpStdioBridge?.serverName == "account-user")
        #expect(accountTool.mcpStdioBridge?.command == accountURL.path)
        #expect(accountTool.mcpStdioBridge?.startupTimeoutSeconds == 300)
        #expect(accountTool.mcpStdioBridge?.toolName == "get_account_bookmarks")
        #expect(throws: Never.self) { try ToolArgumentResolver.validate(accountTool) }
    }

    /// Reproduces the real ~/.codex/config.toml shape around `imessage_search`:
    /// multiple stdio/http MCP entries, a command-only server with no `args`,
    /// then trailing `[plugins."name@vendor"]` sections whose `enabled = true`
    /// lines follow immediately after the last MCP block.
    @Test func scansCodexConfigWithTrailingPluginsAndCommandOnlyServer() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let imessageScript = home.appendingPathComponent("run-codex-search-only.sh")
        let nodeRepl = home.appendingPathComponent("node_repl")
        let xSearch = home.appendingPathComponent("x-mcp-app-only")
        for url in [imessageScript, nodeRepl, xSearch] {
            try Data(Self.mockNamedStdioMCPServer(
                serverName: url.lastPathComponent,
                toolName: "search_messages",
                toolTitle: "Search Messages"
            ).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.firecrawl]
        command = "npx"
        args = ["-y", "firecrawl-mcp"]

        [mcp_servers.firecrawl.env]
        FIRECRAWL_API_KEY = "fc-test-key"

        [mcp_servers.chrome-devtools]
        command = "npx"
        args = ["-y", "chrome-devtools-mcp@latest"]
        startup_timeout_sec = 30.0

        [mcp_servers.chrome-devtools.env]
        CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS = "1"

        [mcp_servers.notion]
        url = "https://mcp.notion.com/mcp"

        [mcp_servers.monologue.tools.list_recent_notes]
        approval_mode = "approve"

        [mcp_servers.node_repl]
        args = []
        command = "\(nodeRepl.path)"
        startup_timeout_sec = 120

        [mcp_servers.node_repl.env]
        CODEX_HOME = "\(home.path)/.codex"

        [mcp_servers.x-search]
        command = "\(xSearch.path)"
        startup_timeout_sec = 60.0

        [mcp_servers.x-docs]
        url = "https://docs.x.com/mcp"

        [mcp_servers.safari_mcp_stp]
        command = "/Applications/Safari Technology Preview.app/Contents/MacOS/safaridriver"
        args = ["--mcp"]

        [mcp_servers.imessage_search]
        command = "\(imessageScript.path)"

        [plugins."build-ios-apps@openai-curated"]
        enabled = true

        [plugins."build-macos-apps@openai-curated"]
        enabled = true

        [plugins."github@openai-curated"]
        enabled = true

        [plugins."pdf@openai-primary-runtime"]
        enabled = true
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { command in
                if command == "npx" { return "/usr/bin/npx" }
                return nil
            },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let imessage = try #require(candidates.first { $0.id == "codex.imessage_search" })

        #expect(imessage.displayName == "imessage_search")
        #expect(imessage.transport == .stdio)
        #expect(imessage.command == imessageScript.path)
        #expect(imessage.args.isEmpty)
        #expect(imessage.environment.isEmpty)
        #expect(imessage.bridgeable)
        #expect(imessage.reason == nil)
        #expect(imessage.probeError == nil)
        #expect(imessage.probe?.tools.map(\.name) == ["search_messages"])

        // Nested tool approval tables must not become importable MCP servers.
        #expect(!candidates.contains { $0.displayName == "monologue.tools.list_recent_notes" })

        // Remote HTTP entries are excluded unless includeRemote is set.
        #expect(!candidates.contains { $0.id == "codex.notion" })
        #expect(!candidates.contains { $0.id == "codex.x_docs" })
    }

    /// The line-based Codex TOML parser keeps `currentName` set to the last
    /// `[mcp_servers.*]` header until another MCP header appears. Trailing
    /// `[plugins.*]` sections therefore mis-attribute `enabled = true` onto the
    /// last MCP block, but those keys are ignored when building candidates.
    @Test func trailingPluginEnabledLineDoesNotBreakCommandOnlyServerBridgeability() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let imessageScript = home.appendingPathComponent("run-codex-search-only.sh")
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "imessage_search",
            toolName: "search_messages",
            toolTitle: "Search Messages"
        ).utf8).write(to: imessageScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: imessageScript.path)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.imessage_search]
        command = "\(imessageScript.path)"

        [plugins."build-ios-apps@openai-curated"]
        enabled = true

        [plugins."github@openai-curated"]
        enabled = true
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)
        let imessage = try #require(candidates.first { $0.id == "codex.imessage_search" })

        #expect(imessage.bridgeable)
        #expect(imessage.args.isEmpty)
        #expect(imessage.environment.isEmpty)
        #expect(imessage.reason == nil)
    }

    @Test func jsonServersFallbackPreservesEnvironmentKeyPath() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let commandURL = home.appendingPathComponent("mock-mcp")
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "fallback",
            toolName: "echo",
            toolTitle: "Echo"
        ).utf8).write(to: commandURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "servers": {
            "profile-one": {
              "command": "\(commandURL.path)",
              "env": {
                "PROFILE_TOKEN": "from-json"
              }
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)
        let candidate = try #require(candidates.first)

        #expect(candidate.id == "cursor.profile_one")
        #expect(candidate.environment.first?.value == nil)
        #expect(candidate.environment.first?.valueSource?.kind == .jsonFile)
        #expect(candidate.environment.first?.valueSource?.keyPath == ["servers", "profile-one", "env", "PROFILE_TOKEN"])
    }

    @Test func scansVSCodeStdioServerWithEnv() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "vscode-mcp")
        let configURL = home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "servers": {
            "notes": {
              "type": "stdio",
              "command": "\(commandURL.path)",
              "args": ["--vscode"],
              "env": { "VSCODE_TOKEN": "secret" }
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "vscode" })

        #expect(candidate.id == "vscode.notes")
        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
        #expect(candidate.args == ["--vscode"])
        #expect(candidate.environment.first?.valueSource?.keyPath == ["servers", "notes", "env", "VSCODE_TOKEN"])
    }

    @Test func scansWindsurfHTTPServerWithServerURL() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "remote-docs": {
              "serverUrl": "http://127.0.0.1:8080/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "windsurf" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:8080/mcp")
        #expect(candidate.bridgeable)
    }

    @Test func scansZedContextServerFromJSONCSettings() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "zed-mcp")
        let configURL = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          // Zed MCP block
          "context_servers": {
            "custom-tools": {
              "source": "custom",
              "command": "\(commandURL.path)",
              "args": ["--zed"]
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "zed" })

        #expect(candidate.id == "zed.custom_tools")
        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
        #expect(candidate.args == ["--zed"])
    }

    @Test func scansGeminiHTTPServerWithHttpURL() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "gemini-remote": {
              "httpUrl": "http://127.0.0.1:9090/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "gemini" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:9090/mcp")
    }

    @Test func scansAntigravityHTTPServerWithServerURL() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".gemini/antigravity/mcp_config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "antigravity-remote": {
              "type": "remote",
              "serverUrl": "http://127.0.0.1:7070/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "antigravity" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:7070/mcp")
    }

    @Test func scansCopilotCLILocalStdioServer() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "copilot-mcp")
        let configURL = home.appendingPathComponent(".copilot/mcp-config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "local-tools": {
              "type": "local",
              "command": "\(commandURL.path)"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "copilot_cli" })

        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
    }

    @Test func scansClineStreamableHTTPServer() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cline/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "cline-remote": {
              "type": "streamableHttp",
              "url": "http://127.0.0.1:5555/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "cline" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:5555/mcp")
    }

    @Test func jsoncStrippingPreservesCommentsInStringsAndRemovesTrailingCommas() {
        let input = """
        {
          "url": "https://example.com/path//not-a-comment",
          "items": [1, /* block */ 2,],
        }
        """
        let prepared = LocalMCPScanner.prepareJSONC(input)
        #expect(prepared.contains("https://example.com/path//not-a-comment"))
        #expect(!prepared.contains("/* block */"))

        let data = Data(prepared.utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["url"] as? String == "https://example.com/path//not-a-comment")
        #expect((object?["items"] as? [Int]) == [1, 2])
    }

    @Test func corruptJSONConfigSurfacesPseudoCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "cursor" })

        #expect(candidate.displayName == "mcp.json")
        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Could not read this file as JSON.")
    }

    @Test func disabledFlagSurfacesNonBridgeableCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "disabled-mcp")
        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "disabled-server": {
              "disabled": true,
              "command": "\(commandURL.path)"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "disabled-server" })

        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Disabled in the source app's settings.")
    }

    @Test func enabledFalseSurfacesNonBridgeableCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "off-server": {
              "enabled": false,
              "url": "http://127.0.0.1:1234/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "off-server" })

        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Disabled in the source app's settings.")
    }

    @Test func scansOpenCodeLocalServerWithCommandArrayAndEnvironmentKey() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "opencode-mcp")
        let configURL = home.appendingPathComponent(".config/opencode/opencode.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcp": {
            "opencode-local": {
              "type": "local",
              "command": ["\(commandURL.path)", "--leading"],
              "args": ["--trailing"],
              "environment": {
                "OPEN_CODE_TOKEN": "secret"
              }
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "opencode" })

        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
        #expect(candidate.args == ["--leading", "--trailing"])
        #expect(candidate.environment.first?.valueSource?.keyPath == ["mcp", "opencode-local", "environment", "OPEN_CODE_TOKEN"])
    }

    @Test func claudeCodeProjectServersGetUniqueIDsAndDedupIdenticalCommands() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandA = try Self.installMockStdioServer(in: home, name: "project-a-mcp")
        let commandB = try Self.installMockStdioServer(in: home, name: "project-b-mcp")
        let sharedCommand = try Self.installMockStdioServer(in: home, name: "shared-mcp")

        let claudeJSON: [String: Any] = [
            "projects": [
                "/Users/test/project-a": [
                    "mcpServers": [
                        "shared-name": [
                            "command": commandA.path
                        ]
                    ]
                ],
                "/Users/test/project-b": [
                    "mcpServers": [
                        "shared-name": [
                            "command": commandB.path
                        ]
                    ]
                ],
                "/Users/test/project-c": [
                    "mcpServers": [
                        "dedup-me": [
                            "command": sharedCommand.path
                        ]
                    ]
                ],
                "/Users/test/project-d": [
                    "mcpServers": [
                        "dedup-me": [
                            "command": sharedCommand.path
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: home.appendingPathComponent(".claude.json"))

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)
        let projectCandidates = candidates.filter { $0.source == "claude_code" && $0.displayName == "shared-name" }

        #expect(projectCandidates.count == 2)
        #expect(Set(projectCandidates.map(\.id)).count == 2)
        #expect(projectCandidates.allSatisfy { $0.displayName == "shared-name" })
        #expect(Set(projectCandidates.map(\.command)) == Set([commandA.path, commandB.path]))

        let dedupCandidates = candidates.filter { $0.source == "claude_code" && $0.displayName == "dedup-me" }
        #expect(dedupCandidates.count == 1)
    }

    @Test func envFileSurfacesNonBridgeableCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "env-file-server": {
              "command": "npx",
              "envFile": ".env.local"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "env-file-server" })

        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "This server loads secrets from an env file; add the values in the source app before importing.")
    }

    @Test func typeNormalizationMapsStreamableHttpAndMissingURLReason() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "streamable-server": {
              "type": "streamableHttp",
              "url": "http://127.0.0.1:4444/mcp"
            },
            "missing-url-server": {
              "type": "http"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)

        let streamable = try #require(candidates.first { $0.displayName == "streamable-server" })
        #expect(streamable.transport == .http)
        #expect(streamable.url == "http://127.0.0.1:4444/mcp")
        #expect(streamable.bridgeable)

        let missingURL = try #require(candidates.first { $0.displayName == "missing-url-server" })
        #expect(missingURL.transport == .http)
        #expect(missingURL.bridgeable == false)
        #expect(missingURL.reason == "No server URL is configured.")
    }

    @Test func tomlForeignSectionKeysDoNotPolluteLastMCPServer() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let imessageScript = try Self.installMockStdioServer(
            in: home,
            name: "run-codex-search-only.sh",
            serverName: "imessage_search",
            toolName: "search_messages",
            toolTitle: "Search Messages"
        )

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.imessage_search]
        command = "\(imessageScript.path)"

        [plugins."build-ios-apps@openai-curated"]
        enabled = true
        secret_key = "must-not-appear"
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.id == "codex.imessage_search" })

        #expect(candidate.bridgeable)
        #expect(candidate.environment.isEmpty)
        #expect(!candidate.args.contains("must-not-appear"))
    }

    private static func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private static func installMockStdioServer(
        in home: URL,
        name: String,
        serverName: String = "mock-stdio",
        toolName: String = "echo",
        toolTitle: String = "Echo"
    ) throws -> URL {
        let serverURL = home.appendingPathComponent(name)
        try Data(mockNamedStdioMCPServer(
            serverName: serverName,
            toolName: toolName,
            toolTitle: toolTitle
        ).utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        return serverURL
    }

    private static let mockStdioMCPServer = """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "protocolVersion": "2025-06-18",
                    "serverInfo": {"name": "mock-stdio", "version": "1.0.0"},
                    "capabilities": {}
                }
            }), flush=True)
        elif method == "tools/list":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "tools": [{
                        "name": "echo",
                        "title": "Echo",
                        "description": "Echo a value.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"query": {"type": "string"}},
                            "required": ["query"]
                        },
                        "annotations": {"readOnlyHint": True}
                    }]
                }
            }), flush=True)
        elif method == "tools/call":
            params = message.get("params", {})
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "content": [{"type": "text", "text": "ok"}],
                    "structuredContent": {
                        "secret": os.environ.get("MOCK_SECRET"),
                        "arguments": params.get("arguments", {})
                    }
                }
            }, sort_keys=True), flush=True)
    """

    private static func mockNamedStdioMCPServer(serverName: String, toolName: String, toolTitle: String) -> String {
        """
        #!/usr/bin/env python3
        import json
        import sys

        SERVER_NAME = "\(serverName)"
        TOOL_NAME = "\(toolName)"
        TOOL_TITLE = "\(toolTitle)"

        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "initialize":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "protocolVersion": "2025-06-18",
                        "serverInfo": {"name": SERVER_NAME, "version": "1.0.0"},
                        "capabilities": {}
                    }
                }), flush=True)
            elif method == "tools/list":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "tools": [{
                            "name": TOOL_NAME,
                            "title": TOOL_TITLE,
                            "description": "Mock X MCP tool.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {}
                            },
                            "annotations": {"readOnlyHint": True}
                        }]
                    }
                }), flush=True)
            elif method == "tools/call":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "content": [{"type": "text", "text": "ok"}],
                        "structuredContent": {"server": SERVER_NAME}
                    }
                }, sort_keys=True), flush=True)
        """
    }
}

private struct LocalMCPScannerCapturedRequest: @unchecked Sendable {
    let method: String
    let headers: [String: String]
}

private struct LocalMCPScannerMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String], body: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(body.utf8)
    }
}

private final class LocalMCPScannerURLProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [LocalMCPScannerMockResponse] = []
    nonisolated(unsafe) private static var capturedRequests: [LocalMCPScannerCapturedRequest] = []

    static func install(_ newResponses: [LocalMCPScannerMockResponse]) {
        lock.lock()
        responses = newResponses
        capturedRequests = []
        lock.unlock()
    }

    static func requests() -> [LocalMCPScannerCapturedRequest] {
        lock.lock()
        let snapshot = capturedRequests
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let method = json["method"] as? String ?? ""

        Self.lock.lock()
        Self.capturedRequests.append(LocalMCPScannerCapturedRequest(method: method, headers: request.allHTTPHeaderFields ?? [:]))
        let response = Self.responses.isEmpty
            ? LocalMCPScannerMockResponse(statusCode: 500, headers: [:], body: #"{"error":"unexpected request"}"#)
            : Self.responses.removeFirst()
        Self.lock.unlock()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }
}
