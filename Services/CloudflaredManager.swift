import Foundation
import Observation

/// Where the Cloudflare helper MacRemote would launch comes from. The app
/// always reports this truthfully — it never claims to manage a copy the user
/// installed themselves.
enum CloudflaredSource: Equatable, Sendable {
    /// MacRemote downloaded, verified, and owns this copy.
    case managed(String)
    /// Found on this Mac (Homebrew or anywhere else on the search path).
    case external(String)

    var path: String {
        switch self {
        case .managed(let path), .external(let path): path
        }
    }

    var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .managed: "Managed by MacRemote"
        case .external: "Installed by you"
        }
    }
}

/// Why an install stopped, in the user's terms. Hash and signature failures are
/// deliberately one message: the download did not match what Cloudflare
/// published, and it was thrown away.
enum CloudflaredInstallFailure: Equatable, Sendable {
    case unsupportedHardware
    case download(String)
    case notWhatCloudflarePublished(String)
    case install(String)
    case tunnelRunning
    case cancelled

    /// The headline a person reads. Fixed per case: a system error string is
    /// never promoted to a headline or to a Settings value — it belongs in
    /// `detail`, as secondary text.
    var message: String {
        switch self {
        case .unsupportedHardware:
            "MacRemote doesn't have a Cloudflare helper for this Mac's processor. Install it yourself and MacRemote will use your copy."
        case .download, .install:
            "MacRemote couldn't install Cloudflare's helper."
        case .notWhatCloudflarePublished:
            "The download didn't match what Cloudflare published, so MacRemote discarded it."
        case .tunnelRunning:
            "Turn the public link off before replacing Cloudflare's helper."
        case .cancelled:
            "The install was cancelled. Nothing was kept."
        }
    }

    /// The underlying technical reason, carried separately so views can show it
    /// as selectable secondary text without ever making it the headline.
    var detail: String? {
        switch self {
        case .download(let detail), .install(let detail), .notWhatCloudflarePublished(let detail):
            detail.isEmpty ? nil : detail
        case .unsupportedHardware, .tunnelRunning, .cancelled:
            nil
        }
    }
}

enum CloudflaredHelperState: Equatable, Sendable {
    case checking
    case notInstalled
    case downloading(progress: Double)
    case verifying
    case ready(version: String?, source: CloudflaredSource)
    case updateAvailable(installed: String, available: String, source: CloudflaredSource)
    case failed(CloudflaredInstallFailure)

    var isWorking: Bool {
        switch self {
        case .checking, .downloading, .verifying: true
        default: false
        }
    }

    var isInstalling: Bool {
        switch self {
        case .downloading, .verifying: true
        default: false
        }
    }

    var source: CloudflaredSource? {
        switch self {
        case .ready(_, let source), .updateAvailable(_, _, let source): source
        default: nil
        }
    }

    /// One truthful line for cards and tiles.
    var summary: String {
        switch self {
        case .checking:
            "Checking Cloudflare's helper."
        case .notInstalled:
            "Cloudflare's helper isn't installed."
        case .downloading:
            "Downloading Cloudflare's helper…"
        case .verifying:
            "Checking the download."
        case .ready(let version, let source):
            switch source {
            case .managed:
                "Cloudflare's helper is ready · \(source.title) · \(version ?? CloudflaredManifest.version)"
            case .external:
                "Cloudflare's helper is ready · \(source.title)"
            }
        case .updateAvailable(let installed, let available, _):
            "Cloudflare's helper \(installed) is ready. Version \(available) is available."
        case .failed(let failure):
            failure.message
        }
    }
}

/// Snapshot of what is actually on disk right now, computed off the main actor.
struct CloudflaredResolution: Equatable, Sendable {
    var managedPath: String?
    var record: CloudflaredInstallRecord?
    var externalPath: String?
    var integrityFailure: String?
}

/// The thread-safe half of the manager. `TunnelService` resolves an executable
/// path from wherever it happens to launch, so resolution cannot be
/// main-actor-isolated; observable state stays on `CloudflaredManager`.
final class CloudflaredResolutionCore: @unchecked Sendable {
    /// Anything older than this in `staging/` belongs to a run that ended.
    static let staleStagingAge: TimeInterval = 15 * 60

    /// Serializes verification, so two callers never hash the same file at
    /// once. It is held for the whole (slow) check.
    private let verificationLock = NSLock()
    /// Guards the published result only. Deliberately separate: a status reader
    /// must never wait behind a running hash.
    private let cacheLock = NSLock()
    private let store: CloudflaredInstallStore
    private let externalResolver: @Sendable () -> String?
    private let signatureReader: any SignatureReading
    /// Full hashing is expensive, so a proven copy is remembered by
    /// (inode, modification time, size). Any change re-runs the whole check.
    private var verifiedKey: CloudflaredIntegrityKey?
    private var verifiedRecord: CloudflaredInstallRecord?
    private var lastIntegrityFailure: String?

    init(
        store: CloudflaredInstallStore,
        externalResolver: @escaping @Sendable () -> String?,
        signatureReader: any SignatureReading
    ) {
        self.store = store
        self.externalResolver = externalResolver
        self.signatureReader = signatureReader
    }

    /// Precedence: MacRemote's own verified copy first, then whatever the user
    /// installed. A live tunnel's pinned path is enforced by `TunnelService`
    /// and always wins over both.
    ///
    /// This hashes and reads a code signature when the cache is cold, so it is
    /// the *launch* answer and must not run on the main actor. Status refreshes
    /// use `cachedExecutablePath()`.
    func resolvedExecutablePath() -> String? {
        verifiedManagedPath() ?? externalResolver()
    }

    /// Status answer: never hashes, never reads a signature. A managed copy is
    /// reported when a previous verification still covers the exact bytes on
    /// disk, or when the cheap structural check passes; the bytes are proven
    /// again before anything is launched, and the detached refresh corrects the
    /// reported state if that proof fails.
    func cachedExecutablePath() -> String? {
        let proven: CloudflaredIntegrityKey? = cacheLock.withLock {
            verifiedRecord == nil ? nil : verifiedKey
        }
        let managed: String?
        if let proven, CloudflaredInstallStore.integrityKey(forFileAt: store.binaryURL) == proven {
            managed = store.binaryURL.path
        } else {
            managed = store.plausibleInstalledBinaryPath()
        }
        return managed ?? externalResolver()
    }

    /// Re-proves one exact executable immediately before it is launched.
    /// Anything outside MacRemote's own folder is not ours to prove, so it
    /// passes through untouched.
    func verifyLaunchPath(_ path: String) -> Bool {
        guard path == store.binaryURL.path else { return true }
        return verifiedManagedPath() == path
    }

    func resolve() -> CloudflaredResolution {
        // Tens of megabytes can be left in staging by a quit mid-download, and
        // this is the one path that already runs off the main actor on launch.
        // The age floor keeps a transfer that is running right now out of it.
        store.cleanStaleStaging(olderThan: Self.staleStagingAge)
        let managedPath = verifiedManagedPath()
        let (record, failure): (CloudflaredInstallRecord?, String?) = cacheLock.withLock {
            (verifiedRecord, lastIntegrityFailure)
        }
        return CloudflaredResolution(
            managedPath: managedPath,
            record: record,
            externalPath: externalResolver(),
            integrityFailure: failure
        )
    }

    func invalidate() {
        cacheLock.withLock {
            verifiedKey = nil
            verifiedRecord = nil
            lastIntegrityFailure = nil
        }
    }

    /// The full proof. A cache hit only ever comes from a previous run of this
    /// method, so a cached path has always passed the pinned-digest check too.
    private func verifiedManagedPath() -> String? {
        verificationLock.withLock {
            guard store.installedRecord() != nil else {
                cacheLock.withLock {
                    verifiedKey = nil
                    verifiedRecord = nil
                }
                return nil
            }
            let key = CloudflaredInstallStore.integrityKey(forFileAt: store.binaryURL)
            let proven: CloudflaredIntegrityKey? = cacheLock.withLock {
                verifiedRecord == nil ? nil : verifiedKey
            }
            if let key, let proven, key == proven {
                return store.binaryURL.path
            }
            do {
                let record = try store.verifyInstalledBinary(signatureReader: signatureReader)
                let verifiedAt = CloudflaredInstallStore.integrityKey(forFileAt: store.binaryURL)
                cacheLock.withLock {
                    verifiedRecord = record
                    verifiedKey = verifiedAt
                    lastIntegrityFailure = nil
                }
                return store.binaryURL.path
            } catch {
                // `verifyInstalledBinary` already quarantined the copy, so the
                // app can never launch what it could not prove.
                cacheLock.withLock {
                    verifiedKey = nil
                    verifiedRecord = nil
                    lastIntegrityFailure = error.localizedDescription
                }
                return nil
            }
        }
    }
}

/// Owns the managed Cloudflare helper: its state machine, the one-at-a-time
/// install, removal, and the executable path the rest of the app launches.
/// It is a property of `AppModel`, never a global.
@MainActor
@Observable
final class CloudflaredManager {
    private(set) var state: CloudflaredHelperState = .checking

    @ObservationIgnored private let store: CloudflaredInstallStore
    @ObservationIgnored private let downloader: CloudflaredDownloader
    @ObservationIgnored private let core: CloudflaredResolutionCore
    @ObservationIgnored private let signatureReader: any SignatureReading
    @ObservationIgnored private let artifactProvider: @Sendable () -> CloudflaredArtifact?
    @ObservationIgnored private var isTunnelRunning: @MainActor () -> Bool = { false }
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    /// Activity-log sink, installed by `AppModel`.
    @ObservationIgnored var onLog: (@MainActor (AppLogEntry.Level, String) -> Void)?
    /// Fired after a successful install so readiness can refresh without the
    /// user hunting for a button.
    @ObservationIgnored var onInstalled: (@MainActor () -> Void)?
    /// Fired whenever a background resolution lands, so anything derived from
    /// the helper (tunnel status, readiness) catches up with the proven answer
    /// rather than the cheap one it showed while verification ran.
    @ObservationIgnored var onResolved: (@MainActor () -> Void)?

    init(
        store: CloudflaredInstallStore = CloudflaredInstallStore(),
        downloader: CloudflaredDownloader = CloudflaredDownloader(),
        externalResolver: @escaping @Sendable () -> String? = {
            ExecutableLocator.executablePath(
                named: "cloudflared",
                in: ExecutableLocator.systemFirstSearchDirectories
            )
        },
        artifactProvider: @escaping @Sendable () -> CloudflaredArtifact? = { CloudflaredManifest.current },
        signatureReader: any SignatureReading = CodeSignatureReader()
    ) {
        self.store = store
        self.downloader = downloader
        self.signatureReader = signatureReader
        self.artifactProvider = artifactProvider
        self.core = CloudflaredResolutionCore(
            store: store,
            externalResolver: externalResolver,
            signatureReader: signatureReader
        )
    }

    /// Installed by `AppModel` so removal can refuse while a tunnel is live.
    func setTunnelRunningCheck(_ check: @escaping @MainActor () -> Bool) {
        isTunnelRunning = check
    }

    /// The path the app should launch, proven before it is handed out. Safe to
    /// call from any thread, but it can hash the binary, so keep it off the
    /// main actor.
    nonisolated func resolvedExecutablePath() -> String? {
        core.resolvedExecutablePath()
    }

    /// The path status displays may use. Cheap by construction — no hashing, no
    /// signature read — so a status refresh never blocks the main actor on a
    /// 40 MB file.
    nonisolated func cachedExecutablePath() -> String? {
        core.cachedExecutablePath()
    }

    /// Proves one exact executable again right before it is launched, so a
    /// managed copy that stopped verifying mid-session is quarantined instead
    /// of relaunched.
    nonisolated func verifyLaunchPath(_ path: String) -> Bool {
        core.verifyLaunchPath(path)
    }

    var pinnedArtifact: CloudflaredArtifact? { artifactProvider() }

    // MARK: - Refresh

    func refresh() {
        guard !state.isInstalling else { return }
        refreshTask?.cancel()
        state = .checking
        let core = self.core
        refreshTask = Task { [weak self] in
            let resolution = await Task.detached(priority: .utility) { core.resolve() }.value
            guard !Task.isCancelled else { return }
            self?.publishResolution(resolution)
        }
    }

    private func apply(_ resolution: CloudflaredResolution) {
        if let failure = resolution.integrityFailure {
            log(.warning, "Cloudflare helper check failed: \(failure) MacRemote quarantined its copy.")
        }
        if let managedPath = resolution.managedPath, let record = resolution.record {
            let source = CloudflaredSource.managed(managedPath)
            // Version-only comparison: install() always fetches the artifact for
            // the current host architecture, so a cross-architecture migrated
            // install (still verified, runs under Rosetta) is offered the same
            // update as any other outdated copy. No network is consulted here.
            if record.version != CloudflaredManifest.version {
                state = .updateAvailable(installed: record.version, available: CloudflaredManifest.version, source: source)
            } else {
                state = .ready(version: record.version, source: source)
            }
            return
        }
        if let externalPath = resolution.externalPath {
            state = .ready(version: nil, source: .external(externalPath))
            return
        }
        state = .notInstalled
    }

    private func publishResolution(_ resolution: CloudflaredResolution) {
        apply(resolution)
        onResolved?()
    }

    // MARK: - Install

    /// User-initiated, single-flight. A second tap while one install is running
    /// does nothing.
    func install() {
        guard installTask == nil else {
            return
        }
        // Replacing the file a running tunnel launched from is the same hazard
        // removal already refuses. The buttons are disabled for this, but the
        // refusal has to be real, not drawn.
        if isTunnelRunning() {
            state = .failed(.tunnelRunning)
            log(.warning, CloudflaredInstallFailure.tunnelRunning.message)
            return
        }
        guard let artifact = artifactProvider() else {
            state = .failed(.unsupportedHardware)
            log(.error, "No pinned Cloudflare helper exists for this Mac's processor.")
            return
        }

        state = .downloading(progress: 0)
        log(
            .info,
            "Installing Cloudflare helper \(CloudflaredManifest.version) (\(artifact.architecture.displayName)) from \(artifact.downloadURL.absoluteString)."
        )

        let store = self.store
        let downloader = self.downloader
        let signatureReader = self.signatureReader
        installTask = Task.detached(priority: .userInitiated) { [weak self] in
            var stagingDirectory: URL?
            do {
                let staging = try store.prepareStagingDirectory()
                stagingDirectory = staging
                let archiveURL = staging.appendingPathComponent("cloudflared.tgz")
                let stagedExecutable = staging.appendingPathComponent(CloudflaredManifest.expectedEntryName)

                try await downloader.download(artifact: artifact, to: archiveURL) { progress in
                    Task { @MainActor in
                        self?.updateDownloadProgress(progress)
                    }
                }
                try Task.checkCancellation()
                await MainActor.run { self?.state = .verifying }

                try CloudflaredArchiveExtractor.extract(
                    archiveAt: archiveURL,
                    artifact: artifact,
                    to: stagedExecutable,
                    signatureReader: signatureReader
                )
                try Task.checkCancellation()

                let record = CloudflaredInstallRecord(
                    version: CloudflaredManifest.version,
                    architecture: artifact.architecture,
                    executableSHA256: artifact.executableSHA256,
                    byteCount: artifact.executableByteCount,
                    installedAt: Date(),
                    sourceURL: artifact.downloadURL.absoluteString
                )
                try store.commit(stagedExecutable: stagedExecutable, record: record)
                if let stagingDirectory {
                    store.discardStagingDirectory(stagingDirectory)
                }
                await MainActor.run { self?.completeInstall(record: record) }
            } catch {
                if let stagingDirectory {
                    store.discardStagingDirectory(stagingDirectory)
                }
                await MainActor.run { self?.failInstall(error) }
            }
        }
    }

    func cancelInstall() {
        installTask?.cancel()
    }

    private func updateDownloadProgress(_ progress: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: progress)
    }

    private func completeInstall(record: CloudflaredInstallRecord) {
        installTask = nil
        // Leave the installing states before refreshing: `refresh()` refuses to
        // run mid-install, and the new truth comes from disk, not from here.
        state = .checking
        core.invalidate()
        log(
            .info,
            "Installed Cloudflare helper \(record.version) (\(record.architecture.displayName)) at \(store.binaryURL.path). SHA-256 \(record.executableSHA256), signed by Developer ID team \(CloudflaredManifest.expectedTeamIdentifier)."
        )
        refresh()
        onInstalled?()
    }

    private func failInstall(_ error: any Error) {
        installTask = nil
        let failure = Self.failure(for: error)
        state = .failed(failure)
        // The log keeps the technical detail the headline deliberately drops.
        let detail = failure.detail.map { " \($0)" } ?? ""
        log(failure == .cancelled ? .warning : .error, "Cloudflare helper install stopped: \(failure.message)\(detail)")
        // Fall back to whatever is genuinely available rather than sitting on a
        // stale failure once the user looks again.
        core.invalidate()
    }

    nonisolated static func failure(for error: any Error) -> CloudflaredInstallFailure {
        if error is CancellationError {
            return .cancelled
        }
        if let downloadError = error as? CloudflaredDownloadError {
            if downloadError == .cancelled {
                return .cancelled
            }
            if case .sizeMismatch = downloadError {
                return .notWhatCloudflarePublished(downloadError.localizedDescription)
            }
            return .download(downloadError.localizedDescription)
        }
        if let archiveError = error as? CloudflaredArchiveError {
            return .notWhatCloudflarePublished(archiveError.localizedDescription)
        }
        if let storeError = error as? CloudflaredInstallStoreError {
            return .install(storeError.localizedDescription)
        }
        return .install(error.localizedDescription)
    }

    // MARK: - Removal

    /// Removes only MacRemote's own copy. Returns a message when it refuses.
    @discardableResult
    func remove() -> String? {
        if isTunnelRunning() {
            let message = "Turn the public link off before removing Cloudflare's helper."
            log(.warning, message)
            return message
        }
        guard state.source?.isManaged == true || store.installedRecord() != nil else {
            let message = "MacRemote has no copy of Cloudflare's helper to remove."
            log(.warning, message)
            return message
        }
        do {
            try store.remove()
            core.invalidate()
            log(.info, "Removed MacRemote's copy of Cloudflare's helper from \(store.rootDirectory.path).")
            refresh()
            return nil
        } catch {
            let message = error.localizedDescription
            log(.error, "Could not remove MacRemote's copy of Cloudflare's helper: \(message)")
            return message
        }
    }

    private func log(_ level: AppLogEntry.Level, _ message: String) {
        onLog?(level, message)
    }
}
