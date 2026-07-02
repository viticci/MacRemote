import Foundation
import Testing
@testable import MacRemote

struct RemCTLToolCatalogTests {
    @Test func todayArgumentsUseGlobalJSONFormat() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.today")
        #expect(arguments == ["--format", "json", "today"])
    }

    @Test func upcomingDefaultsToSevenDays() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.upcoming")
        #expect(arguments == ["--format", "json", "upcoming", "7"])
    }

    @Test func defaultProfileUsesDirectFullFidelityReadCommands() {
        #expect(RemCTLToolCatalog.readOnlyTools.count == 20)
        #expect((RemCTLToolCatalog.readOnlyTools.contains { $0.argumentPattern.contains("--via-eventkit") }) == false)
    }

    @Test func builtInProfileIncludesFullRemCTLCLIAdapter() throws {
        #expect(RemCTLToolCatalog.builtInTools.count == 21)

        let tool = try #require(RemCTLToolCatalog.tool(id: "remctl.run"))
        #expect(tool.executablePath == RemCTLToolCatalog.executablePath)
        #expect(tool.argumentPattern == ["{args}"])
        #expect(tool.parameters.map(\.name) == ["args", "stdin"])
        #expect(tool.capability == .destructive)
        #expect(tool.isGenericCLIAdapter)
        #expect(tool.permissionRequirements == [.fullDiskAccess, .reminders])
    }

    @Test func allBuiltInRemCTLToolsRequireFullDiskAccess() {
        #expect(RemCTLToolCatalog.builtInTools.isEmpty == false)
        #expect(RemCTLToolCatalog.builtInTools.allSatisfy { tool in
            tool.permissionRequirements == [.fullDiskAccess, .reminders]
        })
    }

    @Test func toolExposureSummaryForDefaultRemCTLProfile() {
        let summary = ToolExposureSummary(tools: RemCTLToolCatalog.builtInTools)

        #expect(summary.total == 21)
        #expect(summary.readOnly == 20)
        #expect(summary.write == 0)
        #expect(summary.destructive == 1)
        #expect(summary.gatedToolCount == 1)
        #expect(summary.builtIn == 21)
        #expect(summary.custom == 0)
        #expect(summary.genericAdapters == 1)
        #expect(summary.nonReadOnlyToolNames == ["Run RemCTL"])
        #expect(summary.customDescription == "No custom tools")
        #expect(summary.capabilityDescription == "20 read-only, 1 host-gated")
    }

    @Test func toolExposureSummaryCountsCustomTools() {
        let customTool = ToolDefinition(
            id: "custom.echo",
            name: "Custom Echo",
            summary: "Echo a value.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [],
            capability: .write,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            category: .utilities
        )

        let summary = ToolExposureSummary(tools: RemCTLToolCatalog.builtInTools + [customTool])

        #expect(summary.total == 22)
        #expect(summary.write == 1)
        #expect(summary.destructive == 1)
        #expect(summary.gatedToolCount == 2)
        #expect(summary.custom == 1)
        #expect(summary.genericAdapters == 2)
        #expect(summary.nonReadOnlyToolNames == ["Custom Echo", "Run RemCTL"])
        #expect(summary.customDescription == "1 custom")
    }

    @Test func fullRemCTLCLIAdapterPassesArgumentsDirectly() throws {
        let arguments = try RemCTLToolCatalog.arguments(
            for: "remctl.run",
            parameters: ["args": .stringArray(["add", "Test", "-l", "Work"])]
        )
        #expect(arguments == ["add", "Test", "-l", "Work"])
    }

    @Test func fullRemCTLCLIAdapterAllowsLongNoteArguments() throws {
        let note = String(repeating: "n", count: 1024)
        let arguments = try RemCTLToolCatalog.arguments(
            for: "remctl.run",
            parameters: ["args": .stringArray(["add", "Test", "-l", "Work", "-n", note])]
        )
        #expect(arguments.last == note)
    }

    @Test func sectionsArgumentsUseGlobalJSONFormat() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.sections")
        #expect(arguments == ["--format", "json", "sections"])
    }

    @Test func statsArgumentsUseGlobalJSONFormat() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.stats")
        #expect(arguments == ["--format", "json", "stats"])
    }

    @Test func remCTL13ReadHelpersUseGlobalJSONFormat() throws {
        let expected: [String: [String]] = [
            "remctl.flagged": ["--format", "json", "flagged"],
            "remctl.urgent": ["--format", "json", "urgent"],
            "remctl.groups": ["--format", "json", "groups"],
            "remctl.smart_lists": ["--format", "json", "smart-lists"],
            "remctl.templates": ["--format", "json", "templates"],
            "remctl.tags": ["--format", "json", "tags"],
            "remctl.list_symbols": ["--format", "json", "list-symbols"]
        ]

        for (toolID, arguments) in expected {
            #expect(try RemCTLToolCatalog.arguments(for: toolID) == arguments)
        }
    }

    @Test func remCTL13ParameterizedReadHelpersUseGlobalJSONFormat() throws {
        #expect(
            try RemCTLToolCatalog.arguments(for: "remctl.group_info", parameters: ["group": "Writing"]) ==
            ["--format", "json", "group-info", "Writing"]
        )
        #expect(
            try RemCTLToolCatalog.arguments(for: "remctl.template_info", parameters: ["template": "Packing"]) ==
            ["--format", "json", "template-info", "Packing"]
        )
        #expect(
            try RemCTLToolCatalog.arguments(for: "remctl.sharees", parameters: ["list": "Shopping"]) ==
            ["--format", "json", "sharees", "Shopping"]
        )
        #expect(
            try RemCTLToolCatalog.arguments(for: "remctl.subtasks", parameters: ["id": "23880"]) ==
            ["--format", "json", "subtasks", "23880"]
        )
    }

    @Test func upcomingAcceptsRemCTL13MaximumDays() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.upcoming", parameters: ["days": "3650"])
        #expect(arguments == ["--format", "json", "upcoming", "3650"])
    }

    @Test func upcomingRejectsOutOfRangeDays() {
        #expect(throws: ToolValidationError.integerOutOfRange("days")) {
            try RemCTLToolCatalog.arguments(for: "remctl.upcoming", parameters: ["days": "3651"])
        }
    }

    @Test func searchRejectsOverlongQuery() {
        let query = String(repeating: "a", count: 161)
        #expect(throws: ToolValidationError.stringTooLong("query")) {
            try RemCTLToolCatalog.arguments(for: "remctl.search", parameters: ["query": query])
        }
    }

    @Test func searchRejectsNULByte() {
        #expect(throws: ToolValidationError.nulByte("query")) {
            try RemCTLToolCatalog.arguments(for: "remctl.search", parameters: ["query": "hello\0world"])
        }
    }
    @Test func reminderActionsTargetTheFlexibleAdapterByBasename() throws {
        // Library-added reminder tools carry random custom.* ids, so the
        // actions must resolve to the shared RemCTL flex adapter by basename,
        // never by the built-in "remctl.run" id (which those installs lack).
        let actions = RemCTLToolCatalog.reminderRowUIActions
        #expect(!actions.isEmpty)
        for action in actions {
            #expect(action.toolID == nil, "\(action.id) must not hard-code an internal tool id")
            #expect(action.targetExecutableBasename == "remctl")
        }
        #expect(actions.contains { $0.id == "complete" && $0.kind == .checkOff })
        #expect(actions.contains { $0.id == "reschedule" && ($0.inputs?.isEmpty == false) })
        #expect(actions.contains { $0.id == "delete" && $0.style == .destructive })
    }

    @Test func libraryRemCTLPresetsCarryReminderActions() throws {
        // The bug: remCTLPresets mapped built-in tools but dropped uiActions,
        // so preset-derived reminder tools rendered a plain table.
        let presets = DefaultToolPresetCatalog.presets
        guard let upcoming = presets.first(where: { $0.id == "preset.remctl.upcoming" }) else {
            // remctl not installed on this machine — nothing to assert.
            return
        }
        #expect(upcoming.uiActions?.contains { $0.id == "complete" } == true)
        let draftTool = try upcoming.draft.makeTool(id: "custom.deadbeef")
        #expect(draftTool.uiActions?.isEmpty == false, "uiActions survive preset → draft → tool")
    }
}
