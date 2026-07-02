import Foundation
import Testing
@testable import MacRemote

/// The FDA fixer's quit-and-reopen flow: one automatic relaunch per session,
/// only after the user has already seen a Required (or helper-opened) result,
/// and a sheet identity that stays stable while the prompt is up.
struct FullDiskAccessFlowTests {
    @MainActor
    @Test func autoRelaunchFiresOnlyAfterRequiredOrHelperOpenedStates() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)

        #expect(model.shouldAutoRelaunchForFullDiskAccess(previousState: .required))
        #expect(model.shouldAutoRelaunchForFullDiskAccess(previousState: .helperOpened))
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .unknown))
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .checking))
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .ready))
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .confirmationRequired))
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .failed("boom")))
    }

    @MainActor
    @Test func pendingRelaunchMarkerIsConsumedAndBlocksASecondAutoRelaunch() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        defaults.set(true, forKey: "MacRemote.fullDiskAccessRelaunchPending")

        let model = try makeIsolatedAppModel(userDefaults: defaults)

        // The relaunched instance consumes the marker so a crash loop is
        // impossible, and it refuses a second automatic relaunch this session.
        #expect(defaults.object(forKey: "MacRemote.fullDiskAccessRelaunchPending") == nil)
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .required))
        #expect(!model.shouldAutoRelaunchForFullDiskAccess(previousState: .helperOpened))
    }

    @MainActor
    @Test func fullDiskAccessPromptKeepsItsIdentityWhilePresented() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)

        let serverURL = URL(string: "http://127.0.0.1:61234")!
        model.serverStatus = .running(serverURL)
        model.fullDiskAccessReport = FullDiskAccessReport(state: .required, detail: "needs access")

        // Adding FDA-requiring tools while the server runs presents the prompt.
        // A bulk import adds many tools back to back; the sheet identity must
        // not change per tool or the sheet dismisses and re-opens repeatedly.
        #expect(model.addUserTool(from: makeFDADraft(name: "First FDA Tool")) == nil)
        let first = try #require(model.fullDiskAccessPrompt)

        #expect(model.addUserTool(from: makeFDADraft(name: "Second FDA Tool")) == nil)
        let second = try #require(model.fullDiskAccessPrompt)
        #expect(first.id == second.id)

        // Once dismissed, the next trigger may present a fresh prompt.
        model.dismissFullDiskAccessPrompt()
        #expect(model.addUserTool(from: makeFDADraft(name: "Third FDA Tool")) == nil)
        let third = try #require(model.fullDiskAccessPrompt)
        #expect(third.id != second.id)
    }
}

private func makeFDADraft(name: String) -> ToolDefinitionDraft {
    var draft = ToolDefinitionDraft()
    draft.name = name
    draft.summary = "Reads protected data for tests."
    draft.executablePath = "/bin/echo"
    draft.requiresFullDiskAccess = true
    return draft
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
