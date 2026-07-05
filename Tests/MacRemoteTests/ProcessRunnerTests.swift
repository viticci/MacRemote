import Darwin
import Foundation
import Testing
@testable import MacRemote

struct ProcessRunnerTests {
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
        #expect(result.stdout == input)
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

    @Test func runnerKillsDirectSleepAfterTimeout() async throws {
        let marker = 337
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/sleep",
            arguments: ["\(marker)"],
            timeoutSeconds: 1,
            outputByteLimit: 1024
        )

        #expect(result.timedOut == true)
        #expect(sleepProcessExists(duration: marker) == false)
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
            for try await (duration, result) in group {
                #expect(result.timedOut == true)
                let pid = pid_t(Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
                #expect(pid > 1)
                pids.append(pid)
                #expect(sleepProcessExists(duration: duration) == false)
            }
            for pid in pids {
                #expect(isProcessRunning(pid: pid) == false)
            }
        }
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

private func sleepProcessExists(duration: Int) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", "sleep \(duration)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        return false
    }
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}
