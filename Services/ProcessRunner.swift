import Darwin
import Foundation

private final class ProcessInputCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var waiter: CheckedContinuation<Void, Never>?

    func finish() {
        lock.lock()
        isFinished = true
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.resume()
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }
}

/// Stops a tool and everything it started, on a timeout or a cancellation.
///
/// Foundation's `Process` starts each child as the leader of its own process
/// group, so the group's ID is the child's PID and one signal to the group
/// reaches every descendant that stayed in it, including a grandchild whose
/// own parent already exited. The process tree is walked as well, for a
/// descendant that moved to a group of its own.
final class ProcessTerminationController: @unchecked Sendable {
    private struct Target: Sendable {
        let pid: pid_t
        let descendantPIDs: [pid_t]
    }

    private static let escalationQueue = DispatchQueue(
        label: "com.macstories.MacRemote.process-cancellation",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let lock = NSLock()
    private var installedPID: pid_t?
    private var terminationWasRequested = false
    private var processFinished = false
    private var escalationToken: UUID?

    func install(pid: pid_t) {
        let shouldTerminate: Bool = lock.withLock {
            guard !processFinished else { return false }
            installedPID = pid
            return terminationWasRequested
        }
        if shouldTerminate {
            terminateInstalledTarget()
        }
    }

    func markFinished() {
        lock.withLock {
            processFinished = true
            installedPID = nil
            escalationToken = nil
        }
    }

    /// Stops the tool if it is still running. `beforeSignalling` runs only in
    /// that case, and before any signal goes out: the tool can exit, and its
    /// result be read, before this call returns, so whatever the result
    /// reports about the stop has to be recorded first.
    @discardableResult
    func requestTermination(beforeSignalling: () -> Void = {}) -> Bool {
        let shouldTerminate: Bool = lock.withLock {
            terminationWasRequested = true
            return installedPID != nil && !processFinished
        }
        if shouldTerminate {
            beforeSignalling()
            terminateInstalledTarget()
        }
        return shouldTerminate
    }

    private func terminateInstalledTarget() {
        let target: Target? = lock.withLock {
            guard let installedPID, !processFinished else { return nil }
            self.installedPID = nil
            return Target(
                pid: installedPID,
                descendantPIDs: Self.descendantProcessIDs(of: installedPID)
            )
        }
        guard let target else { return }

        let token = UUID()
        let armed: Bool = lock.withLock {
            guard !processFinished else { return false }
            escalationToken = token
            return true
        }
        guard armed else { return }
        // Listed while the tool is still running, so each of these is known
        // to be in the tool's own group.
        let groupMembers = Self.processIDs(proc_listpgrppids, of: target.pid)
        Self.signal(target, signal: SIGTERM)
        Self.escalationQueue.asyncAfter(deadline: .now() + 2) {
            if self.claimEscalation(token: token) {
                // The tool itself ignored SIGTERM.
                let currentTarget = Target(
                    pid: target.pid,
                    descendantPIDs: Self.descendantProcessIDs(of: target.pid)
                )
                Self.signal(currentTarget, signal: SIGKILL)
            } else {
                // The tool exited, so its PID may belong to another program
                // by now and the group is not signalled again. Something it
                // started may have ignored SIGTERM: kill only the processes
                // seen earlier that are still in that group.
                for member in groupMembers
                where member != target.pid && getpgid(member) == target.pid {
                    _ = kill(member, SIGKILL)
                }
            }
        }
    }

    private func claimEscalation(token: UUID) -> Bool {
        lock.withLock {
            guard !processFinished, escalationToken == token else { return false }
            escalationToken = nil
            return true
        }
    }

    var escalationIsArmedForTesting: Bool {
        lock.withLock { escalationToken != nil && !processFinished }
    }

    /// Signals the tool's process group, then each descendant found in the
    /// process tree, then the tool itself. The group signal is safe while the
    /// tool has not been collected: a group with this ID can only be the
    /// tool's own, and if there is none the call does nothing.
    private static func signal(_ target: Target, signal: Int32) {
        guard target.pid > 1 else { return }
        _ = kill(-target.pid, signal)
        // Descendants first, so none is orphaned before the walk reaches it.
        for pid in target.descendantPIDs.reversed() where pid > 1 {
            _ = kill(pid, signal)
        }
        _ = kill(target.pid, signal)
    }

    private static func descendantProcessIDs(of rootPID: pid_t) -> [pid_t] {
        var visited: Set<pid_t> = [rootPID]
        var pending = [rootPID]
        var descendants: [pid_t] = []

        while let parentPID = pending.popLast() {
            for childPID in processIDs(proc_listchildpids, of: parentPID)
            where childPID > 1 && visited.insert(childPID).inserted {
                descendants.append(childPID)
                pending.append(childPID)
            }
        }
        return descendants
    }

    /// Runs one of the system's process listings: `proc_listchildpids` for
    /// the children of a process, `proc_listpgrppids` for the members of a
    /// process group.
    private static func processIDs(
        _ list: (pid_t, UnsafeMutableRawPointer?, Int32) -> Int32,
        of id: pid_t
    ) -> [pid_t] {
        let requiredCount = list(id, nil, 0)
        guard requiredCount > 0 else { return [] }

        var pids = [pid_t](
            repeating: 0,
            count: Int(requiredCount) + 8
        )
        let populatedCount = pids.withUnsafeMutableBytes { buffer in
            list(id, buffer.baseAddress, Int32(buffer.count))
        }
        guard populatedCount > 0 else { return [] }
        return Array(pids.prefix(Int(populatedCount)))
    }
}

final class ProcessOutputSpool: @unchecked Sendable, Equatable {
    let fileURL: URL
    let sizeBytes: Int

    private let lock = NSLock()
    private var removed = false

    init(fileURL: URL, sizeBytes: Int) {
        self.fileURL = fileURL
        self.sizeBytes = sizeBytes
    }

    func remove() {
        lock.lock()
        defer { lock.unlock() }
        guard !removed else { return }
        removed = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    deinit {
        remove()
    }

    static func == (lhs: ProcessOutputSpool, rhs: ProcessOutputSpool) -> Bool {
        lhs.fileURL == rhs.fileURL && lhs.sizeBytes == rhs.sizeBytes
    }
}

enum ProcessRunnerError: LocalizedError, Equatable, Sendable {
    case executableUnavailable
    case stdoutSpoolingFailed(String)

    var errorDescription: String? {
        switch self {
        case .executableUnavailable:
            "The command this tool needs is not installed or is no longer available on this Mac."
        case .stdoutSpoolingFailed(let message):
            "Could not preserve complete stdout: \(message)"
        }
    }
}

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
    let stdoutSpool: ProcessOutputSpool?
    let stdoutBytesAreValidUTF8: Bool
    let stdoutPreservationError: String?
    /// The signal that killed the tool, when it was not MacRemote's own
    /// timeout. `exitCode` then holds the signal number.
    let terminationSignal: Int32?

    init(
        executablePath: String,
        arguments: [String],
        exitCode: Int32,
        stdout: String,
        stderr: String,
        duration: TimeInterval,
        timedOut: Bool,
        truncatedStdout: Bool,
        truncatedStderr: Bool,
        stdoutSpool: ProcessOutputSpool? = nil,
        stdoutBytesAreValidUTF8: Bool = true,
        stdoutPreservationError: String? = nil,
        terminationSignal: Int32? = nil
    ) {
        self.executablePath = executablePath
        self.arguments = arguments
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
        self.timedOut = timedOut
        self.truncatedStdout = truncatedStdout
        self.truncatedStderr = truncatedStderr
        self.stdoutSpool = stdoutSpool
        self.stdoutBytesAreValidUTF8 = stdoutBytesAreValidUTF8
        self.stdoutPreservationError = stdoutPreservationError
        self.terminationSignal = terminationSignal
    }

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
    static let stdoutInlineByteLimit = 100_000
    static let stderrCaptureByteLimit = 1024 * 1024
    private static let timeoutQueue = DispatchQueue(
        label: "com.macstories.MacRemote.process-timeout",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private let stdoutSpoolDirectory: URL
    private let allowsStdoutSpooling: Bool

    /// Output too large to keep in memory is written to a file in the app's
    /// staging folder, which the app empties at launch, so a crash cannot
    /// leave such files behind for good.
    init(stdoutSpoolDirectory: URL = ArtifactStore.stagingRoot, allowsStdoutSpooling: Bool = true) {
        self.stdoutSpoolDirectory = stdoutSpoolDirectory
        self.allowsStdoutSpooling = allowsStdoutSpooling
    }

    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String] = [:],
        standardInput: String? = nil
    ) async throws -> CommandRunResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = Self.emptyWorkingDirectory()

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
        let stdoutSpoolDirectory = self.stdoutSpoolDirectory
        let allowsStdoutSpooling = self.allowsStdoutSpooling
        let drainDeadline = DrainDeadline()
        // Each pipe is read on a thread of its own: the reads block for as
        // long as the tool runs, and must not hold one of Swift's async threads.
        let stdoutDrain = Task.detached {
            await onBlockingThread {
                if !allowsStdoutSpooling {
                    let output = Self.collectOutput(
                        from: stdoutHandle,
                        limit: max(0, outputByteLimit),
                        until: drainDeadline
                    )
                    return CollectedStdout(
                        inlineData: output.data, truncated: output.truncated, spool: nil,
                        bytesAreValidUTF8: String(data: output.data, encoding: .utf8) != nil,
                        preservationError: nil
                    )
                }
                return Self.collectStdout(
                    from: stdoutHandle,
                    limit: outputByteLimit,
                    spoolDirectory: stdoutSpoolDirectory,
                    until: drainDeadline
                )
            }
        }
        let stderrDrain = Task.detached {
            await onBlockingThread {
                Self.collectOutput(
                    from: stderrHandle,
                    limit: min(max(0, outputByteLimit), Self.stderrCaptureByteLimit),
                    until: drainDeadline
                )
            }
        }

        let started = Date()
        let timeoutState = TimeoutState()
        let terminationController = ProcessTerminationController()
        let processExit = ProcessInputCompletion()
        process.terminationHandler = { _ in
            terminationController.markFinished()
            processExit.finish()
        }

        return try await withTaskCancellationHandler {
            do {
                try process.run()
            } catch {
                // A saved tool can pass validation and then disappear or lose
                // execute permission before launch. Close our pipe endpoints so
                // the already-started drains finish, then translate only known
                // launch-availability errors into the stable tool contract.
                try? stdoutPipe.fileHandleForWriting.close()
                try? stderrPipe.fileHandleForWriting.close()
                if let stdinPipe {
                    try? stdinPipe.fileHandleForReading.close()
                    try? stdinPipe.fileHandleForWriting.close()
                }
                drainDeadline.arm(after: 0)
                _ = await stdoutDrain.value
                _ = await stderrDrain.value
                if Self.isExecutableUnavailableLaunchError(error) {
                    throw ProcessRunnerError.executableUnavailable
                }
                throw error
            }
            terminationController.install(pid: process.processIdentifier)
            // Process has duplicated the pipe's read end into the child. Closing
            // our unused copy lets a blocked writer receive EPIPE when the child
            // exits or the timeout watchdog terminates it.
            if let stdinPipe {
                try? stdinPipe.fileHandleForReading.close()
            }

            let timeout = DispatchSource.makeTimerSource(queue: Self.timeoutQueue)
            timeout.schedule(deadline: .now() + timeoutSeconds)
            timeout.setEventHandler {
                terminationController.requestTermination { timeoutState.markTimedOut() }
            }
            timeout.resume()

            // Input may exceed the kernel pipe buffer while the child ignores
            // stdin. Deliver it off-thread and only after the timeout watchdog is
            // active so a blocked write cannot disable process termination.
            let stdinWriteCompletion: ProcessInputCompletion?
            if let standardInput, let stdinPipe {
                let inputData = Data(standardInput.utf8)
                let writeHandle = stdinPipe.fileHandleForWriting
                let completion = ProcessInputCompletion()
                stdinWriteCompletion = completion
                _ = fcntl(writeHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
                Thread.detachNewThread {
                    defer {
                        try? writeHandle.close()
                        completion.finish()
                    }
                    try? writeHandle.write(contentsOf: inputData)
                }
            } else {
                stdinWriteCompletion = nil
            }

            await processExit.wait()
            timeout.cancel()
            // The tool itself is done. A background process it started may
            // still hold these pipes open for hours; waiting for that would
            // ignore the timeout and keep an execution slot.
            drainDeadline.arm(after: Self.drainGraceSeconds)
            await stdinWriteCompletion?.wait()

            let stdoutCollected = await stdoutDrain.value
            let stderrCollected = await stderrDrain.value
            try Task.checkCancellation()
            let stdout = cappedString(
                from: stdoutCollected.inlineData,
                truncated: stdoutCollected.truncated
            )
            let stderr = cappedString(
                from: stderrCollected.data,
                truncated: stderrCollected.truncated
            )
            // A timeout's own stop is reported as the timeout.
            let terminationSignal: Int32? = process.terminationReason == .uncaughtSignal && !timeoutState.timedOut
                ? process.terminationStatus
                : nil
            var stderrText = stderr.value
            if let terminationSignal {
                if !stderrText.isEmpty, !stderrText.hasSuffix("\n") {
                    stderrText += "\n"
                }
                stderrText += "The tool was killed by a signal (\(String(cString: strsignal(terminationSignal))))."
            }

            return CommandRunResult(
                executablePath: executablePath,
                arguments: arguments,
                exitCode: process.terminationStatus,
                stdout: stdout.value,
                stderr: stderrText,
                duration: Date().timeIntervalSince(started),
                timedOut: timeoutState.timedOut,
                truncatedStdout: stdout.truncated,
                truncatedStderr: stderr.truncated,
                stdoutSpool: stdoutCollected.spool,
                stdoutBytesAreValidUTF8: stdoutCollected.bytesAreValidUTF8,
                stdoutPreservationError: stdoutCollected.preservationError?.localizedDescription,
                terminationSignal: terminationSignal
            )
        } onCancel: {
            terminationController.requestTermination()
        }
    }

    private struct CollectedStdout: Sendable {
        let inlineData: Data
        let truncated: Bool
        let spool: ProcessOutputSpool?
        let bytesAreValidUTF8: Bool
        let preservationError: ProcessRunnerError?
    }

    private static func isExecutableUnavailableLaunchError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError
                || nsError.code == NSFileReadNoPermissionError
                || nsError.code == NSExecutableNotLoadableError
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return nsError.code == Int(ENOENT)
                || nsError.code == Int(EACCES)
                || nsError.code == Int(ENOEXEC)
        }
        return false
    }

    /// Validates the complete retained byte stream without mistaking a scalar
    /// split across pipe chunks (or the inline preview boundary) for malformed
    /// UTF-8. The first-continuation bounds reject overlong encodings,
    /// surrogates, and values above U+10FFFF.
    private struct UTF8StreamValidator {
        private var isWellFormed = true
        private var continuationBytesRemaining = 0
        private var nextContinuationMinimum: UInt8 = 0x80
        private var nextContinuationMaximum: UInt8 = 0xbf

        mutating func consume(_ data: Data) {
            guard isWellFormed else { return }

            for byte in data {
                if continuationBytesRemaining > 0 {
                    guard byte >= nextContinuationMinimum,
                          byte <= nextContinuationMaximum else {
                        isWellFormed = false
                        return
                    }
                    continuationBytesRemaining -= 1
                    nextContinuationMinimum = 0x80
                    nextContinuationMaximum = 0xbf
                    continue
                }

                switch byte {
                case 0x00...0x7f:
                    continue
                case 0xc2...0xdf:
                    continuationBytesRemaining = 1
                case 0xe0:
                    continuationBytesRemaining = 2
                    nextContinuationMinimum = 0xa0
                case 0xe1...0xec, 0xee...0xef:
                    continuationBytesRemaining = 2
                case 0xed:
                    continuationBytesRemaining = 2
                    nextContinuationMaximum = 0x9f
                case 0xf0:
                    continuationBytesRemaining = 3
                    nextContinuationMinimum = 0x90
                case 0xf1...0xf3:
                    continuationBytesRemaining = 3
                case 0xf4:
                    continuationBytesRemaining = 3
                    nextContinuationMaximum = 0x8f
                default:
                    isWellFormed = false
                    return
                }
            }
        }

        var isValidAtEndOfStream: Bool {
            isWellFormed && continuationBytesRemaining == 0
        }
    }

    private static func collectStdout(
        from handle: FileHandle,
        limit: Int,
        spoolDirectory: URL,
        until deadline: DrainDeadline
    ) -> CollectedStdout {
        let hardLimit = max(0, limit)
        var inlineData = Data()
        var retainedByteCount = 0
        var truncated = false
        var spoolURL: URL?
        var spoolHandle: FileHandle?
        var spoolError: ProcessRunnerError?
        var utf8Validator = UTF8StreamValidator()

        var reader = PipeReader(handle, until: deadline)
        while let chunk = reader.next() {
            let remaining = hardLimit - retainedByteCount
            guard remaining > 0 else {
                truncated = true
                continue
            }

            let acceptedCount = min(chunk.count, remaining)
            let accepted = Data(chunk.prefix(acceptedCount))
            utf8Validator.consume(accepted)
            if acceptedCount < chunk.count {
                truncated = true
            }

            if retainedByteCount + acceptedCount > stdoutInlineByteLimit {
                if spoolHandle == nil, spoolError == nil {
                    do {
                        let created = try makeStdoutSpool(in: spoolDirectory)
                        spoolURL = created.url
                        spoolHandle = created.handle
                        try created.handle.write(contentsOf: inlineData)
                    } catch {
                        spoolError = .stdoutSpoolingFailed(error.localizedDescription)
                    }
                }

                if let spoolHandle, spoolError == nil {
                    do {
                        try spoolHandle.write(contentsOf: accepted)
                    } catch {
                        spoolError = .stdoutSpoolingFailed(error.localizedDescription)
                    }
                }

                let inlineRemaining = stdoutInlineByteLimit - inlineData.count
                if inlineRemaining > 0 {
                    inlineData.append(accepted.prefix(inlineRemaining))
                }
            } else {
                inlineData.append(accepted)
            }

            retainedByteCount += acceptedCount
        }

        if let spoolHandle {
            do {
                try spoolHandle.close()
            } catch where spoolError == nil {
                spoolError = .stdoutSpoolingFailed(error.localizedDescription)
            } catch {
                // Keep the first spooling failure; it is the useful root cause.
            }
        }

        let bytesAreValidUTF8 = utf8Validator.isValidAtEndOfStream
        if !bytesAreValidUTF8, spoolURL == nil, spoolError == nil, !inlineData.isEmpty {
            do {
                let created = try makeStdoutSpool(in: spoolDirectory)
                spoolURL = created.url
                do {
                    try created.handle.write(contentsOf: inlineData)
                    try created.handle.close()
                } catch {
                    try? created.handle.close()
                    throw error
                }
            } catch {
                spoolError = .stdoutSpoolingFailed(error.localizedDescription)
            }
        }

        if let spoolError {
            if let spoolURL {
                try? FileManager.default.removeItem(at: spoolURL)
            }
            return CollectedStdout(
                inlineData: inlineData,
                truncated: true,
                spool: nil,
                bytesAreValidUTF8: bytesAreValidUTF8,
                preservationError: spoolError
            )
        }

        let spool = spoolURL.map { ProcessOutputSpool(fileURL: $0, sizeBytes: retainedByteCount) }
        return CollectedStdout(
            inlineData: inlineData,
            truncated: truncated,
            spool: spool,
            bytesAreValidUTF8: bytesAreValidUTF8,
            preservationError: nil
        )
    }

    private static func makeStdoutSpool(in directory: URL) throws -> (url: URL, handle: FileHandle) {
        // The staging folder is created on first use, and the system may clear
        // the temporary directory while the app runs.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent("MacRemoteStdout-\(UUID().uuidString).tmp")
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        guard created else {
            throw ProcessRunnerError.stdoutSpoolingFailed("could not create temporary file")
        }

        do {
            return (url, try FileHandle(forWritingTo: url))
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Where every tool process starts: an empty folder nothing can be written
    /// to. A relative path an app supplies then names nothing, where the app's
    /// own starting folder is the root of the disk and "Users/…" would name
    /// any file on it. Returns nil if it cannot be created; the process then
    /// starts where the app did, as before.
    private static func emptyWorkingDirectory() -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteEmptyWorkingDirectory", isDirectory: true)
        // Creating is safe to repeat and to race, and the system may clear the
        // temporary folder while the app runs, so it is ensured on every call.
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }

    /// How long output is still collected after the tool's own process exits.
    static let drainGraceSeconds: TimeInterval = 1

    /// Reads a pipe until end of stream or until `deadline` passes. Plain
    /// poll(2) and read(2): they can be abandoned, and they report a failed
    /// read as a value where FileHandle raises an exception Swift cannot catch.
    private struct PipeReader {
        /// After the deadline, only what is already buffered is still read. A
        /// pipe holds 64 KiB; this bound stops a descendant that keeps writing.
        private static let maximumBytesAfterDeadline = 1024 * 1024

        let descriptor: Int32
        let deadline: DrainDeadline
        private var bytesAfterDeadline = 0
        private var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        init(_ handle: FileHandle, until deadline: DrainDeadline) {
            descriptor = handle.fileDescriptor
            self.deadline = deadline
        }

        mutating func next() -> Data? {
            while true {
                let expired = deadline.hasPassed
                if expired, bytesAfterDeadline >= Self.maximumBytesAfterDeadline {
                    return nil
                }
                var poller = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                let ready = poll(&poller, 1, expired ? 0 : 100)
                if ready > 0 {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count > 0 {
                        if expired {
                            bytesAfterDeadline += count
                        }
                        return Data(buffer[..<count])
                    }
                    if count == 0 || (errno != EINTR && errno != EAGAIN) {
                        return nil
                    }
                } else if expired || (ready < 0 && errno != EINTR) {
                    return nil
                }
            }
        }
    }

    private static func collectOutput(
        from handle: FileHandle,
        limit: Int,
        until deadline: DrainDeadline
    ) -> (data: Data, truncated: Bool) {
        var data = Data()
        var truncated = false
        var reader = PipeReader(handle, until: deadline)
        while let chunk = reader.next() {
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

    private func cappedString(from data: Data, truncated: Bool) -> (value: String, truncated: Bool) {
        (String(decoding: data, as: UTF8.self), truncated)
    }
}

extension ProcessRunner: ProcessRunning {}

/// Armed once the tool's own process has exited; the output readers stop
/// when it passes.
private final class DrainDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date?

    func arm(after seconds: TimeInterval) {
        lock.withLock { deadline = Date().addingTimeInterval(seconds) }
    }

    var hasPassed: Bool {
        lock.withLock { deadline.map { $0 <= Date() } ?? false }
    }
}

private final class TimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false

    var timedOut: Bool {
        lock.withLock { _timedOut }
    }

    func markTimedOut() {
        lock.withLock { _timedOut = true }
    }
}
