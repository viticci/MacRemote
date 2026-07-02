import Foundation
import Testing
@testable import MacRemote

struct ConnectorProfileTests {
    @Test func providerRecommendationsMatchClientCapabilities() {
        #expect(ConnectorProviderProfile.raycast.recommendedAccessMode == .serviceTokenHeaders)
        #expect(ConnectorProviderProfile.claude.recommendedAccessMode == .oauthClientSecret)
        #expect(ConnectorProviderProfile.notion.recommendedAccessMode == .oauthClientSecret)
    }

    @Test func compatibilityFlagsBlockedHeaderlessProviders() {
        #expect(
            ConnectorProviderProfile.claude.status(for: .oauthClientSecret) ==
            .recommended
        )
        #expect(
            ConnectorProviderProfile.notion.status(for: .oauthClientSecret) ==
            .recommended
        )
        #expect(
            ConnectorProviderProfile.claude.status(for: .serviceTokenHeaders) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.notion.status(for: .serviceTokenHeaders) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.raycast.status(for: .serviceTokenHeaders) ==
            .recommended
        )
    }
}
