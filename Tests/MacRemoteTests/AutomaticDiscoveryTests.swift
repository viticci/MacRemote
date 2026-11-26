import CryptoKit
import Foundation
import Testing
@testable import MacRemote

struct AutomaticDiscoveryTests {
    // MARK: - 1. Quiet refresh: no .scanning, no probing, no subprocess

    @MainActor
    @Test func quietRefreshPopulatesCandidatesWithoutScanningOrProbing() async throws {
        let context = try makeMCPDiscoveryContext(
            processRunner: CountingProcessRunner()
        )
        defer { context.tearDown() }

        try writeCodexFixture(
            home: context.home,
            serverName: "quiet-server",
            command: "/usr/bin/true"
        )

        let runner = try #require(context.processRunner as? CountingProcessRunner)
        #expect(await runner.invocationCount == 0)
        #expect(context.model.localMCPScanState == .idle)

        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)

        guard case .loaded(let candidates, _) = context.model.localMCPScanState else {
            Issue.record("expected .loaded, got \(context.model.localMCPScanState)")
            return
        }
        #expect(!context.model.localMCPScanState.isScanning)
        #expect(candidates.contains { $0.displayName == "quiet-server" })
        #expect(candidates.allSatisfy { $0.probe == nil })
        #expect(await runner.invocationCount == 0)
    }

    @Test func scanWithRuntimeSourcesDisabledNeverInvokesClaude() async throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let runner = CountingProcessRunner()
        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { $0 == "claude" ? "/usr/bin/claude" : nil },
            processRunner: runner
        )

        _ = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        #expect(await runner.invocationCount == 0)
    }

    // MARK: - 2. New flag + seen-set expansion on manual scan

    @MainActor
    @Test func newCandidateClearsAfterManualScanExpandsSeenSet() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexFixture(
            home: context.home,
            serverName: "fresh-server",
            command: "/usr/bin/true"
        )

        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)

        guard case .loaded(let first, _) = context.model.localMCPScanState else {
            Issue.record("expected loaded quiet refresh")
            return
        }
        let candidate = try #require(first.first { $0.displayName == "fresh-server" })
        #expect(candidate.isNewSinceLastScan)

        context.model.scanLocalMCPServers()
        await waitForMCPManualScan(on: context.model)

        guard case .loaded(let manual, _) = context.model.localMCPScanState else {
            Issue.record("expected loaded manual scan")
            return
        }
        #expect(manual.first { $0.displayName == "fresh-server" }?.isNewSinceLastScan == false)

        context.model.refreshLocalMCPDiscovery(trigger: .activation)
        await waitForMCPRefresh(on: context.model)

        guard case .loaded(let after, _) = context.model.localMCPScanState else {
            Issue.record("expected loaded second quiet refresh")
            return
        }
        #expect(after.first { $0.displayName == "fresh-server" }?.isNewSinceLastScan == false)
    }

    // MARK: - 3. Seen-set persisted as SHA-256 hex — no raw URLs on disk

    @MainActor
    @Test func cachePersistsHashedIdentitiesNotRawURLs() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        let secretURL = "http://127.0.0.1:8080/super-secret-token-path/mcp"
        try writeCodexHTTPFixture(home: context.home, serverName: "secret-server", url: secretURL)

        context.model.scanLocalMCPServers()
        await waitForMCPManualScan(on: context.model)

        let cacheData = try Data(contentsOf: context.mcpCacheURL)
        let cacheJSON = try #require(String(data: cacheData, encoding: .utf8))
        #expect(!cacheJSON.contains(secretURL))
        #expect(!cacheJSON.contains("super-secret-token-path"))

        let decoded = try JSONDecoder().decode(LocalMCPScanCache.self, from: cacheData)
        let candidate = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "secret-server" }
        )
        let canonicalIdentity = try #require(candidate.canonicalRuntimeIdentity)
        let expectedHash = SHA256.hash(data: Data(canonicalIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(decoded.hashedSeenBridgeIdentities.contains(expectedHash))
    }

    // MARK: - 4. configSnapshot + freshness stale

    @Test func configSnapshotChangesWhenFixtureChanges() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("[mcp_servers.a]\nurl = \"http://127.0.0.1:1/mcp\"\n".utf8).write(to: configURL)

        let first = MCPConfigLocator.configSnapshot(homeDirectory: home)
        try Data("""
        [mcp_servers.changed]
        command = "/usr/bin/false"
        args = ["--extra", "padding", "to", "change", "file", "size"]
        """.utf8).write(to: configURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)],
            ofItemAtPath: configURL.path
        )
        let second = MCPConfigLocator.configSnapshot(homeDirectory: home)
        #expect(first != second)
    }

    /// The Tools page reads this snapshot on every redraw, so it must not walk
    /// an extension's dependency tree.
    @Test func extensionSnapshotWatchesOnlyEachExtensionsOwnManifest() throws {
        let home = try makeTemporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let manager = FileManager.default
        let extensionFolder = home.appendingPathComponent(
            "Library/Application Support/Claude/Claude Extensions/local.example",
            isDirectory: true
        )
        let manifest = extensionFolder.appendingPathComponent("manifest.json")
        let dependencyManifest = extensionFolder.appendingPathComponent("node_modules/pkg/dist/manifest.json")
        try manager.createDirectory(at: dependencyManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: manifest)
        try Data("{}".utf8).write(to: dependencyManifest)
        func touch(_ url: URL, _ seconds: TimeInterval) throws {
            try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: seconds)], ofItemAtPath: url.path)
        }
        try touch(manifest, 1_700_000_000)
        try touch(dependencyManifest, 1_700_000_000)
        let first = MCPConfigLocator.configSnapshot(homeDirectory: home)

        try touch(dependencyManifest, 1_800_000_000)
        #expect(MCPConfigLocator.configSnapshot(homeDirectory: home) == first)

        try touch(manifest, 1_800_000_000)
        #expect(MCPConfigLocator.configSnapshot(homeDirectory: home) != first)
    }

    @MainActor
    @Test func freshnessFlipsToStaleWhenConfigsChange() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexFixture(
            home: context.home,
            serverName: "stale-server",
            command: "/usr/bin/true"
        )

        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)
        #expect(context.model.localMCPFreshness != .neverScanned)

        let configURL = context.home.appendingPathComponent(".codex/config.toml")
        try Data("""
        [mcp_servers.changed]
        command = "/usr/bin/false"
        """.utf8).write(to: configURL)

        guard case .stale(_, let reason) = context.model.localMCPFreshness else {
            Issue.record("expected stale freshness after config change")
            return
        }
        #expect(reason == .configsChanged)
    }

    // MARK: - 5. Quiet refresh skipped while manual scan in flight

    @MainActor
    @Test func quietRefreshSkippedDuringManualScan() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        context.model.localMCPScanState = .scanning
        context.model.refreshLocalMCPDiscovery(trigger: .activation)
        await Task.yield()

        #expect(context.model.localMCPScanState.isScanning)
        #expect(context.model.localMCPScanState.candidates.isEmpty)
    }

    // MARK: - 6. Cache round-trip + corrupt fallback

    @Test func mcpScanCacheRoundTripsThroughCodable() throws {
        let cache = LocalMCPScanCache(
            hashedSeenBridgeIdentities: ["abc123"],
            configSnapshot: "path|1|2|3",
            lastConfigScanDate: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(cache)
        let decoded = try JSONDecoder().decode(LocalMCPScanCache.self, from: data)
        #expect(decoded == cache)
    }

    @MainActor
    @Test func corruptCacheFallsBackToNeverScanned() async throws {
        let context = try makeMCPDiscoveryContext(
            processRunner: CountingProcessRunner(),
            prewriteMCPCache: Data("{not valid json".utf8)
        )
        defer { context.tearDown() }

        #expect(context.model.localMCPFreshness == .neverScanned)
    }

    // MARK: - 7. CLI fingerprint staleness without auto-scan

    @MainActor
    @Test func cliFreshnessReflectsFingerprintMismatchWithoutAutoScan() async throws {
        let context = try makeCLIFreshnessContext()
        defer { context.tearDown() }

        let live = context.scanner.fingerprints()
        let staleCache = CLIScanCache(
            candidates: [],
            lastScanDate: Date(timeIntervalSince1970: 1_700_000_000),
            seenStablePaths: [],
            sourceFingerprints: [CLIScanSource.homebrew.rawValue: "stale-value"]
        )
        try JSONEncoder().encode(staleCache).write(to: context.cliCacheURL)

        let model = makeTestAppModel(
            userDefaults: context.defaults,
            toolStore: ToolRegistryStore(fileURL: context.storeURL),
            cliScanner: context.scanner
        )

        guard case .stale(_, let reason) = model.cliFreshness else {
            Issue.record("expected stale cliFreshness, got \(model.cliFreshness)")
            return
        }
        #expect(reason == .installRecordsChanged)
        #expect(!model.cliScanState.isScanning)

        let matchingCache = CLIScanCache(
            candidates: [],
            lastScanDate: Date(timeIntervalSince1970: 1_700_000_000),
            seenStablePaths: [],
            sourceFingerprints: Dictionary(uniqueKeysWithValues: live.map { ($0.key.rawValue, $0.value) })
        )
        try JSONEncoder().encode(matchingCache).write(to: context.cliCacheURL)

        let freshModel = makeTestAppModel(
            userDefaults: context.defaults,
            toolStore: ToolRegistryStore(fileURL: context.storeURL),
            cliScanner: context.scanner
        )
        guard case .current = freshModel.cliFreshness else {
            Issue.record("expected current cliFreshness, got \(freshModel.cliFreshness)")
            return
        }
        #expect(!freshModel.cliScanState.isScanning)
        _ = live
    }

    // MARK: - 8. No auto-import after quiet refresh

    @MainActor
    @Test func quietRefreshDoesNotAutoImportTools() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexFixture(
            home: context.home,
            serverName: "no-import-server",
            command: "/usr/bin/true"
        )

        let toolsBefore = context.model.tools
        let disabledBefore = context.model.disabledToolIDs

        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)

        #expect(context.model.tools == toolsBefore)
        #expect(context.model.disabledToolIDs == disabledBefore)
        guard case .loaded(let candidates, _) = context.model.localMCPScanState else {
            Issue.record("expected candidates from quiet refresh")
            return
        }
        #expect(!candidates.isEmpty)
    }

    // MARK: - 9. Imported-server ownership reconciliation

    @MainActor
    @Test func removingOriginalMCPConfigRemovesOwnedToolsAndGrants() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexFixture(
            home: context.home,
            serverName: "removed-server",
            command: "/usr/bin/false"
        )
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)
        let candidate = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "removed-server" }
        )
        let tool = makeImportedStdioTool(id: "removed_server_echo", candidate: candidate)
        let disabledTool = makeImportedStdioTool(
            id: "removed_server_write",
            candidate: candidate,
            upstreamToolName: "write"
        )
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool, disabledTool],
            bridgeIdentity: candidate.bridgeIdentity
        )
        #expect(context.model.setToolEnabled(id: disabledTool.id, enabled: false) == nil)
        context.model.setToolAlwaysAllowed(
            true,
            toolID: tool.id,
            clientID: "disconnected-client",
            clientTrustID: "stable-client-trust"
        )

        #expect(context.model.tools.contains { $0.id == tool.id })
        #expect(context.model.toolSurfaceRuntime.tool(id: tool.id) != nil)
        #expect(context.model.disabledToolIDs.contains(disabledTool.id))
        #expect(context.model.clientToolPermissionSnapshot["stable-client-trust"] == [tool.id])

        context.model.scanLocalMCPServers()
        await waitForMCPManualScan(on: context.model)
        let canonicalIdentity = try #require(candidate.canonicalRuntimeIdentity)
        let seenHash = SHA256.hash(data: Data(canonicalIdentity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let cacheBeforeRemoval = try JSONDecoder().decode(
            LocalMCPScanCache.self,
            from: Data(contentsOf: context.mcpCacheURL)
        )
        #expect(cacheBeforeRemoval.hashedSeenBridgeIdentities.contains(seenHash))

        try FileManager.default.removeItem(
            at: context.home.appendingPathComponent(".codex/config.toml")
        )
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForToolRemoval(tool.id, on: context.model)

        #expect(!context.model.tools.contains { $0.id == tool.id })
        #expect(context.model.toolSurfaceRuntime.tool(id: tool.id) == nil)
        #expect(!context.model.disabledToolIDs.contains(disabledTool.id))
        #expect(!(context.defaults.stringArray(forKey: "MacRemote.disabledToolIDs") ?? []).contains(disabledTool.id))
        #expect(context.model.clientToolPermissionSnapshot["stable-client-trust"] == nil)
        #expect(ClientToolPermissionStore(userDefaults: context.defaults).snapshot()["stable-client-trust"] == nil)
        #expect(try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools().isEmpty)
        let cacheAfterRemoval = try JSONDecoder().decode(
            LocalMCPScanCache.self,
            from: Data(contentsOf: context.mcpCacheURL)
        )
        #expect(!cacheAfterRemoval.hashedSeenBridgeIdentities.contains(seenHash))
        #expect(context.model.logs.contains { $0.message.contains("original config is gone") })
    }

    /// A bridged server describes its own tools. If a refresh relabels a
    /// shared tool that asked first as read-only, it would start running
    /// unasked, so it becomes Not Shared for the owner to review.
    @MainActor
    @Test func aServerRelabelingASharedToolReadOnlyUnsharesIt() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexFixture(home: context.home, serverName: "notes-server", command: "/usr/bin/false")
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)
        let candidate = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "notes-server" }
        )

        let asksFirst = makeImportedStdioTool(id: "notes_server_delete", candidate: candidate, capability: .destructive)
        _ = try context.model.replaceLocalMCPBridgeTools([asksFirst], bridgeIdentity: candidate.bridgeIdentity)
        #expect(context.model.isToolExposed(asksFirst))

        let relabeled = makeImportedStdioTool(id: "notes_server_delete", candidate: candidate, capability: .readOnly)
        _ = try context.model.replaceLocalMCPBridgeTools([relabeled], bridgeIdentity: candidate.bridgeIdentity)

        #expect(!context.model.isToolIDExposed("notes_server_delete"))
        #expect(context.model.toolSurfaceRuntime.tool(id: "notes_server_delete") == nil)
        #expect(context.model.logs.contains { $0.message.contains("describes it as read-only") })
    }

    @MainActor
    @Test func configuredButOfflineMCPServerPreservesImportedTools() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexFixture(
            home: context.home,
            serverName: "offline-server",
            command: "/usr/bin/false"
        )
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)
        let candidate = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "offline-server" }
        )
        let tool = makeImportedStdioTool(id: "offline_server_echo", candidate: candidate)
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool],
            bridgeIdentity: candidate.bridgeIdentity
        )

        context.model.scanLocalMCPServers()
        await waitForMCPManualScan(on: context.model)

        #expect(context.model.tools.contains { $0.id == tool.id })
        #expect(context.model.toolSurfaceRuntime.tool(id: tool.id) != nil)
        #expect(try ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools().map(\.id) == [tool.id])
        let refreshed = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "offline-server" }
        )
        // The scan did not launch the stdio server, so it learned nothing new
        // about it, and what was imported stays.
        #expect(refreshed.probe == nil)
    }

    @MainActor
    @Test func duplicateCodexAndClaudeOwnershipSurvivesOneConfigRemoval() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }
        try writeCodexFixture(
            home: context.home,
            serverName: "shared-browser",
            command: "/usr/bin/false"
        )
        let claudeConfig = try writeClaudeDesktopFixture(
            home: context.home,
            serverName: "shared-browser",
            command: "/usr/bin/false"
        )

        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)
        let candidate = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "shared-browser" }
        )
        #expect(Set(candidate.configurationOwners.map(\.source)) == ["codex", "claude_desktop"])
        let tool = makeImportedStdioTool(id: "shared_browser_echo", candidate: candidate)
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool],
            bridgeIdentity: candidate.bridgeIdentity
        )

        try FileManager.default.removeItem(at: context.home.appendingPathComponent(".codex/config.toml"))
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)

        #expect(context.model.tools.contains { $0.id == tool.id })
        #expect(context.model.localMCPScanState.candidates.count { $0.displayName == "shared-browser" } == 1)

        try FileManager.default.removeItem(at: claudeConfig)
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForToolRemoval(tool.id, on: context.model)
        #expect(context.model.tools.contains { $0.id == tool.id } == false)
    }

    @MainActor
    @Test func sameConfigOwnerKeepsFamilyAcrossRuntimeChangeAndRefreshMatching() throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }
        let oldCandidate = makeOwnedCandidate(
            source: "codex",
            sourcePath: context.home.appendingPathComponent(".codex/config.toml").path,
            args: ["old"]
        )
        let newCandidate = makeOwnedCandidate(
            source: "codex",
            sourcePath: context.home.appendingPathComponent(".codex/config.toml").path,
            args: ["new"]
        )
        let tool = makeImportedStdioTool(id: "owned_server_echo", candidate: oldCandidate)
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool],
            bridgeIdentity: oldCandidate.bridgeIdentity
        )

        #expect(oldCandidate.persistedServerIdentity != newCandidate.persistedServerIdentity)
        #expect(
            oldCandidate.configurationOwners.map(\.serverIdentity) ==
                newCandidate.configurationOwners.map(\.serverIdentity)
        )
        #expect(context.model.reconcileImportedMCPTools(with: [newCandidate]) == 0)
        #expect(
            AppModel.refreshableImportedMCPTools(for: newCandidate, in: context.model.tools).map(\.id) ==
                [tool.id]
        )
        let refreshedDefinition = makeImportedStdioTool(id: tool.id, candidate: newCandidate)
        let replaced = try context.model.replaceLocalMCPBridgeTools(
            [refreshedDefinition],
            bridgeIdentity: newCandidate.bridgeIdentity
        )
        let refreshed = try #require(context.model.tools.first { $0.id == tool.id })
        #expect(replaced.replacedCount == 1)
        #expect(refreshed.id == tool.id)
        #expect(refreshed.permissionEpoch == tool.permissionEpoch)
        #expect(refreshed.mcpStdioBridge?.args == ["new"])
        #expect(refreshed.securityFingerprint != tool.securityFingerprint)
    }

    @MainActor
    @Test func unreadableOneOfSeveralRecordedOwnersPreservesFamily() throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }
        let claudeRoot = context.home.appendingPathComponent(
            "Library/Application Support/Claude/Claude Extensions",
            isDirectory: true
        )
        let failedSubtree = claudeRoot.appendingPathComponent("Browser", isDirectory: true)
        var candidate = makeOwnedCandidate(
            source: "codex",
            sourcePath: context.home.appendingPathComponent(".codex/config.toml").path
        )
        candidate.discoveryOwners = candidate.configurationOwners + [MCPDiscoveryOwner(
            serverIdentity: "claude_extension.browser.owner",
            source: "claude_extension",
            sourcePath: failedSubtree.appendingPathComponent("manifest.json").path
        )]
        let tool = makeImportedStdioTool(id: "multi_owner_echo", candidate: candidate)
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool],
            bridgeIdentity: candidate.bridgeIdentity
        )
        let sentinel = LocalMCPServerCandidate(
            id: "claude_extension.browser.unreadable",
            source: "claude_extension",
            sourcePath: failedSubtree.path,
            name: "browser",
            displayName: "Browser",
            transport: .stdio,
            url: nil,
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: false,
            bridgeable: false,
            reason: "Could not read this extensions directory.",
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil,
            sourceReadFailureScopePath: failedSubtree.path
        )

        #expect(context.model.reconcileImportedMCPTools(with: [sentinel]) == 0)
        #expect(context.model.tools.contains { $0.id == tool.id })
    }

    @MainActor
    @Test func sameCommandDifferentEnvironmentProfilesDoNotReplaceEachOther() throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }
        let firstCandidate = makeOwnedCandidate(
            source: "codex",
            sourcePath: "/tmp/codex.toml",
            environment: [MCPStdioEnvironmentVariable(name: "PROFILE", value: "codex")]
        )
        let secondCandidate = makeOwnedCandidate(
            source: "claude_desktop",
            sourcePath: "/tmp/claude.json",
            environment: [MCPStdioEnvironmentVariable(name: "PROFILE", value: "claude")]
        )
        let first = makeImportedStdioTool(id: "browser_echo", candidate: firstCandidate)
        let second = makeImportedStdioTool(id: "browser_echo_2", candidate: secondCandidate)
        _ = try context.model.replaceLocalMCPBridgeTools(
            [first],
            bridgeIdentity: firstCandidate.bridgeIdentity
        )
        let replaced = try context.model.replaceLocalMCPBridgeTools(
            [second],
            bridgeIdentity: secondCandidate.bridgeIdentity
        )

        #expect(firstCandidate.bridgeIdentity == secondCandidate.bridgeIdentity)
        #expect(firstCandidate.persistedServerIdentity != secondCandidate.persistedServerIdentity)
        #expect(replaced.replacedCount == 0)
        #expect(Set(context.model.tools.map(\.id)) == [first.id, second.id])
    }

    @MainActor
    @Test func explicitDirectEndpointIsNotTreatedAsMissingConfig() throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        let tool = ToolDefinition(
            id: "manual_endpoint_echo",
            name: "Manual Endpoint: Echo",
            summary: "Explicit direct endpoint.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1_024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverIdentity: "manual.endpoint.0123456789abcdef",
                discoverySource: "manual",
                serverName: "Manual Endpoint",
                serverURL: "http://127.0.0.1:39725/mcp",
                toolName: "echo"
            )
        )
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool],
            bridgeIdentity: tool.mcpBridgeIdentity
        )

        #expect(context.model.reconcileImportedMCPTools(with: []) == 0)
        #expect(context.model.tools.contains { $0.id == tool.id })
        #expect(context.model.toolSurfaceRuntime.tool(id: tool.id) != nil)
    }

    @MainActor
    @Test func legacyBridgeExactMatchIsNeitherStampedNorDeleted() async throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }

        try writeCodexHTTPFixture(
            home: context.home,
            serverName: "legacy-server",
            url: "http://127.0.0.1:45678/mcp"
        )
        context.model.refreshLocalMCPDiscovery(trigger: .launch)
        await waitForMCPRefresh(on: context.model)
        let candidate = try #require(
            context.model.localMCPScanState.candidates.first { $0.displayName == "legacy-server" }
        )

        let legacyTool = ToolDefinition(
            id: "legacy_unowned_echo",
            name: "legacy-server: Echo",
            summary: "Predates persisted scanner ownership.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1_024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "legacy-server",
                serverURL: "http://127.0.0.1:45678/mcp",
                toolName: "echo"
            )
        )
        _ = try context.model.replaceLocalMCPBridgeTools(
            [legacyTool],
            bridgeIdentity: legacyTool.mcpBridgeIdentity
        )

        #expect(context.model.reconcileImportedMCPTools(with: [candidate]) == 0)
        let stillLegacy = try #require(context.model.tools.first { $0.id == legacyTool.id })
        #expect(stillLegacy.mcpBridgeServerIdentity == nil)
        #expect(stillLegacy.mcpBridgeDiscoverySource == nil)
        #expect(stillLegacy.mcpBridgeDiscoverySourcePath == nil)

        #expect(context.model.reconcileImportedMCPTools(with: []) == 0)
        #expect(context.model.tools.contains { $0.id == legacyTool.id })
        let persisted = try #require(
            ToolRegistryStore(fileURL: context.storeURL).loadUserDefinedTools().first
        )
        #expect(persisted.id == legacyTool.id)
        #expect(persisted.mcpBridgeServerIdentity == nil)
        #expect(persisted.mcpBridgeDiscoverySource == nil)
        #expect(persisted.mcpBridgeDiscoverySourcePath == nil)
        #expect(context.model.toolSurfaceRuntime.tool(id: legacyTool.id) != nil)
    }

    @MainActor
    @Test func claudeExtensionSubtreeReadFailurePreservesOwnedTool() throws {
        let context = try makeMCPDiscoveryContext(processRunner: CountingProcessRunner())
        defer { context.tearDown() }
        let root = context.home.appendingPathComponent(
            "Library/Application Support/Claude/Claude Extensions",
            isDirectory: true
        )
        let failedSubtree = root.appendingPathComponent("Unavailable", isDirectory: true)
        let manifest = failedSubtree.appendingPathComponent("manifest.json")
        let tool = ToolDefinition(
            id: "unavailable_extension_echo",
            name: "Unavailable Extension: Echo",
            summary: "Config-owned extension tool.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1_024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverIdentity: "claude_extension.unavailable.0123456789abcdef",
                discoverySource: "claude_extension",
                discoverySourcePath: manifest.path,
                serverName: "Unavailable Extension",
                serverURL: "http://127.0.0.1:45679/mcp",
                toolName: "echo"
            )
        )
        _ = try context.model.replaceLocalMCPBridgeTools(
            [tool],
            bridgeIdentity: tool.mcpBridgeIdentity
        )
        let sentinel = LocalMCPServerCandidate(
            id: "claude_extension.unavailable",
            source: "claude_extension",
            sourcePath: failedSubtree.path,
            name: "unavailable",
            displayName: "Unavailable",
            transport: .stdio,
            url: nil,
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: false,
            bridgeable: false,
            reason: "Could not read this extensions directory.",
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil,
            sourceReadFailureScopePath: failedSubtree.path
        )

        #expect(context.model.reconcileImportedMCPTools(with: [sentinel]) == 0)
        #expect(context.model.tools.contains { $0.id == tool.id })
        #expect(context.model.toolSurfaceRuntime.tool(id: tool.id) != nil)
    }
}

// MARK: - Helpers

private actor CountingProcessRunner: ProcessRunning {
    private(set) var invocationCount = 0

    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String],
        standardInput: String?
    ) async throws -> CommandRunResult {
        invocationCount += 1
        return CommandRunResult(
            executablePath: executablePath,
            arguments: arguments,
            exitCode: 0,
            stdout: "",
            stderr: "",
            duration: 0,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

@MainActor
private func waitForMCPRefresh(on model: AppModel, attempts: Int = 500) async {
    for _ in 0..<attempts {
        if case .loaded = model.localMCPScanState { return }
        if case .failed = model.localMCPScanState { return }
        await Task.yield()
    }
}

@MainActor
private func waitForMCPManualScan(on model: AppModel, attempts: Int = 5000) async {
    for _ in 0..<attempts {
        if !model.localMCPScanState.isScanning { return }
        await Task.yield()
    }
}

private func makeTemporaryHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func writeCodexFixture(home: URL, serverName: String, command: String) throws {
    let configURL = home.appendingPathComponent(".codex/config.toml")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    [mcp_servers.\(serverName)]
    command = "\(command)"
    """.utf8).write(to: configURL)
}

private func writeCodexHTTPFixture(home: URL, serverName: String, url: String) throws {
    let configURL = home.appendingPathComponent(".codex/config.toml")
    try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("""
    [mcp_servers.\(serverName)]
    url = "\(url)"
    """.utf8).write(to: configURL)
}

@discardableResult
private func writeClaudeDesktopFixture(home: URL, serverName: String, command: String) throws -> URL {
    let configURL = home.appendingPathComponent(
        "Library/Application Support/Claude/claude_desktop_config.json"
    )
    try FileManager.default.createDirectory(
        at: configURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try Data("""
    {"mcpServers":{"\(serverName)":{"command":"\(command)"}}}
    """.utf8).write(to: configURL)
    return configURL
}

private func makeImportedStdioTool(
    id: String,
    candidate: LocalMCPServerCandidate,
    upstreamToolName: String = "echo",
    capability: ToolCapability = .readOnly
) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: "\(candidate.displayName): Echo",
        summary: "Imported test tool.",
        executablePath: "",
        argumentPattern: [],
        parameters: [],
        capability: capability,
        timeoutSeconds: 5,
        outputByteLimit: 1_024,
        origin: .userDefined,
        category: .developer,
        backend: .mcpStdioBridge,
        mcpStdioBridge: MCPStdioBridgeConfiguration(
            serverIdentity: candidate.persistedServerIdentity,
            discoverySource: candidate.source,
            discoverySourcePath: candidate.sourcePath,
            discoveryOwners: candidate.configurationOwners,
            serverName: candidate.displayName,
            command: candidate.command ?? "/usr/bin/false",
            args: candidate.args,
            toolName: upstreamToolName,
            environment: candidate.environment
        )
    )
}

private func makeOwnedCandidate(
    source: String,
    sourcePath: String,
    args: [String] = [],
    environment: [MCPStdioEnvironmentVariable] = []
) -> LocalMCPServerCandidate {
    LocalMCPServerCandidate(
        id: "\(source).owned-server",
        source: source,
        sourcePath: sourcePath,
        name: "owned-server",
        displayName: "owned-server",
        transport: .stdio,
        url: nil,
        command: "/usr/bin/false",
        args: args,
        startupTimeoutSeconds: nil,
        isLocal: false,
        bridgeable: true,
        reason: nil,
        headers: [],
        environment: environment
    )
}

@MainActor
private func waitForToolRemoval(_ toolID: String, on model: AppModel, attempts: Int = 2_000) async {
    for _ in 0..<attempts {
        if !model.tools.contains(where: { $0.id == toolID }) { return }
        await Task.yield()
    }
}

private struct MCPDiscoveryContext {
    let home: URL
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let storeURL: URL
    let mcpCacheURL: URL
    let model: AppModel
    let processRunner: any ProcessRunning

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeMCPDiscoveryContext(
    processRunner: any ProcessRunning,
    prewriteMCPCache: Data? = nil
) throws -> MCPDiscoveryContext {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let suiteName = "MacRemoteAutomaticDiscoveryTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "AutomaticDiscoveryTests", code: 1)
    }
    defaults.removePersistentDomain(forName: suiteName)

    let storeURL = root.appendingPathComponent("tools.json")
    let mcpCacheURL = root.appendingPathComponent("mcp-scan-cache.json")
    if let prewriteMCPCache {
        try prewriteMCPCache.write(to: mcpCacheURL)
    }

    let scanner = LocalMCPScanner(
        homeDirectory: home,
        executablePath: { _ in nil },
        processRunner: processRunner,
        stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
    )
    let model = makeTestAppModel(
        userDefaults: defaults,
        toolStore: ToolRegistryStore(fileURL: storeURL),
        localMCPScanner: scanner
    )

    return MCPDiscoveryContext(
        home: home,
        root: root,
        suiteName: suiteName,
        defaults: defaults,
        storeURL: storeURL,
        mcpCacheURL: mcpCacheURL,
        model: model,
        processRunner: processRunner
    )
}

private struct CLIFreshnessContext {
    let suiteName: String
    let defaults: UserDefaults
    let storeURL: URL
    let cliCacheURL: URL
    let scanner: LocalCLIScanner
    let root: URL

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func makeCLIFreshnessContext() throws -> CLIFreshnessContext {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let home = root.appendingPathComponent("home")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

    let suiteName = "MacRemoteCLIFreshnessTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        throw NSError(domain: "AutomaticDiscoveryTests", code: 2)
    }
    defaults.removePersistentDomain(forName: suiteName)

    let storeURL = root.appendingPathComponent("tools.json")
    let cliCacheURL = root.appendingPathComponent("cli-scan-cache.json")
    let scanner = LocalCLIScanner(
        homeDirectory: home.path,
        brewPrefix: root.appendingPathComponent("homebrew").path,
        apiCacheDirectory: root.appendingPathComponent("api").path,
        etcShellsPath: root.appendingPathComponent("shells").path,
        binDirectories: [],
        presetExecutablePaths: [],
        originDomainReader: { _ in nil }
    )

    return CLIFreshnessContext(
        suiteName: suiteName,
        defaults: defaults,
        storeURL: storeURL,
        cliCacheURL: cliCacheURL,
        scanner: scanner,
        root: root
    )
}
