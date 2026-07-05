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
        var processGroupLeaderPID: pid_t = 0

        let termination = Task {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }

        try process.run()
        processGroupLeaderPID = process.processIdentifier
        Self.makeProcessGroupLeader(pid: processGroupLeaderPID)

        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                await timeoutState.markTimedOut()
                Self.signalProcessGroup(leaderPID: processGroupLeaderPID, signal: SIGTERM)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    Self.signalProcessGroup(leaderPID: processGroupLeaderPID, signal: SIGKILL)
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

    private static func makeProcessGroupLeader(pid: pid_t) {
        guard pid > 1 else {
            return
        }
        _ = setpgid(pid, pid)
    }

    private static func signalProcessGroup(leaderPID: pid_t, signal: Int32) {
        guard leaderPID > 1 else {
            return
        }
        _ = kill(-leaderPID, signal)
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
