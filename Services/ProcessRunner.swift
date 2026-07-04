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
        }

        let started = Date()
        let timeoutState = TimeoutState()

        let termination = Task {
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in
                    continuation.resume()
                }
            }
        }

        try process.run()
        if let standardInput, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(Data(standardInput.utf8))
            try? stdinPipe.fileHandleForWriting.close()
        }

        let timeout = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            if process.isRunning {
                await timeoutState.markTimedOut()
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning {
                    process.interrupt()
                }
            }
        }

        await termination.value
        timeout.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = cappedString(from: stdoutData, limit: outputByteLimit)
        let stderr = cappedString(from: stderrData, limit: outputByteLimit)

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

    private func cappedString(from data: Data, limit: Int) -> (value: String, truncated: Bool) {
        let truncated = data.count > limit
        let cappedData = truncated ? data.prefix(limit) : data[...]
        return (String(decoding: cappedData, as: UTF8.self), truncated)
    }
}

extension ProcessRunner: ProcessRunning {}

private actor TimeoutState {
    private(set) var timedOut = false

    func markTimedOut() {
        timedOut = true
    }
}
