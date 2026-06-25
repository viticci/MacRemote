import XCTest
@testable import MacRemote

final class TunnelServiceTests: XCTestCase {
    func testParsesTryCloudflareURLFromOutput() {
        let output = "INFO Your quick Tunnel has been created! Visit it at https://quiet-river-123.trycloudflare.com"
        XCTAssertEqual(
            TunnelService.firstPublicURL(in: output)?.absoluteString,
            "https://quiet-river-123.trycloudflare.com"
        )
    }

    func testIgnoresNonTryCloudflareURL() {
        let output = "Forwarding to http://127.0.0.1:60735"
        XCTAssertNil(TunnelService.firstPublicURL(in: output))
    }

    @MainActor
    func testAppModelCurrentPublicMCPURLAddsInstancePath() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.instanceID = "abc123"
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)

        XCTAssertEqual(
            model.currentPublicMCPURL?.absoluteString,
            "https://quiet-river-123.trycloudflare.com/mcp/abc123"
        )
    }

    @MainActor
    func testRotateInstanceIDStopsExposureClearsApprovalsAndPersistsNewID() throws {
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

        XCTAssertEqual(model.currentPublicMCPURL?.absoluteString, "https://quiet-river-123.trycloudflare.com/mcp/\(originalInstanceID)")

        model.rotateInstanceID()

        XCTAssertNotEqual(model.instanceID, originalInstanceID)
        XCTAssertEqual(model.instanceID.count, 32)
        XCTAssertEqual(defaults.string(forKey: "MacRemote.instanceID"), model.instanceID)
        XCTAssertEqual(model.serverStatus, .stopped)
        XCTAssertNil(model.localServerURL)
        XCTAssertNil(model.currentPublicMCPURL)
        XCTAssertTrue(model.approvals.isEmpty)
        XCTAssertTrue(model.toolCallApprovals.isEmpty)
        XCTAssertEqual(model.selection, .settings)
        XCTAssertTrue(model.logs.first?.message.contains("Rotated instance ID") == true)
    }

    @MainActor
    func testCustomDomainDeployIsAllowedBeforeLocalServerStarts() throws {
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

        XCTAssertTrue(model.canDeployCustomDomainTunnel)
        XCTAssertEqual(model.customDomainDeployHint, "Deploy will start the local MCP server first.")
    }

    @MainActor
    func testCustomDomainDeployHintRequiresAPIToken() throws {
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

        XCTAssertTrue(model.canDeployCustomDomainTunnel)
        XCTAssertEqual(
            model.customDomainDeployHint,
            CloudflareServiceError.missingAPIToken.localizedDescription
        )
    }
}

private func makeIsolatedDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> UserDefaults {
    let suiteName = "MacRemoteTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        XCTFail("Could not create isolated UserDefaults suite.", file: file, line: line)
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
