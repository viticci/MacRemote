import Testing
@testable import MacRemote

struct ToolLibraryCatalogScopeActionTests {
    @Test func freshScopeOffersAdd() {
        #expect(
            ToolLibraryCatalogScopeAction.resolve(
                remainingCount: 16,
                updateCount: 0
            ) == .add
        )
    }

    @Test func representedScopeOffersOnlyCatalogUpdate() {
        #expect(
            ToolLibraryCatalogScopeAction.resolve(
                remainingCount: 15,
                updateCount: 15
            ) == .update
        )
        #expect(
            ToolLibraryCatalogScopeAction.resolve(
                remainingCount: 16,
                updateCount: 16
            ) == .update
        )
    }

    @Test func currentScopeReportsAllAdded() {
        #expect(
            ToolLibraryCatalogScopeAction.resolve(
                remainingCount: 0,
                updateCount: 0
            ) == .current
        )
    }
}
