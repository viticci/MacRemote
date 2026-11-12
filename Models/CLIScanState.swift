import Foundation

/// User-visible ledger sources for the CLI scan (spec §2.2). One entry per
/// progress row; candidates map into these via `DiscoveredCLICandidate.Source`.
enum CLIScanSource: String, CaseIterable, Codable, Sendable {
    case homebrew        // formulas + taps + cask binaries (one ledger entry)
    case npm
    case python          // uv tools + pipx + pip --user (one ledger entry: "Python")
    case cargo
    case go
    case pathFolders     // /usr/local/bin loose, ~/bin, ~/.local/bin loose, app-vended symlinks

    var displayName: String {
        switch self {
        case .homebrew: "Homebrew"
        case .npm: "npm"
        case .python: "Python"
        case .cargo: "Cargo"
        case .go: "Go"
        case .pathFolders: "PATH"
        }
    }
}

struct CLISourceProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case pending
        case enumerating
        case done(count: Int)
        case failed(String)
    }

    let source: CLIScanSource
    var phase: Phase

    var isFinished: Bool {
        switch phase {
        case .done, .failed: true
        case .pending, .enumerating: false
        }
    }
}

enum CLIScanState: Equatable, Sendable {
    case idle
    case scanning(progress: [CLISourceProgress], partial: [DiscoveredCLICandidate])
    case loaded([DiscoveredCLICandidate], Date)
    case canceled([DiscoveredCLICandidate], completed: [CLIScanSource], Date)
    case failed(String, partial: [DiscoveredCLICandidate], Date?)

    var isScanning: Bool {
        if case .scanning = self {
            return true
        }
        return false
    }

    var candidates: [DiscoveredCLICandidate] {
        switch self {
        case .idle:
            return []
        case .scanning(_, let partial):
            return partial
        case .loaded(let candidates, _):
            return candidates
        case .canceled(let candidates, _, _):
            return candidates
        case .failed(_, let partial, _):
            return partial
        }
    }

    var lastScanDate: Date? {
        switch self {
        case .idle, .scanning:
            return nil
        case .loaded(_, let date):
            return date
        case .canceled(_, _, let date):
            return date
        case .failed(_, _, let date):
            return date
        }
    }

    var progress: [CLISourceProgress] {
        if case .scanning(let progress, _) = self {
            return progress
        }
        return []
    }

    func candidate(id: String) -> DiscoveredCLICandidate? {
        candidates.first { $0.id == id }
    }
}

/// Persisted scan memory (DL-11): cached candidates, the last scan date, the
/// seen-set that powers "New since last scan", and per-source freshness
/// fingerprints for warm re-scans. Local app storage only; never exported and
/// never logged beyond counts (R19).
struct CLIScanCache: Codable, Equatable, Sendable {
    var candidates: [DiscoveredCLICandidate]
    var lastScanDate: Date
    var seenStablePaths: Set<String>
    var sourceFingerprints: [String: String]   // keyed by CLIScanSource.rawValue

    init(
        candidates: [DiscoveredCLICandidate],
        lastScanDate: Date,
        seenStablePaths: Set<String>,
        sourceFingerprints: [String: String] = [:]
    ) {
        self.candidates = candidates
        self.lastScanDate = lastScanDate
        self.seenStablePaths = seenStablePaths
        self.sourceFingerprints = sourceFingerprints
    }

    private enum CodingKeys: String, CodingKey {
        case candidates
        case lastScanDate
        case seenStablePaths
        case sourceFingerprints
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCandidates = try container.decode([DiscoveredCLICandidate].self, forKey: .candidates)
        lastScanDate = try container.decode(Date.self, forKey: .lastScanDate)
        sourceFingerprints = try container.decodeIfPresent(
            [String: String].self,
            forKey: .sourceFingerprints
        ) ?? [:]

        if let persistedStablePaths = try container.decodeIfPresent(
            Set<String>.self,
            forKey: .seenStablePaths
        ) {
            candidates = decodedCandidates
            seenStablePaths = persistedStablePaths
        } else {
            // Legacy caches keyed New state by resolved Cellar paths. A package
            // upgrade changes those paths, so their stored flags are ambiguous.
            // Clear them once and derive the stable identity baseline from the
            // cached rows instead of carrying inflated counts forward.
            candidates = decodedCandidates.map { $0.replacing(isNewSinceLastScan: false) }
            seenStablePaths = Set(decodedCandidates.map(\.stablePath))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(lastScanDate, forKey: .lastScanDate)
        try container.encode(seenStablePaths, forKey: .seenStablePaths)
        try container.encode(sourceFingerprints, forKey: .sourceFingerprints)
    }

    func fingerprint(for source: CLIScanSource) -> String? {
        sourceFingerprints[source.rawValue]
    }

    /// State to restore at launch from the persisted cache.
    var restoredState: CLIScanState {
        .loaded(candidates, lastScanDate)
    }
}
