import Foundation

enum TunnelServiceEvent: Sendable {
    case log(String)
    /// The link is up: the helper has a connection to Cloudflare. Sent at
    /// start, and again each time a lost connection comes back.
    case started(URL)
    /// The helper is still running but has no connection to Cloudflare, so
    /// the public address reaches nothing until `started` is sent again.
    case connectionLost
    case stopped
    case failed(String)
    /// A Your Domain helper failed after Cloudflare rejected its run token.
    /// Carries the message `failed` would have carried.
    case runTokenRefused(String)
}

enum TunnelServiceError: LocalizedError {
    case cloudflaredUnavailable
    case alreadyRunning
    case helperNoLongerVerified

    var errorDescription: String? {
        switch self {
        case .cloudflaredUnavailable:
            "Cloudflare's helper isn't installed yet. Install it from Connection ▸ Address."
        case .alreadyRunning:
            "A Cloudflare tunnel is already running."
        case .helperNoLongerVerified:
            "MacRemote's copy of Cloudflare's helper didn't pass its check, so the public link didn't start. Install it again in Settings ▸ General."
        }
    }
}

final class TunnelService: @unchecked Sendable {
    typealias EventHandler = @Sendable (TunnelServiceEvent) -> Void

    static let namedTunnelStartupTimeout: TimeInterval = 15
    static let namedTunnelStartupFailure =
        "Cloudflare's helper did not register the tunnel connection before startup timed out."

    /// How the tunnel finds and proves Cloudflare's helper. Status and launch
    /// are deliberately different answers: status runs on the main actor and
    /// must stay cheap, while a launch must not start bytes nobody proved.
    struct CloudflaredResolver: Sendable {
        /// Cheap answer for status refreshes. Never hashes.
        var status: @Sendable () -> String?
        /// Proven answer for a fresh launch.
        var launch: @Sendable () -> String?
        /// Re-proves one exact executable before it is (re)launched. `false`
        /// means the pinned copy no longer verifies and must not run.
        var verify: @Sendable (String) -> Bool

        /// Path-only resolution, for callers with nothing to prove (tests).
        static func pathOnly(_ resolve: @escaping @Sendable () -> String?) -> Self {
            CloudflaredResolver(status: resolve, launch: resolve, verify: { _ in true })
        }
    }

    /// How long after the helper prints something the app asks it how many
    /// connections it has. Long enough for the helper to finish what it was
    /// reporting, short enough that a lost link is noticed at once.
    static let edgeCheckDelay: TimeInterval = 1

    /// Asks the helper's own status page how many connections to Cloudflare
    /// it has. `nil` means no answer, which changes nothing.
    typealias ReadyConnectionsProbe = @Sendable (URL) async -> Int?

    private let lock = NSLock()
    private let outputQueue = DispatchQueue(label: "com.macremote.tunnel-output")
    private let resolver: CloudflaredResolver
    private let namedStartupTimeout: TimeInterval
    private let readyConnections: ReadyConnectionsProbe
    private var process: Process?
    private var outputSource: DispatchSourceRead?
    private var outputPipe: Pipe?
    private var startupTimer: DispatchSourceTimer?
    private var eventHandler: EventHandler?
    /// The address this helper serves once it is connected: known from the
    /// start for Your Domain, read from the helper's output for Instant Link.
    private var announcedURL: URL?
    /// The address while the link is up, and nil whenever the helper has no
    /// connection to Cloudflare. `status` reports "running" only from this.
    private var publicURL: URL?
    private var isEdgeConnected = false
    /// Goes up each time the helper's output shows a new connection, so an
    /// older "no connections" answer cannot take the link down again.
    private var edgeEvidenceCount = 0
    /// Where the running helper answers `/ready`.
    private var readinessURL: URL?
    /// The helper printed that Cloudflare rejected its run token, and no
    /// connection has registered since.
    private var sawRunTokenRefusal = false
    private var edgeCheckScheduled = false
    private var stopping = false
    private var suppressNextStoppedEvent = false
    /// The exact executable of the process running right now.
    private var launchedExecutablePath: String?
    /// The executable this supervised session started with. It outlives an
    /// unexpected exit so a watchdog restart relaunches the same binary instead
    /// of silently switching to a different one mid-session.
    private var sessionExecutablePath: String?

    /// Where the running helper's process ID is recorded, so a helper that
    /// outlived the app (a crash, a forced quit) can be stopped at next launch.
    private let childRecordURL: URL?

    /// The app's own executable, which can run as a `HelperTether`. Nil in
    /// tests, where the running executable is not the app.
    private let tetherExecutableURL: URL?
    /// The tether watching the helper running right now.
    private var tether: Process?

    convenience init(
        namedStartupTimeout: TimeInterval = TunnelService.namedTunnelStartupTimeout,
        readyConnections: @escaping ReadyConnectionsProbe = TunnelService.fetchReadyConnections,
        resolveCloudflared: @escaping @Sendable () -> String?
    ) {
        self.init(
            resolver: .pathOnly(resolveCloudflared),
            namedStartupTimeout: namedStartupTimeout,
            readyConnections: readyConnections
        )
    }

    init(
        resolver: CloudflaredResolver,
        namedStartupTimeout: TimeInterval = TunnelService.namedTunnelStartupTimeout,
        childRecordURL: URL? = nil,
        tetherExecutableURL: URL? = nil,
        readyConnections: @escaping ReadyConnectionsProbe = TunnelService.fetchReadyConnections
    ) {
        self.resolver = resolver
        self.namedStartupTimeout = namedStartupTimeout
        self.childRecordURL = childRecordURL
        self.tetherExecutableURL = tetherExecutableURL
        self.readyConnections = readyConnections
    }

    // MARK: - Helper left running by a previous launch

    private struct ChildRecord: Codable {
        let pid: Int32
        let startSeconds: UInt64
        let executablePath: String
    }

    /// Stops the helper a previous launch started and never stopped. The
    /// tether normally stops it the moment the app dies; this covers a tether
    /// that died with the app. Without it, the public address would stay
    /// connected to a local port the app no longer owns. The process is matched by ID, start time, and
    /// executable, so an unrelated process that reused the ID is left alone,
    /// and so is any tunnel the owner runs themselves. Returns true when a
    /// leftover helper was stopped.
    @discardableResult
    func stopHelperLeftByPreviousLaunch() -> Bool {
        guard let childRecordURL,
              let data = try? Data(contentsOf: childRecordURL),
              let record = try? JSONDecoder().decode(ChildRecord.self, from: data) else {
            return false
        }
        try? FileManager.default.removeItem(at: childRecordURL)
        guard record.pid != ProcessInfo.processInfo.processIdentifier,
              Self.startSeconds(ofProcess: record.pid) == record.startSeconds,
              Self.executablePath(ofProcess: record.pid) == record.executablePath else {
            return false
        }
        return kill(record.pid, SIGTERM) == 0
    }

    private func recordChild(_ process: Process, executablePath: String) {
        guard let childRecordURL,
              let startSeconds = Self.startSeconds(ofProcess: process.processIdentifier),
              let data = try? JSONEncoder().encode(ChildRecord(
                  pid: process.processIdentifier,
                  startSeconds: startSeconds,
                  executablePath: Self.executablePath(ofProcess: process.processIdentifier) ?? executablePath
              )) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: childRecordURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: childRecordURL, options: .atomic)
    }

    /// Makes sure the helper stops if the app dies without stopping it.
    private func attachTether(to process: Process, executablePath: String) {
        guard let tetherExecutableURL else { return }
        let tether = HelperTether.attach(
            executable: tetherExecutableURL,
            helperPID: process.processIdentifier,
            helperPath: Self.executablePath(ofProcess: process.processIdentifier) ?? executablePath
        )
        lock.withLock { self.tether = tether }
    }

    private func clearChildRecord() {
        guard let childRecordURL else { return }
        try? FileManager.default.removeItem(at: childRecordURL)
    }

    private static func startSeconds(ofProcess pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec
    }

    static func executablePath(ofProcess pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Status-facing path. Cheap: it never verifies, so it is safe on the main
    /// actor. `startQuickTunnel`/`startNamedTunnel` use the proven path
    /// instead.
    func cloudflaredPath() -> String? {
        let pins: (launched: String?, session: String?) = lock.withLock {
            (launchedExecutablePath, sessionExecutablePath)
        }
        return Self.resolvedExecutablePath(
            launched: pins.launched,
            session: pins.session,
            external: resolver.status
        )
    }

    /// The executable this session is pinned to, if any. Callers that can run
    /// off the main actor prove it there before asking for a restart.
    func sessionExecutablePin() -> String? {
        lock.withLock { launchedExecutablePath ?? sessionExecutablePath }
    }

    /// The exact executable a launch will use. A session pin is re-proven,
    /// never replaced: if the pinned copy stopped verifying, the tunnel fails
    /// instead of quietly starting some other binary.
    private func launchExecutablePath() throws -> String {
        if let pinned = sessionExecutablePin() {
            guard resolver.verify(pinned) else {
                throw TunnelServiceError.helperNoLongerVerified
            }
            return pinned
        }
        guard let path = resolver.launch() else {
            throw TunnelServiceError.cloudflaredUnavailable
        }
        return path
    }

    /// Pure precedence rule: a running process wins, then the current
    /// supervised session, then whatever the app resolves today.
    static func resolvedExecutablePath(
        launched: String?,
        session: String?,
        external: () -> String?
    ) -> String? {
        launched ?? session ?? external()
    }

    /// Ends the executable pin for this session. Called when the tunnel is no
    /// longer supervised, so a later start picks up a newly installed helper.
    func clearSessionPin() {
        lock.withLock {
            sessionExecutablePath = nil
        }
    }

    func isProcessRunning() -> Bool {
        lock.withLock { process?.isRunning == true }
    }

    /// The host name the running helper serves, or nil when no helper runs.
    /// The local server asks on every request, from its own queue, to decide
    /// which Host headers belong to this Mac.
    ///
    /// This is the announced address, not the "link is up" one. A request
    /// that arrives through the helper proves the link works, and it must not
    /// be refused because the app's own reading of the connection count is a
    /// moment behind.
    func publicHost() -> String? {
        lock.withLock { process?.isRunning == true ? announcedURL?.host() : nil }
    }

    /// What the app shows. "Running" needs a connection to Cloudflare: a
    /// helper that is running without one, at start or after the network
    /// dropped, is still "starting".
    func status(localServerURL: URL?) -> TunnelStatus {
        guard cloudflaredPath() != nil else {
            return .unavailable
        }

        return lock.withLock {
            if process?.isRunning == true {
                if let publicURL {
                    return .running(publicURL)
                }
                return .starting
            }
            return localServerURL == nil ? .stopped : .ready
        }
    }

    func startQuickTunnel(localServerURL: URL, onEvent: @escaping EventHandler) throws {
        let path = try launchExecutablePath()

        try startProcess(
            executablePath: path,
            arguments: Self.helperArguments + ["--url", localServerURL.absoluteString],
            environment: [:],
            namedPublicURL: nil,
            startMessage: "cloudflared started for \(localServerURL.absoluteString).",
            onEvent: onEvent
        )
    }

    func startNamedTunnel(deployment: CloudflareCustomDomainDeployment, onEvent: @escaping EventHandler) throws {
        let path = try launchExecutablePath()

        try startProcess(
            executablePath: path,
            arguments: Self.helperArguments + ["run"],
            environment: [
                "TUNNEL_TOKEN": deployment.tunnelToken
            ],
            namedPublicURL: deployment.publicURL,
            startMessage: "cloudflared started for \(deployment.hostname).",
            onEvent: onEvent
        )
    }

    /// Shared by both kinds of link. `--metrics` gives the helper a status
    /// page on this Mac only, at a free port it then prints; the app reads
    /// `/ready` there to learn whether the link is really connected.
    private static let helperArguments = ["tunnel", "--no-autoupdate", "--metrics", "127.0.0.1:0"]

    private func startProcess(
        executablePath path: String,
        arguments: [String],
        environment: [String: String],
        namedPublicURL: URL?,
        startMessage: String,
        onEvent: @escaping EventHandler
    ) throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(ExecutableLocator.toolEnvironment) { _, new in new }
            .merging(environment) { _, new in new }
        process.standardOutput = pipe
        process.standardError = pipe

        let source = DispatchSource.makeReadSource(
            fileDescriptor: pipe.fileHandleForReading.fileDescriptor,
            queue: outputQueue
        )
        // Reads once from the helper's output and acts on it. Returns false
        // when there was nothing to read. Runs on `outputQueue` only.
        let readOutput: @Sendable () -> Bool = { [weak self, weak process, pipe] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let count = read(pipe.fileHandleForReading.fileDescriptor, &buffer, buffer.count)
            guard count > 0 else { return false }
            let data = Data(buffer[..<count])

            let text = String(decoding: data, as: UTF8.self)
            let lines = text
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            for line in lines {
                onEvent(.log(line))
            }

            guard let self, let process else { return true }
            self.noteHelperOutput(
                for: process,
                announcedURL: namedPublicURL == nil ? Self.firstPublicURL(in: text) : nil,
                readinessURL: Self.readinessURL(in: text),
                registeredConnection: Self.containsRegisteredConnectionEvidence(in: text),
                refusedRunToken: namedPublicURL != nil && Self.containsRunTokenRefusal(in: text)
            )
            return true
        }
        source.setEventHandler {
            _ = readOutput()
        }
        source.setCancelHandler { [pipe] in
            try? pipe.fileHandleForReading.close()
        }

        process.terminationHandler = { [weak self, outputQueue, pipe] process in
            // The helper's last lines say why it stopped, and they can still
            // be unread when it exits. Read them before deciding what the
            // exit means. A cancelled source has closed the pipe already.
            outputQueue.sync {
                guard !source.isCancelled else { return }
                var pending = pollfd(fd: pipe.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                while poll(&pending, 1, 0) > 0, pending.revents & Int16(POLLIN) != 0, readOutput() {}
            }
            self?.handleTermination(of: process, onEvent: onEvent)
        }

        try lock.withLock {
            if self.process?.isRunning == true {
                throw TunnelServiceError.alreadyRunning
            }
            self.process = process
            self.outputSource = source
            self.outputPipe = pipe
            self.resetLinkLocked(eventHandler: onEvent, announcedURL: namedPublicURL)
            self.stopping = false
            self.suppressNextStoppedEvent = false
            self.launchedExecutablePath = path
            self.sessionExecutablePath = path
        }

        do {
            try process.run()
            recordChild(process, executablePath: path)
            attachTether(to: process, executablePath: path)
            if namedPublicURL != nil {
                armNamedStartupTimeout(for: process, onEvent: onEvent)
            }
            source.resume()
            onEvent(.log(startMessage))
        } catch {
            // A dispatch source must run before it is released; releasing one
            // that never started ends the app instead of reporting the failure.
            source.resume()
            source.cancel()
            lock.withLock {
                self.process = nil
                self.outputSource = nil
                self.outputPipe = nil
                self.startupTimer?.cancel()
                self.startupTimer = nil
                self.resetLinkLocked()
                self.stopping = false
                self.suppressNextStoppedEvent = false
                self.launchedExecutablePath = nil
                self.sessionExecutablePath = nil
            }
            throw error
        }
    }

    func stop() {
        let runningProcess: Process? = lock.withLock {
            stopping = true
            outputSource?.cancel()
            outputSource = nil
            outputPipe = nil
            startupTimer?.cancel()
            startupTimer = nil
            resetLinkLocked()
            launchedExecutablePath = nil
            return process
        }

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()
        } else {
            lock.withLock {
                process = nil
                stopping = false
            }
        }
    }

    /// The first Instant Link address in the helper's output. Cloudflare's own
    /// API host is skipped: it appears in the error line the helper prints when
    /// it cannot create a link, and must not be reported as the public address.
    static func firstPublicURL(in text: String) -> URL? {
        for match in text.matches(of: /https:\/\/[A-Za-z0-9-]+\.trycloudflare\.com/) {
            if let url = URL(string: String(match.output)), url.host() != "api.trycloudflare.com" {
                return url
            }
        }
        return nil
    }

    static func containsRegisteredConnectionEvidence(in text: String) -> Bool {
        text.localizedCaseInsensitiveContains("Registered tunnel connection")
    }

    /// True when the helper's output says Cloudflare rejected the tunnel's
    /// run token: the token was replaced, or the tunnel was deleted. The
    /// helper itself tells this error apart by the same word.
    static func containsRunTokenRefusal(in text: String) -> Bool {
        text.localizedCaseInsensitiveContains("Unauthorized")
            || text.localizedCaseInsensitiveContains("Tunnel token is not valid")
    }

    /// Where the helper says its status page is. Only an address on this Mac
    /// is accepted, because the app goes on to send requests to it.
    static func readinessURL(in text: String) -> URL? {
        guard let match = text.firstMatch(of: /Starting metrics server on 127\.0\.0\.1:(\d{1,5})\/metrics/) else {
            return nil
        }
        return URL(string: "http://127.0.0.1:\(match.output.1)/ready")
    }

    /// The number of connections in the helper's `/ready` answer, which looks
    /// like `{"status":200,"readyConnections":4,"connectorId":"…"}`.
    static func readyConnectionCount(from data: Data) -> Int? {
        struct Answer: Decodable { let readyConnections: Int }
        return (try? JSONDecoder().decode(Answer.self, from: data))?.readyConnections
    }

    /// The default probe: one short request to the helper on this Mac. The
    /// helper answers 503 when it has no connections, so the count is read
    /// from the body whatever the status.
    static let fetchReadyConnections: ReadyConnectionsProbe = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return readyConnectionCount(from: data)
    }

    /// Asks the running helper how many connections to Cloudflare it has, and
    /// takes the link down or brings it back to match. The helper keeps
    /// running and reconnects by itself when the network drops or the Mac
    /// wakes, so the process being alive says nothing about the link. Called
    /// by the watchdog's regular check and shortly after the helper prints.
    func refreshEdgeConnection() async {
        let check: (process: Process, url: URL, evidenceCount: Int)? = lock.withLock {
            guard let process, process.isRunning, let readinessURL else { return nil }
            return (process, readinessURL, edgeEvidenceCount)
        }
        guard let check, let count = await readyConnections(check.url) else { return }
        updateLink(for: check.process) {
            // An answer of "none" from before the helper printed a new
            // connection is out of date.
            if count > 0 || self.edgeEvidenceCount == check.evidenceCount {
                self.isEdgeConnected = count > 0
            }
        }
    }

    /// Takes in one read of the helper's output: the address it serves, where
    /// its status page is, whether a connection registered, and whether
    /// Cloudflare rejected the run token. A registered connection proves the
    /// token works, so it clears an earlier rejection: Cloudflare can reject
    /// a tunnel for a few seconds right after it is created.
    private func noteHelperOutput(
        for expectedProcess: Process,
        announcedURL: URL?,
        readinessURL: URL?,
        registeredConnection: Bool,
        refusedRunToken: Bool
    ) {
        updateLink(for: expectedProcess) {
            if let announcedURL, self.announcedURL == nil {
                self.announcedURL = announcedURL
            }
            if let readinessURL {
                self.readinessURL = readinessURL
            }
            if registeredConnection {
                self.isEdgeConnected = true
                self.edgeEvidenceCount += 1
                self.sawRunTokenRefusal = false
            } else if refusedRunToken {
                self.sawRunTokenRefusal = true
            }
        }
        scheduleEdgeConnectionCheck()
    }

    /// The one place the link goes up or down. `change` runs under the lock
    /// for the helper it was meant for; afterwards the link is up exactly when
    /// that helper is connected and its address is known. A helper that is
    /// being stopped no longer changes anything.
    private func updateLink(for expectedProcess: Process, _ change: () -> Void) {
        let result: (event: TunnelServiceEvent, handler: EventHandler, timer: DispatchSourceTimer?)? = lock.withLock {
            guard process === expectedProcess, !stopping, let eventHandler else { return nil }
            change()
            if isEdgeConnected, publicURL == nil, let announcedURL {
                publicURL = announcedURL
                let timer = startupTimer
                startupTimer = nil
                return (.started(announcedURL), eventHandler, timer)
            }
            if !isEdgeConnected, publicURL != nil {
                publicURL = nil
                return (.connectionLost, eventHandler, nil)
            }
            return nil
        }
        result?.timer?.cancel()
        if let result {
            result.handler(result.event)
        }
    }

    /// The helper prints a line whenever a connection comes or goes, so its
    /// output is the cue to ask it for the real count. One check covers
    /// everything printed in the delay before it runs.
    private func scheduleEdgeConnectionCheck() {
        let shouldSchedule = lock.withLock {
            guard readinessURL != nil, !edgeCheckScheduled else { return false }
            edgeCheckScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        outputQueue.asyncAfter(deadline: .now() + Self.edgeCheckDelay) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.edgeCheckScheduled = false }
            Task { await self.refreshEdgeConnection() }
        }
    }

    /// Forgets everything known about the previous helper's link, and records
    /// who hears about the next one. The caller holds the lock.
    private func resetLinkLocked(eventHandler: EventHandler? = nil, announcedURL: URL? = nil) {
        self.eventHandler = eventHandler
        self.announcedURL = announcedURL
        publicURL = nil
        isEdgeConnected = false
        readinessURL = nil
        sawRunTokenRefusal = false
    }

    private func armNamedStartupTimeout(for expectedProcess: Process, onEvent: @escaping EventHandler) {
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        timer.schedule(deadline: .now() + namedStartupTimeout)
        timer.setEventHandler { [weak self, weak expectedProcess] in
            guard let self, let expectedProcess else { return }
            let timedOut: (process: Process, refused: Bool)? = self.lock.withLock {
                guard self.process === expectedProcess,
                      expectedProcess.isRunning,
                      self.publicURL == nil else {
                    return nil
                }
                self.startupTimer?.cancel()
                self.startupTimer = nil
                self.stopping = true
                self.suppressNextStoppedEvent = true
                return (expectedProcess, self.sawRunTokenRefusal)
            }
            guard let timedOut else { return }
            timedOut.process.terminate()
            onEvent(Self.failure(Self.namedTunnelStartupFailure, runTokenRefused: timedOut.refused))
        }

        let shouldStart = lock.withLock {
            guard process === expectedProcess,
                  expectedProcess.isRunning,
                  publicURL == nil else {
                return false
            }
            startupTimer?.cancel()
            startupTimer = timer
            return true
        }
        if shouldStart {
            timer.resume()
        } else {
            timer.resume()
            timer.cancel()
        }
    }

    private func handleTermination(of endedProcess: Process, onEvent: EventHandler) {
        let exitCode = endedProcess.terminationStatus
        // A late handler for a helper that was already replaced must not
        // clear the state of the one running now.
        guard lock.withLock({ process === endedProcess }) else { return }
        clearChildRecord()
        let notification: TunnelTerminationNotification = lock.withLock {
            let wasStopping = stopping
            let suppressStopped = suppressNextStoppedEvent
            let refused = sawRunTokenRefusal
            process = nil
            outputSource?.cancel()
            outputSource = nil
            outputPipe = nil
            startupTimer?.cancel()
            startupTimer = nil
            resetLinkLocked()
            stopping = false
            suppressNextStoppedEvent = false
            launchedExecutablePath = nil
            if suppressStopped {
                return .none
            }
            return wasStopping ? .stopped : .failed(runTokenRefused: refused)
        }

        switch notification {
        case .none:
            return
        case .stopped:
            onEvent(.stopped)
        case .failed(let runTokenRefused):
            onEvent(Self.failure(
                "cloudflared exited unexpectedly with status \(exitCode).",
                runTokenRefused: runTokenRefused
            ))
        }
    }

    /// A failed start or an unexpected exit, reported as a rejected run token
    /// when that is what the helper said before it failed.
    private static func failure(_ message: String, runTokenRefused: Bool) -> TunnelServiceEvent {
        runTokenRefused ? .runTokenRefused(message) : .failed(message)
    }
}

private enum TunnelTerminationNotification {
    case none
    case stopped
    case failed(runTokenRefused: Bool)
}
