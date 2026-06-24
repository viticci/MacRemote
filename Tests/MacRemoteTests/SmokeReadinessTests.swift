import XCTest
@testable import MacRemote

final class SmokeReadinessTests: XCTestCase {
    @MainActor
    func testDefaultReadinessBlocksRemoteProof() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = AppModel(userDefaults: defaults)
        model.tools = RemCTLToolCatalog.builtInTools
        let readiness = model.smokeReadiness

        XCTAssertFalse(readiness.canRunPreflight)
        XCTAssertFalse(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.contains { $0.id == "full-disk-access" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "local-server" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "public-tunnel" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "anthropic-key" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .ready })
    }

    @MainActor
    func testPreparedRemCTLOnlyStateCanRunBothSmokeTests() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = AppModel(userDefaults: defaults)
        model.tools = RemCTLToolCatalog.builtInTools
        model.fullDiskAccessReport = FullDiskAccessReport(state: .ready, detail: "ready")
        model.localServerURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(model.localServerURL!)
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)
        model.anthropicCredentialState = .ready

        let readiness = model.smokeReadiness

        XCTAssertTrue(readiness.canRunPreflight)
        XCTAssertTrue(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.allSatisfy { $0.status == .ready })
    }

    @MainActor
    func testFullDiskAccessDoesNotBlockProfilesWithoutFDARequiredTools() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = AppModel(userDefaults: defaults)
        model.tools = [
            ToolDefinition(
                id: "custom.echo",
                name: "Echo",
                summary: "Echo test.",
                executablePath: "/bin/echo",
                argumentPattern: ["hello"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024,
                origin: .userDefined
            )
        ]

        let readiness = model.smokeReadiness

        XCTAssertTrue(readiness.checks.contains { check in
            check.id == "full-disk-access" &&
                check.status == .ready &&
                check.detail == "No exposed tools currently require Full Disk Access."
        })
    }

    @MainActor
    func testDisablingRemCTLProfileLeavesCustomReadOnlyToolsSmokeReadyWithoutFDA() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = AppModel(userDefaults: defaults)
        model.tools = RemCTLToolCatalog.builtInTools + [
            ToolDefinition(
                id: "custom.echo",
                name: "Echo",
                summary: "Echo test.",
                executablePath: "/bin/echo",
                argumentPattern: ["hello"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024,
                origin: .userDefined
            )
        ]
        XCTAssertNil(model.setRemCTLProfileEnabled(false))
        model.localServerURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(model.localServerURL!)
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)
        model.anthropicCredentialState = .ready

        let readiness = model.smokeReadiness

        XCTAssertEqual(model.toolExposureSummary.total, 1)
        XCTAssertEqual(model.toolExposureSummary.custom, 1)
        XCTAssertTrue(readiness.canRunPreflight)
        XCTAssertTrue(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.contains { check in
            check.id == "full-disk-access" &&
                check.status == .ready &&
                check.detail == "No exposed tools currently require Full Disk Access."
        })
        XCTAssertTrue(readiness.checks.contains { check in
            check.id == "tool-surface" &&
                check.status == .ready &&
                check.detail.contains("Smoke tool: custom.echo")
        })
    }

    @MainActor
    func testDisabledRemCTLProfileWithNoCustomToolsBlocksServerReadiness() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = AppModel(userDefaults: defaults)
        model.tools = RemCTLToolCatalog.builtInTools
        XCTAssertNil(model.setRemCTLProfileEnabled(false))

        let readiness = model.smokeReadiness

        XCTAssertEqual(model.toolExposureSummary.total, 0)
        XCTAssertFalse(readiness.canRunPreflight)
        XCTAssertFalse(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .blocked })
    }

    @MainActor
    func testCustomToolsNoLongerBlockRemoteProofWhenReadOnlyToolIsAvailable() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = AppModel(userDefaults: defaults)
        model.fullDiskAccessReport = FullDiskAccessReport(state: .ready, detail: "ready")
        model.localServerURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(model.localServerURL!)
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)
        model.anthropicCredentialState = .ready
        model.tools = RemCTLToolCatalog.builtInTools + [
            ToolDefinition(
                id: "custom.echo",
                name: "Echo",
                summary: "Echo test.",
                executablePath: "/bin/echo",
                argumentPattern: ["hello"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024,
                origin: .userDefined
            )
        ]

        let readiness = model.smokeReadiness

        XCTAssertTrue(readiness.canRunPreflight)
        XCTAssertTrue(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .ready })
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

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}
