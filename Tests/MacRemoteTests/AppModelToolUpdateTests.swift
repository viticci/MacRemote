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

/// One-time catalog category reconciliation: preset-derived tools carry
/// random ids, so stale categories (tools added before a preset moved to
/// AI & Agents) are matched by name + executable basename.
struct CatalogCategoryMigrationTests {
    @Test func staleCategoriesFollowTheCatalogWithoutTouchingOthers() throws {
        let claudePath = "/Users/viticci/.local/bin/claude"
        let codexPath = "/Users/viticci/.local/bin/codex"
        let presets = [
            AppModel.CatalogCategoryReference(name: "Claude Code", executablePath: claudePath, category: .ai),
            AppModel.CatalogCategoryReference(name: "Codex CLI", executablePath: codexPath, category: .ai),
            AppModel.CatalogCategoryReference(name: "Git Status", executablePath: "/usr/bin/git", category: .developer)
        ]

        // Exact name + full path as the preset → a genuine catalog-derived tool.
        let staleClaude = try makeTool(id: "custom.1", name: "Claude Code", executablePath: claudePath, category: .developer)
        // Right name, but a DIFFERENT binary of the same basename → must NOT flip
        // (this is the safety guard: full path, not basename).
        let otherClaude = try makeTool(id: "custom.5", name: "Claude Code", executablePath: "/opt/impostor/bin/claude", category: .developer)
        let correctCodex = try makeTool(id: "custom.2", name: "Codex CLI", executablePath: codexPath, category: .ai)
        let unrelated = try makeTool(id: "custom.3", name: "My Claude Wrapper", executablePath: claudePath, category: .developer)
        let gitStatus = try makeTool(id: "custom.4", name: "Git Status", executablePath: "/usr/bin/git", category: .developer)

        let updates = AppModel.staleCatalogCategoryUpdates(
            tools: [staleClaude, otherClaude, correctCodex, unrelated, gitStatus],
            presets: presets
        )

        // Only the exact name+path match flips; the same-basename impostor,
        // already-correct, renamed, and same-category tools are untouched.
        #expect(updates == ["custom.1": .ai])
    }

    private func makeTool(id: String, name: String, executablePath: String, category: ToolCategory) throws -> ToolDefinition {
        // Construct directly (not via draft.makeTool) so the fixture doesn't
        // require the executable to exist on the test machine — the migration
        // logic operates purely on the persisted name + path.
        ToolDefinition(
            id: id,
            name: name,
            summary: "Test tool",
            executablePath: executablePath,
            argumentPattern: ["{args}"],
            parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            category: category
        )
    }
}

/// Imported-server rows only spin for a real matching candidate — comparing
/// optionals directly read `nil == nil` as importing, so servers whose
/// original config disappeared showed "Importing tools…" forever.
struct LocalMCPImportSpinnerTests {
    @MainActor
    @Test func missingCandidateNeverReadsAsImporting() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.localMCPWorkingServerID == nil)
        #expect(!model.isImportingLocalMCPServer(candidateID: nil))

        model.localMCPWorkingServerID = "server-a"
        #expect(!model.isImportingLocalMCPServer(candidateID: nil))
        #expect(!model.isImportingLocalMCPServer(candidateID: "server-b"))
        #expect(model.isImportingLocalMCPServer(candidateID: "server-a"))
    }
}

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
