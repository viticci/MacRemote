import Darwin
import CryptoKit
import Foundation
import Testing
@testable import MacRemote

struct ProcessRunnerTests {
    @Test func credentialCaptureNeverSpoolsOversizedOrInvalidUTF8() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = ProcessRunner(stdoutSpoolDirectory: root, allowsStdoutSpooling: false)
        for script in ["import sys; sys.stdout.buffer.write(b'x' * 120000)", "import sys; sys.stdout.buffer.write(bytes([255]))"] {
            let result = try await runner.run(executablePath: "/usr/bin/python3", arguments: ["-c", script], timeoutSeconds: 10, outputByteLimit: 8192)
            #expect(result.succeeded)
            #expect(result.stdoutSpool == nil)
            #expect(result.truncatedStdout || !result.stdoutBytesAreValidUTF8)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        }
    }

    @Test func runnerExecutesWithoutShell() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/echo",
            arguments: ["hello"],
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )

        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(result.arguments == ["hello"])
        #expect(result.executablePath == "/bin/echo")
    }

    @Test func missingExecutableLaunchHasTypedPathFreeError() async throws {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemote-missing-\(UUID().uuidString)")
            .path

        do {
            _ = try await ProcessRunner().run(
                executablePath: missingPath,
                arguments: ["--secret-argument"],
                timeoutSeconds: 2,
                outputByteLimit: 1024
            )
            Issue.record("A missing executable must not launch.")
        } catch let error as ProcessRunnerError {
            #expect(error == .executableUnavailable)
            #expect(error.localizedDescription.contains(missingPath) == false)
            #expect(error.localizedDescription.contains("--secret-argument") == false)
        }
    }

    @Test func runnerAppliesExplicitEnvironment() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/env",
            arguments: [],
            timeoutSeconds: 2,
            outputByteLimit: 4 * 1024,
            environment: ["MACREMOTE_TEST_ENV": "present"]
        )

        #expect(result.succeeded)
        #expect(result.stdout.contains("MACREMOTE_TEST_ENV=present"))
        #expect(result.stdout.contains("PATH=") == false)
        #expect(result.stdout.contains("ANTHROPIC_API_KEY=") == false)
    }

    @Test func runnerWritesStandardInput() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            standardInput: "hello stdin"
        )

        #expect(result.succeeded)
        #expect(result.stdout == "hello stdin")
    }

    @Test func runnerDrainsLargeStdoutWithoutDeadlock() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/dd",
            arguments: ["if=/dev/zero", "bs=1024", "count=200"],
            timeoutSeconds: 5,
            outputByteLimit: 65_536
        )

        #expect(result.timedOut == false)
        #expect(result.succeeded)
        #expect(result.truncatedStdout == true)
        #expect(result.stdout.utf8.count == 65_536)
    }

    @Test func runnerBigStdinRoundTrip() async throws {
        let input = String(repeating: "x", count: 256 * 1024)
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024,
            standardInput: input
        )

        #expect(result.succeeded)
        #expect(result.timedOut == false)
        #expect(result.truncatedStdout == false)
        #expect(result.stdout == String(input.prefix(ProcessRunner.stdoutInlineByteLimit)))
        let spool = try #require(result.stdoutSpool)
        defer { spool.remove() }
        #expect(try Data(contentsOf: spool.fileURL) == Data(input.utf8))
    }

    @Test func largeMultibyteStdinCannotBlockTimeoutWhenChildIgnoresInput() async throws {
        // 24,000 emoji stay below NotesCTL's 64K-character stdin schema while
        // producing ~96 KB of UTF-8, enough to exceed a macOS pipe buffer.
        let input = String(repeating: "🙂", count: 24_000)
        let runner = ProcessRunner()
        let started = Date()
        let result = try await runner.run(
            executablePath: "/bin/sleep",
            arguments: ["10"],
            timeoutSeconds: 0.2,
            outputByteLimit: 4 * 1024,
            standardInput: input
        )

        #expect(result.timedOut)
        #expect(result.succeeded == false)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func runnerKeepsExactlyThresholdStdoutInline() async throws {
        let input = String(repeating: "x", count: ProcessRunner.stdoutInlineByteLimit)
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024,
            standardInput: input
        )

        #expect(result.succeeded)
        #expect(result.stdout == input)
        #expect(result.stdoutSpool == nil)
        #expect(result.truncatedStdout == false)
    }

    @Test func runnerSpoolsCompleteUnicodeStdoutAboveInlineThreshold() async throws {
        let input = String(repeating: "🙂", count: 30_000)
        let expectedData = Data(input.utf8)
        let expectedSHA256 = SHA256.hash(data: expectedData).map { String(format: "%02x", $0) }.joined()
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024,
            standardInput: input
        )
        let spool = try #require(result.stdoutSpool)
        defer { spool.remove() }

        #expect(result.succeeded)
        #expect(result.truncatedStdout == false)
        #expect(result.stdout.utf8.count == ProcessRunner.stdoutInlineByteLimit)
        #expect(spool.sizeBytes == expectedData.count)
        #expect(FileManager.default.fileExists(atPath: spool.fileURL.path))

        let spooledData = try Data(contentsOf: spool.fileURL)
        let spooledSHA256 = SHA256.hash(data: spooledData).map { String(format: "%02x", $0) }.joined()
        #expect(spooledData == expectedData)
        #expect(spooledSHA256 == expectedSHA256)
    }

    @Test func runnerSpoolContainsExactHardCappedPrefixAndStillDrains() async throws {
        let input = String(repeating: "z", count: 300_000)
        let hardLimit = 150_000
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 5,
            outputByteLimit: hardLimit,
            standardInput: input
        )
        let spool = try #require(result.stdoutSpool)
        defer { spool.remove() }

        #expect(result.succeeded)
        #expect(result.timedOut == false)
        #expect(result.truncatedStdout)
        #expect(result.stdout.utf8.count == ProcessRunner.stdoutInlineByteLimit)
        #expect(spool.sizeBytes == hardLimit)
        #expect(try Data(contentsOf: spool.fileURL) == Data(input.utf8).prefix(hardLimit))
    }

    @Test func runnerSpoolCleanupRemovesTemporarySource() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024,
            standardInput: String(repeating: "c", count: 150_000)
        )
        let spool = try #require(result.stdoutSpool)

        #expect(FileManager.default.fileExists(atPath: spool.fileURL.path))
        spool.remove()
        #expect(FileManager.default.fileExists(atPath: spool.fileURL.path) == false)
        spool.remove()
        #expect(FileManager.default.fileExists(atPath: spool.fileURL.path) == false)
    }

    @Test func runnerSpoolsNonUTF8StdoutBelowInlineLimitWithoutLosingBytes() async throws {
        let expected = Data([0x41, 0xff, 0x42])
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", "import sys; sys.stdout.buffer.write(bytes([0x41, 0xff, 0x42]))"],
            timeoutSeconds: 5,
            outputByteLimit: 1024
        )
        let spool = try #require(result.stdoutSpool)
        defer { spool.remove() }

        #expect(result.succeeded)
        #expect(result.stdoutBytesAreValidUTF8 == false)
        #expect(result.stdoutPreservationError == nil)
        #expect(result.truncatedStdout == false)
        #expect(try Data(contentsOf: spool.fileURL) == expected)
    }

    @Test func runnerValidatesUnicodeAcrossTheInlinePreviewBoundary() async throws {
        let expected = Data(repeating: 0x61, count: ProcessRunner.stdoutInlineByteLimit - 1)
            + Data([0xc3, 0xa9, 0x62])
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys; sys.stdout.buffer.write(b'a' * 99999 + bytes([0xc3, 0xa9, 0x62]))"
            ],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024
        )
        let spool = try #require(result.stdoutSpool)
        defer { spool.remove() }

        #expect(result.succeeded)
        #expect(result.stdoutBytesAreValidUTF8)
        #expect(result.stdoutPreservationError == nil)
        #expect(try Data(contentsOf: spool.fileURL) == expected)
    }

    @Test func runnerDetectsInvalidUTF8AfterTheInlinePreviewBoundary() async throws {
        let expected = Data(repeating: 0x61, count: ProcessRunner.stdoutInlineByteLimit)
            + Data([0xff])
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys; sys.stdout.buffer.write(b'a' * 100000 + bytes([0xff]))"
            ],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024
        )
        let spool = try #require(result.stdoutSpool)
        defer { spool.remove() }

        #expect(result.succeeded)
        #expect(result.stdoutBytesAreValidUTF8 == false)
        #expect(result.stdoutPreservationError == nil)
        #expect(try Data(contentsOf: spool.fileURL) == expected)
    }

    @Test func runnerReportsSpoolFailureAfterKeepingCompletedExitStatus() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-blocked-spool-\(UUID().uuidString)")
        try Data().write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }

        let runner = ProcessRunner(stdoutSpoolDirectory: root)
        let result = try await runner.run(
            executablePath: "/usr/bin/python3",
            arguments: ["-c", "import sys; sys.stdout.write('x' * 150000)"],
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024
        )

        #expect(result.exitCode == 0)
        #expect(result.succeeded)
        #expect(result.stdoutSpool == nil)
        #expect(result.stdoutPreservationError != nil)
        #expect(result.truncatedStdout)
    }

    @Test func highConfiguredOutputLimitStillBoundsAndDrainsStderr() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys; sys.stderr.buffer.write(b'e' * (2 * 1024 * 1024)); sys.stderr.flush(); sys.stdout.write('done')"
            ],
            timeoutSeconds: 5,
            outputByteLimit: ToolArgumentResolver.maximumOutputByteLimit
        )

        #expect(result.succeeded)
        #expect(result.timedOut == false)
        #expect(result.stdout == "done")
        #expect(result.stderr.utf8.count == ProcessRunner.stderrCaptureByteLimit)
        #expect(result.truncatedStderr)
    }

    @Test func stderrRespectsSmallerConfiguredOutputLimitAndStillDrains() async throws {
        let runner = ProcessRunner()
        let configuredLimit = 4 * 1024
        let result = try await runner.run(
            executablePath: "/usr/bin/python3",
            arguments: [
                "-c",
                "import sys; sys.stderr.buffer.write(b'e' * (2 * 1024 * 1024)); sys.stderr.flush(); sys.stdout.write('done')"
            ],
            timeoutSeconds: 5,
            outputByteLimit: configuredLimit
        )

        #expect(result.succeeded)
        #expect(result.timedOut == false)
        #expect(result.stdout == "done")
        #expect(result.stderr.utf8.count == configuredLimit)
        #expect(result.truncatedStderr)
    }

    @Test func inspectorTreatsSpoolBackedStdoutAsPreviewWithoutHardCapLoss() async throws {
        let tool = ToolDefinition(
            id: "test.inspector-spool",
            name: "Inspector Spool",
            summary: "Emit enough stdout to exercise the Inspector preview.",
            executablePath: "/usr/bin/python3",
            argumentPattern: ["-c", "import sys; sys.stdout.write('p' * 150000)"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 512 * 1024
        )
        let outcome = try await ConfiguredToolExecutor(
            tools: [tool],
            environment: ExecutableLocator.toolEnvironment
        ).execute(toolID: tool.id, parameters: [:])
        let spool = try #require(outcome.stdoutSpool)
        defer { spool.remove() }

        #expect(outcome.truncatedStdout == false)
        #expect(outcome.stdout.utf8.count == ProcessRunner.stdoutInlineByteLimit)
        #expect(outcome.inspectorStdoutIsPreview)
        #expect(outcome.inspectorHasCompleteSpoolBackedStdout)
    }

    /// The app itself starts at the root of the disk, where a relative path
    /// such as "Users/…" names any file. Tools start in an empty folder that
    /// cannot be written to instead.
    @Test func toolsStartInAnEmptyReadOnlyFolder() async throws {
        let result = try await ProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", "pwd; ls -A | wc -l | tr -d ' '; touch probe 2>/dev/null && echo writable || echo read-only"],
            timeoutSeconds: 5,
            outputByteLimit: 4096
        )
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasSuffix("/MacRemoteEmptyWorkingDirectory") == true)
        #expect(lines.dropFirst().first == "0")
        #expect(lines.last == "read-only")
    }

    /// A tool that leaves a background process holding its output pipe used
    /// to keep the call open for that process's whole life, past the timeout.
    @Test func runnerReturnsWhenABackgroundChildKeepsTheOutputPipeOpen() async throws {
        let started = Date()
        let result = try await ProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", "(sleep 20 &) ; echo done"],
            timeoutSeconds: 10,
            outputByteLimit: 1024
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout == "done\n")
        #expect(!result.timedOut)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func runnerTimesOutHangingChild() async throws {
        let runner = ProcessRunner()
        let started = Date()
        let result = try await runner.run(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            timeoutSeconds: 1,
            outputByteLimit: 1024
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.timedOut == true)
        #expect(result.succeeded == false)
        #expect(elapsed < 5)
    }

    @Test func runnerKillsTimedOutChildProcess() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/perl",
            arguments: ["-e", "print $$; exec('/bin/sleep', '30')"],
            timeoutSeconds: 1,
            outputByteLimit: 64
        )

        #expect(result.timedOut == true)
        let pid = pid_t(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        #expect(pid > 1)
        #expect(isProcessRunning(pid: pid) == false)
    }

    @Test func runnerKillsConcurrentTimedOutChildren() async throws {
        let uniqueDurations = (0..<8).map { 340 + $0 }
        try await withThrowingTaskGroup(of: (Int, CommandRunResult).self) { group in
            for duration in uniqueDurations {
                group.addTask {
                    let runner = ProcessRunner()
                    let result = try await runner.run(
                        executablePath: "/usr/bin/perl",
                        arguments: ["-e", "print $$; exec('/bin/sleep', '\(duration)')"],
                        timeoutSeconds: 1,
                        outputByteLimit: 64
                    )
                    return (duration, result)
                }
            }

            var pids: [pid_t] = []
            for try await (_, result) in group {
                #expect(result.timedOut == true)
                let pid = pid_t(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
                #expect(pid > 1)
                pids.append(pid)
            }
            for pid in pids {
                #expect(isProcessRunning(pid: pid) == false)
            }
        }
    }

    @Test func cancellingSwiftTaskKillsProcessAndDescendant() async throws {
        let markerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteCancellation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: markerDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: markerDirectory) }
        let markerURL = markerDirectory.appendingPathComponent("pids")

        let runTask = Task {
            try await ProcessRunner().run(
                executablePath: "/usr/bin/python3",
                arguments: [
                    "-c",
                    """
                    import os, pathlib, subprocess, sys, time
                    child = subprocess.Popen(['/bin/sleep', '331'])
                    pathlib.Path(sys.argv[1]).write_text(f'{os.getpid()} {child.pid}')
                    while True:
                        time.sleep(1)
                    """,
                    markerURL.path
                ],
                timeoutSeconds: 30,
                outputByteLimit: 1_024
            )
        }

        var processIDs: [pid_t] = []
        for _ in 0..<100_000 {
            if let contents = try? String(contentsOf: markerURL, encoding: .utf8) {
                processIDs = contents.split(separator: " ").compactMap {
                    guard let value = Int32($0) else { return nil }
                    return pid_t(value)
                }
                if processIDs.count == 2 {
                    break
                }
            }
            await Task.yield()
        }
        #expect(processIDs.count == 2)

        runTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await runTask.value
        }
        for pid in processIDs {
            #expect(isProcessRunning(pid: pid) == false)
        }
    }

    /// A grandchild whose own parent already exited is no longer below the
    /// tool in the process tree. Only the tool's process group still reaches
    /// it, so a timeout must signal the group.
    @Test func timeoutKillsAGrandchildWhoseParentAlreadyExited() async throws {
        let result = try await ProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", "(/bin/sleep 600 >/dev/null 2>&1 & echo $!); exec /bin/sleep 600"],
            timeoutSeconds: 1,
            outputByteLimit: 64
        )

        #expect(result.timedOut)
        let orphan = pid_t(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        defer { _ = kill(orphan, SIGKILL) }
        #expect(orphan > 1)
        #expect(await processExits(orphan))
    }

    /// The tool exits on the first signal, but something it started ignores
    /// that signal. The harder one that follows must still reach it.
    @Test func timeoutKillsAGrandchildThatIgnoresThePoliteSignal() async throws {
        let result = try await ProcessRunner().run(
            executablePath: "/bin/sh",
            arguments: ["-c", "(trap '' TERM; /bin/sleep 600 >/dev/null 2>&1 & echo $!); exec /bin/sleep 600"],
            timeoutSeconds: 1,
            outputByteLimit: 64
        )

        #expect(result.timedOut)
        let orphan = pid_t(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        defer { _ = kill(orphan, SIGKILL) }
        #expect(orphan > 1)
        #expect(await processExits(orphan))
    }

    @Test func cancellationKillsAGrandchildWhoseParentAlreadyExited() async throws {
        let markerURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteOrphan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: markerURL) }

        let runTask = Task {
            try await ProcessRunner().run(
                executablePath: "/bin/sh",
                // `$0` is the marker path: the orphan's PID is written there.
                arguments: ["-c", "(/bin/sleep 600 >/dev/null 2>&1 & echo $! > \"$0\"); exec /bin/sleep 600", markerURL.path],
                timeoutSeconds: 30,
                outputByteLimit: 64
            )
        }
        var orphan: pid_t = 0
        for _ in 0..<500 where orphan == 0 {
            let contents = (try? String(contentsOf: markerURL, encoding: .utf8)) ?? ""
            orphan = pid_t(Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
            try await Task.sleep(for: .milliseconds(10))
        }
        defer { _ = kill(orphan, SIGKILL) }
        #expect(orphan > 1)

        runTask.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await runTask.value
        }
        #expect(await processExits(orphan))
    }

    /// Swift's async runtime has about one thread per CPU core. Waiting on a
    /// slow tool must not hold any of them, or a few slow tools stall every
    /// other async task in the app.
    @Test func slowToolsLeaveSwiftsAsyncThreadsFree() async throws {
        let slowTools = (0..<ProcessInfo.processInfo.activeProcessorCount).map { _ in
            Task {
                try await ProcessRunner().run(
                    executablePath: "/bin/sleep",
                    arguments: ["30"],
                    timeoutSeconds: 4,
                    outputByteLimit: 1024
                )
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        try await Task.sleep(for: .milliseconds(300))
        await Task.detached {}.value
        let waited = clock.now - started
        for tool in slowTools {
            tool.cancel()
        }
        for tool in slowTools {
            _ = try? await tool.value
        }

        #expect(waited < .seconds(2))
    }

    @Test func finishedProcessDisarmsDelayedKillEscalation() {
        let controller = ProcessTerminationController()
        controller.install(pid: pid_t(Int32.max))
        controller.requestTermination()
        #expect(controller.escalationIsArmedForTesting)

        controller.markFinished()

        #expect(controller.escalationIsArmedForTesting == false)
    }

    @Test func aStopIsRecordedBeforeTheToolIsSignalled() {
        // The tool can exit, and its result be read, as soon as the signal
        // goes out. A timeout has to be on record before that.
        let controller = ProcessTerminationController()
        controller.install(pid: pid_t(Int32.max))
        var signalledWhenRecorded: Bool?

        controller.requestTermination {
            signalledWhenRecorded = controller.escalationIsArmedForTesting
        }

        #expect(signalledWhenRecorded == false)
        #expect(controller.escalationIsArmedForTesting)
    }

    @Test func aToolThatAlreadyFinishedIsNotRecordedAsStopped() {
        let controller = ProcessTerminationController()
        controller.install(pid: pid_t(Int32.max))
        controller.markFinished()
        var recorded = false

        let stopped = controller.requestTermination { recorded = true }

        #expect(stopped == false)
        #expect(recorded == false)
    }
}

private func isProcessRunning(pid: pid_t) -> Bool {
    guard pid > 1 else {
        return false
    }
    if kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

/// Waits up to five seconds for one process to be gone. The harder signal
/// follows the polite one by two seconds.
private func processExits(_ pid: pid_t) async -> Bool {
    for _ in 0..<500 where isProcessRunning(pid: pid) {
        try? await Task.sleep(for: .milliseconds(10))
    }
    return !isProcessRunning(pid: pid)
}
