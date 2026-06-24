import Foundation
import XCTest
@testable import MacRemote

final class ToolRegistryTests: XCTestCase {
    func testToolEnvironmentPrefersUserAndHomebrewBinsBeforeSystemBins() throws {
        let directories = ExecutableLocator.searchDirectories
        let userBinIndex = try XCTUnwrap(directories.firstIndex(of: "\(ExecutableLocator.homeDirectory)/bin"))
        let homebrewIndex = try XCTUnwrap(directories.firstIndex(of: "/opt/homebrew/bin"))
        let systemIndex = try XCTUnwrap(directories.firstIndex(of: "/usr/bin"))

        XCTAssertLessThan(userBinIndex, systemIndex)
        XCTAssertLessThan(homebrewIndex, systemIndex)
        XCTAssertEqual(ExecutableLocator.toolEnvironment["PATH"], directories.joined(separator: ":"))
    }

    func testDraftInfersStringParametersFromArgumentPlaceholders() throws {
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
        XCTAssertEqual(tool.argumentPattern, ["fixed", "{value}"])
        XCTAssertEqual(tool.parameters.map(\.name), ["value"])
        XCTAssertEqual(try ToolArgumentResolver.arguments(for: tool, stringParameters: ["value": "hello"]), ["fixed", "hello"])
    }

    func testDraftDefaultsToGenericCLIAdapterArguments() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Generic echo adapter."
        draft.executablePath = "/bin/echo"

        let tool = try draft.makeTool(id: "custom.echo")
        XCTAssertEqual(tool.argumentPattern, ["{args}"])
        XCTAssertEqual(tool.parameters.first?.name, "args")
        XCTAssertEqual(tool.parameters.first?.kind, .stringArray)
        XCTAssertEqual(tool.parameters.map(\.name), ["args", "stdin"])
        XCTAssertEqual(
            try ToolArgumentResolver.arguments(
                for: tool,
                parameters: ["args": .stringArray(["hello", "world"])]
            ),
            ["hello", "world"]
        )
        XCTAssertEqual(tool.permissionRequirements, [])
    }

    func testDraftCanRequireMacOSPrivacyServicesWithoutFullDiskAccess() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Screenshot"
        draft.summary = "Capture the screen."
        draft.executablePath = "/usr/sbin/screencapture"
        draft.permissionRequirements = [.screenRecording, .automation]

        let tool = try draft.makeTool(id: "custom.screencapture")

        XCTAssertEqual(tool.permissionRequirements, [.screenRecording, .automation])
    }

    func testDraftUsesPracticalMaximumLengthsForCommonPlaceholders() throws {
        let parameters = try ToolDefinitionDraft.inferredParameters(from: [
            "{prompt}",
            "{path}",
            "{query}",
            "{value}"
        ])
        func maximumLength(for name: String) -> Int? {
            parameters.first { $0.name == name }?.maximumLength
        }

        XCTAssertEqual(maximumLength(for: "prompt"), 4096)
        XCTAssertEqual(maximumLength(for: "path"), 1024)
        XCTAssertEqual(maximumLength(for: "query"), 512)
        XCTAssertEqual(maximumLength(for: "value"), 256)
    }

    func testDraftCanRequireFullDiskAccess() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Generic echo adapter."
        draft.executablePath = "/bin/echo"
        draft.requiresFullDiskAccess = true

        let tool = try draft.makeTool(id: "custom.echo")

        XCTAssertEqual(tool.permissionRequirements, [.fullDiskAccess])
    }

    func testShellExecutablesAreBlocked() throws {
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

        XCTAssertThrowsError(try ToolArgumentResolver.validate(tool)) { error in
            XCTAssertEqual(error as? ToolValidationError, .blockedExecutable("/bin/sh"))
        }
    }

    func testStorePersistsOnlyUserDefinedTools() throws {
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
        XCTAssertEqual(loaded, [custom])
    }

    func testLegacyToolDefinitionDecodesWithDefaultOriginAndCategory() throws {
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
        XCTAssertEqual(tool.origin, .userDefined)
        XCTAssertEqual(tool.category, .utilities)
        XCTAssertEqual(tool.permissionRequirements, [])
    }

    func testDefaultPresetsCreateValidUserDefinedTools() throws {
        XCTAssertFalse(DefaultToolPresetCatalog.presets.isEmpty)

        for preset in DefaultToolPresetCatalog.presets {
            let tool = try preset.draft.makeTool(id: preset.id)
            XCTAssertEqual(tool.origin, .userDefined)
            XCTAssertEqual(tool.category, preset.category)
            XCTAssertEqual(tool.capability, preset.capability)
            XCTAssertEqual(tool.permissionRequirements, preset.permissionRequirements)
        }
    }

    func testPresetSetsReferenceValidAvailablePresets() {
        let allPresetIDs = Set(DefaultToolPresetCatalog.presets.map(\.id))
        let allSystemSet = DefaultToolPresetCatalog.presetSets.first { $0.id == "set.all_system_presets" }

        XCTAssertEqual(Set(allSystemSet?.presetIDs ?? []), allPresetIDs)
        XCTAssertFalse(DefaultToolPresetCatalog.presetSets.isEmpty)
        for presetSet in DefaultToolPresetCatalog.presetSets {
            XCTAssertFalse(presetSet.presets.isEmpty)
            XCTAssertTrue(presetSet.presetIDs.allSatisfy { allPresetIDs.contains($0) })
        }
    }

    func testPocketCTLPresetsAreAvailableWhenExecutableIsInstalled() throws {
        guard let executablePath = DefaultToolPresetCatalog.pocketCTLExecutablePath else {
            throw XCTSkip("PocketCTL is not installed on this Mac.")
        }

        let presets = DefaultToolPresetCatalog.presets(in: .podcasts)
        XCTAssertFalse(presets.isEmpty)
        XCTAssertTrue(presets.allSatisfy { $0.executablePath == executablePath })
        XCTAssertTrue(presets.contains { $0.id == "preset.pocketctl.run" && $0.mode == .cliAdapter && $0.capability == .destructive })
        XCTAssertTrue(DefaultToolPresetCatalog.categories.contains(.podcasts))
    }

    func testCodexPresetIsAvailableWhenExecutableIsInstalled() throws {
        guard let executablePath = DefaultToolPresetCatalog.codexExecutablePath else {
            throw XCTSkip("Codex is not installed on this Mac.")
        }

        let presets = DefaultToolPresetCatalog.presets(in: .developer)
        let readOnlyExec = try XCTUnwrap(presets.first { $0.id == "preset.developer.codex_read_only_exec" })
        XCTAssertEqual(readOnlyExec.executablePath, executablePath)
        XCTAssertEqual(readOnlyExec.mode, .commandTemplate)
        XCTAssertLessThan(
            try XCTUnwrap(readOnlyExec.argumentPattern.firstIndex(of: "--ask-for-approval")),
            try XCTUnwrap(readOnlyExec.argumentPattern.firstIndex(of: "exec"))
        )

        XCTAssertTrue(presets.contains { preset in
            preset.id == "preset.developer.codex" &&
                preset.executablePath == executablePath &&
                preset.mode == .cliAdapter &&
                preset.capability == .destructive
        })
        XCTAssertEqual(DefaultToolPresetCatalog.preferredCategory, .developer)
        XCTAssertTrue(DefaultToolPresetCatalog.featuredPresets.contains { $0.id == "preset.developer.codex" })
    }

    func testRemCTLPresetsAreAvailableWhenExecutableIsInstalled() throws {
        guard let executablePath = DefaultToolPresetCatalog.remCTLExecutablePath else {
            throw XCTSkip("RemCTL is not installed on this Mac.")
        }

        let presets = DefaultToolPresetCatalog.presets(in: .reminders)
        XCTAssertEqual(presets.count, RemCTLToolCatalog.builtInTools.count)
        XCTAssertTrue(presets.allSatisfy { $0.executablePath == executablePath })
        XCTAssertTrue(presets.allSatisfy(\.requiresFullDiskAccess))
        XCTAssertTrue(presets.allSatisfy { $0.permissionRequirements.contains(.reminders) })
        XCTAssertTrue(presets.contains { $0.id == "preset.remctl.run" && $0.mode == .cliAdapter && $0.capability == .destructive })
        XCTAssertTrue(DefaultToolPresetCatalog.categories.contains(.reminders))
        XCTAssertTrue(DefaultToolPresetCatalog.featuredPresets.contains { $0.id == "preset.remctl.run" })
    }

    func testDetectedPopularCLIsAppearAsPresetsWhenInstalled() {
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
            ("claude-session", "preset.claude_session.run"),
            ("grok-session", "preset.grok_session.run"),
            ("cora", "preset.cora.run"),
            ("monologue", "preset.monologue.run"),
            ("matter", "preset.matter.run"),
            ("spark", "preset.spark.run"),
            ("frames", "preset.frames.run")
        ]

        for (executable, presetID) in expected where ExecutableLocator.executablePath(named: executable) != nil {
            XCTAssertNotNil(DefaultToolPresetCatalog.preset(id: presetID), "\(executable) should expose \(presetID)")
        }
    }

    func testDetectedSystemCLIsAppearAsGenericAdaptersWhenInstalled() {
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
            ("textutil", "preset.textutil.run")
        ]

        for (executable, presetID) in expected where ExecutableLocator.executablePath(named: executable) != nil {
            let preset = DefaultToolPresetCatalog.preset(id: presetID)
            XCTAssertNotNil(preset, "\(executable) should expose \(presetID)")
            XCTAssertEqual(preset?.mode, .cliAdapter)
        }
    }

    func testDetectedPrivacySensitiveCLIPresetsDeclareMacOSPermissions() throws {
        if ExecutableLocator.executablePath(named: "remctl") != nil {
            let preset = try XCTUnwrap(DefaultToolPresetCatalog.preset(id: "preset.remctl.run"))
            XCTAssertEqual(preset.permissionRequirements, [.fullDiskAccess, .reminders])
        }
        if ExecutableLocator.executablePath(named: "peekaboo") != nil {
            let preset = try XCTUnwrap(DefaultToolPresetCatalog.preset(id: "preset.peekaboo.run"))
            XCTAssertEqual(preset.permissionRequirements, [.screenRecording, .accessibility])
        }
        if ExecutableLocator.executablePath(named: "osascript") != nil {
            let preset = try XCTUnwrap(DefaultToolPresetCatalog.preset(id: "preset.osascript.run"))
            XCTAssertEqual(preset.permissionRequirements, [.accessibility, .automation])
        }
        if ExecutableLocator.executablePath(named: "screencapture") != nil {
            let preset = try XCTUnwrap(DefaultToolPresetCatalog.preset(id: "preset.screencapture.run"))
            XCTAssertEqual(preset.permissionRequirements, [.screenRecording])
        }
    }

    func testBuildScriptIncludesCommonMacOSPrivacyUsageDescriptions() throws {
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
            XCTAssertTrue(contents.contains("<key>\(key)</key>"), "\(key) should be included in generated Info.plist")
        }
    }

    @MainActor
    func testAppModelCanBulkAddPresetSetAndSkipExistingToolSignatures() throws {
        let suiteName = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
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

        XCTAssertNil(model.addUserTools(from: [preset], sourceName: "Test Set"))
        XCTAssertEqual(model.tools.count, 1)
        XCTAssertEqual(model.tools.first?.name, "Echo Once")

        XCTAssertNotNil(model.addUserTools(from: [preset], sourceName: "Test Set"))
        XCTAssertEqual(model.tools.count, 1)
    }

    func testFilesystemPresetsAvoidDestructiveCommands() {
        let destructiveBasenames: Set<String> = ["rm", "rmdir", "unlink", "trash"]
        let filesystemPresets = DefaultToolPresetCatalog.presets(in: .filesystem)

        XCTAssertFalse(filesystemPresets.isEmpty)
        for preset in filesystemPresets {
            XCTAssertFalse(destructiveBasenames.contains(URL(fileURLWithPath: preset.executablePath).lastPathComponent))
            if preset.mode == .commandTemplate {
                XCTAssertEqual(preset.capability, .readOnly)
            } else {
                XCTAssertEqual(preset.mode, .cliAdapter)
                XCTAssertEqual(preset.argumentPattern, ["{args}"])
            }
            XCTAssertFalse(preset.argumentPattern.contains { argument in
                argument.localizedCaseInsensitiveContains("delete")
                    || argument.localizedCaseInsensitiveContains("remove")
            })
        }
    }
}
