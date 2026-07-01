import XCTest
@testable import MacRemote

final class SmokeReadinessTests: XCTestCase {
    @MainActor
    func testDefaultReadinessBlocksRemoteProof() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        let readiness = model.smokeReadiness

        XCTAssertEqual(model.toolExposureSummary.total, 0)
        XCTAssertFalse(readiness.canRunPreflight)
        XCTAssertFalse(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.contains { $0.id == "full-disk-access" && $0.status == .ready })
        XCTAssertTrue(readiness.checks.contains { $0.id == "local-server" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "public-tunnel" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "anthropic-key" && $0.status == .blocked })
        XCTAssertTrue(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .blocked })
    }

    @MainActor
    func testPreparedRemCTLOnlyStateCanRunBothSmokeTests() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
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

        let model = try makeIsolatedAppModel(userDefaults: defaults)
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
    func testManualFullDiskAccessConfirmationMarksCurrentSurfaceReady() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.fullDiskAccessReport = FullDiskAccessReport(
            state: .required,
            detail: "Manual confirmation required.",
            targets: [
                FullDiskAccessTarget(
                    title: "Echo executable",
                    path: "/bin/echo",
                    subtitle: "Tool process.",
                    role: .toolExecutable
                )
            ],
            requiresManualConfirmation: true,
            confirmationSignature: "custom.echo=/bin/echo#toolExecutable=/bin/echo"
        )

        model.confirmFullDiskAccessSetup()

        XCTAssertTrue(model.fullDiskAccessReport.isReady)
        XCTAssertFalse(model.fullDiskAccessReport.requiresManualConfirmation)
        XCTAssertEqual(model.fullDiskAccessReport.confirmationSignature, "custom.echo=/bin/echo#toolExecutable=/bin/echo")
        XCTAssertNil(model.fullDiskAccessPrompt)
    }

    @MainActor
    func testDisablingRemCTLProfileLeavesCustomReadOnlyToolsSmokeReadyWithoutFDA() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
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

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.tools = RemCTLToolCatalog.builtInTools
        XCTAssertNil(model.setRemCTLProfileEnabled(false))

        let readiness = model.smokeReadiness

        XCTAssertEqual(model.toolExposureSummary.total, 0)
        XCTAssertFalse(readiness.canRunPreflight)
        XCTAssertFalse(readiness.canRunAnthropicAPI)
        XCTAssertTrue(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .blocked })
    }

    @MainActor
    func testToolsCanBeDisabledIndividually() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
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

        XCTAssertNil(model.setToolEnabled(id: "remctl.today", enabled: false))
        XCTAssertNil(model.setToolEnabled(id: "custom.echo", enabled: false))

        XCTAssertFalse(model.isToolIDExposed("remctl.today"))
        XCTAssertFalse(model.isToolIDExposed("custom.echo"))
        XCTAssertTrue(model.isToolIDExposed("remctl.upcoming"))
        XCTAssertEqual(model.toolExposureSummary.total, RemCTLToolCatalog.builtInTools.count - 1)

        XCTAssertNil(model.setToolEnabled(id: "remctl.today", enabled: true))
        XCTAssertTrue(model.isToolIDExposed("remctl.today"))
        XCTAssertEqual(model.toolExposureSummary.total, RemCTLToolCatalog.builtInTools.count)
    }

    @MainActor
    func testCustomToolsNoLongerBlockRemoteProofWhenReadOnlyToolIsAvailable() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
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
