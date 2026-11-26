import Foundation

struct NativeToolExecutor: Sendable {
    private let pathPolicy: FileTransferPathPolicy
    private let artifactStore: ArtifactStore
    private let processRunner: any ProcessRunning
    private let spotlight: FileNameSearch.SpotlightLookup
    /// Runs after an edit has read its file and before it saves, with the
    /// file's path. Tests use it to change the file system at exactly that
    /// moment; the app passes nothing.
    private let editWillSave: @Sendable (String) -> Void
    /// Runs after a save has written its hidden copy and just before it
    /// checks that nothing changed and renames the copy into place, with the
    /// copy's path. Tests only, like `editWillSave`.
    private let saveWillRename: @Sendable (String) -> Void

    init(
        pathPolicy: FileTransferPathPolicy = FileTransferPathPolicy(),
        artifactStore: ArtifactStore = ArtifactStore(),
        processRunner: any ProcessRunning = ProcessRunner(),
        spotlight: @escaping FileNameSearch.SpotlightLookup = FileNameSearch.systemSpotlight,
        editWillSave: @escaping @Sendable (String) -> Void = { _ in },
        saveWillRename: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.pathPolicy = pathPolicy
        self.artifactStore = artifactStore
        self.processRunner = processRunner
        self.spotlight = spotlight
        self.editWillSave = editWillSave
        self.saveWillRename = saveWillRename
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
            result = await offloaded(until: deadline) { _ in fsStat(parameters: parameters) }
        case .fsListTree:
            result = await offloaded(until: deadline) { _ in fsListTree(parameters: parameters) }
        case .fsFind:
            // A walk can run for many seconds, so it also stops when the
            // caller goes away.
            let cancelled = StopSignal()
            result = await withTaskCancellationHandler {
                await offloaded(until: deadline) { _ in
                    fsFind(parameters: parameters, deadline: deadline, cancelled: cancelled)
                }
            } onCancel: {
                cancelled.raise()
            }
            try Task.checkCancellation()
        case .fsReadFile:
            result = await offloaded(until: deadline) { _ in fsReadFile(parameters: parameters) }
        case .fsWriteFile:
            result = await offloaded(until: deadline) { _ in fsWriteFile(parameters: parameters) }
        case .fsAppendFile, .fsReplaceInFile:
            result = await offloaded(until: deadline) { gate in
                fsEditFile(nativeToolID, parameters: parameters, commit: gate.commit)
            }
        case .fsUploadFile:
            let bytes = FileUploadStore.confirmedBytes
            result = await offloaded(until: deadline) { gate in
                fsUploadFile(parameters: parameters, bytes: bytes, commit: gate.commit)
            }
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
    ///
    /// The operation keeps running after "timed out" is reported, so one
    /// that changes a file asks `commit()` on the gate it is handed just
    /// before its one step that cannot be undone, and stops when told no.
    private func offloaded(
        until deadline: Date,
        _ operation: @escaping @Sendable (FirstResult) -> NativeOperationResult
    ) async -> NativeOperationResult {
        await withCheckedContinuation { continuation in
            let first = FirstResult(continuation)
            let queue = DispatchQueue.global(qos: .userInitiated)
            queue.async { first.offer(operation(first)) }
            queue.asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0)) {
                first.expire()
            }
        }
    }

    /// Hands back the first result offered and ignores the rest: the
    /// operation's own result, or "timed out" from the deadline. Once the
    /// operation has committed, the deadline reports nothing and the call
    /// waits for the operation's own result, so a call that reported "timed
    /// out" never changed anything.
    private final class FirstResult: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<NativeOperationResult, Never>?
        private var committed = false

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

        /// Reports "timed out", unless the operation already committed.
        func expire() {
            lock.lock()
            let waiting = committed ? nil : continuation
            if waiting != nil { continuation = nil }
            lock.unlock()
            waiting?.resume(returning: .timedOut)
        }

        /// True when the operation may make its change: nothing has been
        /// reported yet, and from now on the deadline reports nothing.
        func commit() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard continuation != nil else { return false }
            committed = true
            return true
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

    /// An Append to File or Replace in File call worked out against the file
    /// as it was read: the file held open, its complete new contents, and the
    /// result to report once they are saved.
    private struct PlannedEdit {
        let target: SaveTarget
        let contents: Data
        let result: [String: Any]
    }

    /// Where a save puts a file: the folder, held open, and the file already
    /// there, held open too, if there is one. Every step after the open names
    /// the file relative to the folder held here, never by its path again, so
    /// a folder in the path swapped for a link, or a file put in the target's
    /// place, cannot send the save anywhere else.
    private final class SaveTarget {
        /// The real path the path policy approved.
        let path: String
        let folder: Int32
        let folderIdentity: FileIdentity
        /// The file at `path` and how it was just before it was read, so the
        /// save can tell whether anything changed it since. Nil when nothing
        /// was there: an upload that creates the file.
        let original: (file: Int32, info: stat)?

        var name: String { (path as NSString).lastPathComponent }
        var folderPath: String { (path as NSString).deletingLastPathComponent }

        init(path: String, folder: Int32, folderIdentity: FileIdentity, original: (file: Int32, info: stat)?) {
            self.path = path
            self.folder = folder
            self.folderIdentity = folderIdentity
            self.original = original
        }

        deinit {
            if let original { close(original.file) }
            close(folder)
        }
    }

    /// Which file or folder something is on disk, whatever path names it:
    /// the same measure `FileTransferPathPolicy` uses.
    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t

        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// Lets one edit at a time work in each folder, so two edits of one file
    /// can never both read it and then save over each other. The key is the
    /// folder's file identity. The file's own identity would not do: every
    /// save puts a new file in its place. A file with a single hard link,
    /// the only kind an edit accepts, is in exactly one folder, whatever
    /// path names it.
    private static let editLocks = FolderLocks()

    private final class FolderLocks: @unchecked Sendable {
        private let condition = NSCondition()
        private var busy: Set<FileIdentity> = []

        func withLock<T>(on folder: FileIdentity, _ body: () -> T) -> T {
            condition.lock()
            while busy.contains(folder) {
                condition.wait()
            }
            busy.insert(folder)
            condition.unlock()
            defer {
                condition.lock()
                busy.remove(folder)
                condition.broadcast()
                condition.unlock()
            }
            return body()
        }
    }

    /// Runs an Append to File or Replace in File call. The checks run again
    /// here, after approval, because the file can change while the owner
    /// decides. They run inside the folder's edit lock, so an edit reads
    /// what any edit before it saved. `commit` is the timeout gate from
    /// `offloaded`: an edit that waited for the lock past its deadline has
    /// already reported "timed out", and saves nothing.
    private func fsEditFile(
        _ nativeToolID: NativeToolIdentifier,
        parameters: [String: ToolArgumentValue],
        commit: () -> Bool
    ) -> NativeOperationResult {
        let path: String
        switch editPath(in: parameters) {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        var folder = stat()
        guard stat((path as NSString).deletingLastPathComponent, &folder) == 0 else {
            return .failure(.fileNotFound)
        }
        let lockedFolder = FileIdentity(folder)
        return Self.editLocks.withLock(on: lockedFolder) {
            let edit: PlannedEdit
            switch planEdit(nativeToolID, at: path, parameters: parameters) {
            case .success(let planned): edit = planned
            case .failure(let failure): return .failure(failure)
            }
            // The lock covers the folder held only if the path still led to
            // the same folder when it was opened.
            guard edit.target.folderIdentity == lockedFolder else {
                return .failure(.fileChanged)
            }
            editWillSave(path)
            let failure = save(edit.target, commit: commit) { temporary in
                try FileHandle(fileDescriptor: temporary, closeOnDealloc: false).write(contentsOf: edit.contents)
            }
            if let failure {
                return .failure(failure)
            }
            return .success(edit.result)
        }
    }

    /// Saves an upload's confirmed bytes, or an empty file, at `path`
    /// (SPEC D83). Everything is checked again here, at the moment of the
    /// save: the path policy, whether a file is there and may be replaced,
    /// and the folder. The bytes are copied into a hidden file and renamed
    /// into place by the same save the edit tools use.
    private func fsUploadFile(
        parameters: [String: ToolArgumentValue],
        bytes: ConfirmedUploadBytes?,
        commit: () -> Bool
    ) -> NativeOperationResult {
        let target: SaveTarget
        let file: UploadedFileInput
        switch uploadTarget(parameters) {
        case .success(let opened): (target, file) = opened
        case .failure(let failure): return .failure(failure)
        }
        guard file.size == 0 || bytes?.size == file.size else {
            return .failure(.ioError("The file's bytes have not arrived. Nothing changed."))
        }
        // Only where the owner approved: a folder or link in the path that
        // changed since the first call leads elsewhere.
        if let bytes, target.path != bytes.destination {
            return .failure(.ioError(
                "The destination changed since the owner approved this upload, so nothing was written. Start the upload again."
            ))
        }
        let failure = save(target, commit: commit) { temporary in
            guard let bytes, file.size > 0 else { return }
            let output = FileHandle(fileDescriptor: temporary, closeOnDealloc: false)
            try bytes.handle.seek(toOffset: 0)
            var copied: Int64 = 0
            while let chunk = try bytes.handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
                copied += Int64(chunk.count)
            }
            guard copied == file.size else { throw CocoaError(.fileReadCorruptFile) }
        }
        if let failure {
            return .failure(failure)
        }
        return .success([
            "path": target.path,
            "size_bytes": file.size,
            "overwritten": target.original != nil
        ])
    }

    /// The held target an upload saves to, and its file, or why it cannot:
    /// a path the policy refuses, a folder that does not exist, a file there
    /// without `overwrite`, or anything `openTarget` refuses.
    private func uploadTarget(
        _ parameters: [String: ToolArgumentValue]
    ) -> Result<(SaveTarget, UploadedFileInput), NativeExecutionFailure> {
        let file: UploadedFileInput
        do {
            file = try UploadedFileInput(parameters["file"]?.jsonValue)
        } catch {
            return .failure(.invalidFile((error as? ToolValidationError)?.callToolMessage(tool: nil, arguments: [:]) ?? "\(error)"))
        }
        let path: String
        switch editPath(in: parameters) {
        case .success(let resolved): path = resolved
        case .failure(let failure): return .failure(failure)
        }
        let target: SaveTarget
        switch openTarget(at: path) {
        case .success(let opened): target = opened
        case .failure(let failure):
            return .failure(failure.code == "not_found" ? .folderNotFound : failure)
        }
        if target.original != nil, !bool(named: "overwrite", in: parameters, default: false) {
            return .failure(.alreadyExists)
        }
        return .success((target, file))
    }

    /// The real path an edit names, as the path policy resolves it.
    private func editPath(in parameters: [String: ToolArgumentValue]) -> Result<String, NativeExecutionFailure> {
        guard let rawPath = requiredString(named: "path", in: parameters) else {
            return .failure(.missingParameter("path"))
        }
        return resolve(rawPath)
    }

    /// Works out an edit without changing anything, against the file at
    /// `path`, the real path the policy approved. The edit works on bytes,
    /// so line endings and a missing final newline outside the change stay
    /// as they are.
    private func planEdit(
        _ nativeToolID: NativeToolIdentifier,
        at path: String,
        parameters: [String: ToolArgumentValue]
    ) -> Result<PlannedEdit, NativeExecutionFailure> {
        let target: SaveTarget
        let original: Data
        switch openEdit(at: path) {
        case .success(let opened):
            target = opened.target
            original = opened.contents
        case .failure(let failure):
            return .failure(failure)
        }

        switch nativeToolID {
        case .fsAppendFile:
            guard let text = requiredString(named: "text", in: parameters) else {
                return .failure(.missingParameter("text"))
            }
            let added = Data(text.utf8)
            let contents = original + added
            return .success(PlannedEdit(target: target, contents: contents, result: [
                "path": path,
                "bytes_appended": added.count,
                "size_bytes": contents.count
            ]))
        case .fsReplaceInFile:
            guard let find = requiredString(named: "find", in: parameters) else {
                return .failure(.missingParameter("find"))
            }
            // Present, not necessarily non-empty: an empty replacement
            // deletes the passage.
            guard let replacement = parameters["replace"]?.stringValue else {
                return .failure(.missingParameter("replace"))
            }
            let found = Self.occurrences(of: Data(find.utf8), in: original)
            guard found.count == 1, let range = found.first else {
                return .failure(.matchCount(found.count))
            }
            var contents = original
            contents.replaceSubrange(range, with: Data(replacement.utf8))
            return .success(PlannedEdit(target: target, contents: contents, result: [
                "path": path,
                "replacements": 1,
                "size_bytes": contents.count
            ]))
        default:
            return .failure(NativeExecutionFailure(
                code: "invalid_native_tool",
                message: "This tool does not edit files.",
                stderr: "Not an edit tool."
            ))
        }
    }

    /// Opens the folder `path` is in and the file at `path`, if there is one,
    /// and holds both. `path` is a real path, so no part of it is a link: the
    /// folder is opened refusing a link anywhere in the path, the file
    /// refusing a link in its place, and both are then checked to be what
    /// the policy approves at `path` now.
    ///
    /// Refuses anything but a regular file, a file with more than one hard
    /// link, and a file or folder this app could not save (see
    /// `saveRestriction`). A missing file is not refused: the target then
    /// holds the folder alone.
    private func openTarget(at path: String) -> Result<SaveTarget, NativeExecutionFailure> {
        let folder = open((path as NSString).deletingLastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard folder >= 0 else {
            return .failure(Self.openFailure(errno))
        }
        var folderInfo = stat()
        guard fstat(folder, &folderInfo) == 0 else {
            let error = errno
            close(folder)
            return .failure(Self.openFailure(error))
        }
        // O_NONBLOCK: opening a pipe for reading would otherwise wait for a
        // writer. It changes nothing for a regular file.
        let file = openat(folder, (path as NSString).lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        var info = stat()
        var original: (file: Int32, info: stat)?
        if file >= 0, fstat(file, &info) == 0 {
            original = (file, info)
        } else {
            let error = errno
            if file >= 0 { close(file) }
            guard error == ENOENT else {
                close(folder)
                // A link in the file's place is not a regular file.
                return .failure(error == ELOOP ? .notAFile : Self.openFailure(error))
            }
        }
        let target = SaveTarget(path: path, folder: folder, folderIdentity: FileIdentity(folderInfo), original: original)
        // First, before anything about it is looked at or reported.
        guard pathStillLeads(to: target) else {
            return .failure(.fileChanged)
        }
        if let original {
            // A folder, a pipe, or a device is not a file to save over.
            guard original.info.st_mode & S_IFMT == S_IFREG else {
                return .failure(.notAFile)
            }
            // A save puts a new file in this one's place, which would split
            // it from its other names.
            guard original.info.st_nlink == 1 else {
                return .failure(.hardLinked(Int(original.info.st_nlink)))
            }
        }
        if let restriction = saveRestriction(of: target) {
            return .failure(restriction)
        }
        return .success(target)
    }

    /// Opens and reads the file an edit names, held as `openTarget` holds
    /// it. Refuses everything `openTarget` refuses, a missing file, a file
    /// over `editFileByteLimit`, and bytes that are not UTF-8 text.
    private func openEdit(at path: String) -> Result<(target: SaveTarget, contents: Data), NativeExecutionFailure> {
        let target: SaveTarget
        switch openTarget(at: path) {
        case .success(let opened): target = opened
        case .failure(let failure): return .failure(failure)
        }
        guard let original = target.original else {
            return .failure(.fileNotFound)
        }

        let limit = FileTransferToolCatalog.editFileByteLimit
        let data: Data
        do {
            // One byte past the limit tells a file that is too large apart
            // from one that is exactly at it.
            data = try FileHandle(fileDescriptor: original.file, closeOnDealloc: false).read(upToCount: limit + 1) ?? Data()
        } catch {
            return .failure(.ioError("Could not read file: \(error.localizedDescription)"))
        }
        guard data.count <= limit else {
            return .failure(.fileTooLarge)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            return .failure(.notEditableText)
        }
        return .success((target, data))
    }

    /// The failure for a file or folder an edit could not open.
    private static func openFailure(_ error: Int32) -> NativeExecutionFailure {
        switch error {
        case ENOENT:
            return .fileNotFound
        case ELOOP, ENOTDIR:
            // A folder in the path became a link or a file.
            return .fileChanged
        default:
            return .ioError("Could not open file: \(String(cString: strerror(error))).")
        }
    }

    /// True when `target.path` still leads to the folder and file the save
    /// holds open: the path policy still approves the path, unchanged, and
    /// the folder and file found there are the ones held, by file identity.
    /// For a target that held no file, nothing may have taken its name.
    private func pathStillLeads(to target: SaveTarget) -> Bool {
        guard (try? pathPolicy.resolveUserPath(target.path)) == target.path else {
            return false
        }
        var folderThere = stat()
        guard stat(target.folderPath, &folderThere) == 0,
              FileIdentity(folderThere) == target.folderIdentity else {
            return false
        }
        var fileThere = stat()
        let found = fstatat(target.folder, target.name, &fileThere, AT_SYMLINK_NOFOLLOW) == 0
        guard let original = target.original else {
            return !found && errno == ENOENT
        }
        return found && FileIdentity(fileThere) == FileIdentity(original.info)
    }

    /// Why this app could not save the held file, or nil when it can. Saving
    /// writes a new file into the folder and renames it over the file, so
    /// both must be writable; the same check catches a locked file and a
    /// read-only volume. A read-only file is refused too, although the rename
    /// alone would replace it: read-only is the owner's choice. The rename
    /// also removes names from the folder, the old file's and the hidden
    /// copy's, which an append-only folder or an access rule can forbid while
    /// still allowing writes. This runs before the owner is asked, so a save
    /// that would fail never asks for approval, and never leaves its hidden
    /// copy behind in a folder that would not let it be removed.
    private func saveRestriction(of target: SaveTarget) -> NativeExecutionFailure? {
        // The folder first: whether the file can be deleted depends on its
        // folder too, and the folder's own reason is the one to report.
        if faccessat(target.folder, ".", W_OK | X_OK, 0) != 0 {
            return .cannotSave(Self.restriction(errno, subject: "its folder"))
        }
        if faccessat(target.folder, ".", _RMFILE_OK, 0) != 0 {
            switch errno {
            case EPERM: return .cannotSave("its folder is append-only")
            case EACCES: return .cannotSave("an access rule on its folder forbids replacing files in it")
            case let error: return .cannotSave(String(cString: strerror(error)))
            }
        }
        if target.original != nil {
            if faccessat(target.folder, target.name, W_OK, AT_SYMLINK_NOFOLLOW) != 0 {
                return .cannotSave(Self.restriction(errno, subject: "the file"))
            }
            if faccessat(target.folder, target.name, _DELETE_OK, AT_SYMLINK_NOFOLLOW) != 0 {
                let error = errno
                return .cannotSave(error == EACCES ? "an access rule forbids replacing the file" : Self.restriction(error, subject: "the file"))
            }
        }
        return nil
    }

    /// Why the system refused to let this app write `subject`.
    private static func restriction(_ error: Int32, subject: String) -> String {
        switch error {
        case EROFS: "it is on a read-only volume"
        case EPERM: "\(subject) is locked"
        case EACCES: "\(subject) is read-only"
        default: String(cString: strerror(error))
        }
    }

    /// True when nothing has written to the held file since it was read: its
    /// size, modification time, and status-change time are as they were.
    /// Always true for a target that held no file.
    private func heldFileIsUnchanged(_ target: SaveTarget) -> Bool {
        guard let original = target.original else { return true }
        var now = stat()
        guard fstat(original.file, &now) == 0 else { return false }
        let before = original.info
        return now.st_size == before.st_size
            && now.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec
            && now.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
            && now.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec
            && now.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
    }

    /// Where `needle` first appears in `haystack`, and how many times it
    /// appears in all. Overlapping appearances count, so "aa" appears twice
    /// in "aaa": either could be the one the caller meant.
    static func occurrences(of needle: Data, in haystack: Data) -> (first: Range<Int>?, count: Int) {
        haystack.withUnsafeBytes { hay in
            needle.withUnsafeBytes { pin in
                guard let hayStart = hay.baseAddress, let pinStart = pin.baseAddress, pin.count > 0 else {
                    return (nil, 0)
                }
                var first: Range<Int>?
                var count = 0
                var offset = 0
                while offset + pin.count <= hay.count,
                      let found = memmem(hayStart + offset, hay.count - offset, pinStart, pin.count) {
                    let position = hayStart.distance(to: UnsafeRawPointer(found))
                    if first == nil {
                        first = position..<(position + pin.count)
                    }
                    count += 1
                    offset = position + 1
                }
                return (first, count)
            }
        }
    }

    /// Puts new contents at a held target without ever leaving a file half
    /// written, working only through the folder and file the target holds
    /// open. Edits and uploads both save this way.
    ///
    /// `write` fills a hidden file in the held folder, readable only by the
    /// owner while it is written. Replacing a file, the hidden file then
    /// takes on its permissions, ACLs, owner where the system allows it,
    /// extended attributes such as Finder tags, and creation date, with a new
    /// modification time; a new file is readable by everyone and writable by
    /// the owner. Then, only if the path still leads to what the target held,
    /// nothing has written to the file since, and the hidden file's name
    /// still names the file written, it is renamed into place in one step: a
    /// new file only if nothing has taken its name. `commit` is asked just
    /// before that rename (see `offloaded`), and a no changes nothing.
    /// Otherwise, or if any step fails, the original stays as it was and the
    /// hidden file is removed.
    private func save(
        _ target: SaveTarget,
        commit: () -> Bool,
        write: (Int32) throws -> Void
    ) -> NativeExecutionFailure? {
        let temporaryName = ".macremote-edit-\(UUID().uuidString)"
        let temporary = openat(target.folder, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard temporary >= 0 else {
            return .ioError("Could not save the file: \(String(cString: strerror(errno))). Nothing changed.")
        }
        // Held open until the end, so the name can be checked against it.
        defer { close(temporary) }
        var written = stat()
        let copyIdentity = fstat(temporary, &written) == 0 ? FileIdentity(written) : nil
        // The name is checked, not trusted: anything that can write in the
        // folder can put another file, or a link, in the hidden copy's place.
        func nameHoldsCopy() -> Bool {
            var there = stat()
            return fstatat(target.folder, temporaryName, &there, AT_SYMLINK_NOFOLLOW) == 0
                && FileIdentity(there) == copyIdentity
        }
        var renamed = false
        defer {
            // Only the file this save made; whatever took its name is left alone.
            if !renamed, nameHoldsCopy() {
                unlinkat(target.folder, temporaryName, 0)
            }
        }
        do {
            try write(temporary)
            if let original = target.original {
                guard fcopyfile(original.file, temporary, nil, copyfile_flags_t(COPYFILE_SECURITY | COPYFILE_XATTR)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // COPYFILE_SECURITY copies the old file's times too. The
                // contents are new, so the modification time is now; the
                // last-opened time stays as it was.
                var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), timespec(tv_sec: 0, tv_nsec: Int(UTIME_NOW))]
                guard futimens(temporary, &times) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                // The creation date is best effort, like the owner: not every
                // volume keeps one.
                var created = original.info.st_birthtimespec
                var attributes = attrlist(
                    bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME),
                    volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0
                )
                _ = fsetattrlist(temporary, &attributes, &created, MemoryLayout<timespec>.size, 0)
            } else if fchmod(temporary, 0o644) != 0 {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard fsync(temporary) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            return .ioError("Could not save the file: \(error.localizedDescription) Nothing changed.")
        }
        saveWillRename(target.folderPath + "/" + temporaryName)
        guard pathStillLeads(to: target), heldFileIsUnchanged(target), nameHoldsCopy() else {
            return .fileChanged
        }
        guard commit() else {
            return .timedOut
        }
        let status = target.original == nil
            ? renameatx_np(target.folder, temporaryName, target.folder, target.name, UInt32(RENAME_EXCL))
            : renameat(target.folder, temporaryName, target.folder, target.name)
        guard status == 0 else {
            let error = errno
            return error == EEXIST
                ? .alreadyExists
                : .ioError("Could not save the file: \(String(cString: strerror(error))). Nothing changed.")
        }
        renamed = true
        return nil
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

    /// Checks an Append to File or Replace in File call against the file
    /// before the owner is asked, so a call that would fail (a missing file,
    /// a file that is not UTF-8 text or that this app cannot save, a find
    /// text that does not appear exactly once) is refused without a prompt.
    /// Other tools pass.
    func validateEdit(of tool: ToolDefinition, parameters: [String: ToolArgumentValue]) throws {
        guard let nativeToolID = tool.nativeToolID,
              nativeToolID == .fsAppendFile || nativeToolID == .fsReplaceInFile else { return }
        let planned = editPath(in: parameters).flatMap { planEdit(nativeToolID, at: $0, parameters: parameters) }
        if case .failure(let failure) = planned {
            throw ToolValidationError.constraintViolation(failure.message)
        }
    }

    /// The real path an Upload File call's `path` resolves to now, or nil
    /// when the path policy refuses it.
    func uploadDestination(_ parameters: [String: ToolArgumentValue]) -> String? {
        guard case .success(let path) = editPath(in: parameters) else { return nil }
        return path
    }

    /// Checks an Upload File call before the owner is asked: the file
    /// argument, its size, and the destination as it is now (a folder that
    /// exists and can be saved into, and no file there unless `overwrite`).
    /// Other tools pass.
    func validateUpload(of tool: ToolDefinition, parameters: [String: ToolArgumentValue]) throws {
        guard tool.nativeToolID == .fsUploadFile else { return }
        if case .failure(let failure) = uploadTarget(parameters) {
            throw ToolValidationError.constraintViolation(failure.message)
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
        static let fileNotFound = Self(
            code: "not_found",
            message: "File does not exist. To create it, use filesystem_write_file.",
            stderr: "File does not exist."
        )
        static let folderNotFound = Self(
            code: "not_found",
            message: "The folder in path does not exist. Upload File saves only into a folder that already exists.",
            stderr: "Folder does not exist."
        )

        /// Upload File's `file` argument is not one this server takes.
        static func invalidFile(_ message: String) -> Self {
            Self(code: "invalid_file", message: message, stderr: message)
        }
        static let notEditableText = Self(
            code: "not_text",
            message: "File is not UTF-8 text, so it can't be edited as text. Nothing changed.",
            stderr: "File is not UTF-8 text."
        )
        static let fileTooLarge = Self(
            code: "file_too_large",
            message: "File is larger than \(FileTransferToolCatalog.editFileByteLimit / (1024 * 1024)) MiB, "
                + "too large to edit in one call. Nothing changed.",
            stderr: "File is too large to edit."
        )

        static let fileChanged = Self(
            code: "file_changed",
            message: "The file, or a folder in its path, changed while this edit was being made, so nothing was saved. "
                + "Read the file again and retry.",
            stderr: "File changed during the edit."
        )

        static func hardLinked(_ links: Int) -> Self {
            Self(
                code: "hard_linked",
                message: "File has \(links) hard links, other names for the same file. An edit saves a new copy in its "
                    + "place, which would split it from those names, so it can't be edited. Nothing changed.",
                stderr: "File has more than one hard link."
            )
        }

        /// The file, or the folder it is in, does not let this app save it;
        /// `reason` says why (see `saveRestriction`).
        static func cannotSave(_ reason: String) -> Self {
            Self(
                code: "not_writable",
                message: "Can't save this file: \(reason). Nothing changed.",
                stderr: "File can't be saved: \(reason)."
            )
        }

        /// A save that reached its deadline before it could commit. The call
        /// has already reported "timed out", so this is never shown.
        static let timedOut = Self(code: "timeout", message: "Timed out. Nothing changed.", stderr: "Timed out.")

        /// Replace in File found its text zero times, or more than once.
        static func matchCount(_ count: Int) -> Self {
            if count == 0 {
                return Self(
                    code: "no_match",
                    message: "find appears 0 times in the file. Nothing changed. "
                        + "Matching is exact: letter case, spaces, and line endings must all match.",
                    stderr: "find appears 0 times."
                )
            }
            return Self(
                code: "multiple_matches",
                message: "find appears \(count) times in the file. Nothing changed. "
                    + "Add surrounding text to find so that it appears exactly once.",
                stderr: "find appears \(count) times."
            )
        }

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
