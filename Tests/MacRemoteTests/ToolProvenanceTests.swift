import Foundation
import Testing
@testable import MacRemote

/// CLI-DISCOVERY-SPEC coverage for the model integration: ToolProvenance
/// Codable back-compat (§3.2), scan draft invariants (R5/DL-1/DL-9), the
/// `addToolsFromScan` transaction (R4/G3), harvested-mark clearing through
/// `updateUserTool` (R11/D8), category changes (DL-12), and R16 revalidation.
struct ToolProvenanceTests {
    // MARK: - Codable back-compat (§3.2)

    @Test func legacyToolJSONWithoutProvenanceDecodesUnchanged() throws {
        let data = Data("""
        {
          "id": "custom.legacy",
          "name": "Legacy",
          "summary": "Old saved tool.",
          "executablePath": "/bin/echo",
          "argumentPattern": ["hello"],
          "parameters": [],
          "capability": "readOnly",
          "timeoutSeconds": 5,
          "outputByteLimit": 1024,
          "category": "imageProcessing"
        }
        """.utf8)

        let tool = try JSONDecoder().decode(ToolDefinition.self, from: data)
        #expect(tool.provenance == nil)
        #expect(tool.origin == .userDefined)
        #expect(tool.category == .imageProcessing)
        #expect(tool.category.title == "Media")
    }

    @Test func encodedToolWithoutProvenanceOmitsTheKey() throws {
        let tool = ToolDefinition(
            id: "custom.plain",
            name: "Plain",
            summary: "No provenance.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )

        let data = try JSONEncoder().encode(tool)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["provenance"] == nil)
    }

    @Test func provenanceRoundTripsThroughCodable() throws {
        let tool = ToolDefinition(
            id: "scan_homebrew_formula_rg",
            name: "rg",
            summary: "Search tool like grep and The Silver Searcher",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [],
            capability: .destructive,
            timeoutSeconds: 60,
            outputByteLimit: 2048 * 1024,
            origin: .userDefined,
            provenance: makeProvenance()
        )

        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: data)
        #expect(decoded == tool)
        #expect(decoded.provenance?.sourceKind == .homebrewFormula)
        #expect(decoded.provenance?.summaryIsHarvested == true)
        #expect(decoded.provenance?.summaryOrigin == "Homebrew")
    }

    // MARK: - Category system (DL-12)

    @Test func categorySystemAddsDomainCategoriesAndRetitlesMediaWithoutRawValueChanges() {
        #expect(ToolCategory.ai.rawValue == "ai")
        #expect(ToolCategory.ai.title == "AI & Agents")
        #expect(ToolCategory.allCases.contains(.ai))
        #expect(ToolCategory.notes.rawValue == "notes")
        #expect(ToolCategory.notes.title == "Notes")
        #expect(ToolCategory.allCases.contains(.notes))
        #expect(ToolCategory.readLater.rawValue == "readLater")
        #expect(ToolCategory.readLater.title == "Read Later")
        #expect(ToolCategory.allCases.contains(.readLater))
        #expect(ToolCategory(rawValue: "imageProcessing") == .imageProcessing)
        #expect(ToolCategory.imageProcessing.title == "Media")
        #expect(ToolCategory.iphone.rawValue == "iphone")
        #expect(ToolCategory.iphone.title == "iPhone")
        #expect(ToolCategory.allCases.contains(.iphone))
    }

    // MARK: - Scan draft invariants (R5/DL-1/DL-9 — test plan #17)

    @MainActor
    @Test func scanDraftForcesFlexibleCommandDestructiveAndProvenance() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }

        let candidate = makeCandidate(summary: "Prints its arguments.", summaryOrigin: "Homebrew")
        let draft = context.model.scanToolDraft(for: candidate)

        #expect(draft.mode == .cliAdapter)
        #expect(draft.capability == .destructive)
        #expect(draft.argumentPattern == ["{args}"])
        #expect(draft.timeoutSeconds == 60)
        #expect(draft.outputLimitKB == 2048)
        #expect(draft.permissionRequirements.isEmpty)
        #expect(draft.summary == "Prints its arguments.")

        let provenance = try #require(draft.provenance)
        #expect(provenance.sourceKind == .homebrewFormula)
        #expect(provenance.packageName == "echo-pkg")
        #expect(provenance.packageVersion == "1.0.0")
        #expect(provenance.resolvedPathAtAdd == "/bin/echo")
        #expect(provenance.signingIdentityAtAdd == "Developer ID: TEAM1234")
        #expect(provenance.contentSHA256AtAdd == "hash-at-add")
        #expect(provenance.wasQuarantinedAtAdd == false)
        #expect(provenance.summaryIsHarvested == true)
        #expect(provenance.summaryOrigin == "Homebrew")

        let tool = try draft.makeTool(id: "scan_homebrew_formula_echo")
        #expect(tool.capability == .destructive)
        #expect(tool.isGenericCLIAdapter)
        #expect(tool.provenance == provenance)
    }

    @MainActor
    @Test func scanDraftWithoutHarvestedSummaryUsesNeutralFallback() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }

        let candidate = makeCandidate(summary: nil, summaryOrigin: nil)
        let draft = context.model.scanToolDraft(for: candidate)

        #expect(draft.summary == "Runs echo (found via Homebrew) by passing argv directly.")
        #expect(draft.provenance?.summaryIsHarvested == false)
        #expect(draft.provenance?.summaryOrigin == nil)
    }

    // MARK: - Scan tool IDs (§3.4)

    @MainActor
    @Test func scanToolIDsKeepTheirNamespaceAndCollisionSuffix() {
        let candidate = makeCandidate(binaryName: "echo")
        let first = AppModel.mintScanToolID(for: candidate, existingIDs: [])
        #expect(first == "scan_homebrew_formula_echo")

        let second = AppModel.mintScanToolID(for: candidate, existingIDs: [first])
        #expect(second == "scan_homebrew_formula_echo_2")

        let third = AppModel.mintScanToolID(for: candidate, existingIDs: [first, second])
        #expect(third == "scan_homebrew_formula_echo_3")
    }

    // MARK: - addToolsFromScan (R4/G3 — test plan #18)

    @MainActor
    @Test func addToolsFromScanLandsNotSharedInOneTransaction() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        let candidates = [
            makeCandidate(binaryName: "echo", stablePath: "/bin/echo", summary: "Prints arguments."),
            makeCandidate(binaryName: "true", stablePath: "/usr/bin/true", resolvedPath: "/usr/bin/true", summary: nil)
        ]

        #expect(model.addToolsFromScan(candidates) == nil)
        #expect(model.tools.count == 2)

        for tool in model.tools {
            #expect(tool.id.hasPrefix("scan_homebrew_formula_"))
            #expect(tool.capability == .destructive)
            #expect(tool.provenance != nil)
            #expect(model.disabledToolIDs.contains(tool.id))
            #expect(!model.isToolExposed(tool))
        }

        let persisted = try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools()
        #expect(persisted.count == 2)
        let persistedDisabled = Set(context.defaults.stringArray(forKey: "MacRemote.disabledToolIDs") ?? [])
        #expect(persistedDisabled.isSuperset(of: model.tools.map(\.id)))
        #expect(model.logs.contains { $0.message.contains("Added 2 tools from a scan of this Mac — none shared.") })
    }

    @MainActor
    @Test func addToolsFromScanRollsBackOnPersistenceFailure() throws {
        let defaults = try makeIsolatedProvenanceDefaults()
        defer { defaults.removePersistentDomain(forName: provenanceSuiteName(defaults)) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let blockerFile = temporaryDirectory.appendingPathComponent("blocker")
        try Data().write(to: blockerFile)
        let blockedStore = ToolRegistryStore(
            fileURL: blockerFile.appendingPathComponent("sub").appendingPathComponent("tools.json")
        )

        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: blockedStore,
            provenanceInspector: StubProvenanceInspector(identity: baselineIdentity)
        )
        let originalDisabledToolIDs = model.disabledToolIDs

        let error = model.addToolsFromScan([makeCandidate()])
        #expect(error != nil)
        #expect(model.tools.isEmpty)
        #expect(model.disabledToolIDs == originalDisabledToolIDs)
    }

    @MainActor
    @Test func addToolsFromScanSkipsAlreadyAddedSignatures() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        var handMade = ToolDefinitionDraft()
        handMade.mode = .cliAdapter
        handMade.name = "Echo Adapter"
        handMade.summary = "Hand-added echo adapter."
        handMade.executablePath = "/bin/echo"
        handMade.capability = .destructive
        #expect(model.addUserTool(from: handMade) == nil)
        #expect(model.tools.count == 1)

        // Same `\u{1f}` signature (executablePath + {args}) as the hand-added
        // adapter — the scan add must treat it as "Added ✓" (test plan #19).
        let message = model.addToolsFromScan([makeCandidate(binaryName: "echo", stablePath: "/bin/echo")])
        #expect(message == "All selected tools are already added.")
        #expect(model.tools.count == 1)
    }

    @MainActor
    @Test func addToolsFromScanSuffixesDisplayNameCollisions() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        var handMade = ToolDefinitionDraft()
        handMade.mode = .commandTemplate
        handMade.name = "echo"
        handMade.summary = "Fixed echo."
        handMade.executablePath = "/bin/echo"
        handMade.argumentsText = "hello"
        #expect(model.addUserTool(from: handMade) == nil)

        #expect(model.addToolsFromScan([makeCandidate(binaryName: "echo", stablePath: "/bin/echo")]) == nil)
        let scanned = try #require(model.tools.first { $0.id.hasPrefix("scan_") })
        #expect(scanned.name == "echo (Homebrew)")
    }

    // MARK: - Summary edits clear the harvested mark (R11/D8 — test plan #20)

    @MainActor
    @Test func summaryEditClearsHarvestedMarkThroughUpdateUserTool() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.addToolsFromScan([makeCandidate(summary: "Prints its arguments.", summaryOrigin: "Homebrew")]) == nil)
        let tool = try #require(model.tools.first)
        #expect(tool.provenance?.summaryIsHarvested == true)

        // Editing everything but the summary keeps the mark (and the provenance
        // record survives a draft that never carried it — D8).
        var renameDraft = draftFromScannedTool(tool)
        renameDraft.name = "Echo Renamed"
        #expect(model.updateUserTool(id: tool.id, draft: renameDraft) == nil)
        let renamed = try #require(model.tools.first)
        #expect(renamed.provenance?.summaryIsHarvested == true)
        #expect(renamed.provenance?.summaryOrigin == "Homebrew")

        var summaryDraft = draftFromScannedTool(renamed)
        summaryDraft.summary = "My own words about echo."
        #expect(model.updateUserTool(id: tool.id, draft: summaryDraft) == nil)
        let edited = try #require(model.tools.first)
        #expect(edited.summary == "My own words about echo.")
        #expect(edited.provenance != nil)
        #expect(edited.provenance?.summaryIsHarvested == false)
        #expect(edited.provenance?.summaryOrigin == nil)
        #expect(edited.provenance?.sourceKind == .homebrewFormula)
    }

    // MARK: - R16 revalidation (test plan #22)

    @MainActor
    @Test func identityChangeAutoUnsharesAndLogsOneWarning() async throws {
        let context = try makeProvenanceContext(
            inspector: StubProvenanceInspector(
                identity: ToolBinaryIdentity(signingIdentity: "Developer ID: EVIL9999", contentSHA256: "tampered")
            )
        )
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]
        #expect(model.isToolExposed(tool))

        let outcome = await model.revalidateToolProvenance(toolID: tool.id)
        #expect(outcome == .identityChanged(previous: "Developer ID: TEAM1234", current: "Developer ID: EVIL9999"))
        #expect(model.disabledToolIDs.contains(tool.id))
        #expect(model.provenanceIdentityChangedToolIDs.contains(tool.id))

        let warnings = model.logs.filter { $0.message.contains("publisher changed since it was added — sharing turned off pending review") }
        #expect(warnings.count == 1)

        // A second check informs no further — still exactly one Activity warning.
        _ = await model.revalidateToolProvenance(toolID: tool.id)
        let repeatWarnings = model.logs.filter { $0.message.contains("publisher changed since it was added") }
        #expect(repeatWarnings.count == 1)
    }

    @MainActor
    @Test func contentChangeUnderSameIdentityOnlyInforms() async throws {
        let context = try makeProvenanceContext(
            inspector: StubProvenanceInspector(
                identity: ToolBinaryIdentity(signingIdentity: "Developer ID: TEAM1234", contentSHA256: "new-content")
            )
        )
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]

        let outcome = await model.revalidateToolProvenance(toolID: tool.id)
        #expect(outcome == .contentChanged)
        #expect(!model.disabledToolIDs.contains(tool.id))
        #expect(model.provenanceIdentityChangedToolIDs.isEmpty)
        #expect(model.provenanceContentUpdates[tool.id] != nil)
        #expect(!model.logs.contains { $0.message.contains("publisher changed") })
    }

    @MainActor
    @Test func unsignedToUnsignedContentChangeIsInformational() async throws {
        let context = try makeProvenanceContext(
            inspector: StubProvenanceInspector(
                identity: ToolBinaryIdentity(signingIdentity: "unsigned", contentSHA256: "rebuilt")
            )
        )
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool(signingIdentityAtAdd: "unsigned")
        model.tools = [tool]

        let outcome = await model.revalidateToolProvenance(toolID: tool.id)
        #expect(outcome == .contentChanged)
        #expect(!model.disabledToolIDs.contains(tool.id))
    }

    @MainActor
    @Test func unchangedIdentityAndContentPassRevalidation() async throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]

        let outcome = await model.revalidateToolProvenance(toolID: tool.id)
        #expect(outcome == .identityUnchanged)
        #expect(!model.disabledToolIDs.contains(tool.id))
        #expect(model.provenanceContentUpdates[tool.id] == nil)
    }

    @MainActor
    @Test func missingExecutableIsNotAnIdentityChange() async throws {
        let context = try makeProvenanceContext(inspector: StubProvenanceInspector(identity: nil))
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]

        let outcome = await model.revalidateToolProvenance(toolID: tool.id)
        #expect(outcome == nil)
        #expect(!model.disabledToolIDs.contains(tool.id))
    }

    @MainActor
    @Test func toolTestBlocksExecutionAfterIdentityChange() async throws {
        let context = try makeProvenanceContext(
            inspector: StubProvenanceInspector(
                identity: ToolBinaryIdentity(signingIdentity: "Developer ID: EVIL9999", contentSHA256: "tampered")
            )
        )
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]

        _ = await model.runInspectorToolTest(toolID: tool.id, parameters: [:])

        #expect(model.disabledToolIDs.contains(tool.id))
        #expect(model.logs.contains { $0.message.contains("publisher changed since it was added") })
        #expect(!model.logs.contains { $0.message.contains("completed in") })
        #expect(!model.logs.contains { $0.message.contains("Tool test failed") })
    }

    @MainActor
    @Test func addUserToolNotSharedLandsDisabledInOneTransaction() throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        var draft = draftFromScannedTool(makeScannedTool())
        draft.provenance = makeProvenance()
        #expect(model.addUserTool(from: draft, shared: false) == nil)

        let added = try #require(model.tools.first { $0.isUserDefined })
        #expect(model.disabledToolIDs.contains(added.id))
        #expect(!model.isToolExposed(added))
        #expect(model.logs.contains { $0.message.contains("Added tool echo — not shared.") })
        // The Not-Shared state persists with the add, not as a follow-up write.
        let persistedDisabled = Set(context.defaults.stringArray(forKey: "MacRemote.disabledToolIDs") ?? [])
        #expect(persistedDisabled.contains(added.id))
    }

    @MainActor
    @Test func remoteExecutionPathBlocksIdentityChangedTool() async throws {
        let context = try makeProvenanceContext(
            inspector: StubProvenanceInspector(
                identity: ToolBinaryIdentity(signingIdentity: "Developer ID: EVIL9999", contentSHA256: "tampered")
            )
        )
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]
        // The R16 pre-execution gate is installed on the runtime at init; the
        // remote MCP surface executes exclusively through this runtime.
        model.toolSurfaceRuntime.update(tools: [tool])

        await #expect(throws: ToolValidationError.identityChanged("echo")) {
            try await model.toolSurfaceRuntime.execute(
                toolID: tool.id,
                parameters: ["args": .stringArray(["hi"])]
            )
        }
        #expect(model.disabledToolIDs.contains(tool.id))
        #expect(model.logs.contains { $0.message.contains("publisher changed since it was added") })
    }

    @MainActor
    @Test func remoteExecutionPathRunsUnchangedTool() async throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        let tool = makeScannedTool()
        model.tools = [tool]
        model.toolSurfaceRuntime.update(tools: [tool])

        let outcome = try await model.toolSurfaceRuntime.execute(
            toolID: tool.id,
            parameters: ["args": .stringArray(["hi"])]
        )
        #expect(outcome.succeeded)
        #expect(!model.disabledToolIDs.contains(tool.id))
    }

    // MARK: - Scan state machine wiring (stub scanner)

    @MainActor
    @Test func scanInstalledCLIsDrivesStateToLoaded() async throws {
        let context = try makeProvenanceContext()
        defer { context.tearDown() }
        let model = context.model

        #expect(model.cliScanState == .idle)
        model.scanInstalledCLIs()
        #expect(model.cliScanState.isScanning)

        var attempts = 0
        while model.cliScanState.isScanning, attempts < 2000 {
            attempts += 1
            await Task.yield()
        }

        guard case .loaded(let candidates, _) = model.cliScanState else {
            Issue.record("expected .loaded, got \(model.cliScanState)")
            return
        }
        #expect(candidates.isEmpty)
        #expect(model.logs.contains { $0.message.contains("Scanned this Mac: 0 command-line tools found.") })
    }

    // MARK: - Inspector cache

    /// Every call re-checks the binary. Hashing a large one on each call costs
    /// 40–230 ms, so an unchanged file is read once; any change reads it again.
    @Test func inspectorReadsAnUnchangedBinaryOnceAndAChangedOneAgain() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemote-InspectorCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("tool")
        try Data("version-1".utf8).write(to: binary)

        let reader = CountingSignatureReader()
        let inspector = SecStaticCodeProvenanceInspector(signatureReader: reader)

        let first = try #require(inspector.currentIdentity(forExecutableAt: binary.path))
        let second = inspector.currentIdentity(forExecutableAt: binary.path)
        #expect(second == first)
        #expect(reader.callCount == 1)

        // Same size, so only the file's identity and times give it away.
        try Data("version-2".utf8).write(to: binary)
        let changed = try #require(inspector.currentIdentity(forExecutableAt: binary.path))
        #expect(reader.callCount == 2)
        #expect(changed.contentSHA256 != first.contentSHA256)
    }
}

// MARK: - Fixtures

/// Reading the signature is the expensive step, so counting reads shows
/// whether the inspector checked the binary again.
private final class CountingSignatureReader: SignatureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func signatureTrust(atPath path: String) -> DiscoveredCLICandidate.SignatureTrust {
        lock.withLock { calls += 1 }
        return .unsigned
    }
}

private let baselineIdentity = ToolBinaryIdentity(
    signingIdentity: "Developer ID: TEAM1234",
    contentSHA256: "hash-at-add"
)

private struct StubProvenanceInspector: ToolProvenanceInspecting {
    let identity: ToolBinaryIdentity?

    func currentIdentity(forExecutableAt path: String) -> ToolBinaryIdentity? {
        identity
    }
}

private func makeCandidate(
    binaryName: String = "echo",
    stablePath: String = "/bin/echo",
    resolvedPath: String = "/bin/echo",
    summary: String? = "Prints its arguments.",
    summaryOrigin: String? = "Homebrew"
) -> DiscoveredCLICandidate {
    DiscoveredCLICandidate(
        id: "scan_homebrew_formula_\(binaryName)",
        source: .homebrewFormula,
        binaryName: binaryName,
        stablePath: stablePath,
        resolvedPath: resolvedPath,
        resolutionChain: [stablePath],
        aliases: [],
        packageName: "echo-pkg",
        version: "1.0.0",
        summary: summary,
        summaryOrigin: summary == nil ? nil : summaryOrigin,
        homepage: nil,
        siblingExecutables: [],
        installedOnRequest: true,
        installDate: nil,
        fileKind: .machO(architectures: ["arm64"]),
        signature: .adhoc,
        isQuarantined: false,
        originDomain: nil,
        isInterpreter: false,
        isDependencyOnly: false,
        suggestedCategory: .utilities,
        isNewSinceLastScan: true
    )
}

private func makeScannedTool(signingIdentityAtAdd: String = "Developer ID: TEAM1234") -> ToolDefinition {
    ToolDefinition(
        id: "scan_homebrew_formula_echo",
        name: "echo",
        summary: "Prints its arguments.",
        executablePath: "/bin/echo",
        argumentPattern: ["{args}"],
        parameters: (try? ToolDefinitionDraft.inferredParameters(from: ["{args}"])) ?? [],
        capability: .destructive,
        timeoutSeconds: 60,
        outputByteLimit: 2048 * 1024,
        origin: .userDefined,
        provenance: makeProvenance(signingIdentityAtAdd: signingIdentityAtAdd)
    )
}

private func makeProvenance(signingIdentityAtAdd: String = "Developer ID: TEAM1234") -> ToolProvenance {
    ToolProvenance(
        sourceKind: .homebrewFormula,
        packageName: "echo-pkg",
        packageVersion: "1.0.0",
        addedDate: Date(timeIntervalSince1970: 1_780_000_000),
        resolvedPathAtAdd: "/bin/echo",
        signingIdentityAtAdd: signingIdentityAtAdd,
        contentSHA256AtAdd: "hash-at-add",
        wasQuarantinedAtAdd: false,
        summaryIsHarvested: true,
        summaryOrigin: "Homebrew"
    )
}

/// A Definition-editor-shaped draft for an existing scanned tool: fields copied
/// over, provenance deliberately absent (updateUserTool must carry it forward).
private func draftFromScannedTool(_ tool: ToolDefinition) -> ToolDefinitionDraft {
    var draft = ToolDefinitionDraft()
    draft.mode = .cliAdapter
    draft.name = tool.name
    draft.summary = tool.summary
    draft.executablePath = tool.executablePath
    draft.capability = tool.capability
    draft.category = tool.category
    draft.timeoutSeconds = tool.timeoutSeconds
    draft.outputLimitKB = tool.outputByteLimit / 1024
    return draft
}

// MARK: - Harness

private struct ProvenanceContext {
    let model: AppModel
    let storeURL: URL
    let defaults: UserDefaults

    func tearDown() {
        defaults.removePersistentDomain(forName: provenanceSuiteName(defaults))
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }
}

@MainActor
private func makeProvenanceContext(
    inspector: any ToolProvenanceInspecting = StubProvenanceInspector(identity: baselineIdentity)
) throws -> ProvenanceContext {
    let defaults = try makeIsolatedProvenanceDefaults()
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let storeURL = root.appendingPathComponent("tools.json")
    // Hermetic scanner: every root points inside the test directory, so a scan
    // reads nothing from the real Mac and completes instantly.
    let scanner = LocalCLIScanner(
        homeDirectory: root.appendingPathComponent("home").path,
        brewPrefix: root.appendingPathComponent("homebrew").path,
        apiCacheDirectory: root.appendingPathComponent("api").path,
        etcShellsPath: root.appendingPathComponent("shells").path,
        binDirectories: [],
        presetExecutablePaths: [],
        originDomainReader: { _ in nil }
    )
    let model = makeTestAppModel(
        userDefaults: defaults,
        toolStore: ToolRegistryStore(fileURL: storeURL),
        cliScanner: scanner,
        provenanceInspector: inspector
    )
    return ProvenanceContext(model: model, storeURL: storeURL, defaults: defaults)
}

private func makeIsolatedProvenanceDefaults() throws -> UserDefaults {
    let suiteName = "MacRemoteToolProvenanceTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "MacRemoteToolProvenanceTests", code: 1)
    }
    defaults.removePersistentDomain(forName: suiteName)
    defaults.set(suiteName, forKey: "MacRemoteTests.suiteName")
    return defaults
}

private func provenanceSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}
