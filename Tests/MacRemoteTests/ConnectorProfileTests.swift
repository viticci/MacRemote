import Foundation
import Testing
@testable import MacRemote

struct ConnectorProfileTests {
    @Test func providerRecommendationsMatchClientCapabilities() {
        #expect(ConnectorProviderProfile.raycast.recommendedAuthMode == .macRemoteOAuthOnly)
        #expect(ConnectorProviderProfile.claude.recommendedAuthMode == .oauthClientSecret)
        #expect(ConnectorProviderProfile.notion.recommendedAuthMode == .oauthClientSecret)
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
        // Claude.ai and Notion connectors can't send custom headers, so the
        // Single Header mode can never work for them.
        #expect(
            ConnectorProviderProfile.claude.status(for: .singleHeaderToken) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.notion.status(for: .singleHeaderToken) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.raycast.status(for: .macRemoteOAuthOnly) ==
            .recommended
        )
        #expect(
            ConnectorProviderProfile.raycast.status(for: .singleHeaderToken) ==
            .works
        )
    }

    @Test func persistedRawValuesResolveDirectly() {
        #expect(ConnectorAuthMode.from(persistedRawValue: "oauthClientSecret") == .oauthClientSecret)
        #expect(ConnectorAuthMode.from(persistedRawValue: "macRemoteOAuthOnly") == .macRemoteOAuthOnly)
        #expect(ConnectorAuthMode.from(persistedRawValue: "singleHeaderToken") == .singleHeaderToken)
    }

    @Test func retiredCloudflareAccessModesMigrateToDynamicOAuth() {
        // Both retired modes also ran MacRemote OAuth, so their clients hold
        // valid grants — Dynamic OAuth keeps them connected without the wall.
        #expect(ConnectorAuthMode.from(persistedRawValue: "serviceTokenHeaders") == .macRemoteOAuthOnly)
        #expect(ConnectorAuthMode.from(persistedRawValue: "serviceTokenAuthorizationHeader") == .macRemoteOAuthOnly)
    }

    @Test func unknownPersistedRawValueResolvesToNil() {
        #expect(ConnectorAuthMode.from(persistedRawValue: "nonsense") == nil)
    }
}
