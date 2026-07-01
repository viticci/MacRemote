import XCTest
@testable import MacRemote

final class RemCTLToolCatalogTests: XCTestCase {
    func testTodayArgumentsUseGlobalJSONFormat() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.today")
        XCTAssertEqual(arguments, ["--format", "json", "today"])
    }

    func testUpcomingDefaultsToSevenDays() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.upcoming")
        XCTAssertEqual(arguments, ["--format", "json", "upcoming", "7"])
    }

    func testDefaultProfileUsesDirectFullFidelityReadCommands() {
        XCTAssertEqual(RemCTLToolCatalog.readOnlyTools.count, 20)
        XCTAssertFalse(RemCTLToolCatalog.readOnlyTools.contains { $0.argumentPattern.contains("--via-eventkit") })
    }

    func testBuiltInProfileIncludesFullRemCTLCLIAdapter() throws {
        XCTAssertEqual(RemCTLToolCatalog.builtInTools.count, 21)

        let tool = try XCTUnwrap(RemCTLToolCatalog.tool(id: "remctl.run"))
        XCTAssertEqual(tool.executablePath, RemCTLToolCatalog.executablePath)
        XCTAssertEqual(tool.argumentPattern, ["{args}"])
        XCTAssertEqual(tool.parameters.map(\.name), ["args", "stdin"])
        XCTAssertEqual(tool.capability, .destructive)
        XCTAssertTrue(tool.isGenericCLIAdapter)
        XCTAssertEqual(tool.permissionRequirements, [.fullDiskAccess, .reminders])
    }

    func testAllBuiltInRemCTLToolsRequireFullDiskAccess() {
        XCTAssertFalse(RemCTLToolCatalog.builtInTools.isEmpty)
        XCTAssertTrue(RemCTLToolCatalog.builtInTools.allSatisfy { tool in
            tool.permissionRequirements == [.fullDiskAccess, .reminders]
        })
    }

    func testToolExposureSummaryForDefaultRemCTLProfile() {
        let summary = ToolExposureSummary(tools: RemCTLToolCatalog.builtInTools)

        XCTAssertEqual(summary.total, 21)
        XCTAssertEqual(summary.readOnly, 20)
        XCTAssertEqual(summary.write, 0)
        XCTAssertEqual(summary.destructive, 1)
        XCTAssertEqual(summary.gatedToolCount, 1)
        XCTAssertEqual(summary.builtIn, 21)
        XCTAssertEqual(summary.custom, 0)
        XCTAssertEqual(summary.genericAdapters, 1)
        XCTAssertEqual(summary.nonReadOnlyToolNames, ["Run RemCTL"])
        XCTAssertEqual(summary.customDescription, "No custom tools")
        XCTAssertEqual(summary.capabilityDescription, "20 read-only, 1 host-gated")
    }

    func testToolExposureSummaryCountsCustomTools() {
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

        XCTAssertEqual(summary.total, 22)
        XCTAssertEqual(summary.write, 1)
        XCTAssertEqual(summary.destructive, 1)
        XCTAssertEqual(summary.gatedToolCount, 2)
        XCTAssertEqual(summary.custom, 1)
        XCTAssertEqual(summary.genericAdapters, 2)
        XCTAssertEqual(summary.nonReadOnlyToolNames, ["Custom Echo", "Run RemCTL"])
        XCTAssertEqual(summary.customDescription, "1 custom")
    }

    func testFullRemCTLCLIAdapterPassesArgumentsDirectly() throws {
        let arguments = try RemCTLToolCatalog.arguments(
            for: "remctl.run",
            parameters: ["args": .stringArray(["add", "Test", "-l", "Work"])]
        )
        XCTAssertEqual(arguments, ["add", "Test", "-l", "Work"])
    }

    func testFullRemCTLCLIAdapterAllowsLongNoteArguments() throws {
        let note = String(repeating: "n", count: 1024)
        let arguments = try RemCTLToolCatalog.arguments(
            for: "remctl.run",
            parameters: ["args": .stringArray(["add", "Test", "-l", "Work", "-n", note])]
        )
        XCTAssertEqual(arguments.last, note)
    }

    func testSectionsArgumentsUseGlobalJSONFormat() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.sections")
        XCTAssertEqual(arguments, ["--format", "json", "sections"])
    }

    func testStatsArgumentsUseGlobalJSONFormat() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.stats")
        XCTAssertEqual(arguments, ["--format", "json", "stats"])
    }

    func testRemCTL13ReadHelpersUseGlobalJSONFormat() throws {
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
            XCTAssertEqual(try RemCTLToolCatalog.arguments(for: toolID), arguments)
        }
    }

    func testRemCTL13ParameterizedReadHelpersUseGlobalJSONFormat() throws {
        XCTAssertEqual(
            try RemCTLToolCatalog.arguments(for: "remctl.group_info", parameters: ["group": "Writing"]),
            ["--format", "json", "group-info", "Writing"]
        )
        XCTAssertEqual(
            try RemCTLToolCatalog.arguments(for: "remctl.template_info", parameters: ["template": "Packing"]),
            ["--format", "json", "template-info", "Packing"]
        )
        XCTAssertEqual(
            try RemCTLToolCatalog.arguments(for: "remctl.sharees", parameters: ["list": "Shopping"]),
            ["--format", "json", "sharees", "Shopping"]
        )
        XCTAssertEqual(
            try RemCTLToolCatalog.arguments(for: "remctl.subtasks", parameters: ["id": "23880"]),
            ["--format", "json", "subtasks", "23880"]
        )
    }

    func testUpcomingAcceptsRemCTL13MaximumDays() throws {
        let arguments = try RemCTLToolCatalog.arguments(for: "remctl.upcoming", parameters: ["days": "3650"])
        XCTAssertEqual(arguments, ["--format", "json", "upcoming", "3650"])
    }

    func testUpcomingRejectsOutOfRangeDays() {
        XCTAssertThrowsError(
            try RemCTLToolCatalog.arguments(for: "remctl.upcoming", parameters: ["days": "3651"])
        ) { error in
            XCTAssertEqual(error as? ToolValidationError, .integerOutOfRange("days"))
        }
    }

    func testSearchRejectsOverlongQuery() {
        let query = String(repeating: "a", count: 161)
        XCTAssertThrowsError(
            try RemCTLToolCatalog.arguments(for: "remctl.search", parameters: ["query": query])
        ) { error in
            XCTAssertEqual(error as? ToolValidationError, .stringTooLong("query"))
        }
    }

    func testSearchRejectsNULByte() {
        XCTAssertThrowsError(
            try RemCTLToolCatalog.arguments(for: "remctl.search", parameters: ["query": "hello\0world"])
        ) { error in
            XCTAssertEqual(error as? ToolValidationError, .nulByte("query"))
        }
    }
}
