import Foundation

struct TunnelWatchdogConfiguration: Sendable, Equatable {
    var healthCheckInterval: TimeInterval = 20
    var initialBackoff: TimeInterval = 1
    var backoffMultiplier: Double = 2
    var maxBackoff: TimeInterval = 32
    var maxConsecutiveRestarts: Int = 5
}

enum TunnelWatchdogBackoff {
    static func delay(forAttempt attempt: Int, configuration: TunnelWatchdogConfiguration) -> TimeInterval {
        guard attempt > 0 else { return configuration.initialBackoff }
        let scaled = configuration.initialBackoff * pow(configuration.backoffMultiplier, Double(attempt - 1))
        return min(scaled, configuration.maxBackoff)
    }
}

protocol OriginHealthChecking: Sendable {
    func isOriginHealthy(at localServerURL: URL) async -> Bool
}

struct URLOriginHealthChecker: OriginHealthChecking {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func isOriginHealthy(at localServerURL: URL) async -> Bool {
        let healthURL = localServerURL.appendingPathComponent("health")
        var request = URLRequest(url: healthURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return http.statusCode == 200
        } catch {
            return false
        }
    }
}

final class TunnelWatchdog: @unchecked Sendable {
    struct Environment: Sendable {
        var configuration: TunnelWatchdogConfiguration = TunnelWatchdogConfiguration()
        var sleep: @Sendable (Duration) async throws -> Void
        var isTunnelProcessRunning: @Sendable () -> Bool
        var stopTunnelIfNeeded: @Sendable () async -> Void
        var restartTunnel: @Sendable () async throws -> Void
        var checkOriginHealth: @Sendable (URL) async -> Bool
        var onReconnecting: @Sendable (Int) -> Void
        var onRecoveryFailed: @Sendable (String) -> Void
        var onLog: @Sendable (String) -> Void
    }

    private let lock = NSLock()
    private let environment: Environment
    private var isActive = false
    private var localServerURL: URL?
    private var consecutiveFailures = 0
    private var sessionGeneration = 0
    private var monitorTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var isRecovering = false
    private var isPerformingControlledStop = false

    init(environment: Environment) {
        self.environment = environment
    }

    func activate(localServerURL: URL?) {
        let generation = lock.withLock { () -> Int in
            isActive = true
            self.localServerURL = localServerURL
            consecutiveFailures = 0
            sessionGeneration += 1
            monitorTask?.cancel()
            recoveryTask?.cancel()
            isRecovering = false
            isPerformingControlledStop = false
            return sessionGeneration
        }
        startHealthMonitor(generation: generation)
    }

    func deactivate() {
        lock.withLock {
            isActive = false
            localServerURL = nil
            sessionGeneration += 1
            monitorTask?.cancel()
            monitorTask = nil
            recoveryTask?.cancel()
            recoveryTask = nil
            isRecovering = false
            isPerformingControlledStop = false
            consecutiveFailures = 0
        }
    }

    /// Returns `true` when recovery will run and the caller should defer surfacing a failed tunnel state.
    @discardableResult
    func handleUnexpectedFailure(_ message: String) -> Bool {
        let shouldRecover: Bool = lock.withLock {
            guard isActive else { return false }
            return true
        }
        guard shouldRecover else { return false }

        environment.onLog("Public link stopped unexpectedly: \(message)")
        beginRecovery(reason: message)
        return true
    }

    func notifyTunnelStarted() {
        lock.withLock {
            consecutiveFailures = 0
            isRecovering = false
        }
    }

    func shouldIgnoreStoppedEvent() -> Bool {
        lock.withLock { isPerformingControlledStop }
    }

    private func beginRecovery(reason: String) {
        let generation = lock.withLock { () -> Int? in
            guard isActive else { return nil }
            sessionGeneration += 1
            recoveryTask?.cancel()
            return sessionGeneration
        }
        guard let generation else { return }

        recoveryTask = Task { [weak self] in
            await self?.runRecoveryLoop(reason: reason, generation: generation)
        }
    }

    private func startHealthMonitor(generation: Int) {
        monitorTask = Task { [weak self] in
            guard let self else { return }
            let interval = environment.configuration.healthCheckInterval
            while !Task.isCancelled {
                do {
                    try await environment.sleep(Duration.seconds(interval))
                } catch {
                    return
                }

                let shouldContinue: Bool = self.lock.withLock {
                    self.isActive && self.sessionGeneration == generation
                }
                guard shouldContinue else { return }
                let localServerURL: URL? = self.lock.withLock { self.localServerURL }
                guard let localServerURL else { continue }

                let originHealthy = await environment.checkOriginHealth(localServerURL)
                guard originHealthy else { continue }

                if environment.isTunnelProcessRunning() {
                    continue
                }

                let alreadyRecovering: Bool = self.lock.withLock { self.isRecovering }
                guard !alreadyRecovering else { continue }

                environment.onLog(
                    "Local server is healthy but the public link process is not running."
                )
                beginRecovery(reason: "The public link process stopped while the local server is still running.")
            }
        }
    }

    private func runRecoveryLoop(reason: String, generation: Int) async {
        while true {
            let nextStep = lock.withLock { () -> RecoveryStep in
                guard isActive, sessionGeneration == generation else {
                    return .stop
                }
                if consecutiveFailures >= environment.configuration.maxConsecutiveRestarts {
                    isRecovering = false
                    return .giveUp
                }
                consecutiveFailures += 1
                isRecovering = true
                return .retry(attempt: consecutiveFailures)
            }

            switch nextStep {
            case .stop:
                lock.withLock { isRecovering = false }
                return
            case .giveUp:
                let message =
                    "Could not restore the public link after \(environment.configuration.maxConsecutiveRestarts) attempts. \(reason)"
                environment.onRecoveryFailed(message)
                return
            case .retry(let attempt):
                let delay = TunnelWatchdogBackoff.delay(
                    forAttempt: attempt,
                    configuration: environment.configuration
                )
                environment.onReconnecting(attempt)
                environment.onLog(
                    "Reconnecting public link (attempt \(attempt) of \(environment.configuration.maxConsecutiveRestarts)) in \(Int(delay))s."
                )

                do {
                    try await environment.sleep(Duration.seconds(delay))
                } catch {
                    lock.withLock { isRecovering = false }
                    return
                }

                let stillActive = lock.withLock {
                    isActive && sessionGeneration == generation
                }
                guard stillActive else {
                    lock.withLock { isRecovering = false }
                    return
                }

                environment.onLog("Restarting public link after unexpected stop.")

                lock.withLock { isPerformingControlledStop = true }
                if environment.isTunnelProcessRunning() {
                    await environment.stopTunnelIfNeeded()
                    try? await environment.sleep(Duration.milliseconds(200))
                }
                lock.withLock { isPerformingControlledStop = false }

                do {
                    try await environment.restartTunnel()
                } catch {
                    environment.onLog("Public link restart failed: \(error.localizedDescription)")
                    continue
                }

                if environment.isTunnelProcessRunning() {
                    environment.onLog("Public link process restarted; waiting for it to become ready.")
                    return
                }

                environment.onLog("Public link process did not stay running after restart.")
            }
        }
    }
}

private enum RecoveryStep {
    case stop
    case giveUp
    case retry(attempt: Int)
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
