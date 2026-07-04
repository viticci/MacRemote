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
        let expectedHash = SHA256.hash(data: Data("http:\(secretURL)".utf8))
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
            seenResolvedPaths: [],
            sourceFingerprints: [CLIScanSource.homebrew.rawValue: "stale-value"]
        )
        try JSONEncoder().encode(staleCache).write(to: context.cliCacheURL)

        let model = AppModel(
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
            seenResolvedPaths: [],
            sourceFingerprints: Dictionary(uniqueKeysWithValues: live.map { ($0.key.rawValue, $0.value) })
        )
        try JSONEncoder().encode(matchingCache).write(to: context.cliCacheURL)

        let freshModel = AppModel(
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
    let model = AppModel(
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
