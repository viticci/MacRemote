import Foundation
import Testing
@testable import MacRemote

struct TunnelServiceTests {
    @Test func parsesTryCloudflareURLFromOutput() {
        let output = "INFO Your quick Tunnel has been created! Visit it at https://quiet-river-123.trycloudflare.com"
        #expect(
            TunnelService.firstPublicURL(in: output)?.absoluteString ==
            "https://quiet-river-123.trycloudflare.com"
        )
    }

    @Test func ignoresNonTryCloudflareURL() {
        let output = "Forwarding to http://127.0.0.1:60735"
        #expect(TunnelService.firstPublicURL(in: output) == nil)
    }

    @MainActor
    @Test func appModelCurrentPublicMCPURLUsesStableAlias() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.instanceID = "abc123"
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)

        #expect(
            model.currentPublicMCPURL?.absoluteString ==
            "https://quiet-river-123.trycloudflare.com/mcp"
        )
    }

    @MainActor
    @Test func rotateInstanceIDStopsExposureClearsApprovalsAndPersistsNewID() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let originalInstanceID = "0123456789abcdef0123456789abcdef"
        defaults.set(originalInstanceID, forKey: "MacRemote.instanceID")
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.serverStatus = .running(URL(string: "http://127.0.0.1:60123")!)
        model.localServerURL = URL(string: "http://127.0.0.1:60123")!
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)
        model.approvals = [
            ApprovalRequest(
                id: UUID(),
                clientID: "client-id",
                clientTrustID: "trust-id",
                clientName: "Client",
                redirectURI: "https://example.com/callback",
                issuer: "https://quiet-river-123.trycloudflare.com",
                resource: "https://quiet-river-123.trycloudflare.com/mcp/\(originalInstanceID)",
                requestedScopes: ["mcp:tools"],
                createdAt: Date(),
                state: .pending
            )
        ]
        model.toolCallApprovals = [
            ToolCallApprovalRequest(
                id: UUID(),
                toolID: "remctl.run",
                toolName: "Run RemCTL",
                capability: .destructive,
                argumentsPreview: "args=add Test -l Work",
                createdAt: Date(),
                state: .pending
            )
        ]

        #expect(model.currentPublicMCPURL?.absoluteString == "https://quiet-river-123.trycloudflare.com/mcp")

        model.rotateInstanceID()

        #expect(model.instanceID != originalInstanceID)
        #expect(model.instanceID.count == 32)
        #expect(defaults.string(forKey: "MacRemote.instanceID") == model.instanceID)
        #expect(model.serverStatus == .stopped)
        #expect(model.localServerURL == nil)
        #expect(model.currentPublicMCPURL == nil)
        #expect(model.approvals.isEmpty)
        #expect(model.toolCallApprovals.isEmpty)
        // §2.4: rotation no longer jumps navigation — Settings › Security confirms in place.
        #expect(model.instanceRotationConfirmation == "New private address created")
        #expect(model.logs.first?.message.contains("Rotated instance ID") == true)
    }

    @MainActor
    @Test func customDomainDeployIsAllowedBeforeLocalServerStarts() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.serverStatus = .stopped
        model.localServerURL = nil
        model.cloudflareZones = [
            CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Test Account"
            )
        ]
        model.cloudflareDraft.selectedZoneID = "zone-id"
        model.cloudflareDraft.subdomain = "macremote-fresh-clients"
        model.cloudflareDraft.apiToken = "test-token"
        model.cloudflareCustomDomainState = .ready

        #expect(model.canDeployCustomDomainTunnel)
        #expect(model.customDomainDeployHint == "Deploy will start the local MCP server first.")
    }

    @MainActor
    @Test func customDomainDeployHintRequiresAPIToken() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.cloudflareZones = [
            CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Test Account"
            )
        ]
        model.cloudflareDraft.selectedZoneID = "zone-id"
        model.cloudflareDraft.subdomain = "macremote-fresh-clients"
        model.cloudflareCustomDomainState = .ready

        #expect(model.canDeployCustomDomainTunnel)
        #expect(
            model.customDomainDeployHint ==
            CloudflareServiceError.missingAPIToken.localizedDescription
        )
    }
}

private func makeIsolatedDefaults(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> UserDefaults {
    let suiteName = "MacRemoteTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated UserDefaults suite.", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    defaults.set(suiteName, forKey: "MacRemoteTests.suiteName")
    return defaults
}

@MainActor
private func makeIsolatedAppModel(userDefaults: UserDefaults) throws -> AppModel {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
    return AppModel(userDefaults: userDefaults, toolStore: store)
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}
