import Foundation

struct NativeToolExecutor: Sendable {
    private let pathPolicy: FileTransferPathPolicy
    private let artifactStore: ArtifactStore
    private let processRunner: any ProcessRunning
    private let spotlight: FileNameSearch.SpotlightLookup

    init(
        pathPolicy: FileTransferPathPolicy = FileTransferPathPolicy(),
        artifactStore: ArtifactStore = ArtifactStore(),
        processRunner: any ProcessRunning = ProcessRunner(),
        spotlight: @escaping FileNameSearch.SpotlightLookup = FileNameSearch.systemSpotlight
    ) {
        self.pathPolicy = pathPolicy
        self.artifactStore = artifactStore
        self.processRunner = processRunner
        self.spotlight = spotlight
    }

    func execute(
        tool: ToolDefinition,
        parameters: [String: ToolArgumentValue],
        timeoutSeconds: TimeInterval
    ) async throws -> ToolExecutionOutcome {
        let started = Date()
        guard !Task.isCancelled else { throw CancellationError() }
        guard timeoutSeconds > 0 else {
            return timedOutOutcome(tool: tool, started: started)
        }

        guard let nativeToolID = tool.nativeToolID else {
            return failureOutcome(
                tool: tool,
                started: started,
                code: "invalid_native_tool",
                message: "Tool is missing a native operation identifier.",
                stderr: "Native tool configuration is incomplete."
            )
        }

        // ConfiguredToolExecutor validates this too, but keep the native entry
        // point safe for direct callers and tests that bypass that wrapper.
        try ToolArgumentResolver.validateNativeArguments(
            for: tool,
            parameters: parameters
        )

        let deadline = started.addingTimeInterval(timeoutSeconds)
        let result: NativeOperationResult
        switch nativeToolID {
        case .fsStat:
            result = await offloaded(until: deadline) { fsStat(parameters: parameters) }
        case .fsListTree:
            result = await offloaded(until: deadline) { fsListTree(parameters: parameters) }
        case .fsFind:
            // A walk can run for many seconds, so it also stops when the
            // caller goes away.
            let cancelled = StopSignal()
            result = await withTaskCancellationHandler {
                await offloaded(until: deadline) {
                    fsFind(parameters: parameters, deadline: deadline, cancelled: cancelled)
                }
            } onCancel: {
                cancelled.raise()
            }
            try Task.checkCancellation()
        case .fsReadFile:
            result = await offloaded(until: deadline) { fsReadFile(parameters: parameters) }
        case .fsWriteFile:
            result = await offloaded(until: deadline) { fsWriteFile(parameters: parameters) }
        case .fsDownloadFile:
            result = try fsDownloadFile(parameters: parameters, deadline: deadline)
        case .fsDownloadZip:
            result = try await fsDownloadZip(parameters: parameters, deadline: deadline)
        }

        switch result {
        case .success(let payload):
            let stdout = try encodeJSON(payload)
            return ToolExecutionOutcome(
                toolID: tool.id,
                toolName: tool.name,
                exitCode: 0,
                stdout: stdout,
                stderr: "",
                duration: Date().timeIntervalSince(started),
                timedOut: false,
                truncatedStdout: false,
                truncatedStderr: false
            )
        case .failure(let failure):
            return failureOutcome(
                tool: tool,
                started: started,
                code: failure.code,
                message: failure.message,
                stderr: failure.stderr
            )
        case .timedOut:
            return timedOutOutcome(tool: tool, started: started)
        }
    }

    // MARK: - Operations

    /// Unchecked: a success holds a JSON dictionary built for this one call
    /// and never shared.
    private enum NativeOperationResult: @unchecked Sendable {
        case success([String: Any])
        case failure(NativeExecutionFailure)
        case timedOut
    }

    /// Runs a blocking file operation off Swift's shared threads, and stops
    /// waiting for it at the deadline. Without this, one call against a
    /// stalled network volume held a thread and a call slot until the volume's
    /// own timeout, and never reported "timed out".
    private func offloaded(
        until deadline: Date,
        _ operation: @escaping @Sendable () -> NativeOperationResult
    ) async -> NativeOperationResult {
        await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async { first.offer(operation()) }
            queue.asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0)) {
                first.offer(.timedOut)
            }
        }
    }

    /// Hands back the first result offered and ignores the rest: the
    /// operation's own result, or "timed out" from the deadline.
    private final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NativeOperationResult, Never>?

        init(_ continuation: CheckedContinuation<NativeOperationResult, Never>) {
            self.continuation = continuation
        }

        func offer(_ result: NativeOperationResult) {
            lock.lock()
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: result)
        }
    }

    /// Tells a long file operation on another thread to stop.
    private final class StopSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false

        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }

        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }
    }

    private func fsStat(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        switch resolve(rawPath) {
        case .success(let path): resolvedPath = path
        case .failure(let failure): return .failure(failure)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return .success([
                "exists": false
            ])
        }

        let type = entryType(at: resolvedPath, isDirectory: isDirectory.boolValue)
        var payload: [String: Any] = [
            "exists": true,
            "type": type,
            "is_readable": FileManager.default.isReadableFile(atPath: resolvedPath),
            "is_writable": FileManager.default.isWritableFile(atPath: resolvedPath)
        ]

        if let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedPath) {
            if let size = attributes[.size] as? NSNumber {
                payload["size_bytes"] = size.int64Value
            }
            if let modified = attributes[.modificationDate] as? Date {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                payload["modified_iso8601"] = formatter.string(from: modified)
            }
        }

        return .success(payload)
    }

    private func fsListTree(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        switch resolve(rawPath) {
        case .success(let path): resolvedPath = path
        case .failure(let failure): return .failure(failure)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.notADirectory)
        }

        let depth = min(max(integer(named: "depth", in: parameters, default: 2), 0), 5)
        let includeSizes = bool(named: "include_sizes", in: parameters, default: true)
        var entries = [[String: Any]]()
        var truncated = false
        let maxEntries = 2000

        func appendEntry(relativePath: String, at absolutePath: String, isDirectory: Bool) {
            guard entries.count < maxEntries else {
                truncated = true
                return
            }
            var entry: [String: Any] = [
                "relative_path": relativePath,
                "type": entryType(at: absolutePath, isDirectory: isDirectory)
            ]
            if includeSizes, !isDirectory {
                if let attributes = try? FileManager.default.attributesOfItem(atPath: absolutePath),
                   let size = attributes[.size] as? NSNumber {
                    entry["size_bytes"] = size.int64Value
                }
            }
            entries.append(entry)
        }

        func listDirectory(at absolutePath: String, relativePrefix: String, currentDepth: Int) {
            guard entries.count < maxEntries else {
                truncated = true
                return
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: absolutePath) else {
                return
            }

            for name in names.sorted() {
                guard entries.count < maxEntries else {
                    truncated = true
                    return
                }

                let childAbsolute = (absolutePath as NSString).appendingPathComponent(name)
                let childRelative = relativePrefix.isEmpty ? name : relativePrefix + "/" + name
                var childIsDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: childAbsolute, isDirectory: &childIsDirectory),
                      !pathPolicy.isProtected(path: childAbsolute) else {
                    continue
                }

                appendEntry(
                    relativePath: childRelative,
                    at: childAbsolute,
                    isDirectory: childIsDirectory.boolValue
                )

                if childIsDirectory.boolValue {
                    if !isSymbolicLink(at: childAbsolute), currentDepth + 1 < depth {
                        listDirectory(
                            at: childAbsolute,
                            relativePrefix: childRelative,
                            currentDepth: currentDepth + 1
                        )
                    }
                }
            }
        }

        listDirectory(at: resolvedPath, relativePrefix: "", currentDepth: 0)

        return .success([
            "path": resolvedPath,
            "entries": entries,
            "truncated": truncated
        ])
    }

    /// Finds files and folders by name. With `path` it walks that folder,
    /// which is exact. Without it, it asks Spotlight across everything File
    /// Transfer reaches, the only way to answer for a whole disk in one call.
    private func fsFind(
        parameters: [String: ToolArgumentValue],
        deadline: Date,
        cancelled: StopSignal
    ) -> NativeOperationResult {
        guard let name = requiredString(named: "name", in: parameters) else {
            return .failure(.missingParameter("name"))
        }
        let search = FileNameSearch(
            policy: pathPolicy,
            name: name,
            kind: FileNameSearch.Kind(rawValue: string(named: "type", in: parameters, default: "any")) ?? .any,
            limit: min(max(integer(named: "max_results", in: parameters, default: 100), 1), 1000)
        )

        let outcome: FileNameSearch.Outcome
        var payload: [String: Any]
        if let rawPath = requiredString(named: "path", in: parameters) {
            let root: String
            switch resolve(rawPath) {
            case .success(let path): root = path
            case .failure(let failure): return .failure(failure)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .failure(.notADirectory)
            }
            // Leave time to send the result before the call's own deadline.
            let walkDeadline = min(deadline.addingTimeInterval(-2), Date().addingTimeInterval(20))
            outcome = search.walk(root: root) { Date() >= walkDeadline || cancelled.isRaised }
            payload = ["method": "walk", "searched": root]
            if outcome.stoppedEarly == "time_limit" {
                payload["note"] = "Stopped at the time limit before the whole folder was searched. "
                    + "Search a smaller folder, or leave path out to search with Spotlight."
            }
        } else {
            outcome = search.spotlight(lookup: spotlight)
            payload = [
                "method": "spotlight",
                "searched": pathPolicy.allowedFoldersDescription,
                "note": "Spotlight only knows indexed files: hidden files and some system and developer "
                    + "folders are missing. Pass path to walk one folder exactly."
            ]
        }

        let formatter = ISO8601DateFormatter()
        payload["matches"] = outcome.matches.map { match -> [String: Any] in
            var entry: [String: Any] = [
                "path": match.path,
                "type": match.type,
                "modified_iso8601": formatter.string(from: match.modified)
            ]
            if let size = match.sizeBytes {
                entry["size_bytes"] = size
            }
            return entry
        }
        payload["truncated"] = outcome.stoppedEarly != nil
        if let reason = outcome.stoppedEarly {
            payload["truncated_reason"] = reason
        }
        return .success(payload)
    }

    private func fsReadFile(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        switch resolve(rawPath) {
        case .success(let path): resolvedPath = path
        case .failure(let failure): return .failure(failure)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .failure(.notAFile)
        }

        let offset = max(integer(named: "offset", in: parameters, default: 0), 0)
        let requestedLength = integer(
            named: "length",
            in: parameters,
            default: FileTransferToolCatalog.readFileChunkByteLimit
        )
        let asText = string(named: "encoding", in: parameters, default: "base64").lowercased() == "utf8"
        // A text read needs room for one whole character, which can be four
        // bytes long.
        let length = min(
            max(requestedLength, asText ? 4 : 1),
            FileTransferToolCatalog.readFileChunkByteLimit
        )

        let fileURL = URL(fileURLWithPath: resolvedPath)
        let fileSize: Int64
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: resolvedPath)
            fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            return .failure(.ioError("Could not read file attributes."))
        }

        if offset >= fileSize {
            return .success([
                "path": resolvedPath,
                "file_size_bytes": fileSize,
                "offset": offset,
                "length_returned": 0,
                asText ? "text" : "data_base64": "",
                "eof": true
            ])
        }

        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(offset))
            var data = try handle.read(upToCount: length) ?? Data()
            var text: String?
            if asText {
                guard let whole = Self.wholeUTF8Characters(in: data) else {
                    return .failure(.notText)
                }
                text = whole.text
                data = data.prefix(whole.byteCount)
            }
            let nextOffset = offset + data.count
            let eof = Self.readReachedEOF(
                bytesRead: data.count,
                nextOffset: nextOffset,
                preReadFileSize: fileSize
            )
            var payload: [String: Any] = [
                "path": resolvedPath,
                "file_size_bytes": fileSize,
                "offset": offset,
                "length_returned": data.count,
                "eof": eof
            ]
            if let text {
                payload["text"] = text
            } else {
                payload["data_base64"] = data.base64EncodedString()
            }
            return .success(payload)
        } catch {
            return .failure(.ioError("Could not read file: \(error.localizedDescription)"))
        }
    }

    /// The text of a chunk, without the bytes of a last character that the
    /// chunk boundary cut in half: the next read starts with that character.
    /// Nil when the bytes are not UTF-8 text.
    static func wholeUTF8Characters(in data: Data) -> (text: String, byteCount: Int)? {
        for cut in 0...min(3, data.count) {
            let prefix = data.prefix(data.count - cut)
            if let text = String(data: prefix, encoding: .utf8) {
                return (text, prefix.count)
            }
        }
        return nil
    }

    /// File size is sampled before opening the handle. A mutable file can
    /// shrink in between, so a zero-byte read is authoritative EOF even when
    /// the earlier size would otherwise leave the caller's chunk loop stuck.
    static func readReachedEOF(
        bytesRead: Int,
        nextOffset: Int,
        preReadFileSize: Int64
    ) -> Bool {
        bytesRead == 0 || nextOffset >= preReadFileSize
    }

    private func fsWriteFile(parameters: [String: ToolArgumentValue]) -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }
        guard let rawData = requiredString(named: "data", in: parameters) else {
            return .failure(.missingParameter("data"))
        }

        let resolvedPath: String
        switch resolve(rawPath) {
        case .success(let path): resolvedPath = path
        case .failure(let failure): return .failure(failure)
        }

        let encoding = string(named: "encoding", in: parameters, default: "base64").lowercased()
        let mode = string(named: "mode", in: parameters, default: "create").lowercased()

        let payload: Data
        switch encoding {
        case "base64":
            guard let decoded = Data(base64Encoded: rawData) else {
                return .failure(.invalidEncoding)
            }
            payload = decoded
        case "utf8":
            guard let decoded = rawData.data(using: .utf8) else {
                return .failure(.invalidEncoding)
            }
            payload = decoded
        default:
            return .failure(.invalidEncoding)
        }

        let fileURL = URL(fileURLWithPath: resolvedPath)
        let exists = FileManager.default.fileExists(atPath: resolvedPath)

        switch mode {
        case "create":
            if exists {
                return .failure(.alreadyExists)
            }
            do {
                try payload.write(to: fileURL, options: .atomic)
            } catch {
                return .failure(.ioError("Could not create file: \(error.localizedDescription)"))
            }
        case "overwrite":
            do {
                try payload.write(to: fileURL, options: .atomic)
            } catch {
                return .failure(.ioError("Could not overwrite file: \(error.localizedDescription)"))
            }
        case "append":
            if exists {
                do {
                    let handle = try FileHandle(forWritingTo: fileURL)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: payload)
                } catch {
                    return .failure(.ioError("Could not append to file: \(error.localizedDescription)"))
                }
            } else {
                do {
                    try payload.write(to: fileURL, options: .atomic)
                } catch {
                    return .failure(.ioError("Could not create file for append: \(error.localizedDescription)"))
                }
            }
        default:
            return .failure(.invalidMode)
        }

        return .success([
            "path": resolvedPath,
            "bytes_written": payload.count,
            "mode": mode
        ])
    }

    /// Makes one file downloadable. The artifact store keeps the only staged
    /// copy, and enforces the size limits before it copies anything.
    private func fsDownloadFile(
        parameters: [String: ToolArgumentValue],
        deadline: Date
    ) throws -> NativeOperationResult {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }

        let resolvedPath: String
        switch resolve(rawPath) {
        case .success(let path): resolvedPath = path
        case .failure(let failure): return .failure(failure)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return .failure(.notAFile)
        }

        guard !Task.isCancelled else { throw CancellationError() }
        guard deadline.timeIntervalSinceNow > 0 else {
            return .timedOut
        }

        let sourceURL = URL(fileURLWithPath: resolvedPath)
        do {
            let handle = try artifactStore.register(
                fileURL: sourceURL,
                suggestedFilename: sourceURL.lastPathComponent
            )
            return .success(artifactPayload(for: handle))
        } catch {
            return .failure(stagingFailure(error))
        }
    }

    /// Makes a zip downloadable: of one file or folder (`path`), or of chosen
    /// entries under a folder (`base` plus `paths`). Either way the files are
    /// read where they are; see `zipAndRegister`.
    private func fsDownloadZip(
        parameters: [String: ToolArgumentValue],
        deadline: Date
    ) async throws -> NativeOperationResult {
        if let rawPath = requiredString(named: "path", in: parameters) {
            let resolvedPath: String
            switch resolve(rawPath) {
            case .success(let path): resolvedPath = path
            case .failure(let failure): return .failure(failure)
            }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
                return .failure(.ioError("Path does not exist."))
            }

            // A folder is archived by its contents, a file under its own name.
            let path = resolvedPath as NSString
            return try await zipAndRegister(
                directory: isDirectory.boolValue ? resolvedPath : path.deletingLastPathComponent,
                members: [isDirectory.boolValue ? "." : "./" + path.lastPathComponent],
                sources: [resolvedPath],
                suggestedZipName: zipFilename(for: resolvedPath),
                deadline: deadline
            )
        }

        guard let rawBase = requiredString(named: "base", in: parameters) else {
            return .failure(.missingParameter("path"))
        }
        guard let relativePaths = parameters["paths"]?.stringArrayValue, !relativePaths.isEmpty else {
            return .failure(.missingParameter("paths"))
        }

        let resolvedBase: String
        switch resolve(rawBase) {
        case .success(let path): resolvedBase = path
        case .failure(let failure): return .failure(failure)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolvedBase, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return .failure(.notADirectory)
        }

        var members = [String]()
        var sources = [String]()
        for relativePath in relativePaths {
            let entry: (member: String, absolutePath: String)
            do {
                entry = try resolveRelativePath(relativePath, under: resolvedBase)
            } catch FileTransferPathPolicy.PathError.pathDenied {
                return .failure(pathDenied)
            } catch {
                return .failure(.invalidPath)
            }

            guard FileManager.default.fileExists(atPath: entry.absolutePath) else {
                return .failure(.ioError("Path does not exist: \(relativePath)"))
            }
            members.append("./" + entry.member)
            sources.append(entry.absolutePath)
        }

        return try await zipAndRegister(
            directory: resolvedBase,
            members: members,
            sources: sources,
            suggestedZipName: zipFilename(for: resolvedBase),
            deadline: deadline
        )
    }

    /// Zips `members` of `directory` and makes the archive downloadable.
    ///
    /// Nothing is copied first. `tar` reads the files where they are and
    /// writes only the archive, into room the artifact store set aside. Before
    /// that, the sizes of `sources` (the same files, as real paths) are added
    /// up, so a request over the limit costs a folder walk and no disk space.
    /// This tool runs without asking, which is why it must not be able to fill
    /// the disk.
    private func zipAndRegister(
        directory: String,
        members: [String],
        sources: [String],
        suggestedZipName: String,
        deadline: Date
    ) async throws -> NativeOperationResult {
        guard !sources.contains(where: pathPolicy.containsProtectedFolder) else {
            return .failure(.containsProtectedFolder)
        }

        let limit = ArtifactStore.defaultMaxSizeBytes
        guard let sourceBytes = try totalSize(of: sources, limit: limit, deadline: deadline) else {
            return .timedOut
        }
        guard sourceBytes <= limit else {
            return .failure(NativeExecutionFailure(
                code: "artifact_too_large",
                message: "The selected files total more than 512 MiB before compression. Zip fewer files.",
                stderr: "Files to archive exceed 512 MiB."
            ))
        }

        let reservation: ArtifactStore.Reservation
        do {
            reservation = try artifactStore.reserve(
                suggestedFilename: suggestedZipName,
                expectedBytes: sourceBytes
            )
        } catch {
            return .failure(stagingFailure(error))
        }
        var registered = false
        defer {
            if !registered {
                artifactStore.discard(reservation)
            }
        }

        do {
            let remainingTimeout = deadline.timeIntervalSinceNow
            guard !Task.isCancelled else { throw CancellationError() }
            guard remainingTimeout > 0 else {
                return .timedOut
            }
            let result = try await processRunner.run(
                executablePath: "/usr/bin/tar",
                arguments: Self.zipArguments(
                    archivePath: reservation.fileURL.path,
                    directory: directory,
                    members: members
                ),
                timeoutSeconds: remainingTimeout,
                outputByteLimit: 64 * 1024,
                environment: ExecutableLocator.toolEnvironment,
                standardInput: nil
            )
            guard !Task.isCancelled else { throw CancellationError() }
            guard !result.timedOut else {
                return .timedOut
            }
            guard result.exitCode == 0 else {
                let detail = result.stderr.isEmpty ? "tar failed." : result.stderr
                return .failure(.ioError("Could not create zip archive: \(detail)"))
            }
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            return .failure(.ioError("Could not create zip archive: \(error.localizedDescription)"))
        }

        do {
            let handle = try artifactStore.commit(reservation)
            registered = true
            return .success(artifactPayload(for: handle))
        } catch {
            return .failure(stagingFailure(error))
        }
    }

    /// The `tar` arguments that write a zip of `members`, read in place from
    /// `directory`. An argv array, never a shell.
    ///
    /// Each member starts with "./" (or is "." for the folder itself). `tar`
    /// reads a member that starts with "-C" as "change folder" and one that
    /// starts with "@" as "add this archive's contents", even after "--", and
    /// a caller chooses these names. The two `-s` rules take the prefix off
    /// again, so the zip names entries the way the caller wrote them. Their
    /// "S" keeps the rules away from where symbolic links point.
    static func zipArguments(archivePath: String, directory: String, members: [String]) -> [String] {
        [
            "--format", "zip",
            // Without this, tar adds "._" entries that it first builds in the
            // temporary directory.
            "--no-mac-metadata",
            // A member that is a symbolic link was resolved and checked, so
            // archive what it points to. Links found inside a folder stay links.
            "-H",
            "-s", ",^\\./,,S",
            "-s", ",^\\.$,,S",
            "-c", "-f", archivePath,
            "-C", directory,
            "--"
        ] + members
    }

    /// The total size of the files at and under `paths`, or nil when the
    /// deadline passes first. Stops as soon as the total is over `limit`; the
    /// caller only needs to know that it is.
    private func totalSize(of paths: [String], limit: Int64, deadline: Date) throws -> Int64? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        var total: Int64 = 0
        var visited = 0

        for path in paths {
            let root = URL(fileURLWithPath: path)
            // Like tar, the walk does not follow symbolic links, and it goes
            // into hidden folders and packages. A file has no children.
            let children = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in true }
            )
            var next: URL? = root
            while let url = next {
                visited += 1
                if visited.isMultiple(of: 256) {
                    guard !Task.isCancelled else { throw CancellationError() }
                    guard deadline.timeIntervalSinceNow > 0 else { return nil }
                }
                if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
                    total += Int64(values.fileSize ?? 0)
                    guard total <= limit else { return total }
                }
                next = children?.nextObject() as? URL
            }
        }
        return total
    }

    /// Turns an artifact store refusal into the failure the calling app sees.
    private func stagingFailure(_ error: Error) -> NativeExecutionFailure {
        switch error as? ArtifactStoreError {
        case .artifactTooLarge:
            return .artifactTooLarge
        case .stagingFull:
            return NativeExecutionFailure(
                code: "download_space_full",
                message: error.localizedDescription,
                stderr: "Staged downloads are at their total size limit."
            )
        default:
            return .ioError("Could not prepare the download: \(error.localizedDescription)")
        }
    }

    /// Checks the path arguments of a call without touching the files, so a
    /// path that will be refused is reported before the owner is asked to
    /// approve the call.
    func validatePaths(in parameters: [String: ToolArgumentValue]) throws {
        for name in ["path", "base"] {
            guard let rawPath = requiredString(named: name, in: parameters) else { continue }
            if case .failure(let failure) = resolve(rawPath) {
                throw ToolValidationError.constraintViolation(failure.message)
            }
        }
    }

    private func resolve(_ rawPath: String) -> Result<String, NativeExecutionFailure> {
        do {
            return .success(try pathPolicy.resolveUserPath(rawPath))
        } catch FileTransferPathPolicy.PathError.pathDenied {
            return .failure(pathDenied)
        } catch {
            return .failure(.invalidPath)
        }
    }

    /// Names the reachable folders, so the calling model can correct itself
    /// instead of probing.
    private var pathDenied: NativeExecutionFailure {
        if pathPolicy.reachesWholeMac {
            return NativeExecutionFailure(
                code: "path_denied",
                message: "MacRemote never shares this location. Keys, keychains, saved credentials, "
                    + "and MacRemote's own data stay out of reach.",
                stderr: "Path is a protected location."
            )
        }
        return NativeExecutionFailure(
            code: "path_denied",
            message: "File Transfer reaches only the folders the owner allowed: \(pathPolicy.allowedFoldersDescription). "
                + "Protected locations such as keys and keychains are never reachable. "
                + "The owner can add folders, or allow the whole Mac, in MacRemote Settings.",
            stderr: "Path is outside the folders allowed for File Transfer."
        )
    }

    private func artifactPayload(for handle: ArtifactHandle) -> [String: Any] {
        [
            "artifact_token": handle.token,
            "artifact_path": handle.artifactPath,
            "filename": handle.filename,
            "size_bytes": handle.sizeBytes,
            "sha256": handle.sha256,
            "expires_in_seconds": handle.expiresInSeconds,
            "downloads_allowed": handle.downloadsAllowed
        ]
    }

    private func zipFilename(for path: String) -> String {
        // The root folder has no name of its own.
        let name = (path as NSString).lastPathComponent
        let baseName = name.isEmpty || name == "/" ? "archive" : name
        return baseName.hasSuffix(".zip") ? baseName : "\(baseName).zip"
    }

    /// Checks one entry of the multi-path form. Returns it cleaned up, as the
    /// archive will name it, and as the real path the policy allowed.
    ///
    /// The entry must stay under `base`: it may not be absolute or contain
    /// "..". Where it really leads, through any symbolic link, is for the
    /// policy to judge.
    private func resolveRelativePath(
        _ relativePath: String,
        under base: String
    ) throws -> (member: String, absolutePath: String) {
        let components = relativePath.split(separator: "/").filter { $0 != "." }
        guard !relativePath.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            throw FileTransferPathPolicy.PathError.invalidPath
        }

        let member = components.joined(separator: "/")
        let absolutePath = try pathPolicy.resolveUserPath((base as NSString).appendingPathComponent(member))
        return (member, absolutePath)
    }

    // MARK: - Helpers

    private struct NativeExecutionFailure: Error, Sendable {
        let code: String
        let message: String
        let stderr: String

        static let notText = Self(
            code: "not_text",
            message: "File is not UTF-8 text. Read it with encoding base64.",
            stderr: "File is not UTF-8 text."
        )

        static let invalidPath = Self(
            code: "invalid_path",
            message: "Path must be absolute after expanding a leading tilde, without \"..\" components.",
            stderr: "Rejected relative path."
        )
        static let containsProtectedFolder = Self(
            code: "path_denied",
            message: "This folder contains folders MacRemote never shares. Archive a subfolder instead.",
            stderr: "Folder contains a protected folder."
        )
        static let notADirectory = Self(
            code: "not_a_directory",
            message: "Path is not a directory.",
            stderr: "Expected a directory."
        )
        static let notAFile = Self(
            code: "not_a_file",
            message: "Path is not a regular file.",
            stderr: "Expected a file."
        )
        static let alreadyExists = Self(
            code: "already_exists",
            message: "File already exists.",
            stderr: "Create mode refuses to overwrite an existing file."
        )
        static let invalidEncoding = Self(
            code: "invalid_encoding",
            message: "Data encoding is invalid.",
            stderr: "Use encoding base64 or utf8."
        )
        static let invalidMode = Self(
            code: "invalid_mode",
            message: "Write mode is invalid.",
            stderr: "Use mode create, overwrite, or append."
        )

        static func missingParameter(_ name: String) -> Self {
            Self(
                code: "missing_parameter",
                message: "Missing required parameter: \(name).",
                stderr: "Missing parameter \(name)."
            )
        }

        static func ioError(_ message: String) -> Self {
            Self(code: "io_error", message: message, stderr: message)
        }

        static let artifactTooLarge = Self(
            code: "artifact_too_large",
            message: "Artifact exceeds the maximum allowed size.",
            stderr: "Artifact exceeds 512 MiB."
        )
    }

    private func entryType(at path: String, isDirectory: Bool) -> String {
        if isSymbolicLink(at: path) {
            return "symlink"
        }
        if isDirectory {
            return "directory"
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return "directory"
        }
        if FileManager.default.isReadableFile(atPath: path) || FileManager.default.isWritableFile(atPath: path) {
            return "file"
        }
        return "other"
    }

    private func isSymbolicLink(at path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func requiredString(named name: String, in parameters: [String: ToolArgumentValue]) -> String? {
        guard let value = parameters[name]?.stringValue, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func string(named name: String, in parameters: [String: ToolArgumentValue], default defaultValue: String) -> String {
        parameters[name]?.stringValue ?? defaultValue
    }

    private func integer(named name: String, in parameters: [String: ToolArgumentValue], default defaultValue: Int) -> Int {
        if let value = parameters[name] {
            switch value {
            case .string(let string):
                return Int(string) ?? defaultValue
            case .json(.number(let number)):
                if let integer = Int(exactly: number) {
                    return integer
                }
            default:
                break
            }
        }
        return defaultValue
    }

    private func bool(named name: String, in parameters: [String: ToolArgumentValue], default defaultValue: Bool) -> Bool {
        if let value = parameters[name] {
            switch value {
            case .string(let string):
                switch string.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: break
                }
            case .json(.bool(let bool)):
                return bool
            case .json(.number(let number)):
                return number != 0
            default:
                break
            }
        }
        return defaultValue
    }

    private func encodeJSON(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.checkedData(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard let string = String(data: data, encoding: .utf8) else {
            throw ToolValidationError.invalidNativeTool("could not encode JSON result")
        }
        return string
    }

    private func failureOutcome(
        tool: ToolDefinition,
        started: Date,
        code: String,
        message: String,
        stderr: String
    ) -> ToolExecutionOutcome {
        let stdout: String
        if let data = try? JSONSerialization.checkedData(
            withJSONObject: ["error": message, "code": code],
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let string = String(data: data, encoding: .utf8) {
            stdout = string
        } else {
            stdout = "{\"error\":\"\(message)\",\"code\":\"\(code)\"}"
        }

        return ToolExecutionOutcome(
            toolID: tool.id,
            toolName: tool.name,
            exitCode: 1,
            stdout: stdout,
            stderr: stderr,
            duration: Date().timeIntervalSince(started),
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }

    private func timedOutOutcome(tool: ToolDefinition, started: Date) -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolID: tool.id,
            toolName: tool.name,
            exitCode: 1,
            stdout: "{\"error\":\"Timed out.\",\"code\":\"timeout\"}",
            stderr: "Native tool exceeded the configured timeout.",
            duration: Date().timeIntervalSince(started),
            timedOut: true,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}
