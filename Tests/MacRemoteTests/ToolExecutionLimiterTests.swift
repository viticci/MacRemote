import Foundation
import Testing
@testable import MacRemote

struct ToolExecutionLimiterTests {
    @Test func upToMaxSlotsRunConcurrently() async throws {
        let maxSlots = 3
        let limiter = ToolExecutionLimiter(maxSlots: maxSlots, acquireTimeout: .milliseconds(500))
        let peak = ConcurrentPeakCounter()
        let hold = TestGate()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<maxSlots {
                group.addTask {
                    _ = try? await limiter.withSlot(timeout: .milliseconds(500)) {
                        await peak.entered()
                        await hold.wait()
                        await peak.exited()
                        return ()
                    }
                }
            }

            // Wait for the tasks to get in instead of guessing how long that
            // takes: a fixed 50 ms failed on a busy Mac.
            for _ in 0..<200 where await peak.activeCount < maxSlots {
                try? await Task.sleep(for: .milliseconds(10))
            }
            #expect(await peak.activeCount == maxSlots)
            #expect(await peak.peak == maxSlots)

            await hold.open()
            await group.waitForAll()
        }
    }

    @Test func waiterRunsAfterSlotRelease() async throws {
        let limiter = ToolExecutionLimiter(maxSlots: 1, acquireTimeout: .seconds(1))
        let entered = TestGate()
        let releaseFirst = TestGate()

        let first = Task {
            try await limiter.withSlot(timeout: .seconds(1)) {
                await entered.open()
                await releaseFirst.wait()
                return 1
            }
        }

        await entered.wait()

        let second = Task {
            try await limiter.withSlot(timeout: .seconds(1)) {
                2
            }
        }

        await releaseFirst.open()

        let secondResult = try await second.value
        #expect(secondResult == 2)
        #expect(try await first.value == 1)
    }

    @Test func acquireTimesOutWhenSlotsStayBusy() async throws {
        let limiter = ToolExecutionLimiter(maxSlots: 1, acquireTimeout: .milliseconds(100))
        let hold = TestGate()

        let holder = Task {
            try await limiter.withSlot(timeout: .seconds(2)) {
                await hold.wait()
            }
        }

        try await Task.sleep(for: .milliseconds(20))

        let result = try await limiter.withSlot(timeout: .milliseconds(100)) {
            "should not run"
        }
        #expect(result == nil)

        await hold.open()
        _ = try await holder.value
    }

    @Test func slotReleasedWhenBodyThrows() async throws {
        let limiter = ToolExecutionLimiter(maxSlots: 1, acquireTimeout: .milliseconds(200))

        enum TestError: Error { case boom }

        do {
            _ = try await limiter.withSlot {
                throw TestError.boom
            }
            Issue.record("Expected body to throw")
        } catch TestError.boom {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let acquired = try await limiter.withSlot(timeout: .milliseconds(200)) {
            true
        }
        #expect(acquired == true)
    }

    @Test func neverOverAdmitsConcurrentBodies() async throws {
        let maxSlots = 4
        let limiter = ToolExecutionLimiter(maxSlots: maxSlots, acquireTimeout: .milliseconds(150))
        let peak = ConcurrentPeakCounter()
        let hold = TestGate()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    _ = try? await limiter.withSlot(timeout: .milliseconds(150)) {
                        await peak.entered()
                        await hold.wait()
                        await peak.exited()
                        return ()
                    }
                }
            }

            try? await Task.sleep(for: .milliseconds(80))
            #expect(await peak.peak <= maxSlots)

            await hold.open()
            await group.waitForAll()
        }

        #expect(await peak.peak <= maxSlots)
    }

    @Test func cancellingWaiterDoesNotConsumeOrLeakCapacity() async throws {
        let limiter = ToolExecutionLimiter(maxSlots: 1, acquireTimeout: .seconds(5))
        let holderEntered = TestGate()
        let releaseHolder = TestGate()

        let holder = Task {
            try await limiter.withSlot {
                await holderEntered.open()
                await releaseHolder.wait()
                return "holder"
            }
        }
        await holderEntered.wait()

        let cancelledWaiter = Task {
            try await limiter.withSlot(timeout: .seconds(5)) {
                "must not run"
            }
        }
        await Task.yield()
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledWaiter.value
        }

        let successor = Task {
            try await limiter.withSlot(timeout: .seconds(5)) {
                "successor"
            }
        }
        await releaseHolder.open()

        #expect(try await holder.value == "holder")
        #expect(try await successor.value == "successor")

        let final = try await limiter.withSlot(timeout: .milliseconds(100)) {
            "capacity intact"
        }
        #expect(final == "capacity intact")
    }
}

// MARK: - Helpers

private actor ConcurrentPeakCounter {
    private(set) var activeCount = 0
    private(set) var peak = 0

    func entered() {
        activeCount += 1
        peak = max(peak, activeCount)
    }

    func exited() {
        activeCount -= 1
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            if isOpen {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
