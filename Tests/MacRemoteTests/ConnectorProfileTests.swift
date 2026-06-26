import XCTest
@testable import MacRemote

final class ConnectorProfileTests: XCTestCase {
    func testProviderRecommendationsMatchClientCapabilities() {
        XCTAssertEqual(ConnectorProviderProfile.raycast.recommendedAccessMode, .serviceTokenHeaders)
        XCTAssertEqual(ConnectorProviderProfile.claude.recommendedAccessMode, .macRemoteOAuthOnly)
        XCTAssertEqual(ConnectorProviderProfile.notion.recommendedAccessMode, .macRemoteOAuthOnly)
    }

    func testCompatibilityFlagsBlockedHeaderlessProviders() {
        XCTAssertEqual(
            ConnectorProviderProfile.claude.status(for: .serviceTokenHeaders),
            .blocked
        )
        XCTAssertEqual(
            ConnectorProviderProfile.notion.status(for: .serviceTokenHeaders),
            .blocked
        )
        XCTAssertEqual(
            ConnectorProviderProfile.raycast.status(for: .serviceTokenHeaders),
            .recommended
        )
    }
}
