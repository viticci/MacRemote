import Foundation
import Testing
@testable import MacRemote

struct SmokeReadinessTests {
    @MainActor
    @Test func defaultReadinessBlocksRemoteProof() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        let readiness = model.smokeReadiness

        #expect(model.toolExposureSummary.total == 0)
        #expect(readiness.canRunPreflight == false)
        #expect(readiness.canRunAnthropicAPI == false)
        #expect(readiness.checks.contains { $0.id == "full-disk-access" && $0.status == .ready })
        // Not-yet-started prerequisites are calm "waiting", not alarming "blocked".
        #expect(readiness.checks.contains { $0.id == "local-server" && $0.status == .waiting })
        #expect(readiness.checks.contains { $0.id == "public-tunnel" && $0.status == .waiting })
        #expect(readiness.checks.contains { $0.id == "anthropic-key" && $0.status == .blocked })
        #expect(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .blocked })
    }

    @MainActor
    @Test func preparedRemCTLOnlyStateCanRunBothSmokeTests() throws {
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

        #expect(readiness.canRunPreflight)
        #expect(readiness.canRunAnthropicAPI)
        #expect(readiness.checks.allSatisfy { $0.status == .ready })
    }

    @MainActor
    @Test func fullDiskAccessDoesNotBlockProfilesWithoutFDARequiredTools() throws {
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

        #expect(readiness.checks.contains { check in
            check.id == "full-disk-access" &&
                check.status == .ready &&
            check.detail == "No exposed tools currently require Full Disk Access."
        })
    }

    @MainActor
    @Test func manualFullDiskAccessConfirmationMarksCurrentSurfaceReady() throws {
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

        #expect(model.fullDiskAccessReport.isReady)
        #expect(model.fullDiskAccessReport.requiresManualConfirmation == false)
        #expect(model.fullDiskAccessReport.confirmationSignature == "custom.echo=/bin/echo#toolExecutable=/bin/echo")
        #expect(model.fullDiskAccessPrompt == nil)
    }

    @MainActor
    @Test func disablingRemCTLProfileLeavesCustomReadOnlyToolsSmokeReadyWithoutFDA() throws {
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
        #expect(model.setRemCTLProfileEnabled(false) == nil)
        model.localServerURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(model.localServerURL!)
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)
        model.anthropicCredentialState = .ready

        let readiness = model.smokeReadiness

        #expect(model.toolExposureSummary.total == 1)
        #expect(model.toolExposureSummary.custom == 1)
        #expect(readiness.canRunPreflight)
        #expect(readiness.canRunAnthropicAPI)
        #expect(readiness.checks.contains { check in
            check.id == "full-disk-access" &&
                check.status == .ready &&
                check.detail == "No exposed tools currently require Full Disk Access."
        })
        #expect(readiness.checks.contains { check in
            check.id == "tool-surface" &&
                check.status == .ready &&
                check.detail.contains("Smoke tool: custom.echo")
        })
    }

    @MainActor
    @Test func disabledRemCTLProfileWithNoCustomToolsBlocksServerReadiness() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.tools = RemCTLToolCatalog.builtInTools
        #expect(model.setRemCTLProfileEnabled(false) == nil)

        let readiness = model.smokeReadiness

        #expect(model.toolExposureSummary.total == 0)
        #expect(readiness.canRunPreflight == false)
        #expect(readiness.canRunAnthropicAPI == false)
        #expect(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .blocked })
    }

    @MainActor
    @Test func toolsCanBeDisabledIndividually() throws {
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

        #expect(model.setToolEnabled(id: "remctl.today", enabled: false) == nil)
        #expect(model.setToolEnabled(id: "custom.echo", enabled: false) == nil)

        #expect(model.isToolIDExposed("remctl.today") == false)
        #expect(model.isToolIDExposed("custom.echo") == false)
        #expect(model.isToolIDExposed("remctl.upcoming"))
        #expect(model.toolExposureSummary.total == RemCTLToolCatalog.builtInTools.count - 1)

        #expect(model.setToolEnabled(id: "remctl.today", enabled: true) == nil)
        #expect(model.isToolIDExposed("remctl.today"))
        #expect(model.toolExposureSummary.total == RemCTLToolCatalog.builtInTools.count)
    }

    @MainActor
    @Test func customToolsNoLongerBlockRemoteProofWhenReadOnlyToolIsAvailable() throws {
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

        #expect(readiness.canRunPreflight)
        #expect(readiness.canRunAnthropicAPI)
        #expect(readiness.checks.contains { $0.id == "tool-surface" && $0.status == .ready })
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
