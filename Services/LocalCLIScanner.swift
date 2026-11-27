import Darwin
import Foundation

// MARK: - File-reading dependency

struct CLIFileAttributes: Equatable, Sendable {
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let isExecutable: Bool
    let fileSize: Int
    let modificationDate: Date?
    let posixPermissions: UInt16
}

/// Every filesystem touch the scanner makes goes through this seam so source
/// parsers are testable against fixtures (spec §7) and the zero-execution
/// guarantee stays reviewable: reads, stats, symlink resolution, and xattr
/// listing are the complete vocabulary.
protocol FileReading: Sendable {
    func fileExists(atPath path: String) -> Bool
    func attributes(atPath path: String) -> CLIFileAttributes?
    func contentsOfDirectory(atPath path: String) -> [String]
    func contents(atPath path: String, maxBytes: Int) -> Data?
    func contents(atPath path: String, offset: UInt64, maxBytes: Int) -> Data?
    func destinationOfSymbolicLink(atPath path: String) -> String?
    func realPath(_ path: String) -> String
    /// The `com.apple.quarantine` value of the file (following symlinks), or nil.
    func quarantineValue(atPath path: String) -> String?
    func isLocalVolume(atPath path: String) -> Bool
}

/// FileManager/Darwin-backed reader. Content reads run with dataless-file
/// materialization disabled so a scan can never trigger an iCloud/FileProvider
/// download (spec §2.1 rule 2).
struct DefaultFileReader: FileReading {
    init() {}

    func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    func attributes(atPath path: String) -> CLIFileAttributes? {
        guard let raw = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        let type = raw[.type] as? FileAttributeType
        return CLIFileAttributes(
            isDirectory: type == .typeDirectory,
            isSymbolicLink: type == .typeSymbolicLink,
            isExecutable: FileManager.default.isExecutableFile(atPath: path),
            fileSize: (raw[.size] as? NSNumber)?.intValue ?? 0,
            modificationDate: raw[.modificationDate] as? Date,
            posixPermissions: (raw[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        )
    }

    func contentsOfDirectory(atPath path: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
    }

    func contents(atPath path: String, maxBytes: Int) -> Data? {
        contents(atPath: path, offset: 0, maxBytes: maxBytes)
    }

    func contents(atPath path: String, offset: UInt64, maxBytes: Int) -> Data? {
        withDatalessMaterializationDisabled {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            if offset > 0 {
                guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
            }
            return try? handle.read(upToCount: maxBytes)
        }
    }

    func destinationOfSymbolicLink(atPath path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    func realPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    func quarantineValue(atPath path: String) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer[0..<read], as: UTF8.self)
    }

    func isLocalVolume(atPath path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey]),
              let isLocal = values.volumeIsLocal else {
            return true
        }
        return isLocal
    }

    private func withDatalessMaterializationDisabled<T>(_ body: () -> T) -> T {
        // sys/resource.h: IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES(3),
        // IOPOL_SCOPE_THREAD(1), IOPOL_MATERIALIZE_DATALESS_FILES_OFF(1).
        let policyType: Int32 = 3
        let threadScope: Int32 = 1
        let previous = getiopolicy_np(policyType, threadScope)
        _ = setiopolicy_np(policyType, threadScope, 1)
        defer { _ = setiopolicy_np(policyType, threadScope, previous) }
        return body()
    }
}

// MARK: - Scan result

/// One finished scan's payload: merged candidates + per-source bookkeeping.
struct CLIScanResult: Sendable {
    let candidates: [DiscoveredCLICandidate]
    let sourceProgress: [CLISourceProgress]
    let completedSources: [CLIScanSource]
    let failures: [CLIScanSource: String]
    let wasCanceled: Bool
    let startedAt: Date
    let finishedAt: Date
    /// Fingerprints for sources that completed, keyed by raw value.
    let sourceFingerprints: [String: String]
    /// The new seen-set to persist at scan completion (DL-11).
    let seenStablePaths: Set<String>

    var sourceErrors: [CLIScanSource: String] { failures }

    var scanState: CLIScanState {
        if wasCanceled {
            return .canceled(candidates, completed: completedSources, finishedAt)
        }
        if completedSources.isEmpty, !failures.isEmpty {
            let reason = failures
                .sorted { $0.key.rawValue < $1.key.rawValue }
                .map(\.value)
                .first ?? "The scan couldn't finish."
            return .failed(reason, partial: candidates, finishedAt)
        }
        return .loaded(candidates, finishedAt)
    }
}

// MARK: - Scanner

/// The zero-execution CLI discovery engine (spec §2). Identifies installed
/// command-line tools purely from install records — receipts, manifests, man
/// pages, static code signatures — and never launches anything it finds.
/// Results are inert `DiscoveredCLICandidate` values; promotion to tools
/// happens only through the review UI and the existing draft pipeline (R3).
struct LocalCLIScanner: Sendable {
    typealias Outcome = CLIScanResult

    static let metadataFileByteLimit = 1024 * 1024          // DL-15
    static let scriptSniffByteLimit = CLIBinaryInspector.scriptSniffByteLimit
    static let goBuildInfoWindowBytes = 4 * 1024 * 1024
    static let goBuildInfoScanLimitBytes = 256 * 1024 * 1024
    static let maximumSymlinkHops = 8
    static let scanPolicyRevision = 2

    let fileReader: any FileReading
    let signatureReader: any SignatureReading
    let homeDirectory: String
    let brewPrefix: String

    /// Homebrew lives in /opt/homebrew on Apple silicon and /usr/local on
    /// Intel. The app ships for both, so the prefix is looked up, not assumed.
    static var installedBrewPrefix: String {
        FileManager.default.fileExists(atPath: "/opt/homebrew/Cellar") || !FileManager.default.fileExists(atPath: "/usr/local/Cellar")
            ? "/opt/homebrew"
            : "/usr/local"
    }
    let apiCacheDirectory: String
    let etcShellsPath: String
    let timeBudget: TimeInterval
    let maximumEntriesPerDirectory: Int
    private let binDirectoriesOverride: [String]?
    private let presetExecutablePathsOverride: [String]?
    private let originDomainReader: @Sendable (String) -> String?
    private let now: @Sendable () -> Date

    init(
        fileReader: any FileReading = DefaultFileReader(),
        signatureReader: any SignatureReading = CodeSignatureReader(),
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        brewPrefix: String = LocalCLIScanner.installedBrewPrefix,
        apiCacheDirectory: String? = nil,
        etcShellsPath: String = "/etc/shells",
        binDirectories: [String]? = nil,
        presetExecutablePaths: [String]? = nil,
        originDomainReader: @escaping @Sendable (String) -> String? = { SpotlightOriginReader.originDomain(atPath: $0) },
        timeBudget: TimeInterval = 30,
        maximumEntriesPerDirectory: Int = 4096,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileReader = fileReader
        self.signatureReader = signatureReader
        self.homeDirectory = homeDirectory
        self.brewPrefix = brewPrefix
        self.apiCacheDirectory = apiCacheDirectory ?? homeDirectory + "/Library/Caches/Homebrew/api"
        self.etcShellsPath = etcShellsPath
        self.binDirectoriesOverride = binDirectories
        self.presetExecutablePathsOverride = presetExecutablePaths
        self.originDomainReader = originDomainReader
        self.timeBudget = timeBudget
        self.maximumEntriesPerDirectory = maximumEntriesPerDirectory
        self.now = now
    }

    // MARK: Scope (spec §2.3)

    /// Enumerated bin directories: `ExecutableLocator.searchDirectories` minus
    /// the system directories, plus `~/go/bin` and `~/Library/Python/*/bin`.
    /// System scope is excluded always — the curated catalog is the only
    /// channel for system tools.
    var inScopeBinDirectories: [String] {
        if let binDirectoriesOverride {
            return binDirectoriesOverride
        }
        let systemDirectories: Set<String> = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var directories = ExecutableLocator.searchDirectories.filter { path in
            !systemDirectories.contains(path)
                && !path.hasPrefix("/System")
                && !path.contains("/Cryptexes/")
        }
        directories.append(homeDirectory + "/go/bin")
        let pythonRoot = homeDirectory + "/Library/Python"
        for version in fileReader.contentsOfDirectory(atPath: pythonRoot) {
            directories.append(pythonRoot + "/" + version + "/bin")
        }
        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    private var brewBinDirectories: [String] {
        var directories = [brewPrefix + "/bin", brewPrefix + "/sbin"]
        if brewPrefix != "/usr/local", fileReader.fileExists(atPath: "/usr/local/Cellar") {
            directories += ["/usr/local/bin", "/usr/local/sbin"]
        }
        return directories.filter { inScopeBinDirectories.contains($0) }
    }

    private var goBinDirectory: String { homeDirectory + "/go/bin" }

    /// Executables the Library already shows as curated rows. Besides the
    /// process presets, that is every installed first-party CLI with its own
    /// MCP server (SPEC D86): Found on This Mac lists it under Federico
    /// Viticci, never as a raw scan hit. A test's override is the whole list.
    private var presetExecutablePaths: [String] {
        if let presetExecutablePathsOverride { return presetExecutablePathsOverride }
        return DefaultToolPresetCatalog.presets.map(\.executablePath)
            + FirstPartyMCPProviderCatalog.detectedProviders().flatMap { detected in
                // Each installed name the CLI goes by, so `rctl` folds with
                // `remctl`. An alias that is not installed folds nothing.
                detected.provider.executableNames.compactMap { ExecutableLocator.executablePath(named: $0) }
            }
    }

    // MARK: Freshness fingerprints (spec §2.3)

    func fingerprints() -> [CLIScanSource: String] {
        var result = [CLIScanSource: String]()
        for source in CLIScanSource.allCases {
            result[source] = fingerprint(for: source)
        }
        return result
    }

    func fingerprint(for source: CLIScanSource) -> String {
        let sourceFingerprint: String
        switch source {
        case .homebrew:
            sourceFingerprint = [
                "bin=" + directoryStamp(brewPrefix + "/bin"),
                "sbin=" + directoryStamp(brewPrefix + "/sbin"),
                "cellar=" + mtimeStamp(brewPrefix + "/Cellar"),
                "cask=" + mtimeStamp(brewPrefix + "/Caskroom"),
                "linked=" + String(fileReader.contentsOfDirectory(atPath: brewPrefix + "/var/homebrew/linked").count),
                "jws=" + mtimeStamp(apiCacheDirectory + "/formula.jws.json")
            ].joined(separator: "|")
        case .npm:
            sourceFingerprint = directoryStamp(brewPrefix + "/lib/node_modules")
        case .python:
            var parts = [
                "uv=" + mtimeStamp(homeDirectory + "/.local/share/uv/tools"),
                "pipx=" + mtimeStamp(homeDirectory + "/.local/pipx/venvs"),
                "pipx2=" + mtimeStamp(homeDirectory + "/.local/share/pipx/venvs")
            ]
            let pythonRoot = homeDirectory + "/Library/Python"
            for version in fileReader.contentsOfDirectory(atPath: pythonRoot) {
                parts.append("py-\(version)=" + directoryStamp(pythonRoot + "/" + version + "/bin"))
            }
            sourceFingerprint = parts.joined(separator: "|")
        case .cargo:
            sourceFingerprint = "crates=" + mtimeStamp(homeDirectory + "/.cargo/.crates2.json")
                + "|bin=" + directoryStamp(homeDirectory + "/.cargo/bin")
        case .go:
            sourceFingerprint = directoryStamp(goBinDirectory)
        case .pathFolders:
            // Homebrew's folders count too: this source reads the tools
            // Homebrew links in from outside its own folders.
            sourceFingerprint = (brewBinDirectories + pathFolderDirectories)
                .map { directory in
                    ((directory as NSString).lastPathComponent) + "=" + directoryStamp(directory)
                }
                .joined(separator: "|")
        }
        return "policy=\(Self.scanPolicyRevision)|" + sourceFingerprint
    }

    private var pathFolderDirectories: [String] {
        let claimed = Set(brewBinDirectories + [goBinDirectory])
        return inScopeBinDirectories.filter { !claimed.contains($0) }
    }

    private func directoryStamp(_ path: String) -> String {
        guard let attributes = fileReader.attributes(atPath: path) else { return "-" }
        let count = fileReader.contentsOfDirectory(atPath: path).count
        return "\(Int(attributes.modificationDate?.timeIntervalSince1970 ?? 0)):\(count)"
    }

    private func mtimeStamp(_ path: String) -> String {
        guard let attributes = fileReader.attributes(atPath: path) else { return "-" }
        return String(Int(attributes.modificationDate?.timeIntervalSince1970 ?? 0))
    }

    // MARK: Scan entry point (spec §2.2)

    /// Scans the selected sources and returns merged, deduplicated, sorted
    /// candidates. `previousCache` powers warm re-scans (unchanged fingerprints
    /// reuse cached candidates) and the "New since last scan" flag; `baseline`
    /// carries candidates from sources outside `sources` (single-source retry).
    /// The 30-second global budget fails individual sources, never the scan.
    /// Cancellation is cooperative: cancel the enclosing `Task` (or flip
    /// `isCancelled`) and completed sources are kept.
    func scan(
        sources: some Sequence<CLIScanSource> & Sendable = CLIScanSource.allCases,
        previousCache: CLIScanCache? = nil,
        merging baseline: [DiscoveredCLICandidate] = [],
        isCancelled: @escaping @Sendable () -> Bool = { false },
        onProgress: @escaping @Sendable (CLISourceProgress, [DiscoveredCLICandidate]) -> Void = { _, _ in }
    ) async -> CLIScanResult {
        let sources = Set(sources)
        let startedAt = now()
        var context = ScanContext(
            deadline: startedAt.addingTimeInterval(timeBudget),
            isCancelled: isCancelled,
            catalogIndex: HomebrewCatalogIndex.load(apiCacheDirectory: apiCacheDirectory, fileReader: fileReader),
            shellPaths: loadShellPaths(),
            previousSeenStablePaths: previousCache?.seenStablePaths ?? [],
            previousNewnessScopes: Self.newnessScopes(from: previousCache),
            now: now
        )

        var results = baseline.filter { !sources.contains($0.source.scanSource) }
        context.registerMintedIDs(of: results)

        var progressBySource = [CLIScanSource: CLISourceProgress]()
        for source in CLIScanSource.allCases where sources.contains(source) {
            progressBySource[source] = CLISourceProgress(source: source, phase: .pending)
        }

        var completed = [CLIScanSource]()
        var errors = [CLIScanSource: String]()
        var recordedFingerprints = [String: String]()
        var wasCanceled = false

        for source in CLIScanSource.allCases where sources.contains(source) {
            guard !wasCanceled else { break }
            if isCancelled() || Task.isCancelled {
                wasCanceled = true
                break
            }
            let currentFingerprint = fingerprint(for: source)

            if let previousCache,
               let previousFingerprint = previousCache.fingerprint(for: source),
               previousFingerprint == currentFingerprint {
                let reused = previousCache.candidates
                    .filter { $0.source.scanSource == source }
                    .map {
                        $0.replacing(
                            isNewSinceLastScan: false,
                            // A wrapper may point somewhere new without
                            // changing any fingerprint, so resolve it again.
                            isQuarantined: isQuarantined(
                                stablePath: $0.stablePath,
                                resolvedPath: CLIBinaryInspector.executionTarget(
                                    ofExecutableAt: $0.stablePath,
                                    fileReader: fileReader
                                )
                            )
                        )
                    }
                context.registerMintedIDs(of: reused)
                results.append(contentsOf: reused)
                let progress = CLISourceProgress(source: source, phase: .done(count: reused.count))
                progressBySource[source] = progress
                completed.append(source)
                recordedFingerprints[source.rawValue] = currentFingerprint
                onProgress(progress, results)
                continue
            }

            var progress = CLISourceProgress(source: source, phase: .enumerating)
            progressBySource[source] = progress
            onProgress(progress, results)

            do {
                let found = try scanPhase(source, context: &context)
                results.append(contentsOf: found)
                progress.phase = .done(count: found.count)
                completed.append(source)
                recordedFingerprints[source.rawValue] = currentFingerprint
            } catch ScanInterrupt.canceled {
                wasCanceled = true
                progress.phase = .pending
            } catch ScanInterrupt.budgetExceeded {
                let message = "Ran out of time reading \(source.displayName)."
                errors[source] = message
                progress.phase = .failed(message)
            } catch {
                let message = "Couldn't read \(source.displayName)'s records: \(error.localizedDescription)"
                errors[source] = message
                progress.phase = .failed(message)
            }
            progressBySource[source] = progress
            onProgress(progress, results)
            await Task.yield()
        }

        results = foldedIntoPresets(results)
        results = deduplicated(results)
        results.sort(by: Self.displayOrder)

        let finishedAt = now()
        return CLIScanResult(
            candidates: results,
            sourceProgress: CLIScanSource.allCases.compactMap { progressBySource[$0] },
            completedSources: completed,
            failures: errors,
            wasCanceled: wasCanceled,
            startedAt: startedAt,
            finishedAt: finishedAt,
            sourceFingerprints: recordedFingerprints,
            seenStablePaths: Set(results.map(\.stablePath))
        )
    }

    private func scanPhase(_ source: CLIScanSource, context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        switch source {
        case .homebrew: try scanHomebrew(context: &context)
        case .npm: try scanNpmGlobals(context: &context)
        case .python: try scanPythonTools(context: &context)
        case .cargo: try scanCargoInstalls(context: &context)
        case .go: try scanGoBinaries(context: &context)
        case .pathFolders: try scanPathFolders(context: &context)
        }
    }

    private func loadShellPaths() -> Set<String> {
        guard let data = fileReader.contents(atPath: etcShellsPath, maxBytes: 64 * 1024) else {
            return []
        }
        return CLIRecommendationBlocklist.shellPaths(fromEtcShells: String(decoding: data, as: UTF8.self))
    }

    // MARK: Shared scan context

    private struct ScanContext {
        let deadline: Date
        let isCancelled: @Sendable () -> Bool
        let catalogIndex: HomebrewCatalogIndex
        let shellPaths: Set<String>
        let previousSeenStablePaths: Set<String>
        let previousNewnessScopes: Set<String>
        let now: @Sendable () -> Date
        var mintedIDs = Set<String>()

        func checkInterrupt() throws {
            if isCancelled() || Task.isCancelled {
                throw ScanInterrupt.canceled
            }
            if now() > deadline {
                throw ScanInterrupt.budgetExceeded
            }
        }

        mutating func registerMintedIDs(of candidates: [DiscoveredCLICandidate]) {
            for candidate in candidates {
                mintedIDs.insert(candidate.id)
            }
        }

        mutating func mintID(source: DiscoveredCLICandidate.Source, binaryName: String) -> String {
            let candidate = ToolIdentifier.scannedToolID(
                source: source,
                binaryName: binaryName,
                existingIDs: mintedIDs
            )
            mintedIDs.insert(candidate)
            return candidate
        }
    }

    private static func newnessScopes(from cache: CLIScanCache?) -> Set<String> {
        guard let cache else { return [] }
        var scopes = Set(cache.candidates.map(\.newnessScope))
        for rawSource in cache.sourceFingerprints.keys {
            guard let source = CLIScanSource(rawValue: rawSource), source != .pathFolders else {
                continue
            }
            scopes.insert("source:" + rawSource)
        }
        return scopes
    }

    private enum ScanInterrupt: Error {
        case canceled
        case budgetExceeded
    }

    // MARK: Symlink routing (spec §2.4)

    struct Route {
        enum Kind: Equatable {
            case cellar(formula: String, version: String)
            case caskroom(token: String, version: String)
            case nodeModules(package: String)
            case uvTool(tool: String)
            case pipxVenv(package: String)
            case appBundle(bundlePath: String)
            case file
        }

        let literalName: String
        let stablePath: String
        let resolvedPath: String
        let chain: [String]
        let kind: Kind
        let inspection: CLIBinaryInspector.Inspection
    }

    func route(_ stablePath: String) -> Route? {
        guard let linkAttributes = fileReader.attributes(atPath: stablePath) else { return nil }
        if linkAttributes.isDirectory { return nil }

        var chain = [stablePath]
        var current = stablePath
        var hops = 0
        while hops < Self.maximumSymlinkHops,
              let attributes = fileReader.attributes(atPath: current),
              attributes.isSymbolicLink,
              let destination = fileReader.destinationOfSymbolicLink(atPath: current) {
            let absolute: String
            if destination.hasPrefix("/") {
                absolute = (destination as NSString).standardizingPath
            } else {
                let parent = (current as NSString).deletingLastPathComponent
                absolute = ((parent + "/" + destination) as NSString).standardizingPath
            }
            chain.append(absolute)
            current = absolute
            hops += 1
        }

        var resolvedPath = fileReader.realPath(stablePath)
        guard let finalAttributes = fileReader.attributes(atPath: resolvedPath), !finalAttributes.isDirectory else {
            return nil
        }
        guard finalAttributes.isExecutable else { return nil }

        var headData = fileReader.contents(atPath: resolvedPath, maxBytes: Self.scriptSniffByteLimit) ?? Data()
        var inspection = CLIBinaryInspector.inspect(headData: headData)

        // Wrapper-script sniff: a single `exec /abs/path "$@"` reveals the
        // real target; classify on the final hop (spec §2.4 step 3).
        if case .script = inspection,
           finalAttributes.fileSize <= Self.scriptSniffByteLimit,
           let target = CLIBinaryInspector.wrapperScriptTarget(inScriptData: headData),
           fileReader.fileExists(atPath: target) {
            chain.append(target)
            resolvedPath = fileReader.realPath(target)
            headData = fileReader.contents(atPath: resolvedPath, maxBytes: Self.scriptSniffByteLimit) ?? Data()
            inspection = CLIBinaryInspector.inspect(headData: headData)
        }

        var kind = Route.Kind.file
        var searchPaths = chain + [resolvedPath]
        if case .script(let interpreterLine) = inspection,
           let shebang = CLIBinaryInspector.shebangComponents(interpreterLine) {
            // uv/pipx entry scripts are plain files whose shebang points into
            // the tool venv — route on the interpreter path too (§2.5).
            searchPaths.append(shebang.path)
        }
        for path in searchPaths {
            if let matched = Self.routeKind(forPath: path) {
                kind = matched
                break
            }
        }

        return Route(
            literalName: (stablePath as NSString).lastPathComponent,
            stablePath: stablePath,
            resolvedPath: resolvedPath,
            chain: chain,
            kind: kind,
            inspection: inspection
        )
    }

    private static func routeKind(forPath path: String) -> Route.Kind? {
        let components = path.split(separator: "/").map(String.init)
        for (index, component) in components.enumerated() {
            if component == "Cellar", index + 2 < components.count {
                return .cellar(formula: components[index + 1], version: components[index + 2])
            }
            if component == "Caskroom", index + 2 < components.count {
                return .caskroom(token: components[index + 1], version: components[index + 2])
            }
            if component == "node_modules", index + 1 < components.count {
                var package = components[index + 1]
                if package.hasPrefix("@"), index + 2 < components.count {
                    package += "/" + components[index + 2]
                }
                return .nodeModules(package: package)
            }
            if component == "tools", index > 0, components[index - 1] == "uv", index + 1 < components.count {
                return .uvTool(tool: components[index + 1])
            }
            if component == "venvs", index > 0, components[index - 1] == "pipx", index + 1 < components.count {
                return .pipxVenv(package: components[index + 1])
            }
            if component.hasSuffix(".app"), index + 1 < components.count, components[index + 1] == "Contents" {
                let bundlePath = "/" + components[0...index].joined(separator: "/")
                return .appBundle(bundlePath: bundlePath)
            }
        }
        return nil
    }

    // MARK: Candidate construction (single choke point — R14)

    private struct CandidateSeed {
        var source: DiscoveredCLICandidate.Source
        var binaryName: String
        var stablePath: String
        var resolvedPath: String
        var chain: [String]
        var packageName: String?
        var version: String?
        var rawSummary: String?
        var summaryOrigin: String?
        var homepage: String?
        var siblingExecutables: [String] = []
        var installedOnRequest: Bool?
        var installDate: Date?
        var inspection: CLIBinaryInspector.Inspection
        var keywords: [String] = []
        var isDependencyOnly = false
    }

    /// True when the tool's file carries a quarantine flag macOS has not
    /// approved. macOS keeps the flag after the owner first opens a
    /// downloaded app and sets the user-approved bit (0x40) in it instead,
    /// so only a flag without that bit means "not yet opened by macOS".
    /// Read on every scan, including for reused results: removing or
    /// approving the flag changes no timestamp the source fingerprints see.
    func isQuarantined(stablePath: String, resolvedPath: String) -> Bool {
        [resolvedPath, stablePath].contains { path in
            Self.isUnapprovedQuarantine(fileReader.quarantineValue(atPath: path))
        }
    }

    /// `value` is the flag's text, "<hex flags>;<date>;<agent>;<id>". An
    /// unreadable flag counts as unapproved.
    static func isUnapprovedQuarantine(_ value: String?) -> Bool {
        guard let value else { return false }
        guard let field = value.split(separator: ";", omittingEmptySubsequences: false).first,
              let flags = UInt32(field, radix: 16) else {
            return true
        }
        return flags & 0x40 == 0
    }

    private func makeCandidate(_ seed: CandidateSeed, context: inout ScanContext) -> DiscoveredCLICandidate? {
        guard let binaryName = CLIHarvestedTextSanitizer.scrubbedDisplayText(seed.binaryName) else {
            return nil
        }

        // Blocklist rings on the resolved binary (R7, §4.3).
        let resolvedBasename = (seed.resolvedPath as NSString).lastPathComponent
        let verdict = CLIRecommendationBlocklist.verdict(
            literalBasename: binaryName,
            resolvedBasename: resolvedBasename,
            resolvedPath: seed.resolvedPath,
            shellPaths: context.shellPaths
        )
        if verdict == .drop {
            return nil
        }

        // Tamper heuristics are auto-Ring-1 (R21, §2.6).
        if CLIRecommendationBlocklist.isStagingPath(seed.stablePath, homeDirectory: homeDirectory)
            || CLIRecommendationBlocklist.isStagingPath(seed.resolvedPath, homeDirectory: homeDirectory)
            || CLIRecommendationBlocklist.isInsideApplicationBundle(seed.stablePath) {
            return nil
        }
        guard let resolvedAttributes = fileReader.attributes(atPath: seed.resolvedPath) else {
            return nil
        }
        let mode = resolvedAttributes.posixPermissions
        if mode & 0o4000 != 0 || mode & 0o2000 != 0 || mode & 0o002 != 0 {
            return nil
        }
        let containingDirectory = (seed.resolvedPath as NSString).deletingLastPathComponent
        if let directoryAttributes = fileReader.attributes(atPath: containingDirectory),
           directoryAttributes.posixPermissions & 0o002 != 0 {
            return nil
        }

        let fileKind = fileKind(for: seed.inspection)
        guard let fileKind else { return nil }   // unrecognized formats are skipped

        // One sanitizer, applied at harvest (R12–R14).
        var summary = CLIHarvestedTextSanitizer.sanitizedSummary(seed.rawSummary)
        var summaryOrigin = summary == nil ? nil : seed.summaryOrigin
        if summary == nil {
            if let fallback = fallbackSummary(for: seed, catalogIndex: context.catalogIndex) {
                summary = fallback.text
                summaryOrigin = fallback.origin
            }
        }
        let version = CLIHarvestedTextSanitizer.sanitizedVersion(seed.version)
        let packageName = CLIHarvestedTextSanitizer.sanitizedPackageName(seed.packageName)
        let homepage = CLIHarvestedTextSanitizer.sanitizedHomepage(seed.homepage)

        let isQuarantined = isQuarantined(stablePath: seed.stablePath, resolvedPath: seed.resolvedPath)

        let category = CLICategoryInference.inferredCategory(
            binaryName: binaryName,
            summary: summary,
            keywords: seed.keywords,
            source: seed.source
        )

        let siblings = seed.siblingExecutables
            .compactMap { CLIHarvestedTextSanitizer.scrubbedDisplayText($0) }
            .filter { $0 != binaryName }
        var uniqueSiblings = [String]()
        var seenSiblings = Set<String>()
        for sibling in siblings.sorted() where seenSiblings.insert(sibling).inserted {
            uniqueSiblings.append(sibling)
        }

        return DiscoveredCLICandidate(
            id: context.mintID(source: seed.source, binaryName: binaryName),
            source: seed.source,
            binaryName: binaryName,
            stablePath: seed.stablePath,
            resolvedPath: seed.resolvedPath,
            resolutionChain: seed.chain,
            aliases: [],
            packageName: packageName,
            version: version,
            summary: summary,
            summaryOrigin: summaryOrigin,
            homepage: homepage,
            siblingExecutables: uniqueSiblings,
            installedOnRequest: seed.installedOnRequest,
            installDate: seed.installDate,
            fileKind: fileKind,
            signature: signatureReader.signatureTrust(atPath: seed.resolvedPath),
            isQuarantined: isQuarantined,
            originDomain: CLIHarvestedTextSanitizer.sanitizedOriginDomain(originDomainReader(seed.resolvedPath)),
            isInterpreter: verdict == .interpreter,
            isDependencyOnly: seed.isDependencyOnly,
            suggestedCategory: category,
            isNewSinceLastScan: !context.previousSeenStablePaths.isEmpty
                && !context.previousSeenStablePaths.contains(seed.stablePath)
                && context.previousNewnessScopes.contains(
                    DiscoveredCLICandidate.newnessScope(
                        source: seed.source,
                        stablePath: seed.stablePath
                    )
                )
        )
    }

    private func fileKind(for inspection: CLIBinaryInspector.Inspection) -> DiscoveredCLICandidate.FileKind? {
        switch inspection {
        case .machO(let architectures):
            return .machO(architectures: architectures)
        case .universal:
            return .universal
        case .script(let interpreterLine):
            guard let shebang = CLIBinaryInspector.shebangComponents(interpreterLine) else {
                return .script(interpreter: interpreterLine, interpreterMissing: true)
            }
            var interpreterPath = shebang.path
            var missing = !fileReader.fileExists(atPath: interpreterPath)
            if (interpreterPath as NSString).lastPathComponent == "env",
               let named = shebang.arguments.first {
                if let located = ExecutableLocator.executablePath(named: named) {
                    interpreterPath = located
                    missing = false
                } else {
                    interpreterPath = named
                    missing = true
                }
            }
            return .script(interpreter: interpreterPath, interpreterMissing: missing)
        case .unknown:
            return nil
        }
    }

    /// Fallback description chain for candidates with no source metadata:
    /// man-page NAME first (local and specific), then the Homebrew catalog's
    /// executables map as a labeled suggestion (§2.5).
    private func fallbackSummary(
        for seed: CandidateSeed,
        catalogIndex: HomebrewCatalogIndex
    ) -> (text: String, origin: String)? {
        if let manText = manPageSummary(binaryName: seed.binaryName, stablePath: seed.stablePath, chain: seed.chain),
           let sanitized = CLIHarvestedTextSanitizer.sanitizedSummary(manText) {
            return (sanitized, "man page")
        }
        if let formula = catalogIndex.formulaName(forExecutable: seed.binaryName),
           let entry = catalogEntry(forFormula: formula, catalogIndex: catalogIndex),
           let sanitized = CLIHarvestedTextSanitizer.sanitizedSummary(entry.desc) {
            return (sanitized, "Homebrew catalog")
        }
        return nil
    }

    private func manPageSummary(binaryName: String, stablePath: String, chain: [String]) -> String? {
        var roots = [String]()
        for path in chain {
            if let range = path.range(of: "/Cellar/") {
                let after = path[range.upperBound...]
                let parts = after.split(separator: "/").map(String.init)
                if parts.count >= 2 {
                    let cellarRoot = String(path[..<range.upperBound])
                    roots.append("\(cellarRoot)\(parts[0])/\(parts[1])/share/man/man1")
                }
                break
            }
        }
        let binDirectory = (stablePath as NSString).deletingLastPathComponent
        let prefix = (binDirectory as NSString).deletingLastPathComponent
        roots.append(prefix + "/share/man/man1")

        for root in roots {
            for name in ["\(binaryName).1", "\(binaryName).1.gz"] {
                guard let data = fileReader.contents(atPath: root + "/" + name, maxBytes: Self.metadataFileByteLimit) else {
                    continue
                }
                if let summary = ManPageNameParser.nameSummary(from: data) {
                    return summary
                }
            }
        }
        return nil
    }

    // MARK: Homebrew (spec §2.5)

    private func scanHomebrew(context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        struct BinHit {
            let name: String
            let route: Route
            let version: String
        }
        var formulaHits = [String: [BinHit]]()
        var caskHits = [String: [BinHit]]()

        for directory in brewBinDirectories {
            guard fileReader.fileExists(atPath: directory), fileReader.isLocalVolume(atPath: directory) else {
                continue
            }
            for entry in cappedEntries(of: directory) {
                try context.checkInterrupt()
                guard let route = route(directory + "/" + entry) else { continue }
                switch route.kind {
                case .cellar(let formula, let version):
                    formulaHits[formula, default: []].append(BinHit(name: entry, route: route, version: version))
                case .caskroom(let token, let version):
                    caskHits[token, default: []].append(BinHit(name: entry, route: route, version: version))
                case .nodeModules:
                    continue   // the npm source reads the package manifests
                case .uvTool, .pipxVenv, .appBundle, .file:
                    continue   // not Homebrew's: the PATH source reads these
                }
            }
        }

        var candidates = [DiscoveredCLICandidate]()

        for (formula, hits) in formulaHits.sorted(by: { $0.key < $1.key }) {
            try context.checkInterrupt()
            guard let version = hits.first?.version else { continue }
            let receiptPath = "\(brewPrefix)/Cellar/\(formula)/\(version)/INSTALL_RECEIPT.json"
            let receipt = fileReader.contents(atPath: receiptPath, maxBytes: Self.metadataFileByteLimit)
                .flatMap(HomebrewInstallReceipt.parse)

            var source = DiscoveredCLICandidate.Source.homebrewFormula
            var entry = catalogEntry(forFormula: formula, catalogIndex: context.catalogIndex)
            if entry?.desc == nil,
               let tap = receipt?.tap, !tap.isEmpty, tap != "homebrew/core", tap != "homebrew/cask" {
                let tapComponents = tap.split(separator: "/").map(String.init)
                if tapComponents.count == 2 {
                    let tapFormulaPath = "\(brewPrefix)/Library/Taps/\(tapComponents[0])/homebrew-\(tapComponents[1])/Formula/\(formula).rb"
                    if let data = fileReader.contents(atPath: tapFormulaPath, maxBytes: Self.metadataFileByteLimit) {
                        let metadata = HomebrewTapFormulaParser.metadata(from: data)
                        if metadata.desc != nil || metadata.homepage != nil {
                            source = .homebrewTap
                            entry = HomebrewCatalogIndex.FormulaEntry(
                                name: formula,
                                desc: metadata.desc,
                                homepage: metadata.homepage,
                                license: nil,
                                aliases: entry?.aliases ?? [],
                                executables: entry?.executables ?? []
                            )
                        }
                    }
                }
            }

            let sorted = hits.sorted { $0.name < $1.name }
            let primary = sorted.first { $0.name == formula }
                ?? sorted.first { entry?.aliases.contains($0.name) == true }
                ?? sorted[0]
            let siblingNames = Set(sorted.map(\.name)).union(entry?.executables ?? [])

            let seed = CandidateSeed(
                source: source,
                binaryName: primary.name,
                stablePath: primary.route.stablePath,
                resolvedPath: primary.route.resolvedPath,
                chain: primary.route.chain,
                packageName: formula,
                version: version,
                rawSummary: entry?.desc,
                summaryOrigin: "Homebrew",
                homepage: entry?.homepage,
                siblingExecutables: Array(siblingNames),
                installedOnRequest: receipt?.installedOnRequest,
                installDate: receipt?.installDate,
                inspection: primary.route.inspection,
                isDependencyOnly: (receipt?.installedAsDependency ?? false) && receipt?.installedOnRequest != true
            )
            if let candidate = makeCandidate(seed, context: &context) {
                candidates.append(candidate)
            }
        }

        for (token, hits) in caskHits.sorted(by: { $0.key < $1.key }) {
            try context.checkInterrupt()
            if let candidate = makeCaskCandidate(token: token, hits: hits.map { ($0.name, $0.route, $0.version) }, context: &context) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func catalogEntry(
        forFormula formula: String,
        catalogIndex: HomebrewCatalogIndex
    ) -> HomebrewCatalogIndex.FormulaEntry? {
        if let entry = catalogIndex.entry(forFormula: formula) {
            return entry
        }
        // Per-formula API cache fallback.
        guard let data = fileReader.contents(
            atPath: apiCacheDirectory + "/formula/\(formula).json",
            maxBytes: Self.metadataFileByteLimit
        ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return HomebrewCatalogIndex.formulaEntry(name: formula, object: object)
    }

    private func makeCaskCandidate(
        token: String,
        hits: [(name: String, route: Route, version: String)],
        context: inout ScanContext
    ) -> DiscoveredCLICandidate? {
        var entry = context.catalogIndex.entry(forCask: token)

        let receiptPath = "\(brewPrefix)/Caskroom/\(token)/.metadata/INSTALL_RECEIPT.json"
        let receipt = fileReader.contents(atPath: receiptPath, maxBytes: Self.metadataFileByteLimit)
            .flatMap(HomebrewInstallReceipt.parse)

        if entry?.desc == nil {
            // Older installs keep a cask copy under .metadata/<version>/<ts>/Casks.
            let metadataRoot = "\(brewPrefix)/Caskroom/\(token)/.metadata"
            versionLoop: for versionDirectory in fileReader.contentsOfDirectory(atPath: metadataRoot)
            where !versionDirectory.hasPrefix(".") && versionDirectory != "INSTALL_RECEIPT.json" && versionDirectory != "config.json" {
                for timestamp in fileReader.contentsOfDirectory(atPath: "\(metadataRoot)/\(versionDirectory)") {
                    let caskFile = "\(metadataRoot)/\(versionDirectory)/\(timestamp)/Casks/\(token).rb"
                    guard let data = fileReader.contents(atPath: caskFile, maxBytes: Self.metadataFileByteLimit) else {
                        continue
                    }
                    let metadata = HomebrewTapFormulaParser.metadata(from: data)
                    if metadata.desc != nil {
                        entry = HomebrewCatalogIndex.CaskEntry(
                            token: token,
                            displayName: entry?.displayName,
                            desc: metadata.desc,
                            homepage: metadata.homepage ?? entry?.homepage,
                            version: entry?.version,
                            binaryNames: entry?.binaryNames ?? []
                        )
                        break versionLoop
                    }
                }
            }
        }

        let sorted = hits.sorted { $0.name < $1.name }
        let primary = sorted.first { $0.name == token } ?? sorted[0]
        let seed = CandidateSeed(
            source: .homebrewCask,
            binaryName: primary.name,
            stablePath: primary.route.stablePath,
            resolvedPath: primary.route.resolvedPath,
            chain: primary.route.chain,
            packageName: token,
            version: entry?.version ?? primary.version,
            rawSummary: entry?.desc,
            summaryOrigin: "Homebrew",
            homepage: entry?.homepage,
            siblingExecutables: Set(sorted.map(\.name)).union(entry?.binaryNames ?? []).sorted(),
            installedOnRequest: receipt?.installedOnRequest ?? true,
            installDate: receipt?.installDate,
            inspection: primary.route.inspection,
            isDependencyOnly: false
        )
        return makeCandidate(seed, context: &context)
    }

    // MARK: npm globals (spec §2.5)

    private func scanNpmGlobals(context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        let root = brewPrefix + "/lib/node_modules"
        guard fileReader.fileExists(atPath: root) else { return [] }

        var packageDirectories = [String]()
        for name in cappedEntries(of: root) {
            guard !name.hasPrefix(".") else { continue }
            if name.hasPrefix("@") {
                for child in cappedEntries(of: root + "/" + name) where !child.hasPrefix(".") {
                    packageDirectories.append(root + "/" + name + "/" + child)
                }
            } else {
                packageDirectories.append(root + "/" + name)
            }
        }

        var candidates = [DiscoveredCLICandidate]()
        for directory in packageDirectories {
            try context.checkInterrupt()
            if let candidate = npmCandidate(forPackageDirectory: directory, context: &context) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func npmCandidate(forPackageDirectory directory: String, context: inout ScanContext) -> DiscoveredCLICandidate? {
        guard let data = fileReader.contents(atPath: directory + "/package.json", maxBytes: Self.metadataFileByteLimit),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let packageName = object["name"] as? String else {
            return nil
        }
        let packageTail = packageName.split(separator: "/").last.map(String.init) ?? packageName

        // The authoritative bin map: object, or a plain string whose bin name
        // is the package tail (`@readwise/cli` → `readwise` comes from here).
        var bins = [String]()
        if let map = object["bin"] as? [String: Any] {
            bins = map.keys.sorted()
        } else if object["bin"] is String {
            bins = [packageTail]
        }
        guard !bins.isEmpty else { return nil }

        var located = [(name: String, route: Route)]()
        for bin in bins {
            let stablePath = brewPrefix + "/bin/" + bin
            if let route = route(stablePath) {
                located.append((bin, route))
            }
        }
        guard !located.isEmpty else { return nil }
        let primary = located.first { $0.name == packageTail } ?? located[0]

        let keywords = (object["keywords"] as? [String]) ?? []
        let seed = CandidateSeed(
            source: .npmGlobal,
            binaryName: primary.name,
            stablePath: primary.route.stablePath,
            resolvedPath: primary.route.resolvedPath,
            chain: primary.route.chain,
            packageName: packageName,
            version: object["version"] as? String,
            rawSummary: object["description"] as? String,
            summaryOrigin: "npm",
            homepage: object["homepage"] as? String,
            siblingExecutables: located.map(\.name),
            installedOnRequest: true,
            installDate: fileReader.attributes(atPath: directory)?.modificationDate,
            inspection: primary.route.inspection,
            keywords: keywords
        )
        return makeCandidate(seed, context: &context)
    }

    // MARK: Python tools (spec §2.5)

    private func scanPythonTools(context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        var candidates = [DiscoveredCLICandidate]()

        // uv tools.
        let uvRoot = homeDirectory + "/.local/share/uv/tools"
        for tool in cappedEntries(of: uvRoot) where !tool.hasPrefix(".") {
            try context.checkInterrupt()
            guard let receiptData = fileReader.contents(
                atPath: "\(uvRoot)/\(tool)/uv-receipt.toml",
                maxBytes: Self.metadataFileByteLimit
            ) else { continue }
            let receipt = UvReceiptParser.parse(String(decoding: receiptData, as: UTF8.self))
            guard !receipt.entrypoints.isEmpty else { continue }

            let packageName = receipt.requirementName ?? tool
            let metadata = distInfoMetadata(inVenv: "\(uvRoot)/\(tool)", package: packageName)
            let sorted = receipt.entrypoints.sorted { $0.name < $1.name }
            let primary = sorted.first { $0.name == tool } ?? sorted[0]
            guard let primaryRoute = route(primary.installPath) else { continue }

            let seed = CandidateSeed(
                source: .uvTool,
                binaryName: primary.name,
                stablePath: primary.installPath,
                resolvedPath: primaryRoute.resolvedPath,
                chain: primaryRoute.chain,
                packageName: packageName,
                version: metadata?.version,
                rawSummary: metadata?.summary,
                summaryOrigin: "PyPI metadata",
                homepage: metadata?.homepage,
                siblingExecutables: sorted.map(\.name),
                installedOnRequest: true,
                installDate: fileReader.attributes(atPath: "\(uvRoot)/\(tool)")?.modificationDate,
                inspection: primaryRoute.inspection,
                keywords: metadata?.keywords ?? []
            )
            if let candidate = makeCandidate(seed, context: &context) {
                candidates.append(candidate)
            }
        }

        // pipx venvs (same layout under two historical roots).
        for venvRoot in [homeDirectory + "/.local/pipx/venvs", homeDirectory + "/.local/share/pipx/venvs"] {
            for venv in cappedEntries(of: venvRoot) where !venv.hasPrefix(".") {
                try context.checkInterrupt()
                guard let data = fileReader.contents(
                    atPath: "\(venvRoot)/\(venv)/pipx_metadata.json",
                    maxBytes: Self.metadataFileByteLimit
                ), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let mainPackage = object["main_package"] as? [String: Any] else {
                    continue
                }
                let packageName = (mainPackage["package"] as? String) ?? venv
                let apps = (mainPackage["apps"] as? [String]) ?? []
                guard !apps.isEmpty else { continue }

                var located = [(name: String, route: Route)]()
                for app in apps.sorted() {
                    let binPath = homeDirectory + "/.local/bin/" + app
                    if let route = route(binPath) {
                        located.append((app, route))
                    }
                }
                guard !located.isEmpty else { continue }
                let primary = located.first { $0.name == packageName } ?? located[0]
                let metadata = distInfoMetadata(inVenv: "\(venvRoot)/\(venv)", package: packageName)

                let seed = CandidateSeed(
                    source: .pipx,
                    binaryName: primary.name,
                    stablePath: primary.route.stablePath,
                    resolvedPath: primary.route.resolvedPath,
                    chain: primary.route.chain,
                    packageName: packageName,
                    version: (mainPackage["package_version"] as? String) ?? metadata?.version,
                    rawSummary: metadata?.summary,
                    summaryOrigin: "PyPI metadata",
                    homepage: metadata?.homepage,
                    siblingExecutables: located.map(\.name),
                    installedOnRequest: true,
                    installDate: fileReader.attributes(atPath: "\(venvRoot)/\(venv)")?.modificationDate,
                    inspection: primary.route.inspection,
                    keywords: metadata?.keywords ?? []
                )
                if let candidate = makeCandidate(seed, context: &context) {
                    candidates.append(candidate)
                }
            }
        }

        // pip --user scripts, mapped back to packages via dist-info records.
        let pythonRoot = homeDirectory + "/Library/Python"
        for version in cappedEntries(of: pythonRoot) where !version.hasPrefix(".") {
            try context.checkInterrupt()
            let binDirectory = "\(pythonRoot)/\(version)/bin"
            let sitePackages = "\(pythonRoot)/\(version)/lib/python/site-packages"
            let scripts = Set(cappedEntries(of: binDirectory))
            guard !scripts.isEmpty else { continue }

            for distInfo in cappedEntries(of: sitePackages) where distInfo.hasSuffix(".dist-info") {
                try context.checkInterrupt()
                let distPath = "\(sitePackages)/\(distInfo)"
                var scriptNames = [String]()
                if let data = fileReader.contents(atPath: distPath + "/entry_points.txt", maxBytes: Self.metadataFileByteLimit) {
                    scriptNames = PythonDistParser.consoleScripts(fromEntryPoints: String(decoding: data, as: UTF8.self))
                }
                if scriptNames.isEmpty,
                   let data = fileReader.contents(atPath: distPath + "/RECORD", maxBytes: Self.metadataFileByteLimit) {
                    scriptNames = PythonDistParser.binScripts(fromRecord: String(decoding: data, as: UTF8.self))
                }
                let owned = scriptNames.filter { scripts.contains($0) }.sorted()
                guard !owned.isEmpty else { continue }

                let metadata = fileReader.contents(atPath: distPath + "/METADATA", maxBytes: Self.metadataFileByteLimit)
                    .map { PythonDistParser.metadata(from: String(decoding: $0, as: UTF8.self)) }
                let packageName = metadata?.name ?? String(distInfo.dropLast(".dist-info".count))
                let primaryName = owned.first {
                    PythonDistParser.normalizedPackageName($0) == PythonDistParser.normalizedPackageName(packageName)
                } ?? owned[0]
                guard let primaryRoute = route(binDirectory + "/" + primaryName) else { continue }

                let seed = CandidateSeed(
                    source: .pipUser,
                    binaryName: primaryName,
                    stablePath: primaryRoute.stablePath,
                    resolvedPath: primaryRoute.resolvedPath,
                    chain: primaryRoute.chain,
                    packageName: packageName,
                    version: metadata?.version,
                    rawSummary: metadata?.summary,
                    summaryOrigin: "PyPI metadata",
                    homepage: metadata?.homepage,
                    siblingExecutables: owned,
                    installedOnRequest: nil,
                    installDate: fileReader.attributes(atPath: distPath)?.modificationDate,
                    inspection: primaryRoute.inspection,
                    keywords: metadata?.keywords ?? []
                )
                if let candidate = makeCandidate(seed, context: &context) {
                    candidates.append(candidate)
                }
            }
        }

        return candidates
    }

    private func distInfoMetadata(inVenv venv: String, package: String) -> PythonDistParser.Metadata? {
        let normalizedTarget = PythonDistParser.normalizedPackageName(package)
        for lib in cappedEntries(of: venv + "/lib") where lib.hasPrefix("python") {
            let sitePackages = "\(venv)/lib/\(lib)/site-packages"
            for entry in cappedEntries(of: sitePackages) where entry.hasSuffix(".dist-info") {
                let stem = String(entry.dropLast(".dist-info".count))
                let namePart = stem.range(of: #"-[0-9]"#, options: .regularExpression)
                    .map { String(stem[..<$0.lowerBound]) } ?? stem
                guard PythonDistParser.normalizedPackageName(namePart) == normalizedTarget else { continue }
                if let data = fileReader.contents(
                    atPath: "\(sitePackages)/\(entry)/METADATA",
                    maxBytes: Self.metadataFileByteLimit
                ) {
                    return PythonDistParser.metadata(from: String(decoding: data, as: UTF8.self))
                }
            }
        }
        return nil
    }

    // MARK: cargo installs (spec §2.5)

    private func scanCargoInstalls(context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        var installs = [(name: String, version: String, bins: [String])]()

        if let data = fileReader.contents(atPath: homeDirectory + "/.cargo/.crates2.json", maxBytes: Self.metadataFileByteLimit),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let rawInstalls = object["installs"] as? [String: Any] {
            for (spec, value) in rawInstalls {
                guard let details = value as? [String: Any] else { continue }
                let parts = spec.split(separator: " ").map(String.init)
                guard parts.count >= 2 else { continue }
                installs.append((parts[0], parts[1], (details["bins"] as? [String]) ?? []))
            }
        } else if let data = fileReader.contents(atPath: homeDirectory + "/.cargo/.crates.toml", maxBytes: Self.metadataFileByteLimit) {
            installs = CargoCratesTomlParser.installs(from: String(decoding: data, as: UTF8.self))
        }

        var candidates = [DiscoveredCLICandidate]()
        for install in installs.sorted(by: { $0.name < $1.name }) {
            try context.checkInterrupt()
            var located = [(name: String, route: Route)]()
            for bin in install.bins.sorted() {
                if let route = route(homeDirectory + "/.cargo/bin/" + bin) {
                    located.append((bin, route))
                }
            }
            guard !located.isEmpty else { continue }
            let primary = located.first { $0.name == install.name } ?? located[0]

            // Best-effort description fillers, in spec order.
            var rawSummary: String?
            var summaryOrigin: String?
            let registrySource = homeDirectory + "/.cargo/registry/src"
            registryLoop: for indexDirectory in cappedEntries(of: registrySource) {
                let crateDirectory = "\(registrySource)/\(indexDirectory)/\(install.name)-\(install.version)"
                guard let data = fileReader.contents(atPath: crateDirectory + "/Cargo.toml", maxBytes: Self.metadataFileByteLimit) else {
                    continue
                }
                if let description = CargoCratesTomlParser.packageDescription(from: String(decoding: data, as: UTF8.self)) {
                    rawSummary = description
                    summaryOrigin = "crates.io metadata"
                    break registryLoop
                }
            }
            if rawSummary == nil {
                if let formula = context.catalogIndex.formulaName(forExecutable: primary.name),
                   let desc = catalogEntry(forFormula: formula, catalogIndex: context.catalogIndex)?.desc {
                    rawSummary = desc
                    summaryOrigin = "Homebrew catalog"
                }
            }

            let seed = CandidateSeed(
                source: .cargo,
                binaryName: primary.name,
                stablePath: primary.route.stablePath,
                resolvedPath: primary.route.resolvedPath,
                chain: primary.route.chain,
                packageName: install.name,
                version: install.version,
                rawSummary: rawSummary,
                summaryOrigin: summaryOrigin,
                homepage: nil,
                siblingExecutables: located.map(\.name),
                installedOnRequest: true,
                installDate: fileReader.attributes(atPath: primary.route.stablePath)?.modificationDate,
                inspection: primary.route.inspection
            )
            if let candidate = makeCandidate(seed, context: &context) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    // MARK: Go binaries (spec §2.5)

    private func scanGoBinaries(context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        guard fileReader.fileExists(atPath: goBinDirectory) else { return [] }
        var candidates = [DiscoveredCLICandidate]()
        for entry in cappedEntries(of: goBinDirectory) {
            try context.checkInterrupt()
            guard let route = route(goBinDirectory + "/" + entry) else { continue }
            if let candidate = goOrLooseCandidate(for: route, context: &context) {
                candidates.append(candidate)
            }
        }
        return candidates
    }

    private func goOrLooseCandidate(for route: Route, context: inout ScanContext) -> DiscoveredCLICandidate? {
        var seed = CandidateSeed(
            source: .looseBinary,
            binaryName: route.literalName,
            stablePath: route.stablePath,
            resolvedPath: route.resolvedPath,
            chain: route.chain,
            packageName: nil,
            version: nil,
            rawSummary: nil,
            summaryOrigin: nil,
            homepage: nil,
            installedOnRequest: nil,
            installDate: fileReader.attributes(atPath: route.resolvedPath)?.modificationDate,
            inspection: route.inspection
        )
        switch route.inspection {
        case .machO, .universal:
            if let info = goBuildInfo(atPath: route.resolvedPath), info.modulePath != nil || info.goVersion != nil {
                seed.source = .goBinary
                seed.packageName = info.modulePath
                seed.version = info.moduleVersion
                seed.homepage = info.modulePath
            }
        case .script, .unknown:
            break
        }
        return makeCandidate(seed, context: &context)
    }

    /// Bounded streaming window scan for the Go buildinfo header (DL-15).
    func goBuildInfo(atPath path: String) -> CLIBinaryInspector.GoBuildInfo? {
        var offset: UInt64 = 0
        let window = Self.goBuildInfoWindowBytes
        while offset < UInt64(Self.goBuildInfoScanLimitBytes) {
            guard let data = fileReader.contents(atPath: path, offset: offset, maxBytes: window),
                  !data.isEmpty else {
                return nil
            }
            if let magicRange = data.range(of: CLIBinaryInspector.goBuildInfoMagic) {
                // Re-read a fresh window anchored at the magic so the header
                // and its inline strings cannot straddle the window edge.
                let absolute = offset + UInt64(magicRange.lowerBound - data.startIndex)
                guard let anchored = fileReader.contents(atPath: path, offset: absolute, maxBytes: 1024 * 1024) else {
                    return nil
                }
                return CLIBinaryInspector.goBuildInfo(inWindow: anchored)
            }
            if data.count < window {
                return nil
            }
            offset += UInt64(window - CLIBinaryInspector.goBuildInfoMagic.count)
        }
        return nil
    }

    // MARK: PATH folders + app-vended symlinks (spec §2.5, DL-17)

    private func scanPathFolders(context: inout ScanContext) throws -> [DiscoveredCLICandidate] {
        // Homebrew's folders also hold links to app bundles and loose files
        // that Homebrew did not install. They are PATH tools, read here on
        // every PATH scan, so they never depend on a Homebrew rescan.
        var stablePaths = [String]()
        for directory in brewBinDirectories {
            guard fileReader.fileExists(atPath: directory), fileReader.isLocalVolume(atPath: directory) else {
                continue
            }
            for entry in cappedEntries(of: directory) {
                try context.checkInterrupt()
                switch route(directory + "/" + entry)?.kind {
                case .appBundle?, .file?:
                    stablePaths.append(directory + "/" + entry)
                default:
                    continue
                }
            }
        }
        for directory in pathFolderDirectories {
            guard fileReader.fileExists(atPath: directory), fileReader.isLocalVolume(atPath: directory) else {
                continue
            }
            for entry in cappedEntries(of: directory) {
                stablePaths.append(directory + "/" + entry)
            }
        }

        var candidates = [DiscoveredCLICandidate]()
        for stablePath in stablePaths {
            try context.checkInterrupt()
            guard let route = route(stablePath) else { continue }

            switch route.kind {
            case .cellar(let formula, let version):
                // A formula reached from a personal bin dir is still the
                // formula; the dedupe pass merges it with the Homebrew hit.
                let hit = [(name: route.literalName, route: route, version: version)]
                if let candidate = makeFormulaCandidateFromPathHit(formula: formula, hits: hit, context: &context) {
                    candidates.append(candidate)
                }
            case .caskroom(let token, let version):
                if let candidate = makeCaskCandidate(token: token, hits: [(route.literalName, route, version)], context: &context) {
                    candidates.append(candidate)
                }
            case .nodeModules(let package):
                let packageDirectory = nodeModulesDirectory(forPackage: package, chain: route.chain + [route.resolvedPath])
                if let packageDirectory,
                   let candidate = npmCandidate(forPackageDirectory: packageDirectory, context: &context) {
                    candidates.append(candidate)
                } else if let candidate = looseCandidate(for: route, context: &context) {
                    candidates.append(candidate)
                }
            case .uvTool, .pipxVenv:
                continue   // the Python source owns these; realpath dedupe covers stragglers
            case .appBundle(let bundlePath):
                if let candidate = appVendedCandidate(for: route, bundlePath: bundlePath, context: &context) {
                    candidates.append(candidate)
                }
            case .file:
                if let candidate = goOrLooseCandidate(for: route, context: &context) {
                    candidates.append(candidate)
                }
            }
        }
        return candidates
    }

    private func makeFormulaCandidateFromPathHit(
        formula: String,
        hits: [(name: String, route: Route, version: String)],
        context: inout ScanContext
    ) -> DiscoveredCLICandidate? {
        guard let first = hits.first else { return nil }
        let receiptPath = "\(brewPrefix)/Cellar/\(formula)/\(first.version)/INSTALL_RECEIPT.json"
        let receipt = fileReader.contents(atPath: receiptPath, maxBytes: Self.metadataFileByteLimit)
            .flatMap(HomebrewInstallReceipt.parse)
        let entry = catalogEntry(forFormula: formula, catalogIndex: context.catalogIndex)
        let seed = CandidateSeed(
            source: .homebrewFormula,
            binaryName: first.name,
            stablePath: first.route.stablePath,
            resolvedPath: first.route.resolvedPath,
            chain: first.route.chain,
            packageName: formula,
            version: first.version,
            rawSummary: entry?.desc,
            summaryOrigin: "Homebrew",
            homepage: entry?.homepage,
            siblingExecutables: entry?.executables ?? [],
            installedOnRequest: receipt?.installedOnRequest,
            installDate: receipt?.installDate,
            inspection: first.route.inspection,
            isDependencyOnly: (receipt?.installedAsDependency ?? false) && receipt?.installedOnRequest != true
        )
        return makeCandidate(seed, context: &context)
    }

    private func nodeModulesDirectory(forPackage package: String, chain: [String]) -> String? {
        for path in chain {
            guard let range = path.range(of: "/node_modules/") else { continue }
            return String(path[..<range.upperBound]) + package
        }
        return nil
    }

    private func looseCandidate(for route: Route, context: inout ScanContext) -> DiscoveredCLICandidate? {
        var seed = CandidateSeed(
            source: .looseBinary,
            binaryName: route.literalName,
            stablePath: route.stablePath,
            resolvedPath: route.resolvedPath,
            chain: route.chain,
            packageName: nil,
            version: nil,
            rawSummary: nil,
            summaryOrigin: nil,
            homepage: nil,
            installedOnRequest: nil,
            installDate: fileReader.attributes(atPath: route.resolvedPath)?.modificationDate,
            inspection: route.inspection
        )
        seed.installDate = seed.installDate ?? fileReader.attributes(atPath: route.stablePath)?.modificationDate
        return makeCandidate(seed, context: &context)
    }

    /// App-vended CLIs (DL-17): the scanner never enumerates inside `.app`
    /// bundles, but an explicit bin-dir symlink whose target resolves into one
    /// is a first-class candidate labeled with the app's identity.
    private func appVendedCandidate(for route: Route, bundlePath: String, context: inout ScanContext) -> DiscoveredCLICandidate? {
        var appName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var appVersion: String?
        if let data = fileReader.contents(atPath: bundlePath + "/Contents/Info.plist", maxBytes: Self.metadataFileByteLimit),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            appName = CLIHarvestedTextSanitizer.sanitizedDisplayName(
                (plist["CFBundleName"] as? String) ?? (plist["CFBundleDisplayName"] as? String),
                fallback: appName
            )
            appVersion = plist["CFBundleShortVersionString"] as? String
        }

        let summary = "CLI provided by \(appName)\(appVersion.map { " \($0)" } ?? "")"
        let seed = CandidateSeed(
            source: .application,
            binaryName: route.literalName,
            stablePath: route.stablePath,
            resolvedPath: route.resolvedPath,
            chain: route.chain,
            packageName: appName,
            version: appVersion,
            rawSummary: summary,
            summaryOrigin: appName,
            homepage: nil,
            installedOnRequest: true,
            installDate: fileReader.attributes(atPath: route.stablePath)?.modificationDate,
            inspection: route.inspection
        )
        return makeCandidate(seed, context: &context)
    }

    // MARK: Preset folding, dedupe, ordering (spec §2.4 steps 5–6, §3.4)

    /// Curated beats harvested (R9): a candidate whose path or basename
    /// matches a catalog preset executable *is* that preset — the harvested
    /// card is discarded and the Presets group renders the curated identity.
    private func foldedIntoPresets(_ candidates: [DiscoveredCLICandidate]) -> [DiscoveredCLICandidate] {
        let presetPaths = Set(presetExecutablePaths.filter { !$0.isEmpty })
        guard !presetPaths.isEmpty else { return candidates }
        let presetRealPaths = Set(presetPaths.map { fileReader.realPath($0) })
        let presetBasenames = Set(presetPaths.map { ($0 as NSString).lastPathComponent.lowercased() })

        return candidates.filter { candidate in
            if presetPaths.contains(candidate.stablePath) || presetRealPaths.contains(candidate.resolvedPath) {
                return false
            }
            if presetBasenames.contains(candidate.binaryName.lowercased()) {
                return false
            }
            return true
        }
    }

    /// Dedupe by resolved realpath: the richest-metadata source is canonical,
    /// other in-scope locations become aliases (spec §2.4 step 6).
    private func deduplicated(_ candidates: [DiscoveredCLICandidate]) -> [DiscoveredCLICandidate] {
        var byRealPath = [String: [DiscoveredCLICandidate]]()
        var order = [String]()
        for candidate in candidates {
            if byRealPath[candidate.resolvedPath] == nil {
                order.append(candidate.resolvedPath)
            }
            byRealPath[candidate.resolvedPath, default: []].append(candidate)
        }

        var result = [DiscoveredCLICandidate]()
        for realPath in order {
            guard let group = byRealPath[realPath] else { continue }
            guard group.count > 1 else {
                result.append(group[0])
                continue
            }
            // First-on-tie keeps the earliest phase's stable path canonical.
            var winner = group[0]
            for candidate in group.dropFirst() {
                let candidateScore = (candidate.source.metadataRichnessRank, candidate.summary != nil ? 1 : 0)
                let winnerScore = (winner.source.metadataRichnessRank, winner.summary != nil ? 1 : 0)
                if candidateScore > winnerScore {
                    winner = candidate
                }
            }
            var aliases = Set(winner.aliases)
            for candidate in group where candidate.id != winner.id {
                aliases.insert(candidate.stablePath)
                aliases.formUnion(candidate.aliases)
            }
            aliases.remove(winner.stablePath)
            result.append(winner.replacing(aliases: aliases.sorted()))
        }
        return result
    }

    private static func displayOrder(_ lhs: DiscoveredCLICandidate, _ rhs: DiscoveredCLICandidate) -> Bool {
        let leftRank = CLIScanSource.allCases.firstIndex(of: lhs.source.scanSource) ?? 0
        let rightRank = CLIScanSource.allCases.firstIndex(of: rhs.source.scanSource) ?? 0
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        if lhs.isDependencyOnly != rhs.isDependencyOnly {
            return !lhs.isDependencyOnly
        }
        let names = lhs.binaryName.lowercased().compare(rhs.binaryName.lowercased())
        if names != .orderedSame {
            return names == .orderedAscending
        }
        return lhs.stablePath < rhs.stablePath
    }

    private func cappedEntries(of directory: String) -> [String] {
        Array(fileReader.contentsOfDirectory(atPath: directory).prefix(maximumEntriesPerDirectory))
    }
}

// MARK: - Small parsers

/// uv-receipt.toml — just the entrypoint records the scanner needs.
enum UvReceiptParser {
    struct Receipt: Equatable, Sendable {
        let requirementName: String?
        let entrypoints: [(name: String, installPath: String)]

        static func == (lhs: Receipt, rhs: Receipt) -> Bool {
            lhs.requirementName == rhs.requirementName
                && lhs.entrypoints.map(\.name) == rhs.entrypoints.map(\.name)
                && lhs.entrypoints.map(\.installPath) == rhs.entrypoints.map(\.installPath)
        }
    }

    static func parse(_ text: String) -> Receipt {
        var entrypoints = [(String, String)]()
        if let regex = try? NSRegularExpression(
            pattern: #"\{[^{}]*?name\s*=\s*"([^"]+)"[^{}]*?install-path\s*=\s*"([^"]+)"[^{}]*?\}"#,
            options: [.dotMatchesLineSeparators]
        ) {
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges >= 3,
                      let nameRange = Range(match.range(at: 1), in: text),
                      let pathRange = Range(match.range(at: 2), in: text) else { continue }
                entrypoints.append((String(text[nameRange]), String(text[pathRange])))
            }
        }
        var requirementName: String?
        if let match = text.range(
            of: #"requirements\s*=\s*\[\s*\{\s*name\s*=\s*"([^"]+)""#,
            options: .regularExpression
        ) {
            let matched = String(text[match])
            if let quoteStart = matched.range(of: #"name\s*=\s*""#, options: .regularExpression) {
                requirementName = String(matched[quoteStart.upperBound...].prefix { $0 != "\"" })
            }
        }
        // Entry points beat requirement records at naming the command; the
        // requirement names the PyPI package for dist-info lookup.
        return Receipt(requirementName: requirementName, entrypoints: entrypoints)
    }
}

/// Python dist-info parsing: METADATA (RFC 822 headers), entry_points.txt
/// `[console_scripts]`, and RECORD `../../bin/…` rows.
enum PythonDistParser {
    struct Metadata: Equatable, Sendable {
        let name: String?
        let version: String?
        let summary: String?
        let keywords: [String]
        let homepage: String?
    }

    static func metadata(from text: String) -> Metadata {
        var fields = [String: String]()
        var homepage: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty { break }   // header section ends at the first blank line
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key == "project-url" {
                let parts = value.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2, parts[0].lowercased() == "homepage", homepage == nil {
                    homepage = parts[1]
                }
                continue
            }
            if fields[key] == nil {
                fields[key] = value
            }
        }
        return Metadata(
            name: fields["name"],
            version: fields["version"],
            summary: fields["summary"],
            keywords: fields["keywords"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty } ?? [],
            homepage: fields["home-page"] ?? homepage
        )
    }

    static func consoleScripts(fromEntryPoints text: String) -> [String] {
        var inConsoleScripts = false
        var names = [String]()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inConsoleScripts = line == "[console_scripts]"
                continue
            }
            guard inConsoleScripts, let equals = line.firstIndex(of: "=") else { continue }
            let name = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                names.append(name)
            }
        }
        return names
    }

    static func binScripts(fromRecord text: String) -> [String] {
        var names = [String]()
        for line in text.split(whereSeparator: \.isNewline) {
            guard let comma = line.firstIndex(of: ",") else { continue }
            let path = String(line[..<comma])
            guard let range = path.range(of: "/bin/"), path.hasPrefix("..") else { continue }
            let name = String(path[range.upperBound...])
            if !name.isEmpty, !name.contains("/") {
                names.append(name)
            }
        }
        return names
    }

    static func normalizedPackageName(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"[-_.]+"#, with: "-", options: .regularExpression)
    }
}

/// `.crates.toml` `[v1]` table and registry `Cargo.toml` description lines.
enum CargoCratesTomlParser {
    static func installs(from text: String) -> [(name: String, version: String, bins: [String])] {
        var result = [(String, String, [String])]()
        var inV1 = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inV1 = line == "[v1]"
                continue
            }
            guard inV1 else { continue }
            guard let match = line.range(
                of: #"^"([^\s"]+) ([^\s"]+) [^"]*"\s*=\s*\[(.*)\]$"#,
                options: .regularExpression
            ) else { continue }
            let matched = String(line[match])
            guard let firstQuote = matched.firstIndex(of: "\"") else { continue }
            let afterQuote = matched.index(after: firstQuote)
            guard let closingQuote = matched[afterQuote...].firstIndex(of: "\"") else { continue }
            let spec = String(matched[afterQuote..<closingQuote])
            let parts = spec.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { continue }
            guard let binsStart = matched.firstIndex(of: "["), let binsEnd = matched.lastIndex(of: "]") else { continue }
            let bins = matched[matched.index(after: binsStart)..<binsEnd]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                .filter { !$0.isEmpty }
            result.append((parts[0], parts[1], bins))
        }
        return result
    }

    static func packageDescription(from text: String) -> String? {
        guard let match = text.range(
            of: #"(?m)^\s*description\s*=\s*"([^"]+)""#,
            options: .regularExpression
        ) else { return nil }
        let line = String(text[match])
        guard let firstQuote = line.range(of: #"=\s*""#, options: .regularExpression) else { return nil }
        return String(line[firstQuote.upperBound...].prefix { $0 != "\"" })
    }
}

extension CLIScanCache {
    init(result: CLIScanResult) {
        self.init(
            candidates: result.candidates,
            lastScanDate: result.finishedAt,
            seenStablePaths: result.seenStablePaths,
            sourceFingerprints: result.sourceFingerprints
        )
    }
}
