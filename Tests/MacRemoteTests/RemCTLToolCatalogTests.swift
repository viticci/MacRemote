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
