import Foundation
import Testing
@testable import MacRemote

struct TunnelWatchdogTests {
    @Test func backoffScheduleFollowsExponentialCap() {
        let configuration = TunnelWatchdogConfiguration()
        #expect(TunnelWatchdogBackoff.delay(forAttempt: 1, configuration: configuration) == 1)
        #expect(TunnelWatchdogBackoff.delay(forAttempt: 2, configuration: configuration) == 2)
        #expect(TunnelWatchdogBackoff.delay(forAttempt: 3, configuration: configuration) == 4)
        #expect(TunnelWatchdogBackoff.delay(forAttempt: 4, configuration: configuration) == 8)
        #expect(TunnelWatchdogBackoff.delay(forAttempt: 5, configuration: configuration) == 16)
        #expect(TunnelWatchdogBackoff.delay(forAttempt: 6, configuration: configuration) == 32)
    }

    @Test func unexpectedExitTriggersRestart() async {
        let harness = WatchdogTestHarness(
            configuration: TunnelWatchdogConfiguration(
                healthCheckInterval: 60,
                initialBackoff: 0.01,
                maxBackoff: 0.05,
                maxConsecutiveRestarts: 3
            )
        )
        harness.watchdog.activate(localServerURL: harness.localServerURL)
        #expect(harness.watchdog.handleUnexpectedFailure("cloudflared exited unexpectedly with status 1."))

        await harness.waitUntil { harness.state.restartCount == 1 }
        #expect(harness.state.reconnectingAttempts.contains(1))
    }

    @Test func consecutiveFailureCeilingStopsRestartsAndReportsFailed() async {
        let harness = WatchdogTestHarness(
            configuration: TunnelWatchdogConfiguration(
                healthCheckInterval: 60,
                initialBackoff: 0.01,
                maxBackoff: 0.05,
                maxConsecutiveRestarts: 3
            ),
            restartError: TestWatchdogError.restartFailed
        )
        harness.watchdog.activate(localServerURL: harness.localServerURL)
        #expect(harness.watchdog.handleUnexpectedFailure("cloudflared exited unexpectedly with status 1."))

        await harness.waitUntil { harness.state.recoveryFailed != nil }
        #expect(harness.state.restartCount == 0)
        #expect(harness.state.recoveryFailed?.contains("3 attempts") == true)
        #expect(harness.state.reconnectingAttempts == [1, 2, 3])
    }

    @Test func healthyOriginAndDeadTunnelTriggersRestart() async {
        let harness = WatchdogTestHarness(
            configuration: TunnelWatchdogConfiguration(
                healthCheckInterval: 0.05,
                initialBackoff: 0.01,
                maxBackoff: 0.05,
                maxConsecutiveRestarts: 3
            )
        )
        harness.state.originHealthy = true
        harness.state.isTunnelRunning = false
        harness.watchdog.activate(localServerURL: harness.localServerURL)

        await harness.waitUntil { harness.state.restartCount == 1 }
        #expect(harness.state.reconnectingAttempts.contains(1))
    }

    /// The helper can be running with no connection to Cloudflare. The regular
    /// check asks it, and never restarts a helper that is still running.
    @Test func healthCheckAsksARunningHelperWhetherItIsConnected() async {
        let harness = WatchdogTestHarness(
            configuration: TunnelWatchdogConfiguration(
                healthCheckInterval: 0.02,
                initialBackoff: 0.01,
                maxBackoff: 0.05,
                maxConsecutiveRestarts: 3
            )
        )
        harness.state.isTunnelRunning = true
        harness.watchdog.activate(localServerURL: harness.localServerURL)

        await harness.waitUntil { harness.state.connectionChecks >= 2 }
        harness.watchdog.deactivate()
        #expect(harness.state.restartCount == 0)
        #expect(harness.state.reconnectingAttempts.isEmpty)
    }

    @Test func userInitiatedStopDoesNotTriggerAutoRestart() async {
        let harness = WatchdogTestHarness(
            configuration: TunnelWatchdogConfiguration(
                healthCheckInterval: 0.05,
                initialBackoff: 0.01,
                maxBackoff: 0.05,
                maxConsecutiveRestarts: 3
            )
        )
        harness.watchdog.activate(localServerURL: harness.localServerURL)
        harness.watchdog.deactivate()

        #expect(harness.watchdog.handleUnexpectedFailure("cloudflared exited unexpectedly with status 1.") == false)

        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.state.restartCount == 0)
        #expect(harness.state.reconnectingAttempts.isEmpty)
        #expect(harness.state.recoveryFailed == nil)
    }
}

private enum TestWatchdogError: Error {
    case restartFailed
}

private final class WatchdogTestHarness: @unchecked Sendable {
    let localServerURL = URL(string: "http://127.0.0.1:60123")!
    let state = WatchdogTestState()
    let watchdog: TunnelWatchdog
    private let restartError: Error?

    init(
        configuration: TunnelWatchdogConfiguration,
        restartError: Error? = nil
    ) {
        self.restartError = restartError
        watchdog = TunnelWatchdog(environment: TunnelWatchdog.Environment(
            configuration: configuration,
            sleep: { duration in
                try await Task.sleep(for: duration)
            },
            isTunnelProcessRunning: { [state] in
                state.isTunnelRunning
            },
            refreshTunnelConnection: { [state] in
                state.recordConnectionCheck()
            },
            stopTunnelIfNeeded: { },
            restartTunnel: { [state, restartError] in
                if let restartError {
                    throw restartError
                }
                state.recordRestart()
            },
            checkOriginHealth: { [state] _ in
                state.originHealthy
            },
            onReconnecting: { [state] attempt in
                state.reconnectingAttempts.append(attempt)
            },
            onRecoveryFailed: { [state] message in
                state.recoveryFailed = message
            },
            onLog: { _ in }
        ))
    }

    func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: @escaping @Sendable () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for watchdog condition.")
    }
}

private final class WatchdogTestState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var restartCount = 0
    private(set) var connectionChecks = 0
    var isTunnelRunning = false
    var originHealthy = true
    var reconnectingAttempts: [Int] = []
    var recoveryFailed: String?

    func recordConnectionCheck() {
        lock.withLock { connectionChecks += 1 }
    }

    func recordRestart() {
        lock.withLock {
            restartCount += 1
            isTunnelRunning = true
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
