import Foundation
import Testing
@testable import MacRemote

struct ConnectorProfileTests {
    /// D42/R1 — every supported app can finish Dynamic OAuth, so it is the
    /// recommendation for all of them and the app picker stops implying a
    /// different answer per app.
    @Test func everyProviderRecommendsTheProductDefault() {
        for provider in ConnectorProviderProfile.allCases {
            #expect(provider.recommendedAuthMode == .macRemoteOAuthOnly)
            #expect(provider.recommendedAuthMode == ConnectorAuthMode.productDefault)
            #expect(provider.status(for: .macRemoteOAuthOnly) == .recommended)
        }
    }

    @Test func compatibilityFlagsBlockedProviders() {
        // Client Secret mode requires a confidential client, which switches
        // off self-registration for the whole server — the two apps that sign
        // themselves up over the public link cannot connect while it is on.
        #expect(
            ConnectorProviderProfile.chatGPT.status(for: .oauthClientSecret) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.claude.status(for: .oauthClientSecret) ==
            .blocked
        )
        // Apps that accept a pasted ID and secret still work with it.
        #expect(
            ConnectorProviderProfile.notion.status(for: .oauthClientSecret) ==
            .works
        )
        #expect(
            ConnectorProviderProfile.raycast.status(for: .oauthClientSecret) ==
            .works
        )
        #expect(
            ConnectorProviderProfile.generic.status(for: .oauthClientSecret) ==
            .works
        )
        // ChatGPT, Claude.ai, and Notion connectors can't send custom headers,
        // so the Single Header mode can never work for them.
        #expect(
            ConnectorProviderProfile.chatGPT.status(for: .singleHeaderToken) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.claude.status(for: .singleHeaderToken) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.notion.status(for: .singleHeaderToken) ==
            .blocked
        )
        #expect(
            ConnectorProviderProfile.raycast.status(for: .singleHeaderToken) ==
            .works
        )
        #expect(
            ConnectorProviderProfile.generic.status(for: .singleHeaderToken) ==
            .works
        )
    }

    /// A blocked pairing must name the real reason and an escape route; the
    /// generic profile must no longer tell people to start with Client Secret.
    @Test func setupLinesStayTruthfulAndPointAtTheDefault() {
        let claudeSecret = ConnectorProviderProfile.claude.setupLine(for: .oauthClientSecret)
        #expect(claudeSecret.contains("signs itself up"))
        #expect(claudeSecret.contains("Dynamic OAuth"))

        let chatGPTHeader = ConnectorProviderProfile.chatGPT.setupLine(for: .singleHeaderToken)
        #expect(chatGPTHeader.contains("can't send a fixed sign-in header"))
        #expect(chatGPTHeader.contains("Dynamic OAuth"))

        let generic = ConnectorProviderProfile.generic.setupLine(for: .macRemoteOAuthOnly)
        #expect(generic.contains("Start with OAuth Client Secret") == false)
        #expect(generic.contains("remote MCP server"))
    }

    @Test func chatGPTProfileExplainsDynamicClientRegistration() {
        let profile = ConnectorProviderProfile.chatGPT
        #expect(profile.title == "ChatGPT")
        #expect(profile.authLabel == "Dynamic OAuth")
        #expect(profile.headerLabel == "OAuth discovery")
        let setup = profile.setupLine(for: .macRemoteOAuthOnly)
        #expect(setup.contains("Settings ▸ Plugins"))
        #expect(setup.contains("developer-mode app"))
        #expect(setup.contains("Public URL"))
        #expect(setup.contains("Dynamic Client Registration"))
    }

    // Connected-app glyph inference moved to ConnectedAppIdentity (D46) with
    // exact matching; see ConnectedAppIdentityTests.

    // MARK: - Preservation contract (D42)
    //
    // The three tests below are the promise that no redesign of the sign-in UI
    // may break: every raw value someone's Mac has already written to
    // `MacRemote.connector.accessMode` still resolves to the same method, the
    // retired Cloudflare Access values still migrate, and an unrecognized value
    // stays nil so the caller can fall back to the product default. Keep them
    // verbatim — change the UI around them, never them.

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
