import CryptoKit
import Foundation

/// The `file` argument of Upload File: the MCP files extension's file object
/// (SPEC D83), checked. Every value in it is what the app claims; the bytes
/// are checked against `size` and `digest` when they arrive.
struct UploadedFileInput: Equatable, Sendable {
    let id: String
    let name: String?
    let mimeType: String
    let size: Int64
    /// The SHA-256 the app declared, as its 32 bytes.
    let digest: Data?

    /// Reads `value`, or explains to the app what is wrong with it. Inline
    /// `data` is refused: this server accepts files only out of band, so it
    /// advertises no `maxInlineBytes`. An empty `data` for an empty file is
    /// the same empty file.
    init(_ value: JSONValue?) throws {
        guard let object = value?.objectValue else {
            throw ToolValidationError.constraintViolation("file must be an object with id, mimeType, and size.")
        }
        guard case .string(let id)? = object["id"], (1...128).contains(id.count) else {
            throw ToolValidationError.constraintViolation("file.id must be a string of 1 to 128 characters.")
        }
        guard case .string(let mimeType)? = object["mimeType"] else {
            throw ToolValidationError.constraintViolation("file.mimeType must be a string.")
        }
        guard case .number(let number)? = object["size"], let size = Int64(exactly: number), size >= 0 else {
            throw ToolValidationError.constraintViolation("file.size must be a whole number of bytes, 0 or more.")
        }
        var name: String?
        switch object["name"] {
        case nil: break
        case .string(let value)?: name = value
        default: throw ToolValidationError.constraintViolation("file.name must be a string.")
        }
        var digest: Data?
        if let declared = object["digest"] {
            guard case .string("sha-256")? = declared.objectValue?["algorithm"],
                  case .string(let encoded)? = declared.objectValue?["value"],
                  let bytes = Self.base64URLDecoded(encoded), bytes.count == 32 else {
                throw ToolValidationError.constraintViolation(
                    "file.digest must be {\"algorithm\": \"sha-256\", \"value\": <the SHA-256 in base64url>}."
                )
            }
            digest = bytes
        }
        if size == 0, let digest, digest != Data(SHA256.hash(data: Data())) {
            throw ToolValidationError.constraintViolation("file.digest is not the SHA-256 of an empty file, but file.size is 0.")
        }
        if let data = object["data"], !(size == 0 && data == .string("")) {
            throw ToolValidationError.constraintViolation(
                "MacRemote does not take file bytes inside the call. Send the file without data, and the app sends its bytes after the owner approves."
            )
        }
        guard size <= FileTransferToolCatalog.uploadFileByteLimit else {
            throw ToolValidationError.constraintViolation(
                "file is \(size) bytes; Upload File takes at most \(FileTransferToolCatalog.uploadFileByteLimit) bytes."
            )
        }
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.digest = digest
    }

    /// True when the call's file has bytes the app must send out of band:
    /// it is not empty and carries no `data`. A malformed file, such as a
    /// `size` that is not a whole number, is left to validation, which
    /// explains what is wrong; `size` is read the way validation reads it.
    static func needsTransfer(_ arguments: Any?) -> Bool {
        guard let file = (arguments as? [String: Any])?["file"] as? [String: Any],
              case .number(let number)? = JSONValue.fromJSONObject(file["size"] ?? NSNull()),
              let size = Int64(exactly: number) else { return false }
        return size > 0 && file["data"] == nil
    }

    /// base64url, with or without padding.
    static func base64URLDecoded(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 = base64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}

/// An upload's bytes on the call that saves them: open, exactly the declared
/// size, and matching the declared digest when there was one. The handle
/// stays open for as long as anything holds this, so the save reads the very
/// bytes that were checked even if staging is cleaned up meanwhile.
struct ConfirmedUploadBytes: @unchecked Sendable {
    let handle: FileHandle
    let size: Int64
    /// The real path the first call's `path` resolved to, which the owner
    /// approved. The save goes there or nowhere.
    let destination: String
}

/// Uploads through the MCP files extension (SPEC D83), in memory, from the
/// call that asks for one until its file is written or it expires.
///
/// An upload is created only after the owner approved the call. Its
/// `requestState` is an unguessable handle, like the one elicitation uses
/// (`ToolCallTaskStore.newHandle`), bound to the app, the tool name, the
/// arguments, and the approved tool definition. Its transfer token, a second
/// handle, names the one place its bytes may be sent, by that app only. The
/// bytes wait in a private staging folder until the call comes back, and are
/// deleted when it does, when the upload expires, and when the server stops.
///
/// Each upload moves waiting → received (as many times as the app sends its
/// bytes again) → consumed, and every move happens here.
final class FileUploadStore: @unchecked Sendable {
    static let extensionIdentifier = "io.modelcontextprotocol/files"
    /// How long a `requestState` works: about an hour, as Claude's connector
    /// guide suggests.
    static let defaultLifetime: TimeInterval = 60 * 60
    /// How long its transfer target accepts bytes: well within its
    /// `requestState`, and at least the 20 minutes the guide asks for.
    static let defaultTransferLifetime: TimeInterval = 30 * 60
    /// Uploads one app may have waiting for their bytes or their second call:
    /// enough for a host that sends several files at once, or gave up on a
    /// few. The total below is what bounds the disk.
    static let maximumWaitingPerApp = 16
    /// Bytes all waiting uploads may hold, reserved when each is created:
    /// room for four of the largest, like staged downloads.
    static let defaultMaxTotalBytes = ArtifactStore.defaultMaxTotalBytes
    /// Beside staged downloads, so the launch cleanup that empties those
    /// (`ArtifactStore.emptyStagingRoot`) empties this too.
    static let defaultRootDirectory = ArtifactStore.stagingRoot.appendingPathComponent("Uploads", isDirectory: true)

    /// The confirmed bytes of the upload whose second call is running. The
    /// server sets it around that call, and Upload File reads it.
    @TaskLocal static var confirmedBytes: ConfirmedUploadBytes?

    /// True when a request declared the extension's `upload` setting. A
    /// `revision` this server does not know means not declared.
    static func declaresUpload(_ capabilities: JSONValue) -> Bool {
        guard let settings = capabilities.objectValue?["extensions"]?.objectValue?[extensionIdentifier]?.objectValue else {
            return false
        }
        return settings["upload"]?.objectValue != nil && settings["revision"] == nil
    }

    private enum Phase {
        case waiting
        case received(URL)
        /// Claimed by its second call, which is saving these bytes.
        case consumed(URL)
    }

    private struct Upload {
        let ownerID: String
        let toolName: String
        let arguments: JSONValue
        /// The tool definition the owner approved.
        let toolFingerprint: String
        /// The real path the first call's `path` resolved to.
        let destination: String
        let size: Int64
        let digest: Data?
        let transferToken: String
        let transferExpiresAt: Date
        let expiresAt: Date
        var phase: Phase
        /// The transfer whose bytes are arriving now, one at a time: the file
        /// it writes, and how its route stops taking bytes.
        var transfer: (file: URL, stop: (@Sendable () -> Void)?)?

        var stagedFile: URL? {
            switch phase {
            case .waiting: nil
            case .received(let url), .consumed(let url): url
            }
        }
    }

    struct Started: Sendable {
        let requestState: String
        let transferToken: String
        let transferExpiresAt: Date
    }

    /// Where one transfer writes, from `startTransfer` until it is finished
    /// or abandoned.
    struct Transfer: @unchecked Sendable {
        fileprivate let requestState: String
        let declaredSize: Int64
        let handle: FileHandle
        fileprivate let fileURL: URL
    }

    enum TransferRefusal: Error, Equatable {
        /// No upload of this app's has this token, or it no longer takes bytes.
        case notFound
        /// The body is longer than the file the owner approved.
        case tooLarge
        /// Bytes for this upload are already arriving.
        case busy
        case stagingFailed
    }

    enum Claim {
        /// Not an upload's `requestState`.
        case unknown
        /// An upload's, but for another app, tool, or arguments, or used.
        case invalid
        /// The bytes are missing or wrong; the app may send them again and retry.
        case notReady(String)
        case claimed(ConfirmedUploadBytes, toolFingerprint: String)
    }

    private let rootDirectory: URL
    private let lifetime: TimeInterval
    private let transferLifetime: TimeInterval
    private let maxTotalBytes: Int64
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var uploads = [String: Upload]()
    private var requestStates = [String: String]()
    private var closed = false

    init(
        rootDirectory: URL = FileUploadStore.defaultRootDirectory,
        lifetime: TimeInterval = FileUploadStore.defaultLifetime,
        transferLifetime: TimeInterval = FileUploadStore.defaultTransferLifetime,
        maxTotalBytes: Int64 = FileUploadStore.defaultMaxTotalBytes,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.rootDirectory = rootDirectory
        self.lifetime = lifetime
        self.transferLifetime = min(transferLifetime, lifetime)
        self.maxTotalBytes = maxTotalBytes
        self.now = now
    }

    /// Why `ownerID` cannot start an upload of `size` bytes now, or nil when
    /// it can. Asked before the owner is, and again by `begin`.
    func refusal(ownerID: String, size: Int64) -> String? {
        lock.withLock { refusalLocked(ownerID: ownerID, size: size) }
    }

    /// Records an approved upload and returns its handles, or why it could
    /// not: no room, or the server is stopping. `destination` is the real
    /// path the call's `path` resolved to; the second call saves only there.
    func begin(
        ownerID: String,
        toolName: String,
        arguments: JSONValue,
        toolFingerprint: String,
        destination: String,
        file: UploadedFileInput
    ) -> Result<Started, ToolValidationError> {
        let requestState = ToolCallTaskStore.newHandle()
        let transferToken = ToolCallTaskStore.newHandle()
        let started: Result<Started, ToolValidationError> = lock.withLock {
            if let refusal = refusalLocked(ownerID: ownerID, size: file.size) {
                return .failure(.constraintViolation(refusal))
            }
            let date = now()
            let upload = Upload(
                ownerID: ownerID,
                toolName: toolName,
                arguments: arguments,
                toolFingerprint: toolFingerprint,
                destination: destination,
                size: file.size,
                digest: file.digest,
                transferToken: transferToken,
                transferExpiresAt: date.addingTimeInterval(transferLifetime),
                expiresAt: date.addingTimeInterval(lifetime),
                phase: .waiting
            )
            uploads[requestState] = upload
            requestStates[transferToken] = requestState
            return .success(Started(
                requestState: requestState,
                transferToken: transferToken,
                transferExpiresAt: upload.transferExpiresAt
            ))
        }
        if case .success = started {
            let lifetime = lifetime
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(lifetime))
                self?.drop(requestState)
            }
        }
        return started
    }

    /// Starts receiving bytes for the upload with `token`: only its own app,
    /// before its target expires, one transfer at a time, and never more
    /// bytes than the owner approved. A transfer writes to a new file, so the
    /// bytes received before stay until it finishes. Its route hands over how
    /// to stop it with `whenEnded`.
    func startTransfer(token: String, ownerID: String, contentLength: Int64) -> Result<Transfer, TransferRefusal> {
        let fileURL = rootDirectory.appendingPathComponent(UUID().uuidString)
        let checked: Result<(String, Int64), TransferRefusal> = lock.withLock {
            guard let requestState = requestStates[token],
                  var upload = uploads[requestState],
                  upload.ownerID == ownerID,
                  upload.transferExpiresAt > now() else {
                return .failure(.notFound)
            }
            if case .consumed = upload.phase { return .failure(.notFound) }
            guard contentLength <= upload.size else { return .failure(.tooLarge) }
            guard upload.transfer == nil else { return .failure(.busy) }
            upload.transfer = (fileURL, nil)
            uploads[requestState] = upload
            return .success((requestState, upload.size))
        }
        guard case .success(let (requestState, size)) = checked else {
            if case .failure(let refusal) = checked { return .failure(refusal) }
            return .failure(.notFound)
        }
        do {
            try FileManager.default.createDirectory(
                at: rootDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            return .success(Transfer(requestState: requestState, declaredSize: size, handle: handle, fileURL: fileURL))
        } catch {
            lock.withLock { uploads[requestState]?.transfer = nil }
            try? FileManager.default.removeItem(at: fileURL)
            return .failure(.stagingFailed)
        }
    }

    /// Calls `stop` if the upload ends while `transfer` is still taking
    /// bytes, because it expired, was saved, or the server stopped; at once
    /// when it already has. The store deletes what the transfer wrote, and
    /// `stop` cuts the connection, so no further byte is stored.
    func whenEnded(_ transfer: Transfer, stop: @escaping @Sendable () -> Void) {
        let ended: Bool = lock.withLock {
            guard uploads[transfer.requestState]?.transfer?.file == transfer.fileURL else { return true }
            uploads[transfer.requestState]?.transfer?.stop = stop
            return false
        }
        if ended { stop() }
    }

    /// Makes a complete transfer's bytes the upload's staged bytes, replacing
    /// any received before. False when the upload ended meanwhile: its bytes
    /// are then deleted.
    func finishTransfer(_ transfer: Transfer) -> Bool {
        try? transfer.handle.close()
        let replaced: (kept: Bool, stale: URL?) = lock.withLock {
            guard var upload = uploads[transfer.requestState], upload.expiresAt > now() else {
                return (false, transfer.fileURL)
            }
            upload.transfer = nil
            if case .consumed = upload.phase {
                uploads[transfer.requestState] = upload
                return (false, transfer.fileURL)
            }
            let previous = upload.stagedFile
            upload.phase = .received(transfer.fileURL)
            uploads[transfer.requestState] = upload
            return (true, previous)
        }
        if let stale = replaced.stale {
            try? FileManager.default.removeItem(at: stale)
        }
        return replaced.kept
    }

    /// Ends a transfer that failed or was cut off, and deletes what it wrote.
    /// Bytes received before it stay.
    func abandonTransfer(_ transfer: Transfer) {
        try? transfer.handle.close()
        lock.withLock {
            if uploads[transfer.requestState]?.transfer?.file == transfer.fileURL {
                uploads[transfer.requestState]?.transfer = nil
            }
        }
        try? FileManager.default.removeItem(at: transfer.fileURL)
    }

    /// The second call's claim on its upload. Checks the handle and what it
    /// is bound to, then confirms the staged bytes outside the lock: their
    /// size, and their SHA-256 when one was declared, hashed here. Only then
    /// is the upload consumed, in one step, so of two calls at once one
    /// claims it and the other is told it is used.
    func claim(requestState: String, ownerID: String, toolName: String, arguments: JSONValue) -> Claim {
        var answer = Claim.invalid
        var bytes: (staged: URL, size: Int64, digest: Data?, destination: String)?
        lock.withLock {
            guard let upload = uploads[requestState] else {
                answer = .unknown
                return
            }
            guard upload.expiresAt > now(),
                  upload.ownerID == ownerID,
                  upload.toolName == toolName,
                  upload.arguments == arguments else { return }
            switch upload.phase {
            case .consumed:
                break
            case .waiting:
                answer = .notReady("The file's bytes have not arrived. Send them to the upload target, then send the call again.")
            case .received(let staged):
                bytes = (staged, upload.size, upload.digest, upload.destination)
            }
        }
        // The lock is taken again below: a new transfer may replace these
        // bytes while they are checked.
        guard let (staged, size, digest, destination) = bytes else { return answer }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: staged)
        } catch {
            return .notReady("The file's bytes could not be read. Send them again, then send the call again.")
        }
        let received = (try? handle.seekToEnd()).map(Int64.init) ?? -1
        guard received == size else {
            return .notReady("The upload received \(received) bytes, but the file is \(size) bytes. Send the whole file again, then send the call again.")
        }
        if let digest {
            guard (try? Self.sha256(of: handle)) == digest else {
                return .notReady("The bytes received do not match the file's SHA-256 digest. Send the file again, then send the call again.")
            }
        }

        return lock.withLock {
            guard var upload = uploads[requestState], upload.expiresAt > now() else { return .invalid }
            switch upload.phase {
            case .consumed:
                return .invalid
            case .received(let current) where current == staged:
                upload.phase = .consumed(staged)
                uploads[requestState] = upload
                requestStates[upload.transferToken] = nil
                return .claimed(
                    ConfirmedUploadBytes(handle: handle, size: size, destination: destination),
                    toolFingerprint: upload.toolFingerprint
                )
            default:
                return .notReady("New bytes for the file arrived while it was being checked. Send the call again.")
            }
        }
    }

    /// Ends a claimed upload once its call is done, and deletes its bytes.
    func finish(requestState: String) {
        drop(requestState)
    }

    /// Ends every upload, stops every transfer still taking bytes, deletes
    /// every staged file and every file a transfer was writing, and accepts
    /// no new ones. Used when the server stops: nobody can finish them after
    /// that.
    func close() {
        let ended: [Upload] = lock.withLock {
            closed = true
            defer {
                uploads = [:]
                requestStates = [:]
            }
            return Array(uploads.values)
        }
        ended.forEach(Self.end)
    }

    private func drop(_ requestState: String) {
        let ended: Upload? = lock.withLock {
            guard let upload = uploads.removeValue(forKey: requestState) else { return nil }
            requestStates[upload.transferToken] = nil
            return upload
        }
        if let ended {
            Self.end(ended)
        }
    }

    /// What ending `upload` leaves behind: no staged bytes, no partial file,
    /// and no transfer still taking bytes. Call without the lock.
    private static func end(_ upload: Upload) {
        for file in [upload.stagedFile, upload.transfer?.file].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: file)
        }
        upload.transfer?.stop?()
    }

    /// Call with the lock held.
    private func refusalLocked(ownerID: String, size: Int64) -> String? {
        guard !closed else { return "MacRemote is stopping, so it can't receive files now." }
        let date = now()
        let live = uploads.values.filter { $0.expiresAt > date }
        guard live.filter({ $0.ownerID == ownerID }).count < Self.maximumWaitingPerApp else {
            return "This app already has \(Self.maximumWaitingPerApp) uploads waiting. Finish or abandon one before starting another."
        }
        guard live.reduce(0, { $0 + $1.size }) + size <= maxTotalBytes else {
            return "Uploads waiting on this Mac already use the space set aside for them. Try again after they finish or expire."
        }
        return nil
    }

    private static func sha256(of handle: FileHandle) throws -> Data {
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        // The throwing read: the older call raises an exception Swift cannot
        // catch when the volume fails mid-read.
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
