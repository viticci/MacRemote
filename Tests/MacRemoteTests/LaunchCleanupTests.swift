import Foundation
import Testing
@testable import MacRemote

/// What the app puts right, once, when a newer version first opens data saved
/// by an older one.
struct LaunchCleanupTests {
    private func makeInstall() throws -> (defaults: UserDefaults, suite: String, storeURL: URL) {
        let suite = "MacRemoteTests.LaunchCleanup.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-launch-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (defaults, suite, directory.appendingPathComponent("tools.json"))
    }

    private func gitStatusTool(capability: ToolCapability) -> ToolDefinition {
        ToolDefinition(
            id: "developer_git_status",
            name: "Git Status",
            summary: "Show short Git status for a repository path.",
            executablePath: "/usr/bin/git",
            argumentPattern: ["-C", "{path}", "status", "--short"],
            parameters: [ToolParameter(name: "path", title: "Path", kind: .string)],
            capability: capability,
            timeoutSeconds: 10,
            outputByteLimit: 64 * 1024,
            origin: .userDefined
        )
    }

    /// Git runs programs named in a folder's settings, so the read-only Git
    /// tools from the 1.0 Library must not keep running unasked. The change
    /// is made once: an owner who sets the tool back keeps that choice.
    @MainActor
    @Test func gitToolsFromTheOldLibraryAskFirstOnce() throws {
        let install = try makeInstall()
        defer { install.defaults.removePersistentDomain(forName: install.suite) }
        try JSONEncoder().encode([gitStatusTool(capability: .readOnly)]).write(to: install.storeURL)

        let first = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))
        let updated = try #require(first.tools.first)
        #expect(updated.capability == .write)
        #expect(updated.asksBeforeRunning)
        // Still shared: the owner's agent keeps the tool and is asked instead.
        #expect(first.isToolExposed(updated))
        #expect(first.logs.contains { $0.message.contains("Git Status now asks before running") })

        // The owner relabels it in Tools; the next launch leaves it alone.
        try JSONEncoder().encode([gitStatusTool(capability: .readOnly)]).write(to: install.storeURL)
        install.defaults.removeObject(forKey: "MacRemote.knownToolFingerprints")
        let second = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))
        #expect(second.tools.first?.capability == .readOnly)
    }

    /// SPEC D88: a saved Flexible Command for one of the six retired CLIs lost
    /// the argument rules that limited it, so an Always Allow granted before
    /// must stop applying. The tool keeps its id, command, and sharing; a
    /// Flexible Command for a CLI that lost nothing keeps its grant; and an
    /// Always Allow the owner grants again survives the next launch.
    @MainActor
    @Test func flexibleCommandThatLostItsRulesAsksAgainOnce() throws {
        let install = try makeInstall()
        defer { install.defaults.removePersistentDomain(forName: install.suite) }
        let bin = install.storeURL.deletingLastPathComponent()
        func flexible(_ executable: String) throws -> ToolDefinition {
            let path = bin.appendingPathComponent(executable).path
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            return ToolDefinition(
                id: "\(executable)_run",
                name: "\(executable) Flexible Command",
                summary: "Run exact arguments.",
                executablePath: path,
                argumentPattern: ["{args}"],
                parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
                capability: .destructive,
                timeoutSeconds: 10,
                outputByteLimit: 64 * 1024,
                origin: .userDefined,
                approvalPolicy: .everyCall
            )
        }
        let retired = try flexible("pocketctl")
        let kept = try flexible("rg")
        try JSONEncoder().encode([retired, kept]).write(to: install.storeURL)
        let grants = ClientToolPermissionStore(userDefaults: install.defaults)
        grants.setAllowed(true, clientTrustID: "trust-1", tools: [retired, kept])

        let first = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))
        let loaded = try #require(first.tools.first { $0.id == retired.id })
        #expect(loaded.executablePath == retired.executablePath)
        #expect(loaded.asksBeforeRunning)
        #expect(first.isToolExposed(loaded))
        // The approval gate reads this store: no grant, so the call asks.
        #expect(!ClientToolPermissionStore(userDefaults: install.defaults).isAllowed(clientTrustID: "trust-1", tool: loaded))
        #expect(ClientToolPermissionStore(userDefaults: install.defaults).isAllowed(clientTrustID: "trust-1", tool: kept))
        #expect(first.logs.contains { $0.message.contains("pocketctl Flexible Command now asks on every call") })

        ClientToolPermissionStore(userDefaults: install.defaults).setAllowed(true, clientTrustID: "trust-1", tool: loaded)
        let second = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))
        let reloaded = try #require(second.tools.first { $0.id == retired.id })
        #expect(ClientToolPermissionStore(userDefaults: install.defaults).isAllowed(clientTrustID: "trust-1", tool: reloaded))
    }

    /// A launch that cannot read tools.json must not use up the one-time
    /// cleanup: once the file reads again, the grant still goes.
    @MainActor
    @Test func unreadableToolsFileDoesNotUseUpTheCleanup() throws {
        let install = try makeInstall()
        defer { install.defaults.removePersistentDomain(forName: install.suite) }
        let path = install.storeURL.deletingLastPathComponent().appendingPathComponent("pocketctl").path
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        let retired = ToolDefinition(
            id: "pocketctl_run",
            name: "pocketctl Flexible Command",
            summary: "Run exact arguments.",
            executablePath: path,
            argumentPattern: ["{args}"],
            parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
            capability: .destructive,
            timeoutSeconds: 10,
            outputByteLimit: 64 * 1024,
            origin: .userDefined,
            approvalPolicy: .everyCall
        )
        let saved = try JSONEncoder().encode([retired])
        ClientToolPermissionStore(userDefaults: install.defaults).setAllowed(true, clientTrustID: "trust-1", tool: retired)

        try Data("not json".utf8).write(to: install.storeURL)
        let broken = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))
        #expect(broken.tools.allSatisfy { $0.id != retired.id })

        try saved.write(to: install.storeURL)
        let restored = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))
        let loaded = try #require(restored.tools.first { $0.id == retired.id })
        #expect(!ClientToolPermissionStore(userDefaults: install.defaults).isAllowed(clientTrustID: "trust-1", tool: loaded))
    }

    @MainActor
    @Test func filesLeftByBackgroundTasksAreRemoved() throws {
        let install = try makeInstall()
        defer { install.defaults.removePersistentDomain(forName: install.suite) }
        let folder = install.storeURL.deletingLastPathComponent()
        let tasks = folder.appendingPathComponent("Tasks/artifacts", isDirectory: true)
        let preferences = folder.appendingPathComponent("task-execution-preferences.json")
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: preferences)

        _ = makeTestAppModel(userDefaults: install.defaults, toolStore: ToolRegistryStore(fileURL: install.storeURL))

        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("Tasks").path))
        #expect(!FileManager.default.fileExists(atPath: preferences.path))
    }

    /// The saved tools can hold a bridged server's credentials.
    @Test func savedToolsAreReadableOnlyByTheOwner() throws {
        let install = try makeInstall()
        defer { install.defaults.removePersistentDomain(forName: install.suite) }

        try ToolRegistryStore(fileURL: install.storeURL).saveUserDefinedTools([gitStatusTool(capability: .write)])

        let attributes = try FileManager.default.attributesOfItem(atPath: install.storeURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
}
