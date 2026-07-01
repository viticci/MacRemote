import XCTest
@testable import MacRemote

final class ConnectorProfileTests: XCTestCase {
    func testProviderRecommendationsMatchClientCapabilities() {
        XCTAssertEqual(ConnectorProviderProfile.raycast.recommendedAccessMode, .serviceTokenHeaders)
        XCTAssertEqual(ConnectorProviderProfile.claude.recommendedAccessMode, .oauthClientSecret)
        XCTAssertEqual(ConnectorProviderProfile.notion.recommendedAccessMode, .oauthClientSecret)
    }

    func testCompatibilityFlagsBlockedHeaderlessProviders() {
        XCTAssertEqual(
            ConnectorProviderProfile.claude.status(for: .oauthClientSecret),
            .recommended
        )
        XCTAssertEqual(
            ConnectorProviderProfile.notion.status(for: .oauthClientSecret),
            .recommended
        )
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
