import Foundation
import Observation
import Testing
@testable import MacRemote

/// D8: `updateUserTool(id:draft:)` preserves semantic identity and keeps an
/// Always Allow grant only while the approved security contract is unchanged.
/// Every failure must still roll the complete edit back.
struct AppModelToolUpdateTests {
    /// "Shared" belongs to the exact tool the owner last saw in the app. A
    /// row written into the saved tools file by anything else must not start
    /// shared, or one write to that file would hand an app an unasked tool.
    @MainActor
    @Test func toolsAddedOrChangedOutsideTheAppStartNotShared() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let known = try makeDraft(name: "Known Tool").makeTool(id: "custom_known")
        try JSONEncoder().encode([known]).write(to: storeURL)

        // First launch: the owner's existing tool is adopted and stays shared.
        let first = makeTestAppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))
        #expect(first.isToolExposed(known))

        // Something else rewrites the file: the known tool now runs a different
        // program, and a new read-only tool appears.
        let swapped = ToolDefinition(
            id: known.id,
            permissionEpoch: known.permissionEpoch,
            name: known.name,
            summary: known.summary,
            executablePath: "/usr/bin/osascript",
            argumentPattern: known.argumentPattern,
            parameters: known.parameters,
            capability: known.capability,
            timeoutSeconds: known.timeoutSeconds,
            outputByteLimit: known.outputByteLimit,
            origin: .userDefined
        )
        let planted = ToolDefinition(
            id: "custom_planted",
            name: "Planted Tool",
            summary: "Was never added in the app.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        try JSONEncoder().encode([swapped, planted]).write(to: storeURL)

        let second = makeTestAppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))
        #expect(second.tools.count == 2)
        #expect(second.tools.allSatisfy { !second.isToolExposed($0) })
        #expect(second.toolSurfaceRuntime.toolsSnapshot().isEmpty)
        #expect(second.logs.contains { $0.message.contains("outside MacRemote") })

        // Sharing one again in the app is remembered: it survives a relaunch.
        #expect(second.setToolEnabled(id: planted.id, enabled: true) == nil)
        let third = makeTestAppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))
        #expect(third.isToolExposed(planted))
        #expect(!third.isToolExposed(swapped))
    }

    /// The Not Shared list lives in preferences. If they are gone, nothing
    /// says which tools the owner had turned off, so none are shared.
    @MainActor
    @Test func savedToolsStartNotSharedWhenPreferencesWereReset() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = try makeDraft(name: "Saved Tool").makeTool(id: "custom_saved")
        try JSONEncoder().encode([tool]).write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL),
            preferencesWereReset: true
        )
        #expect(model.tools.map(\.id) == [tool.id])
        #expect(!model.isToolExposed(tool))
    }

    @MainActor
    @Test func startupRetainsMissingExecutableShareStateAndPreservesItUntilDelete() async throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let valid = try makeDraft(name: "Working Tool").makeTool(id: "custom_working")
        let missingPath = directory.appendingPathComponent("uninstalled-cli").path
        let invalid = ToolDefinition(
            id: "custom_unavailable",
            name: "Unavailable Tool",
            summary: "Its executable was removed.",
            executablePath: missingPath,
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        try JSONEncoder().encode([valid, invalid]).write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.tools.map(\.id) == [valid.id, invalid.id])
        #expect(model.isToolExposed(valid))
        #expect(model.isToolExposed(invalid))
        #expect(model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == valid.id })
        #expect(model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == invalid.id })
        #expect(model.logs.contains {
            $0.message == "Unavailable Tool: executable no longer found at \(missingPath)"
        })
        await #expect(throws: ToolValidationError.executableUnavailable(missingPath)) {
            try await model.toolSurfaceRuntime.execute(toolID: invalid.id)
        }

        // A missing tool keeps its prior state, but once explicitly stopped it
        // cannot be shared again until its executable is repaired.
        #expect(model.setToolEnabled(id: invalid.id, enabled: false) == nil)
        let enableError = try #require(model.setToolEnabled(id: invalid.id, enabled: true))
        #expect(enableError.contains("not installed or is no longer available"))
        #expect(enableError.contains(missingPath) == false)
        #expect(!model.isToolExposed(invalid))

        // An unrelated save must keep the unavailable row instead of erasing it.
        #expect(model.addUserTool(from: makeDraft(name: "Another Tool")) == nil)
        let afterUnrelatedSave = try JSONDecoder().decode(
            [ToolDefinition].self,
            from: Data(contentsOf: storeURL)
        )
        #expect(afterUnrelatedSave.contains { $0.id == invalid.id })

        #expect(model.deleteUserTool(id: invalid.id) == nil)
        #expect(model.tools.contains { $0.id == invalid.id } == false)
        let afterDelete = try ToolRegistryStore(fileURL: storeURL).loadUserDefinedTools()
        #expect(afterDelete.contains { $0.id == valid.id })
        #expect(afterDelete.contains { $0.id == invalid.id } == false)
    }

    @MainActor
    @Test func startupQuarantinesStructuralValidationFailureWithoutHidingValidTool() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let valid = try makeDraft(name: "Working Tool").makeTool(id: "custom_working")
        let invalid = ToolDefinition(
            id: "custom_invalid_timeout",
            name: "Invalid Timeout",
            summary: "Structurally invalid saved tool.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 0,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        try JSONEncoder().encode([valid, invalid]).write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.isToolExposed(valid))
        #expect(!model.isToolExposed(invalid))
        #expect(model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == valid.id })
        #expect(!model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == invalid.id })
        #expect(model.logs.contains {
            $0.message == "Kept saved tool Invalid Timeout Not Shared: Timeout must be between 1 second and 24 hours."
        })
    }

    @MainActor
    @Test func undecodableRowLoadsValidToolsAndBlocksAddWithoutChangingBytes() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let valid = try makeDraft(name: "Working Tool").makeTool(id: "custom_working")
        let originalData = try registryDataIncludingBrokenRow([valid])
        try originalData.write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.tools == [valid])
        #expect(model.isToolExposed(valid))
        #expect(model.logs.contains { $0.message.contains("row 2") && $0.message.contains("blocked") })
        let addError = try #require(model.addUserTool(from: makeDraft(name: "Must Roll Back")))
        #expect(addError.contains("blocked to preserve tools.json"))
        #expect(model.tools == [valid])
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @MainActor
    @Test func undecodableRowKeepsLegacyIdentifierNotSharedWithoutRewriting() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let legacy = try makeDraft(name: "Legacy Tool").makeTool(id: "custom.legacy")
        let originalData = try registryDataIncludingBrokenRow([legacy])
        try originalData.write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.tools == [legacy])
        #expect(!model.isToolExposed(legacy))
        #expect(!model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == legacy.id })
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @MainActor
    @Test func undecodableRowClaimingDecodedSemanticIDFailsClosed() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let valid = try makeDraft(name: "Today").makeTool(id: "remctl_today")
        let validJSON = try #require(String(data: JSONEncoder().encode(valid), encoding: .utf8))
        let originalData = Data("[\(validJSON),{\"id\":\"remctl_today\",\"name\":\"Unreadable\"}]".utf8)
        try originalData.write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.tools == [valid])
        #expect(!model.isToolExposed(valid))
        #expect(!model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == valid.id })
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @MainActor
    @Test func userToolCollidingWithBuiltinFailsClosedAndExecutorDoesNotTrap() async throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let colliding = try makeDraft(name: "Fake Filesystem Stat").makeTool(id: "filesystem_stat")
        try JSONEncoder().encode([colliding]).write(to: storeURL)
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(!model.isToolExposed(colliding))
        #expect(model.toolSurfaceRuntime.toolsSnapshot().allSatisfy { $0.id != colliding.id })
        #expect(model.logs.contains { $0.message.contains("duplicate or invalid IDs: filesystem_stat") })

        let executor = ConfiguredToolExecutor(
            tools: model.allTools,
            environment: ExecutableLocator.toolEnvironment
        )
        await #expect(throws: ToolIdentifierError.duplicate("filesystem_stat")) {
            try await executor.execute(toolID: "filesystem_stat")
        }
    }

    @MainActor
    @Test func duplicateOrInvalidSavedIDsFailClosedAndBlockAddWithoutChangingBytes() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let valid = try makeDraft(name: "Working Tool").makeTool(id: "custom_working")
        let invalid = try makeDraft(name: "Dotted ID").makeTool(id: "custom.dotted")
        let firstTwin = try makeDraft(name: "First Twin").makeTool(id: "custom_twin")
        let secondTwin = try makeDraft(name: "Second Twin").makeTool(id: "custom_twin")
        let originalData = try JSONEncoder().encode([valid, invalid, firstTwin, secondTwin])
        try originalData.write(to: storeURL)

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.tools == [valid, invalid, firstTwin, secondTwin])
        #expect(model.isToolExposed(valid))
        #expect(!model.isToolExposed(invalid))
        #expect(!model.isToolExposed(firstTwin))
        #expect(model.toolSurfaceRuntime.toolsSnapshot().allSatisfy {
            $0.id != invalid.id && $0.id != firstTwin.id
        })
        #expect(model.logs.contains {
            $0.message.contains("duplicate or invalid IDs: custom.dotted, custom_twin")
        })
        let addError = try #require(model.addUserTool(from: makeDraft(name: "Must Roll Back")))
        #expect(addError.contains("blocked to preserve tools.json"))
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @MainActor
    @Test func unreadableTopLevelBlocksAddWithoutChangingBytes() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let originalData = Data("{\"not\":\"a tool array\"}\n".utf8)
        try originalData.write(to: storeURL)
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )

        #expect(model.tools.isEmpty)
        #expect(model.logs.contains { $0.message.contains("blocked to preserve tools.json") })
        #expect(model.addUserTool(from: makeDraft(name: "Must Roll Back")) != nil)
        #expect(model.tools.isEmpty)
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @MainActor
    @Test func groupEnableValidatesBridgeToolsBeforeExposure() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        let serverURL = "http://127.0.0.1:49001/mcp"
        let validBridge = makeHTTPBridgeTool(
            id: "mcp_valid",
            name: "Valid Bridge",
            serverURL: serverURL
        )
        let invalidBridge = makeHTTPBridgeTool(
            id: "mcp_invalid",
            name: "Invalid Bridge",
            serverURL: serverURL,
            timeoutSeconds: 0
        )
        model.tools = [validBridge, invalidBridge]
        model.disabledToolIDs = [validBridge.id, invalidBridge.id]

        let bridgeIdentity = try #require(validBridge.mcpBridgeIdentity)
        let bridgeError = try #require(
            model.setLocalMCPBridgeServerEnabled(
                bridgeIdentity: bridgeIdentity,
                enabled: true
            )
        )
        #expect(bridgeError.contains("Timeout must be between"))
        #expect(model.isToolExposed(validBridge))
        #expect(!model.isToolExposed(invalidBridge))
        #expect(model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == validBridge.id })
        #expect(!model.toolSurfaceRuntime.toolsSnapshot().contains { $0.id == invalidBridge.id })
    }

    @MainActor
    @Test func deleteRollsBackOrderExposureProvenanceInvalidStateAndAllowance() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let first = try makeDraft(name: "First").makeTool(id: "custom_first")
        let invalid = ToolDefinition(
            id: "custom_invalid",
            name: "Invalid",
            summary: "Invalid timeout.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 0,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        let third = try makeDraft(name: "Third").makeTool(id: "custom_third")
        let originalData = try registryDataIncludingBrokenRow([first, invalid, third])
        try originalData.write(to: storeURL)
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )
        connectTestClient(model)
        model.provenanceIdentityChanges[invalid.id] = "unsigned"
        let updateDate = Date(timeIntervalSince1970: 1234)
        model.provenanceContentUpdates[invalid.id] = updateDate
        model.setToolAlwaysAllowed(true, toolID: invalid.id, clientID: "client-1")
        let originalDisabled = model.disabledToolIDs
        let originalInvalid = model.invalidSavedToolIDs

        #expect(model.deleteUserTool(id: invalid.id) != nil)

        #expect(model.tools.map(\.id) == [first.id, invalid.id, third.id])
        #expect(model.disabledToolIDs == originalDisabled)
        #expect(model.provenanceIdentityChanges[invalid.id] != nil)
        #expect(model.provenanceContentUpdates[invalid.id] == updateDate)
        #expect(model.invalidSavedToolIDs == originalInvalid)
        #expect(model.isToolAlwaysAllowed(toolID: invalid.id, clientID: "client-1"))
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    /// Uninstalling one CLI while MacRemote runs must not block saving the
    /// others. A save checks only the rows it adds or edits.
    @MainActor
    @Test func toolWhoseProgramDisappearsDoesNotBlockUnrelatedSaves() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let directory = context.storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let program = directory.appendingPathComponent("soon-gone")
        try Data("#!/bin/echo\n".utf8).write(to: program)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        var goneDraft = makeDraft(name: "Soon Gone")
        goneDraft.executablePath = program.path
        #expect(model.addUserTool(from: goneDraft) == nil)
        let gone = try #require(model.tools.first)
        try FileManager.default.removeItem(at: program)

        #expect(model.addUserTool(from: makeDraft(name: "Unrelated")) == nil)

        let saved = try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedToolsReport().tools
        #expect(saved.map(\.name) == ["Soon Gone", "Unrelated"])
        // Editing the tool whose program is gone is still checked.
        var renamed = ToolDefinitionDraft(tool: gone)
        renamed.name = "Renamed"
        #expect(model.updateUserTool(id: gone.id, draft: renamed) != nil)
    }

    @MainActor
    @Test func bridgeReplacementValidatesInputAndDefersAllowanceRemovalUntilSave() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let serverURL = "http://127.0.0.1:49002/mcp"
        let existing = makeHTTPBridgeTool(
            id: "mcp_existing",
            name: "Existing",
            serverURL: serverURL,
            timeoutSeconds: 0
        )
        let originalData = try registryDataIncludingBrokenRow([existing])
        try originalData.write(to: storeURL)
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )
        connectTestClient(model)
        model.setToolAlwaysAllowed(true, toolID: existing.id, clientID: "client-1")
        let identity = try #require(existing.mcpBridgeIdentity)

        let invalidIncoming = makeHTTPBridgeTool(
            id: "mcp_incoming_invalid",
            name: "Incoming Invalid",
            serverURL: serverURL,
            timeoutSeconds: 0
        )
        #expect(throws: ToolValidationError.invalidTimeout) {
            try model.replaceLocalMCPBridgeTools([invalidIncoming], bridgeIdentity: identity)
        }
        #expect(model.tools == [existing])

        let validIncoming = makeHTTPBridgeTool(
            id: "mcp_incoming_valid",
            name: "Incoming Valid",
            serverURL: serverURL
        )
        #expect(throws: (any Error).self) {
            try model.replaceLocalMCPBridgeTools([validIncoming], bridgeIdentity: identity)
        }
        #expect(model.tools == [existing])
        #expect(model.invalidSavedToolIDs.contains(existing.id))
        #expect(model.isToolAlwaysAllowed(toolID: existing.id, clientID: "client-1"))
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @MainActor
    @Test func sameDisplayNameDifferentServerIdentityDoesNotReplaceExistingBridge() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let first = makeHTTPBridgeTool(
            id: "shared_server_find",
            name: "Shared Server: Find",
            serverURL: "http://127.0.0.1:41001/mcp",
            serverIdentity: "claude_code.shared.project_a",
            serverName: "Shared Server",
            upstreamToolName: "find"
        )
        model.tools = [first]
        model.disabledToolIDs = []

        let second = makeHTTPBridgeTool(
            id: "shared_server_find_2",
            name: "Shared Server: Find",
            serverURL: "http://127.0.0.1:41002/mcp",
            serverIdentity: "claude_code.shared.project_b",
            serverName: "Shared Server",
            upstreamToolName: "find"
        )
        let replaced = try model.replaceLocalMCPBridgeTools(
            [second],
            bridgeIdentity: second.mcpBridgeIdentity
        )

        #expect(replaced.replacedCount == 0)
        #expect(Set(model.tools.map(\.id)) == [first.id, second.id])
        #expect(Set(model.tools.compactMap(\.mcpBridgeServerIdentity)) == [
            "claude_code.shared.project_a", "claude_code.shared.project_b"
        ])
    }

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
        draft.summary = "Cosmetic copy changed."
        #expect(model.updateUserTool(id: toolID, draft: draft) == nil)

        #expect(model.tools.count == 1)
        let updated = try #require(model.tools.first)
        #expect(updated.id == toolID)
        #expect(updated.name == "Echo Two")
        #expect(updated.argumentPattern == ["hello"])
        #expect(updated.capability == .readOnly)
        #expect(model.isToolAlwaysAllowed(toolID: toolID, clientID: "client-1"))

        let persisted = try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools()
        #expect(persisted.count == 1)
        #expect(persisted.first?.id == toolID)
        #expect(persisted.first?.name == "Echo Two")
    }

    @MainActor
    @Test func updateSecurityContractRequiresFreshAlwaysAllowApproval() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.addUserTool(from: makeDraft(name: "Echo")) == nil)
        let original = try #require(model.tools.first)
        model.setToolAlwaysAllowed(true, toolID: original.id, clientID: "client-1")
        #expect(model.isToolAlwaysAllowed(toolID: original.id, clientID: "client-1"))

        var changed = makeDraft(name: "Echo")
        changed.argumentsText = "different"
        changed.capability = .write
        #expect(model.updateUserTool(id: original.id, draft: changed) == nil)

        let updated = try #require(model.tools.first)
        #expect(updated.id == original.id)
        #expect(updated.permissionEpoch == original.permissionEpoch)
        #expect(updated.securityFingerprint != original.securityFingerprint)
        #expect(!model.isToolAlwaysAllowed(toolID: updated.id, clientID: "client-1"))
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

        let model = makeTestAppModel(userDefaults: defaults, toolStore: blockedStore)
        connectTestClient(model)
        let original = try makeDraft(name: "Echo").makeTool(id: "custom_fixed")
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

        model.tools = FileTransferToolCatalog.builtInTools
        let builtInID = try #require(model.tools.first?.id)
        #expect(model.updateUserTool(id: builtInID, draft: makeDraft(name: "Hijack")) == "Built-in tools can't be edited.")
        #expect(model.tools.first?.name != "Hijack")

        #expect(model.updateUserTool(id: "custom_missing", draft: makeDraft(name: "Ghost")) == "Unknown tool.")
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

    @MainActor
    @Test func catalogUpdateRestoresDefinitionWithoutChangingIdentitySharingOrAllowance() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let preset = try #require(
            DefaultToolPresetCatalog.preset(id: "preset.utilities.current_date")
        )

        #expect(model.addUserTools(from: [preset], sourceName: "Date") == nil)
        let original = try #require(model.tools.first { $0.id == preset.toolID })
        model.setToolAlwaysAllowed(true, toolID: original.id, clientID: "client-1")
        #expect(model.setToolEnabled(id: original.id, enabled: false) == nil)

        var staleDraft = ToolDefinitionDraft(tool: original)
        staleDraft.summary = "Old catalog copy."
        #expect(model.updateUserTool(id: original.id, draft: staleDraft) == nil)
        #expect(model.isCatalogUpdateAvailable(for: try #require(model.tool(id: original.id))))

        #expect(model.updateUserToolFromCatalog(id: original.id) == nil)
        let updated = try #require(model.tool(id: original.id))
        let expected = try preset.draft.makeTool(
            id: original.id,
            permissionEpoch: original.permissionEpoch
        )
        #expect(updated == expected)
        #expect(updated.permissionEpoch == original.permissionEpoch)
        #expect(model.disabledToolIDs.contains(updated.id))
        #expect(model.isToolAlwaysAllowed(toolID: updated.id, clientID: "client-1"))
        #expect(!model.isCatalogUpdateAvailable(for: updated))

        let persisted = try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools()
        #expect(persisted == [updated])
    }

    /// The Tools page reads catalog update state on every render, so AppModel
    /// caches it. The cache must follow every change to `tools`.
    @MainActor
    @Test func cachedCatalogUpdateStateFollowsToolChanges() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let preset = try #require(
            DefaultToolPresetCatalog.preset(id: "preset.utilities.current_date")
        )

        #expect(model.addUserTools(from: [preset], sourceName: "Date") == nil)
        let original = try #require(model.tool(id: preset.toolID))
        // Read first, so a cached answer exists before the tools change.
        #expect(!model.isCatalogUpdateAvailable(for: original))
        let countBefore = model.wholeCatalogUpdateCount
        #expect(countBefore == model.catalogUpdateCount())

        var staleDraft = ToolDefinitionDraft(tool: original)
        staleDraft.summary = "Old catalog copy."
        #expect(model.updateUserTool(id: original.id, draft: staleDraft) == nil)

        let stale = try #require(model.tool(id: original.id))
        #expect(model.isCatalogUpdateAvailable(for: stale))
        #expect(model.wholeCatalogUpdateCount == model.catalogUpdateCount())
        #expect(model.wholeCatalogUpdateCount == countBefore + 1)

        #expect(model.updateUserToolFromCatalog(id: original.id) == nil)
        #expect(!model.isCatalogUpdateAvailable(for: try #require(model.tool(id: original.id))))
        #expect(model.wholeCatalogUpdateCount == countBefore)
    }

    @MainActor
    @Test func catalogSecurityUpdateRequiresFreshAlwaysAllowApproval() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let preset = try #require(
            DefaultToolPresetCatalog.preset(id: "preset.utilities.current_date")
        )

        #expect(model.addUserTools(from: [preset], sourceName: "Date") == nil)
        let original = try #require(model.tools.first { $0.id == preset.toolID })
        var staleDraft = ToolDefinitionDraft(tool: original)
        staleDraft.argumentsText = "+%s"
        #expect(model.updateUserTool(id: original.id, draft: staleDraft) == nil)
        let stale = try #require(model.tool(id: original.id))
        model.setToolAlwaysAllowed(true, toolID: stale.id, clientID: "client-1")
        #expect(model.isToolAlwaysAllowed(toolID: stale.id, clientID: "client-1"))

        #expect(model.updateUserToolsFromCatalog([preset], sourceName: "Date") == nil)
        let updated = try #require(model.tool(id: original.id))
        #expect(updated.argumentPattern == preset.argumentPattern)
        #expect(updated.permissionEpoch == original.permissionEpoch)
        #expect(updated.securityFingerprint != stale.securityFingerprint)
        #expect(!model.isToolAlwaysAllowed(toolID: updated.id, clientID: "client-1"))
    }

    /// D49: the every-call mark sets the default and buys the consent copy; it
    /// no longer refuses the owner's explicit grant.
    @MainActor
    @Test func everyCallToolAcceptsExplicitAlwaysAllowGrant() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        var draft = makeDraft(name: "Always Ask")
        draft.capability = .destructive
        draft.approvalPolicy = .everyCall
        let tool = try draft.makeTool(id: "custom_always_ask")
        model.tools = [tool]

        model.setToolAlwaysAllowed(true, toolID: tool.id, clientID: "client-1")

        #expect(model.isToolAlwaysAllowed(toolID: tool.id, clientID: "client-1"))
        #expect(model.alwaysAllowedToolIDs(for: "client-1").contains(tool.id))
        // The Activity record still says which kind of grant this was.
        #expect(model.logs.contains {
            $0.message.contains("this tool asks every time by default")
        })
    }

    /// Turning the same switch back off is the whole opt-back-in story.
    @MainActor
    @Test func revokingEveryCallGrantRestoresAsking() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        var draft = makeDraft(name: "Always Ask")
        draft.capability = .destructive
        draft.approvalPolicy = .everyCall
        let tool = try draft.makeTool(id: "custom_always_ask")
        model.tools = [tool]

        model.setToolAlwaysAllowed(true, toolID: tool.id, clientID: "client-1")
        #expect(model.isToolAlwaysAllowed(toolID: tool.id, clientID: "client-1"))

        model.setToolAlwaysAllowed(false, toolID: tool.id, clientID: "client-1")
        #expect(!model.isToolAlwaysAllowed(toolID: tool.id, clientID: "client-1"))
        #expect(!model.alwaysAllowedToolIDs(for: "client-1").contains(tool.id))
    }

    /// The Apps counts redraw only when what they read is observed. Flipping a
    /// switch must invalidate them at once, not on the next 30-second refresh.
    @MainActor
    @Test func alwaysAllowReadsRedrawWhenAGrantChanges() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        var draft = makeDraft(name: "Ordinary")
        draft.capability = .write
        let tool = try draft.makeTool(id: "custom_ordinary")
        model.tools = [tool]

        let redrawn = ObservationFlag()
        withObservationTracking {
            _ = model.isToolAlwaysAllowed(toolID: tool.id, clientID: "client-1")
            _ = model.alwaysAllowedToolIDs(for: "client-1")
        } onChange: {
            redrawn.isSet = true
        }
        model.setToolAlwaysAllowed(true, toolID: tool.id, clientID: "client-1")

        #expect(redrawn.isSet)
    }

    /// Revoke All in a category is one change: the grant store, which holds
    /// every app's grants, is written once rather than once per tool.
    @MainActor
    @Test func categoryRevokeWritesTheGrantStoreOnce() throws {
        let suiteName = "MacRemoteToolUpdateTests.\(UUID().uuidString)"
        let defaults = try #require(GrantWriteCountingDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }
        let model = makeTestAppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))
        connectTestClient(model)
        var draft = makeDraft(name: "Ordinary")
        draft.capability = .write
        let tools = try (1...3).map { try draft.makeTool(id: "custom_ordinary_\($0)") }
        model.tools = tools
        for tool in tools {
            model.setToolAlwaysAllowed(true, toolID: tool.id, clientID: "client-1")
        }
        defaults.grantWrites = 0

        model.setToolsAlwaysAllowed(false, toolIDs: tools.map(\.id), clientID: "client-1")

        #expect(defaults.grantWrites == 1)
        #expect(model.alwaysAllowedToolIDs(for: "client-1").isEmpty)
    }

    @MainActor
    @Test func allowAllCurrentToolsCoversEveryCallTools() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        var standardDraft = makeDraft(name: "Ordinary")
        standardDraft.capability = .write
        var everyCallDraft = makeDraft(name: "Always Ask")
        everyCallDraft.capability = .destructive
        everyCallDraft.approvalPolicy = .everyCall
        let standard = try standardDraft.makeTool(id: "custom_ordinary")
        let everyCall = try everyCallDraft.makeTool(id: "custom_always_ask")
        model.tools = [standard, everyCall]

        model.allowAllCurrentTools(for: "client-1")

        #expect(model.isToolAlwaysAllowed(toolID: standard.id, clientID: "client-1"))
        #expect(model.isToolAlwaysAllowed(toolID: everyCall.id, clientID: "client-1"))

        // The card's own arithmetic has to agree, or the badge lies again.
        let summary = model.toolPolicySummary(for: "client-1")
        #expect(summary.riskySharedCount == 1)
        #expect(summary.asksEveryTimeCount == 0)
        #expect(summary.allSharedToolsAllowed)
        #expect(summary.badgeText == "2/2 Always Allowed")
    }

    /// The grant format did not change, so an existing grant on an untouched
    /// tool keeps validating — that is what protects the 263 already on disk.
    @MainActor
    @Test func existingGrantSurvivesWhileTheToolContractIsUnchanged() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        var draft = makeDraft(name: "Ordinary")
        draft.capability = .write
        let tool = try draft.makeTool(id: "custom_ordinary")
        model.tools = [tool]
        model.setToolAlwaysAllowed(true, toolID: tool.id, clientID: "client-1")

        // A cosmetic edit leaves the security contract alone.
        var renamed = ToolDefinitionDraft(tool: tool)
        renamed.summary = "Same command, new sentence."
        #expect(model.updateUserTool(id: tool.id, draft: renamed) == nil)
        #expect(model.isToolAlwaysAllowed(toolID: tool.id, clientID: "client-1"))

        // Changing the argv does change it, and the grant stops applying.
        var retargeted = ToolDefinitionDraft(tool: try #require(model.tool(id: tool.id)))
        retargeted.argumentsText = "goodbye"
        #expect(model.updateUserTool(id: tool.id, draft: retargeted) == nil)
        #expect(!model.isToolAlwaysAllowed(toolID: tool.id, clientID: "client-1"))
    }

    @MainActor
    @Test func firstPartyBulkInstallKeepsFlexibleEscapeHatchNotShared() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let presets = DefaultToolPresetCatalog.presets.filter {
            $0.id.hasPrefix("preset.frames.")
        }
        #expect(presets.count == 6)

        #expect(model.addUserTools(from: presets, sourceName: "Apple Frames") == nil)

        #expect(model.disabledToolIDs.contains("frames_run"))
        #expect(!model.toolSurfaceRuntime.toolsSnapshot().contains {
            $0.id == "frames_run"
        })
        for preset in presets where preset.toolID != "frames_run" {
            #expect(model.isToolExposed(try #require(model.tool(id: preset.toolID))))
        }
    }

    @MainActor
    @Test func catalogUpdateCountDistinguishesFreshAndPartialProviderScopes() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let presets = DefaultToolPresetCatalog.presets.filter {
            $0.id.hasPrefix("preset.frames.")
        }
        let firstPreset = try #require(presets.first)

        #expect(model.catalogUpdateCount(in: presets) == 0)

        model.tools = [try firstPreset.draft.makeTool(id: firstPreset.toolID)]
        #expect(model.catalogUpdateCount(in: presets) == presets.count - 1)
    }

    @MainActor
    @Test(arguments: [true, false])
    func firstPartyCatalogRefreshAdoptsOneExactScannedToolAndResetsAuthorization(
        startsShared: Bool
    ) throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let presets = DefaultToolPresetCatalog.presets.filter {
            $0.id.hasPrefix("preset.frames.")
        }
        let flexiblePreset = try #require(presets.first { $0.toolID == "frames_run" })
        var scannedDraft = flexiblePreset.draft
        scannedDraft.provenance = scanProvenance(for: flexiblePreset.executablePath)
        let scanned = try scannedDraft.makeTool(id: "scan_loose_binary_frames")
        try ToolRegistryStore(fileURL: storeURL).saveUserDefinedTools([scanned])

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )
        connectTestClient(model)
        model.disabledToolIDs = startsShared ? [] : [scanned.id]
        model.setToolAlwaysAllowed(true, toolID: scanned.id, clientID: "client-1")

        #expect(model.catalogUpdateCount(in: presets) == presets.count)
        #expect(model.updateUserToolsFromCatalog(presets, sourceName: "Apple Frames") == nil)

        let adopted = try #require(model.tool(id: flexiblePreset.toolID))
        #expect(model.tool(id: scanned.id) == nil)
        #expect(adopted.permissionEpoch != scanned.permissionEpoch)
        #expect(model.isToolExposed(adopted) == startsShared)
        #expect(!model.disabledToolIDs.contains(scanned.id))
        #expect(model.disabledToolIDs.contains(adopted.id) == !startsShared)
        #expect(!model.isToolAlwaysAllowed(toolID: scanned.id, clientID: "client-1"))
        #expect(!model.isToolAlwaysAllowed(toolID: adopted.id, clientID: "client-1"))

        let persisted = try ToolRegistryStore(fileURL: storeURL).loadUserDefinedTools()
        #expect(!persisted.contains { $0.id == scanned.id })
        #expect(persisted.contains { $0.id == adopted.id })
    }

    @MainActor
    @Test func addOnlyCatalogInstallNeverAdoptsAnEquivalentScannedTool() throws {
        let context = try makeToolUpdateContext()
        defer { context.tearDown() }
        let model = context.model
        let flexiblePreset = try #require(
            DefaultToolPresetCatalog.presets.first { $0.toolID == "frames_run" }
        )
        var scannedDraft = flexiblePreset.draft
        scannedDraft.provenance = scanProvenance(for: flexiblePreset.executablePath)
        let scanned = try scannedDraft.makeTool(id: "scan_loose_binary_frames")
        model.tools = [scanned]
        model.disabledToolIDs = []
        model.setToolAlwaysAllowed(true, toolID: scanned.id, clientID: "client-1")

        #expect(model.addUserTools(from: [flexiblePreset], sourceName: "Apple Frames") == nil)

        #expect(model.tool(id: scanned.id) == scanned)
        #expect(model.tool(id: flexiblePreset.toolID) == nil)
        #expect(model.isToolExposed(scanned))
        #expect(model.isToolAlwaysAllowed(toolID: scanned.id, clientID: "client-1"))
    }

    @MainActor
    @Test(.enabled(if: AppleFramesToolPresetCatalog.detectedExecutablePath != nil, "Apple Frames is not installed on this Mac."))
    func appleFramesCatalogRefreshOwnsOnlyTheCompleteFramesPrefix() throws {
        let defaults = try makeIsolatedToolUpdateDefaults()
        defer { defaults.removePersistentDomain(forName: toolUpdateSuiteName(defaults)) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = directory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let presets = DefaultToolPresetCatalog.presets.filter {
            $0.id.hasPrefix("preset.frames.")
        }
        let retired = ToolDefinition(
            id: "frames_legacy",
            name: "Legacy Apple Frames Tool",
            summary: "Obsolete first-party adapter row.",
            executablePath: "/bin/echo",
            argumentPattern: ["legacy"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            category: .imageProcessing
        )
        let custom = try makeDraft(name: "My Unrelated Tool").makeTool(id: "custom_unrelated")
        try ToolRegistryStore(fileURL: storeURL).saveUserDefinedTools([retired, custom])

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL)
        )
        #expect(model.catalogUpdateCount(in: presets) == presets.count + 1)
        #expect(model.updateUserToolsFromCatalog(presets, sourceName: "Apple Frames") == nil)

        let expectedIDs = Set(presets.map(\.toolID))
        #expect(Set(model.tools.filter { $0.id.hasPrefix("frames_") }.map(\.id)) == expectedIDs)
        #expect(model.tool(id: retired.id) == nil)
        #expect(model.tool(id: custom.id) == custom)
        #expect(model.disabledToolIDs.contains("frames_run"))
    }
}

// MARK: - Helpers

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

/// Counts writes of the Always Allow grant store's one preferences key.
private final class GrantWriteCountingDefaults: UserDefaults, @unchecked Sendable {
    var grantWrites = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "MacRemote.clientToolPermissions.v2" {
            grantWrites += 1
        }
        super.set(value, forKey: defaultName)
    }
}

/// Set from an observation `onChange`, which may run off the main actor.
private final class ObservationFlag: @unchecked Sendable {
    var isSet = false
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
    let model = makeTestAppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))
    connectTestClient(model)
    return ToolUpdateContext(model: model, storeURL: storeURL, defaults: defaults)
}

@MainActor
private func connectTestClient(_ model: AppModel) {
    model.connectedClients = [
        ConnectedClient(
            id: "client-1",
            trustID: "trust-1",
            name: "Test Client",
            redirectURIs: ["https://example.com/callback"],
            issuer: nil,
            resource: nil,
            scopes: ["mcp"],
            createdAt: Date(timeIntervalSince1970: 1),
            lastAuthorizedAt: Date(timeIntervalSince1970: 2),
            activeAccessTokens: 1,
            activeRefreshTokens: 1
        )
    ]
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

private func scanProvenance(for executablePath: String) -> ToolProvenance {
    ToolProvenance(
        sourceKind: .looseBinary,
        packageName: nil,
        packageVersion: nil,
        addedDate: Date(timeIntervalSince1970: 1),
        resolvedPathAtAdd: executablePath,
        signingIdentityAtAdd: "unsigned",
        contentSHA256AtAdd: "fixture",
        wasQuarantinedAtAdd: false,
        summaryIsHarvested: false,
        summaryOrigin: nil
    )
}

private func registryDataIncludingBrokenRow(_ tools: [ToolDefinition]) throws -> Data {
    let encodedTools = try tools.map { tool -> String in
        let data = try JSONEncoder().encode(tool)
        return try #require(String(data: data, encoding: .utf8))
    }
    let rows = encodedTools + ["{\"id\":\"custom.undecodable\",\"name\":\"Undecodable\"}"]
    return Data("[\n  \(rows.joined(separator: ",\n  "))\n]\n".utf8)
}

private func makeHTTPBridgeTool(
    id: String,
    name: String,
    serverURL: String,
    serverIdentity: String? = nil,
    serverName: String = "Test Server",
    upstreamToolName: String = "test_tool",
    timeoutSeconds: TimeInterval = 5
) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: name,
        summary: "Bridge tool.",
        executablePath: "",
        argumentPattern: [],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: timeoutSeconds,
        outputByteLimit: 1024,
        origin: .userDefined,
        category: .developer,
        backend: .mcpHTTPBridge,
        mcpBridge: MCPBridgeConfiguration(
            serverIdentity: serverIdentity,
            serverName: serverName,
            serverURL: serverURL,
            toolName: upstreamToolName
        )
    )
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
