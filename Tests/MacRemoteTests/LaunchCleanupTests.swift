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
