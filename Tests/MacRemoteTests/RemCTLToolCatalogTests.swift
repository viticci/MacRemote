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
        XCTAssertEqual(RemCTLToolCatalog.readOnlyTools.count, 9)
        XCTAssertFalse(RemCTLToolCatalog.readOnlyTools.contains { $0.argumentPattern.contains("--via-eventkit") })
    }

    func testBuiltInProfileIncludesFullRemCTLCLIAdapter() throws {
        XCTAssertEqual(RemCTLToolCatalog.builtInTools.count, 10)

        let tool = try XCTUnwrap(RemCTLToolCatalog.tool(id: "remctl.run"))
        XCTAssertEqual(tool.executablePath, RemCTLToolCatalog.executablePath)
        XCTAssertEqual(tool.argumentPattern, ["{args}"])
        XCTAssertEqual(tool.parameters.map(\.name), ["args", "stdin"])
        XCTAssertEqual(tool.capability, .destructive)
        XCTAssertTrue(tool.isGenericCLIAdapter)
    }

    func testToolExposureSummaryForDefaultRemCTLProfile() {
        let summary = ToolExposureSummary(tools: RemCTLToolCatalog.builtInTools)

        XCTAssertEqual(summary.total, 10)
        XCTAssertEqual(summary.readOnly, 9)
        XCTAssertEqual(summary.write, 0)
        XCTAssertEqual(summary.destructive, 1)
        XCTAssertEqual(summary.gatedToolCount, 1)
        XCTAssertEqual(summary.builtIn, 10)
        XCTAssertEqual(summary.custom, 0)
        XCTAssertEqual(summary.genericAdapters, 1)
        XCTAssertEqual(summary.nonReadOnlyToolNames, ["Run RemCTL"])
        XCTAssertEqual(summary.customDescription, "No custom tools")
        XCTAssertEqual(summary.capabilityDescription, "9 read-only, 1 host-gated")
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

        XCTAssertEqual(summary.total, 11)
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

    func testUpcomingRejectsOutOfRangeDays() {
        XCTAssertThrowsError(
            try RemCTLToolCatalog.arguments(for: "remctl.upcoming", parameters: ["days": "45"])
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
