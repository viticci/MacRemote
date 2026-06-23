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
