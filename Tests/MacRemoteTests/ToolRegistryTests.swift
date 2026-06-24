import Foundation
import XCTest
@testable import MacRemote

final class ToolRegistryTests: XCTestCase {
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
            XCTAssertEqual(tool.permissionRequirements, preset.requiresFullDiskAccess ? [.fullDiskAccess] : [])
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

    func testFilesystemPresetsAvoidDestructiveCommands() {
        let destructiveBasenames: Set<String> = ["rm", "rmdir", "unlink", "trash"]
        let filesystemPresets = DefaultToolPresetCatalog.presets(in: .filesystem)

        XCTAssertFalse(filesystemPresets.isEmpty)
        for preset in filesystemPresets {
            XCTAssertEqual(preset.capability, .readOnly)
            XCTAssertFalse(destructiveBasenames.contains(URL(fileURLWithPath: preset.executablePath).lastPathComponent))
            XCTAssertFalse(preset.argumentPattern.contains { argument in
                argument.localizedCaseInsensitiveContains("delete")
                    || argument.localizedCaseInsensitiveContains("remove")
            })
        }
    }
}
