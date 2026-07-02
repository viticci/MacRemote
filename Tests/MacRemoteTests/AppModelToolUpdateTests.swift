import Foundation
import Testing
@testable import MacRemote

/// D8: `updateUserTool(id:draft:)` must preserve the tool ID and its Always
/// Allow allowances, and roll everything back on failure.
struct AppModelToolUpdateTests {
    @MainActor
    @Test func updateEditsInPlacePreservingIDAndAlwaysAllowances() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.addUserTool(from: makeDraft(name: "Echo")) == nil)
        let toolID = try #require(model.tools.first?.id)
        model.setToolAlwaysAllowed(true, toolID: toolID, clientID: "client-1")
        #expect(model.isToolAlwaysAllowed(toolID: toolID, clientID: "client-1"))

        var draft = makeDraft(name: "Echo Two")
        draft.argumentsText = "hello\nworld"
        draft.capability = .write
        #expect(model.updateUserTool(id: toolID, draft: draft) == nil)

        #expect(model.tools.count == 1)
        let updated = try #require(model.tools.first)
        #expect(updated.id == toolID)
        #expect(updated.name == "Echo Two")
        #expect(updated.argumentPattern == ["hello", "world"])
        #expect(updated.capability == .write)
        #expect(model.isToolAlwaysAllowed(toolID: toolID, clientID: "client-1"))

        let persisted = try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools()
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == toolID)
        #expect(persisted.first?.name == "Echo Two")
    }

    @MainActor
    @Test func updateRollsBackOnValidationFailure() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.addUserTool(from: makeDraft(name: "Echo")) == nil)
        let toolID = try #require(model.tools.first?.id)
        model.setToolAlwaysAllowed(true, toolID: toolID, clientID: "client-1")

        var invalidDraft = makeDraft(name: "")
        invalidDraft.argumentsText = "hello"
        let error = model.updateUserTool(id: toolID, draft: invalidDraft)

        #expect(error != nil)
        #expect(model.tools.count == 1)
        #expect(model.tools.first?.id == toolID)
        #expect(model.tools.first?.name == "Echo")
        #expect(model.isToolAlwaysAllowed(toolID: toolID, clientID: "client-1"))

        let persisted = try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools()
        #expect(persisted.first?.name == "Echo")
    }

    @MainActor
    @Test func updateRollsBackOnPersistenceFailure() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }

        // A file where the store expects a directory makes every save throw.
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let blockerFile = temporaryDirectory.appendingPathComponent("blocker")
        try Data().write(to: blockerFile)
        let blockedStore = ToolRegistryStore(
            fileURL: blockerFile.appendingPathComponent("sub").appendingPathComponent("tools.json")
        )

        let model = AppModel(userDefaults: defaults, toolStore: blockedStore)
        let original = try makeDraft(name: "Echo").makeTool(id: "custom.fixed")
        model.tools = [original]
        model.setToolAlwaysAllowed(true, toolID: original.id, clientID: "client-1")

        var draft = makeDraft(name: "Echo Two")
        draft.argumentsText = "changed"
        let error = model.updateUserTool(id: original.id, draft: draft)

        #expect(error != nil)
        #expect(model.tools.count == 1)
        #expect(model.tools.first?.id == original.id)
        #expect(model.tools.first?.name == "Echo")
        #expect(model.tools.first?.argumentPattern == ["hello"])
        #expect(model.isToolAlwaysAllowed(toolID: original.id, clientID: "client-1"))
    }

    @MainActor
    @Test func updateRejectsBuiltInAndUnknownTools() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        model.tools = RemCTLToolCatalog.builtInTools
        let builtInID = try #require(model.tools.first?.id)
        #expect(model.updateUserTool(id: builtInID, draft: makeDraft(name: "Hijack")) == "Built-in tools can't be edited.")
        #expect(model.tools.first?.name != "Hijack")

        #expect(model.updateUserTool(id: "custom.missing", draft: makeDraft(name: "Ghost")) == "Unknown tool.")
    }

    @MainActor
    @Test func updateKeepsNotSharedState() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.addUserTool(from: makeDraft(name: "Echo")) == nil)
        let toolID = try #require(model.tools.first?.id)
        #expect(model.setToolEnabled(id: toolID, enabled: false) == nil)
        #expect(model.disabledToolIDs.contains(toolID))

        #expect(model.updateUserTool(id: toolID, draft: makeDraft(name: "Echo Two")) == nil)

        #expect(model.disabledToolIDs.contains(toolID))
        #expect(model.tools.first?.name == "Echo Two")
    }

    @MainActor
    @Test func updateDisablesToolWhenFullDiskAccessIsMissingWhileServerRuns() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.addUserTool(from: makeDraft(name: "Echo")) == nil)
        let toolID = try #require(model.tools.first?.id)
        model.serverStatus = .running(URL(string: "http://127.0.0.1:61234")!)
        model.fullDiskAccessReport = FullDiskAccessReport(state: .required, detail: "required")

        var draft = makeDraft(name: "Echo FDA")
        draft.requiresFullDiskAccess = true
        #expect(model.updateUserTool(id: toolID, draft: draft) == nil)

        #expect(model.disabledToolIDs.contains(toolID))
        #expect(model.fullDiskAccessPrompt != nil)
        #expect(model.tools.first?.permissionRequirements.contains(.fullDiskAccess) == true)
    }
}

// MARK: - Helpers

private struct ToolUpdateContext {
    let model: AppModel
    let storeURL: URL
    let defaults: UserDefaults

    func tearDown() {
        defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults))
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }
}

@MainActor
private func makeToolUpdateContext() throws -> ToolUpdateContext {
    let defaults = try makeIsolatedToolUpdateDefaults()
    let storeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("tools.json")
    let model = AppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))
    return ToolUpdateContext(model: model, storeURL: storeURL, defaults: defaults)
}

private func makeDraft(name: String) -> ToolDefinitionDraft {
    var draft = ToolDefinitionDraft()
    draft.mode = .commandTemplate
    draft.name = name
    draft.summary = "Test tool"
    draft.executablePath = "/bin/echo"
    draft.argumentsText = "hello"
    draft.capability = .readOnly
    return draft
}

private func makeIsolatedToolUpdateDefaults() throws -> UserDefaults {
    let suiteName = "MacRemoteToolUpdateTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "MacRemoteToolUpdateTests", code: 1)
    }
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(suiteName, forKey: "MacRemoteTests.suiteName")
    return defaults
}

private func toolUpdateSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}
