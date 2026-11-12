import Testing
@testable import MacRemote

struct SidebarViewTests {
    @Test func toolsBadgeExplanationIsHiddenWithoutNewServers() {
        #expect(SidebarView.toolsBadgeExplanation(count: 0) == nil)
        #expect(SidebarView.toolsBadgeExplanation(count: -1) == nil)
    }

    @Test func toolsBadgeExplanationInflectsAndExplainsConsent() {
        #expect(
            SidebarView.toolsBadgeExplanation(count: 1)
                == "1 new MCP server found. Open Tools to review it; nothing was imported automatically."
        )
        #expect(
            SidebarView.toolsBadgeExplanation(count: 2)
                == "2 new MCP servers found. Open Tools to review them; nothing was imported automatically."
        )
    }
}
