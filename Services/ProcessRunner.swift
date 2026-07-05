import Darwin
import Foundation

struct CommandRunResult: Sendable, Equatable {
    let executablePath: String
    let arguments: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let timedOut: Bool
    let truncatedStdout: Bool
    let truncatedStderr: Bool

    var succeeded: Bool {
        exitCode == 0 && !timedOut
    }
}

protocol ProcessRunning: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String],
        standardInput: String?
    ) async throws -> CommandRunResult
}

struct ProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String] = [:],
        standardInput: String? = nil
    ) async throws -> CommandRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe = standardInput.map { _ in Pipe() }
        if let stdinPipe {
            process.standardInput = stdinPipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutDrain = Task.detached {
            Self.collectOutput(from: stdoutHandle, limit: outputByteLimit)
        }
        let stderrDrain = Task.detached {
            Self.collectOutput(from: stderrHandle, limit: outputByteLimit)
        }

        let started = Date()
        let timeoutState = TimeoutState()
        var childPID: pid_t = 0
        var processGroupEstablished = false

        let termination = Task {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }

        try process.run()
        childPID = process.processIdentifier
        processGroupEstablished = Self.makeProcessGroupLeader(pid: childPID)

        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                await timeoutState.markTimedOut()
                Self.terminateTimedOutChild(
                    pid: childPID,
                    processGroupEstablished: processGroupEstablished
                )
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    Self.killTimedOutChild(
                        pid: childPID,
                        processGroupEstablished: processGroupEstablished
                    )
                }
            }
        }

        await termination.value
        timeout.cancel()

        let stdoutCollected = await stdoutDrain.value
        let stderrCollected = await stderrDrain.value
        let stdout = cappedString(from: stdoutCollected.data, truncated: stdoutCollected.truncated)
        let stderr = cappedString(from: stderrCollected.data, truncated: stderrCollected.truncated)

        return CommandRunResult(
            executablePath: executablePath,
            arguments: arguments,
            exitCode: process.terminationStatus,
            stdout: stdout.value,
            stderr: stderr.value,
            duration: Date().timeIntervalSince(started),
            timedOut: await timeoutState.timedOut,
            truncatedStdout: stdout.truncated,
            truncatedStderr: stderr.truncated
        )
    }

    private static func collectOutput(from handle: FileHandle, limit: Int) -> (data: Data, truncated: Bool) {
        var data = Data()
        var truncated = false
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            guard !truncated else {
                continue
            }
            let remaining = limit - data.count
            if chunk.count > remaining {
                if remaining > 0 {
                    data.append(chunk.prefix(remaining))
                }
                truncated = true
            } else {
                data.append(chunk)
            }
        }
        return (data, truncated)
    }

    /// Attempts to make `pid` its own process-group leader so grandchildren can be reaped via `kill(-pid, …)`.
    /// Returns whether `setpgid` succeeded; after exec this often fails with EACCES, so callers must not rely on it alone.
    private static func makeProcessGroupLeader(pid: pid_t) -> Bool {
        guard pid > 1 else {
            return false
        }
        return setpgid(pid, pid) == 0
    }

    private static func signalProcess(pid: pid_t, signal: Int32) {
        guard pid > 1 else {
            return
        }
        _ = kill(pid, signal)
    }

    private static func signalProcessGroup(leaderPID: pid_t, signal: Int32) {
        guard leaderPID > 1 else {
            return
        }
        _ = kill(-leaderPID, signal)
    }

    /// SIGTERM: process group when established, always the direct child (race-free backstop).
    private static func terminateTimedOutChild(pid: pid_t, processGroupEstablished: Bool) {
        if processGroupEstablished {
            signalProcessGroup(leaderPID: pid, signal: SIGTERM)
        }
        signalProcess(pid: pid, signal: SIGTERM)
    }

    /// SIGKILL: process group when established, always the direct child (race-free backstop).
    private static func killTimedOutChild(pid: pid_t, processGroupEstablished: Bool) {
        if processGroupEstablished {
            signalProcessGroup(leaderPID: pid, signal: SIGKILL)
        }
        signalProcess(pid: pid, signal: SIGKILL)
    }

    private func cappedString(from data: Data, truncated: Bool) -> (value: String, truncated: Bool) {
        (String(decoding: data, as: UTF8.self), truncated)
    }
}

extension ProcessRunner: ProcessRunning {}

private actor TimeoutState {
    private(set) var timedOut = false

    func markTimedOut() {
        timedOut = true
    }
}
