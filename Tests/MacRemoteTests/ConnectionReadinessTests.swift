import Foundation
import Testing
@testable import MacRemote

struct ConnectionReadinessTests {
    @MainActor
    @Test func freshInstallWaitsCalmlyAndAsksForATool() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        let readiness = model.connectionReadiness

        #expect(model.toolExposureSummary.total == 0)
        // Nothing shared needs Full Disk Access, so that row has nothing to do.
        #expect(readiness.contains { $0.id == "full-disk-access" && $0.status == .ready && !$0.isNeeded })
        // Not-yet-started prerequisites are calm "waiting", not alarming "blocked".
        #expect(readiness.contains { $0.id == "local-server" && $0.status == .waiting })
        #expect(readiness.contains { $0.id == "public-tunnel" && $0.status == .waiting })
        #expect(readiness.contains { $0.id == "tool-surface" && $0.status == .blocked })
    }

    @MainActor
    @Test func sharedToolsOnAPublicServerAreAllReady() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.tools = readinessFixtureTools
        model.localServerURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(model.localServerURL!)
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)

        #expect(model.connectionReadiness.allSatisfy { $0.status == .ready })
    }

    /// Access can be revoked while the server runs, so a running server must
    /// not paint the access rows green.
    @MainActor
    @Test func aRunningServerDoesNotHideMissingFullDiskAccess() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.tools = [
            ToolDefinition(
                id: "custom.protected",
                name: "Protected",
                summary: "Reads protected data.",
                executablePath: "/bin/echo",
                argumentPattern: ["hello"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024,
                origin: .userDefined,
                permissionRequirements: [.fullDiskAccess]
            )
        ]
        model.localServerURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(model.localServerURL!)
        model.fullDiskAccessReport = FullDiskAccessReport(state: .required, detail: "Access was removed.")

        #expect(model.connectionReadiness.contains {
            $0.id == "full-disk-access" && $0.status == .blocked && $0.isNeeded
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
                    subtitle: "Tool process."
                )
            ],
            requiresManualConfirmation: true,
            confirmationSignature: "custom.echo=/bin/echo#toolExecutable=/bin/echo"
        )

        model.confirmFullDiskAccessSetup()

        #expect(model.fullDiskAccessReport.isReady)
        #expect(
            model.fullDiskAccessReport.detail ==
                "Manual Full Disk Access confirmation recorded for the current shared tools that require Full Disk Access."
        )
        #expect(!model.fullDiskAccessReport.detail.contains("FDA"))
        #expect(model.fullDiskAccessReport.requiresManualConfirmation == false)
        #expect(model.fullDiskAccessReport.confirmationSignature == "custom.echo=/bin/echo#toolExecutable=/bin/echo")
        #expect(model.fullDiskAccessPrompt == nil)
    }

    @Test func toolExposureSummaryUsesAskFirstCopy() {
        let tools = [
            ToolDefinition(
                id: "read_status",
                name: "Read Status",
                summary: "Read status.",
                executablePath: "/bin/echo",
                argumentPattern: ["read"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024
            ),
            ToolDefinition(
                id: "change_status",
                name: "Change Status",
                summary: "Change status.",
                executablePath: "/bin/echo",
                argumentPattern: ["write"],
                parameters: [],
                capability: .write,
                timeoutSeconds: 5,
                outputByteLimit: 1024
            )
        ]

        #expect(ToolExposureSummary(tools: tools).capabilityDescription == "1 read-only, 1 asks first")

        // A first-time owner often shares exactly one tool: the counts must
        // agree with their nouns and verbs.
        let single = ToolExposureSummary(tools: [tools[0]])
        #expect(single.capabilityDescription == "1 read-only, 0 ask first")
        #expect(single.publicLinkSentence.contains("1 tool will be reachable: 1 read-only, 0 that ask you before running."))
        #expect(ToolExposureSummary(tools: tools).publicLinkSentence.contains("2 tools will be reachable: 1 read-only, 1 that asks you before running."))
        #expect(counted(0, "tool") == "0 tools")
    }

    @MainActor
    @Test func toolsCanBeDisabledIndividually() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.tools = readinessFixtureTools + [
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

        #expect(model.setToolEnabled(id: "fixture_today", enabled: false) == nil)
        #expect(model.setToolEnabled(id: "custom.echo", enabled: false) == nil)

        #expect(model.isToolIDExposed("fixture_today") == false)
        #expect(model.isToolIDExposed("custom.echo") == false)
        #expect(model.isToolIDExposed("fixture_info"))
        #expect(model.toolExposureSummary.total == readinessFixtureTools.count - 1)

        #expect(model.setToolEnabled(id: "fixture_today", enabled: true) == nil)
        #expect(model.isToolIDExposed("fixture_today"))
        #expect(model.toolExposureSummary.total == readinessFixtureTools.count)
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
    // A missing Cloudflare helper now blocks the public-link check, so readiness
    // expectations must not depend on whether this Mac happens to have one.
    return makeTestAppModel(
        userDefaults: userDefaults,
        toolStore: store
    )
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}

/// A small first-party-like surface: two read-only reads and one write.
private let readinessFixtureTools: [ToolDefinition] = [
    ToolDefinition(
        id: "fixture_today",
        name: "Today",
        summary: "Read today.",
        executablePath: "/bin/echo",
        argumentPattern: ["today"],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined,
        category: .reminders
    ),
    ToolDefinition(
        id: "fixture_info",
        name: "Info",
        summary: "Read one item.",
        executablePath: "/bin/echo",
        argumentPattern: ["info", "{id}"],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined,
        category: .reminders
    ),
    ToolDefinition(
        id: "fixture_create",
        name: "Create",
        summary: "Write one item.",
        executablePath: "/bin/echo",
        argumentPattern: ["add", "{title}"],
        parameters: [],
        capability: .write,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined,
        category: .reminders
    )
]
