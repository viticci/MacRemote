import Foundation
import Testing
@testable import MacRemote

struct ToolRegistryTests {
    @Test func toolEnvironmentPrefersUserAndHomebrewBinsBeforeSystemBins() throws {
        let directories = ExecutableLocator.searchDirectories
        let userBinIndex = try #require(directories.firstIndex(of: "\(ExecutableLocator.homeDirectory)/bin"))
        let homebrewIndex = try #require(directories.firstIndex(of: "/opt/homebrew/bin"))
        let systemIndex = try #require(directories.firstIndex(of: "/usr/bin"))

        #expect(userBinIndex < systemIndex)
        #expect(homebrewIndex < systemIndex)
        #expect(ExecutableLocator.toolEnvironment["PATH"] == directories.joined(separator: ":"))
    }

    @Test func draftInfersStringParametersFromArgumentPlaceholders() throws {
        var draft = ToolDefinitionDraft()
        draft.mode = .commandTemplate
        draft.name = "Echo"
        draft.summary = "Echo a value."
        draft.executablePath = "/bin/echo"
        draft.argumentsText = """
        fixed
        {value}
        """

        let tool = try draft.makeTool(id: "custom.echo")
        #expect(tool.argumentPattern == ["fixed", "{value}"])
        #expect(tool.parameters.map(\.name) == ["value"])
        #expect(try ToolArgumentResolver.arguments(for: tool, stringParameters: ["value": "hello"]) == ["fixed", "hello"])
    }

    @Test func draftDefaultsToGenericCLIAdapterArguments() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Generic echo adapter."
        draft.executablePath = "/bin/echo"

        let tool = try draft.makeTool(id: "custom.echo")
        #expect(tool.argumentPattern == ["{args}"])
        #expect(tool.parameters.first?.name == "args")
        #expect(tool.parameters.first?.kind == .stringArray)
        #expect(tool.parameters.map(\.name) == ["args", "stdin"])
        #expect(
            try ToolArgumentResolver.arguments(
                for: tool,
                parameters: ["args": .stringArray(["hello", "world"])]
            ) ==
            ["hello", "world"]
        )
        #expect(tool.permissionRequirements == [])
    }

    @Test func draftCanRequireMacOSPrivacyServicesWithoutFullDiskAccess() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Screenshot"
        draft.summary = "Capture the screen."
        draft.executablePath = "/usr/sbin/screencapture"
        draft.permissionRequirements = [.screenRecording, .automation]

        let tool = try draft.makeTool(id: "custom.screencapture")

        #expect(tool.permissionRequirements == [.screenRecording, .automation])
    }

    @Test func draftUsesPracticalMaximumLengthsForCommonPlaceholders() throws {
        let parameters = try ToolDefinitionDraft.inferredParameters(from: [
            "{prompt}",
            "{path}",
            "{query}",
            "{value}"
        ])
        func maximumLength(for name: String) -> Int? {
            parameters.first { $0.name == name }?.maximumLength
        }

        #expect(maximumLength(for: "prompt") == 4096)
        #expect(maximumLength(for: "path") == 1024)
        #expect(maximumLength(for: "query") == 512)
        #expect(maximumLength(for: "value") == 256)
    }

    @Test func draftCanRequireFullDiskAccess() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Generic echo adapter."
        draft.executablePath = "/bin/echo"
        draft.requiresFullDiskAccess = true

        let tool = try draft.makeTool(id: "custom.echo")

        #expect(tool.permissionRequirements == [.fullDiskAccess])
    }

    @Test func shellExecutablesAreBlocked() throws {
        let tool = ToolDefinition(
            id: "custom.shell",
            name: "Shell",
            summary: "Blocked.",
            executablePath: "/bin/sh",
            argumentPattern: ["-c", "echo nope"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )

        #expect(throws: ToolValidationError.blockedExecutable("/bin/sh")) { try ToolArgumentResolver.validate(tool) }
    }

    // R6/G1 — `dash` and `ksh` are in /etc/shells and must be Ring 0 like the rest.
    @Test(arguments: ["/bin/dash", "/bin/ksh", "/usr/local/bin/DASH"])
    func dashAndKshShellsAreBlocked(path: String) {
        let tool = makeShellShapedTool(executablePath: path)
        #expect(throws: ToolValidationError.blockedExecutable(path)) { try ToolArgumentResolver.validate(tool) }
    }

    // R6/G2 — an innocently named symlink resolving to a shell must not validate.
    @Test func symlinkToShellIsBlockedByResolvedBasename() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let link = temporaryDirectory.appendingPathComponent("notes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/zsh"))

        let tool = makeShellShapedTool(executablePath: link.path)
        #expect(throws: ToolValidationError.blockedExecutable(link.path)) { try ToolArgumentResolver.validate(tool) }
    }

    // R6 — the same Ring-0 check guards the stdio-bridge command path.
    @Test func stdioBridgeCommandSymlinkToShellIsBlocked() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let link = temporaryDirectory.appendingPathComponent("mcp-server")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/bash"))

        let tool = ToolDefinition(
            id: "custom.bridge",
            name: "Bridge",
            summary: "Blocked stdio bridge.",
            executablePath: "/",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                serverName: "Test",
                command: link.path,
                toolName: "tool"
            )
        )

        #expect(throws: ToolValidationError.blockedExecutable(link.path)) { try ToolArgumentResolver.validate(tool) }
    }

    @Test func storePersistsOnlyUserDefinedTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let custom = ToolDefinition(
            id: "custom.echo",
            name: "Echo",
            summary: "Echo a value.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )

        try store.saveUserDefinedTools(RemCTLToolCatalog.builtInTools + [custom])
        let loaded = try store.loadUserDefinedTools()
        #expect(loaded == [custom])
    }

    @Test func legacyToolDefinitionDecodesWithDefaultOriginAndCategory() throws {
        let data = """
        {
          "id": "custom.legacy",
          "name": "Legacy",
          "summary": "Old saved tool.",
          "executablePath": "/bin/echo",
          "argumentPattern": ["hello"],
          "parameters": [],
          "capability": "readOnly",
          "timeoutSeconds": 5,
          "outputByteLimit": 1024
        }
        """.data(using: .utf8)!

        let tool = try JSONDecoder().decode(ToolDefinition.self, from: data)
        #expect(tool.origin == .userDefined)
        #expect(tool.category == .utilities)
        #expect(tool.permissionRequirements == [])
        #expect(tool.backend == .process)
        #expect(tool.mcpBridge == nil)
    }

    @Test func mcpBridgeToolValidationDoesNotRequireExecutable() throws {
        let tool = ToolDefinition(
            id: "mcp.paste.search",
            name: "Paste Search",
            summary: "Search Paste through its local MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            permissionRequirements: [.localNetwork],
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "paste",
                serverURL: "http://127.0.0.1:39725/mcp",
                toolName: "search",
                toolTitle: "Search",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ])
                ]),
                annotations: .object(["readOnlyHint": .bool(true)])
            )
        )

        #expect(throws: Never.self) { try ToolArgumentResolver.validate(tool) }
        #expect(tool.preview == "http://127.0.0.1:39725/mcp → search")
        #expect(tool.isMCPBridge)
    }

    @Test func storePersistsMCPBridgeTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let tool = ToolDefinition(
            id: "mcp.local.search",
            name: "Local Search",
            summary: "Search a local MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "local",
                serverURL: "http://127.0.0.1:4999/mcp",
                toolName: "search",
                inputSchema: .object(["type": .string("object")]),
                headers: [
                    MCPBridgeHeader(
                        name: "Authorization",
                        valueSource: MCPBridgeHeaderValueSource(
                            kind: .environment,
                            environmentKey: "LOCAL_MCP_TOKEN",
                            prefix: "Bearer "
                        )
                    )
                ]
            )
        )

        try store.saveUserDefinedTools([tool])
        #expect(try store.loadUserDefinedTools() == [tool])
    }

    @Test func typedIntegerParameterRejectsInvalidValues() throws {
        let tool = ToolDefinition(
            id: "test.limit",
            name: "Limit Test",
            summary: "Bounded limit.",
            executablePath: "/bin/echo",
            argumentPattern: ["{limit}"],
            parameters: [
                ToolParameter(
                    name: "limit",
                    title: "Limit",
                    kind: .integer,
                    required: true,
                    integerRange: 1...100
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )

        #expect(throws: ToolValidationError.invalidInteger("limit")) {
            try ToolArgumentResolver.arguments(for: tool, stringParameters: ["limit": "banana"])
        }
        #expect(throws: ToolValidationError.integerOutOfRange("limit")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: ["limit": .json(.number(-1))])
        }
    }

    @Test func toolArgumentValuePreservesJSONNumbersForBridgeArguments() throws {
        let value = try #require(ToolArgumentValue.fromJSONObject([
            "count": 2,
            "nested": ["enabled": true]
        ]))
        let object = try #require(value.jsonValue.objectValue)

        #expect(object["count"] == .number(2))
        #expect(object["nested"] == .object(["enabled": .bool(true)]))
    }

    @Test func defaultPresetsCreateValidUserDefinedTools() throws {
        #expect(DefaultToolPresetCatalog.presets.isEmpty == false)

        for preset in DefaultToolPresetCatalog.presets {
            let tool = try preset.draft.makeTool(id: preset.id)
            #expect(tool.origin == .userDefined)
            #expect(tool.category == preset.category)
            #expect(tool.capability == preset.capability)
            #expect(tool.permissionRequirements == preset.permissionRequirements)
        }
    }

    @Test func presetSetsReferenceValidAvailablePresets() {
        let allPresetIDs = Set(DefaultToolPresetCatalog.presets.map(\.id))
        let allSystemSet = DefaultToolPresetCatalog.presetSets.first { $0.id == "set.all_system_presets" }

        #expect(Set(allSystemSet?.presetIDs ?? []) == allPresetIDs)
        #expect(DefaultToolPresetCatalog.presetSets.isEmpty == false)
        for presetSet in DefaultToolPresetCatalog.presetSets {
            #expect(presetSet.presets.isEmpty == false)
            #expect(presetSet.presetIDs.allSatisfy { allPresetIDs.contains($0) })
        }
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.pocketCTLExecutablePath != nil, "PocketCTL is not installed on this Mac."))
    func pocketCTLPresetsAreAvailableWhenExecutableIsInstalled() throws {
        let executablePath = try #require(DefaultToolPresetCatalog.pocketCTLExecutablePath)

        let presets = DefaultToolPresetCatalog.presets(in: .podcasts)
        let presetIDs = Set(presets.map(\.id))
        #expect(presets.isEmpty == false)
        #expect(presets.allSatisfy { $0.executablePath == executablePath })
        #expect(presetIDs.isSuperset(of: [
            "preset.pocketctl.doctor",
            "preset.pocketctl.triage",
            "preset.pocketctl.now",
            "preset.pocketctl.up_next",
            "preset.pocketctl.play_next",
            "preset.pocketctl.play_last",
            "preset.pocketctl.play_now",
            "preset.pocketctl.remove_up_next",
            "preset.pocketctl.in_progress",
            "preset.pocketctl.history",
            "preset.pocketctl.starred",
            "preset.pocketctl.new_releases",
            "preset.pocketctl.subscriptions",
            "preset.pocketctl.bookmarks",
            "preset.pocketctl.playlists",
            "preset.pocketctl.playlist",
            "preset.pocketctl.podcast",
            "preset.pocketctl.search_online",
            "preset.pocketctl.discover",
            "preset.pocketctl.recommendations",
            "preset.pocketctl.episode_url",
            "preset.pocketctl.transcript_source",
            "preset.pocketctl.stats",
            "preset.pocketctl.api_probe",
            "preset.pocketctl.show",
            "preset.pocketctl.run"
        ]))
        #expect(presets.contains { $0.id == "preset.pocketctl.play_next" && $0.capability == .write })
        #expect(presets.contains { $0.id == "preset.pocketctl.play_last" && $0.capability == .write })
        #expect(presets.contains { $0.id == "preset.pocketctl.play_now" && $0.capability == .write })
        #expect(presets.contains { $0.id == "preset.pocketctl.remove_up_next" && $0.capability == .destructive })
        #expect(presets.contains { $0.id == "preset.pocketctl.api_probe" && $0.capability == .readOnly })
        #expect(presets.contains { $0.id == "preset.pocketctl.run" && $0.mode == .cliAdapter && $0.capability == .destructive })
        #expect(DefaultToolPresetCatalog.categories.contains(.podcasts))
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.habitCTLExecutablePath != nil, "HabitCTL is not installed on this Mac."))
    func habitCTLPresetsAreAvailableWhenExecutableIsInstalled() throws {
        let executablePath = try #require(DefaultToolPresetCatalog.habitCTLExecutablePath)

        let presets = DefaultToolPresetCatalog.presets(in: .habits)
        let presetIDs = Set(presets.map(\.id))
        #expect(presets.isEmpty == false)
        #expect(presets.allSatisfy { $0.executablePath == executablePath })
        #expect(presetIDs.isSuperset(of: [
            "preset.habitctl.doctor",
            "preset.habitctl.today",
            "preset.habitctl.journal",
            "preset.habitctl.habits",
            "preset.habitctl.show",
            "preset.habitctl.search",
            "preset.habitctl.streaks",
            "preset.habitctl.stats",
            "preset.habitctl.areas",
            "preset.habitctl.run"
        ]))
        #expect(presets.contains { $0.id == "preset.habitctl.run" && $0.mode == .cliAdapter && $0.capability == .destructive })
        #expect(DefaultToolPresetCatalog.categories.contains(.habits))
        #expect(DefaultToolPresetCatalog.featuredPresets.contains { $0.id == "preset.habitctl.run" })
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.codexExecutablePath != nil, "Codex is not installed on this Mac."))
    func codexPresetIsAvailableWhenExecutableIsInstalled() throws {
        let executablePath = try #require(DefaultToolPresetCatalog.codexExecutablePath)

        // F20/DL-12: the Codex presets live in the AI & Agents category.
        let presets = DefaultToolPresetCatalog.presets(in: .ai)
        let readOnlyExec = try #require(presets.first { $0.id == "preset.developer.codex_read_only_exec" })
        #expect(readOnlyExec.executablePath == executablePath)
        #expect(readOnlyExec.mode == .commandTemplate)
        let approvalFlagIndex = try #require(readOnlyExec.argumentPattern.firstIndex(of: "--ask-for-approval"))
        let execIndex = try #require(readOnlyExec.argumentPattern.firstIndex(of: "exec"))
        #expect(approvalFlagIndex < execIndex)
        // F1: the summary must not claim the tool itself is read-only —
        // capability stays `.destructive` and the copy explains why.
        #expect(readOnlyExec.capability == .destructive)
        #expect(readOnlyExec.summary.contains("read-only mode") == false)
        #expect(readOnlyExec.summary.contains("host approval"))

        #expect(presets.contains { preset in
            preset.id == "preset.developer.codex" &&
                preset.executablePath == executablePath &&
                preset.mode == .cliAdapter &&
                preset.capability == .destructive
        })
        #expect(DefaultToolPresetCatalog.preferredCategory == .ai)
        #expect(DefaultToolPresetCatalog.featuredPresets.contains { $0.id == "preset.developer.codex" })
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "claude") != nil, "Claude Code is not installed on this Mac."))
    func claudeCodePresetUsesClaudeCLIWhenInstalled() throws {
        let executablePath = try #require(ExecutableLocator.executablePath(named: "claude"))

        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.claude.run"))
        #expect(preset.name == "Claude Code")
        #expect(preset.executablePath == executablePath)
        #expect(preset.mode == .cliAdapter)
        #expect(preset.capability == .destructive)
        #expect(preset.timeoutSeconds == 60)
        #expect(preset.outputLimitKB == 5120)
        #expect(preset.summary.contains("--print"))
        #expect(preset.summary.contains("--output-format"))
        #expect(DefaultToolPresetCatalog.preset(id: "preset.claude_session.run") == nil)
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.remCTLExecutablePath != nil, "RemCTL is not installed on this Mac."))
    func remCTLPresetsAreAvailableWhenExecutableIsInstalled() throws {
        let executablePath = try #require(DefaultToolPresetCatalog.remCTLExecutablePath)

        let presets = DefaultToolPresetCatalog.presets(in: .reminders)
        #expect(presets.count == RemCTLToolCatalog.builtInTools.count)
        #expect(presets.allSatisfy { $0.executablePath == executablePath })
        #expect(presets.allSatisfy { $0.requiresFullDiskAccess })
        #expect(presets.allSatisfy { $0.permissionRequirements.contains(.reminders) })
        #expect(presets.contains { $0.id == "preset.remctl.run" && $0.mode == .cliAdapter && $0.capability == .destructive })
        #expect(DefaultToolPresetCatalog.categories.contains(.reminders))
        #expect(DefaultToolPresetCatalog.featuredPresets.contains { $0.id == "preset.remctl.run" })
    }

    @Test func detectedPopularCLIsAppearAsPresetsWhenInstalled() {
        let expected: [(String, String)] = [
            ("peekaboo", "preset.peekaboo.run"),
            ("spogo", "preset.spogo.run"),
            ("summarize", "preset.summarize.run"),
            ("gog", "preset.gog.run"),
            ("llm", "preset.llm.run"),
            ("gh", "preset.gh.run"),
            ("jq", "preset.jq.run"),
            ("rg", "preset.rg.run"),
            ("yt-dlp", "preset.ytdlp.run"),
            ("ffmpeg", "preset.ffmpeg.run"),
            ("cloudflared", "preset.cloudflared.run"),
            ("tailscale", "preset.tailscale.run"),
            ("uv", "preset.uv.run"),
            ("uvx", "preset.uvx.run"),
            ("deno", "preset.deno.run"),
            ("supabase", "preset.supabase.run"),
            ("xcodegen", "preset.xcodegen.run"),
            ("grok-session", "preset.grok_session.run"),
            ("monologue", "preset.monologue.run"),
            ("spark", "preset.spark.run"),
            ("frames", "preset.frames.run"),
            ("habitctl", "preset.habitctl.run"),
            ("readwise", "preset.readwise.run"),
            ("ollama", "preset.ollama.run"),
            ("whisper-cli", "preset.whisper.run"),
            ("pdftotext", "preset.pdftotext.extract"),
            ("pdfinfo", "preset.pdfinfo.info"),
            ("tesseract", "preset.tesseract.ocr"),
            ("trasher", "preset.trasher.trash")
        ]

        for (executable, presetID) in expected where ExecutableLocator.executablePath(named: executable) != nil {
            #expect(DefaultToolPresetCatalog.preset(id: presetID) != nil, "\(executable) should expose \(presetID)")
        }
    }

    @Test func detectedSystemCLIsAppearAsGenericAdaptersWhenInstalled() {
        let expected: [(String, String)] = [
            ("claude", "preset.claude.run"),
            ("grok", "preset.grok.run"),
            ("swift", "preset.swift.run"),
            ("xcodebuild", "preset.xcodebuild.run"),
            ("node", "preset.node.run"),
            ("npm", "preset.npm.run"),
            ("pnpm", "preset.pnpm.run"),
            ("python3", "preset.python3.run"),
            ("ruby", "preset.ruby.run"),
            ("perl", "preset.perl.run"),
            ("curl", "preset.curl.run"),
            ("rsync", "preset.rsync.run"),
            ("sqlite3", "preset.sqlite3.run"),
            ("shortcuts", "preset.shortcuts.run"),
            ("osascript", "preset.osascript.run"),
            ("automator", "preset.automator.run"),
            ("screencapture", "preset.screencapture.run"),
            ("mdfind", "preset.mdfind.run"),
            ("mdls", "preset.mdls.run"),
            ("qlmanage", "preset.qlmanage.run"),
            ("textutil", "preset.textutil.run"),
            ("openclaw", "preset.openclaw.run"),
            ("lms", "preset.lms.run"),
            ("git", "preset.git.run"),
            ("docker", "preset.docker.run"),
            ("ipsw", "preset.ipsw.run"),
            ("vercel", "preset.vercel.run"),
            ("wrangler", "preset.wrangler.run"),
            ("go", "preset.go.run"),
            ("cargo", "preset.cargo.run"),
            ("defuddle", "preset.defuddle.run"),
            ("ntn", "preset.ntn.run"),
            ("obsidian", "preset.obsidian.run"),
            ("pandoc", "preset.pandoc.run"),
            ("magick", "preset.magick.run"),
            ("exiftool", "preset.exiftool.run")
        ]

        for (executable, presetID) in expected where ExecutableLocator.executablePath(named: executable) != nil {
            let preset = DefaultToolPresetCatalog.preset(id: presetID)
            #expect(preset != nil, "\(executable) should expose \(presetID)")
            #expect(preset?.mode == .cliAdapter)
        }
    }

    @Test func detectedPrivacySensitiveCLIPresetsDeclareMacOSPermissions() throws {
        if ExecutableLocator.executablePath(named: "remctl") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.remctl.run"))
            #expect(preset.permissionRequirements == [.fullDiskAccess, .reminders])
        }
        if ExecutableLocator.executablePath(named: "peekaboo") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.peekaboo.run"))
            #expect(preset.permissionRequirements == [.screenRecording, .accessibility])
        }
        if ExecutableLocator.executablePath(named: "osascript") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.osascript.run"))
            #expect(preset.permissionRequirements == [.accessibility, .automation])
        }
        if ExecutableLocator.executablePath(named: "screencapture") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.screencapture.run"))
            #expect(preset.permissionRequirements == [.screenRecording])
        }
    }

    @Test func buildScriptIncludesCommonMacOSPrivacyUsageDescriptions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = projectRoot.appendingPathComponent("script/build_and_run.sh")
        let contents = try String(contentsOf: buildScript, encoding: .utf8)
        let expectedKeys = [
            "NSAppleEventsUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSContactsUsageDescription",
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSRemindersUsageDescription",
            "NSScreenCaptureUsageDescription",
            "NSSpeechRecognitionUsageDescription"
        ]

        for key in expectedKeys {
            #expect(contents.contains("<key>\(key)</key>"), "\(key) should be included in generated Info.plist")
        }
    }

    @MainActor
    @Test func appModelCanBulkAddPresetSetAndSkipExistingToolSignatures() throws {
        let suiteName = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = AppModel(userDefaults: defaults, toolStore: store)
        let preset = DefaultToolPreset(
            id: "preset.test.echo",
            name: "Echo Once",
            summary: "Echo a fixed value.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )

        #expect(model.addUserTools(from: [preset], sourceName: "Test Set") == nil)
        #expect(model.tools.count == 1)
        #expect(model.tools.first?.name == "Echo Once")

        #expect(model.addUserTools(from: [preset], sourceName: "Test Set") != nil)
        #expect(model.tools.count == 1)
    }

    @Test func filesystemPresetsAvoidDestructiveCommands() {
        let destructiveBasenames: Set<String> = ["rm", "rmdir", "unlink", "trash"]
        let filesystemPresets = DefaultToolPresetCatalog.presets(in: .filesystem)

        #expect(filesystemPresets.isEmpty == false)
        for preset in filesystemPresets {
            #expect(destructiveBasenames.contains(URL(fileURLWithPath: preset.executablePath).lastPathComponent) == false)
            if preset.mode == .commandTemplate {
                // Move To Trash is the one deliberate `.write` template
                // (spec §6.1 #13 — it recoverably relocates, never deletes).
                let expected: ToolCapability = preset.id == "preset.trasher.trash" ? .write : .readOnly
                #expect(preset.capability == expected)
            } else {
                #expect(preset.mode == .cliAdapter)
                #expect(preset.argumentPattern == ["{args}"])
            }
            #expect((preset.argumentPattern.contains { argument in
                argument.localizedCaseInsensitiveContains("delete")
                    || argument.localizedCaseInsensitiveContains("remove")
            }) == false)
        }
    }

    // DL-13 + owner decision: the deprecated Matter preset is gone and the
    // unverifiable Cora preset never ships, regardless of what is installed.
    @Test func retiredPresetsNeverAppear() {
        #expect(DefaultToolPresetCatalog.preset(id: "preset.matter.run") == nil)
        #expect(DefaultToolPresetCatalog.preset(id: "preset.cora.run") == nil)
        #expect(DefaultToolPresetCatalog.preset(id: "preset.filesystem.file_info") == nil)
        #expect(DefaultToolPresetCatalog.preset(id: "preset.filesystem.read_head") == nil)
    }

    // DL-14: URL-fetching templates must not be read-only — read-only skips the
    // per-call approval that is the only exfiltration gate.
    @Test func networkFetchingTemplatesRequireApproval() throws {
        if ExecutableLocator.executablePath(named: "summarize") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.summarize.input"))
            #expect(preset.capability == .write)
        }
        if ExecutableLocator.executablePath(named: "yt-dlp") != nil {
            let metadata = try #require(DefaultToolPresetCatalog.preset(id: "preset.ytdlp.metadata"))
            #expect(metadata.capability == .write)
            #expect(metadata.name == "yt-dlp Metadata")
            #expect(metadata.category == .imageProcessing)
            let adapter = try #require(DefaultToolPresetCatalog.preset(id: "preset.ytdlp.run"))
            #expect(adapter.name == "yt-dlp CLI")
            #expect(adapter.category == .imageProcessing)
        }
    }

    // F20/DL-12: the AI cluster presets carry the `.ai` category.
    @Test func aiClusterPresetsUseAICategory() {
        let aiExecutables = ["claude", "codex", "grok", "llm", "ollama", "lms", "whisper-cli"]
        let aiPresetPrefixes = [
            "preset.claude.", "preset.developer.codex", "preset.grok.",
            "preset.llm.", "preset.ollama.", "preset.lms.", "preset.whisper."
        ]

        let aiPresets = DefaultToolPresetCatalog.presets.filter { preset in
            aiPresetPrefixes.contains { preset.id.hasPrefix($0) }
        }
        for preset in aiPresets {
            #expect(preset.category == .ai, "\(preset.id) should be in AI & Agents")
        }

        if aiExecutables.contains(where: { ExecutableLocator.executablePath(named: $0) != nil }) {
            #expect(aiPresets.isEmpty == false)
            #expect(DefaultToolPresetCatalog.categories.contains(.ai))
            #expect(DefaultToolPresetCatalog.presetSets.contains { $0.id == "set.ai" })
        }
    }

    // §6.4 written policy: no preset may wrap a Ring-1 executable (secrets
    // managers, shells, privilege tools, package managers). The scanner and
    // the catalog share `CLIRecommendationBlocklist` as the denylist source.
    @Test func noPresetWrapsRingOneExecutable() {
        for preset in DefaultToolPresetCatalog.presets {
            let basename = URL(fileURLWithPath: preset.executablePath).lastPathComponent
            #expect(
                CLIRecommendationBlocklist.matches(
                    basename,
                    in: CLIRecommendationBlocklist.neverSuggestNames,
                    prefixes: CLIRecommendationBlocklist.neverSuggestPrefixes
                ) == false,
                "\(preset.id) wraps Ring-1 executable \(basename)"
            )
        }
    }

    // §6.3 — the scanner's preset fold pass resolves candidates back to presets.
    @Test func presetLookupsMatchExecutablePathAndBasename() throws {
        let preset = try #require(DefaultToolPresetCatalog.presets.first)

        let byPath = try #require(DefaultToolPresetCatalog.preset(matchingExecutablePath: preset.executablePath))
        #expect(byPath.executablePath == preset.executablePath)

        let basename = URL(fileURLWithPath: preset.executablePath).lastPathComponent
        let byBasename = try #require(DefaultToolPresetCatalog.preset(matchingBasename: basename.uppercased()))
        #expect(
            URL(fileURLWithPath: byBasename.executablePath).lastPathComponent
                .caseInsensitiveCompare(basename) == .orderedSame
        )

        #expect(DefaultToolPresetCatalog.preset(matchingExecutablePath: "/nonexistent/tool") == nil)
        #expect(DefaultToolPresetCatalog.preset(matchingBasename: "definitely-not-a-preset") == nil)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "readwise") != nil, "Readwise CLI is not installed on this Mac."))
    func readwisePresetsReplaceMatter() throws {
        let inbox = try #require(DefaultToolPresetCatalog.preset(id: "preset.readwise.inbox"))
        #expect(inbox.argumentPattern == ["reader-list-documents", "--location", "new", "--json"])
        #expect(inbox.capability == .readOnly)
        #expect(inbox.category == .text)
        #expect(inbox.timeoutSeconds == 20)
        #expect(inbox.outputLimitKB == 1024)

        let adapter = try #require(DefaultToolPresetCatalog.preset(id: "preset.readwise.run"))
        #expect(adapter.mode == .cliAdapter)
        #expect(adapter.capability == .destructive)
        #expect(adapter.category == .text)
        #expect(adapter.timeoutSeconds == 45)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "whisper-cli") != nil, "whisper.cpp is not installed on this Mac."))
    func whisperPresetsTranscribeLocally() throws {
        let transcribe = try #require(DefaultToolPresetCatalog.preset(id: "preset.whisper.transcribe"))
        #expect(transcribe.argumentPattern == ["-m", "{model}", "-f", "{audio}", "--no-prints"])
        #expect(transcribe.capability == .readOnly)
        #expect(transcribe.category == .ai)
        #expect(transcribe.timeoutSeconds == 60)
        #expect(transcribe.outputLimitKB == 2048)

        let adapter = try #require(DefaultToolPresetCatalog.preset(id: "preset.whisper.run"))
        #expect(adapter.mode == .cliAdapter)
        #expect(adapter.category == .ai)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "trasher") != nil, "trasher is not installed on this Mac."))
    func moveToTrashPresetIsRecoverableWrite() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.trasher.trash"))
        #expect(preset.name == "Move To Trash")
        #expect(preset.argumentPattern == ["{path}"])
        #expect(preset.capability == .write)
        #expect(preset.category == .filesystem)
        #expect(preset.timeoutSeconds == 10)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "pdftotext") != nil, "Poppler is not installed on this Mac."))
    func pdfReadPresetsAreReadOnlyTemplates() throws {
        let extract = try #require(DefaultToolPresetCatalog.preset(id: "preset.pdftotext.extract"))
        #expect(extract.argumentPattern == ["{path}", "-"])
        #expect(extract.capability == .readOnly)
        #expect(extract.category == .text)

        if ExecutableLocator.executablePath(named: "pdfinfo") != nil {
            let info = try #require(DefaultToolPresetCatalog.preset(id: "preset.pdfinfo.info"))
            #expect(info.argumentPattern == ["{path}"])
            #expect(info.capability == .readOnly)
        }
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "tesseract") != nil, "Tesseract is not installed on this Mac."))
    func ocrPresetIsReadOnlyMediaTemplate() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.tesseract.ocr"))
        #expect(preset.argumentPattern == ["{image}", "stdout"])
        #expect(preset.capability == .readOnly)
        #expect(preset.category == .imageProcessing)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "openclaw") != nil, "OpenClaw is not installed on this Mac."))
    func steipeteSetIncludesOpenClaw() throws {
        let set = try #require(DefaultToolPresetCatalog.presetSets.first { $0.id == "set.steipete_openclaw" })
        #expect(set.presetIDs.contains("preset.openclaw.run"))
    }

    // F2: the curl summary must not understate approval or reach.
    @Test(.enabled(if: ExecutableLocator.executablePath(named: "curl") != nil, "curl is not installed on this Mac."))
    func curlSummaryStatesApprovalAndReach() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.curl.run"))
        #expect(preset.capability == .destructive)
        #expect(preset.summary.contains("Every call requires host approval"))
        #expect(preset.summary.contains("any host"))
        #expect(preset.permissionRequirements == [.localNetwork])
    }

    @Test func clientToolPermissionStoreUsesStableTrustIDAcrossClientIDChurn() throws {
        let suiteName = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClientToolPermissionStore(userDefaults: defaults)

        _ = store.setAllowed(
            true,
            clientID: "macremote-client-old",
            clientTrustID: "macremote-trust-codex",
            toolID: "preset.remctl.run"
        )

        #expect(store.isAllowed(
            clientID: "macremote-client-new",
            clientTrustID: "macremote-trust-codex",
            toolID: "preset.remctl.run"
        ))
        #expect(store.isAllowed(
            clientID: "macremote-client-new",
            clientTrustID: "macremote-trust-other",
            toolID: "preset.remctl.run"
        ) == false)
    }
}

private func makeShellShapedTool(executablePath: String) -> ToolDefinition {
    ToolDefinition(
        id: "custom.shell-shaped",
        name: "Shell Shaped",
        summary: "Blocked.",
        executablePath: executablePath,
        argumentPattern: [],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined
    )
}
