import CryptoKit
import Foundation

struct ArtifactHandle: Sendable, Equatable {
    let token: String
    let artifactPath: String
    let filename: String
    let sizeBytes: Int64
    let sha256: String
    let expiresInSeconds: Int
    let downloadsAllowed: Int
}

enum ArtifactStoreError: LocalizedError, Equatable, Sendable {
    case artifactTooLarge
    /// Downloads that were not fetched yet already use all the staging space.
    case stagingFull
    case stagingFailed(String)

    /// Plain wording, because these reach the calling app in a tool result.
    var errorDescription: String? {
        switch self {
        case .artifactTooLarge:
            "The file is larger than the download size limit."
        case .stagingFull:
            "Downloads that are still waiting to be fetched use all the space set aside for them. "
                + "Try again after they are fetched or expire."
        case .stagingFailed(let detail):
            detail
        }
    }
}

/// Holds the files an app may download for a short time: copies of files, zip
/// archives, and tool output too large to return inline. Each one gets a
/// random token, expires, and can be fetched a few times.
final class ArtifactStore: @unchecked Sendable {
    static let defaultExpiryInterval: TimeInterval = 600
    static let defaultMaxDownloads = 3
    static let defaultMaxSizeBytes: Int64 = 512 * 1024 * 1024
    /// All staged downloads together: room for four of the largest. Without a
    /// total, an app could fill the disk one 512 MiB download at a time.
    static let defaultMaxTotalBytes: Int64 = 4 * defaultMaxSizeBytes

    /// The one folder every staged file lives in: downloads, and tool output
    /// on its way to becoming one (`ProcessRunner`). Each store keeps to its
    /// own subfolders, so several stores can share it.
    static let stagingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacRemoteStaging", isDirectory: true)

    /// Deletes everything an earlier launch staged. Tokens live only in
    /// memory, so after a quit or a crash nothing left here can be downloaded.
    /// The app calls this once at launch, before it stages anything.
    static func emptyStagingRoot(_ root: URL = stagingRoot) {
        try? FileManager.default.removeItem(at: root)
    }

    /// Room set aside for one download that is still being written. Its bytes
    /// already count toward the total, so the file can be written, however
    /// long that takes, without holding the store's lock. Finish with exactly
    /// one of `commit` or `discard`.
    struct Reservation {
        /// Where to write the file.
        let fileURL: URL
        fileprivate let directory: URL
        fileprivate let filename: String
    }

    private struct Entry {
        let directory: URL
        let fileURL: URL
        let filename: String
        let sizeBytes: Int64
        let expiresAt: Date
        var remainingDownloads: Int
    }

    private let lock = NSLock()
    private let rootDirectory: URL
    private let clock: @Sendable () -> Date
    private let expiryInterval: TimeInterval
    private let maxDownloads: Int
    private let maxSizeBytes: Int64
    private let maxTotalBytes: Int64
    private var entries = [String: Entry]()
    /// Bytes promised to reservations that are not finished, by their folder.
    private var reservedBytes = [URL: Int64]()

    init(
        rootDirectory: URL = ArtifactStore.stagingRoot,
        clock: @escaping @Sendable () -> Date = Date.init,
        expiryInterval: TimeInterval = ArtifactStore.defaultExpiryInterval,
        maxDownloads: Int = ArtifactStore.defaultMaxDownloads,
        maxSizeBytes: Int64 = ArtifactStore.defaultMaxSizeBytes,
        maxTotalBytes: Int64 = ArtifactStore.defaultMaxTotalBytes
    ) {
        self.rootDirectory = rootDirectory
        self.clock = clock
        self.expiryInterval = expiryInterval
        self.maxDownloads = maxDownloads
        self.maxSizeBytes = maxSizeBytes
        self.maxTotalBytes = maxTotalBytes
    }

    deinit {
        // No token can be redeemed once the store is gone.
        for entry in entries.values {
            try? FileManager.default.removeItem(at: entry.directory)
        }
    }

    /// Copies a file into staging and makes the copy downloadable.
    func register(fileURL: URL, suggestedFilename: String) throws -> ArtifactHandle {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let reservation = try reserve(suggestedFilename: suggestedFilename, expectedBytes: sizeBytes)
        do {
            try FileManager.default.copyItem(at: fileURL, to: reservation.fileURL)
        } catch {
            discard(reservation)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }
        return try commit(reservation)
    }

    /// Writes bytes into staging and makes them downloadable.
    func register(data: Data, suggestedFilename: String) throws -> ArtifactHandle {
        let reservation = try reserve(suggestedFilename: suggestedFilename, expectedBytes: Int64(data.count))
        do {
            try data.write(to: reservation.fileURL)
        } catch {
            discard(reservation)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }
        return try commit(reservation)
    }

    /// Sets aside room for a download of about `expectedBytes` and says where
    /// to write it. Refuses when that one file, or all staged files together,
    /// would be over the limit. Expired downloads are cleared first, so they
    /// never count against a new one.
    func reserve(suggestedFilename: String, expectedBytes: Int64) throws -> Reservation {
        guard expectedBytes <= maxSizeBytes else {
            throw ArtifactStoreError.artifactTooLarge
        }
        let filename = Self.sanitizedFilename(suggestedFilename)
        let directory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

        try lock.withLock {
            sweepLocked(now: clock())
            let stagedBytes = entries.values.reduce(0) { $0 + $1.sizeBytes }
                + reservedBytes.values.reduce(0, +)
            guard stagedBytes + expectedBytes <= maxTotalBytes else {
                throw ArtifactStoreError.stagingFull
            }
            reservedBytes[directory] = expectedBytes
        }

        let reservation = Reservation(
            fileURL: directory.appendingPathComponent(filename),
            directory: directory,
            filename: filename
        )
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            discard(reservation)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }
        return reservation
    }

    /// Makes the file written at a reservation downloadable. The hash reads
    /// the whole file, so it runs here, outside the lock.
    func commit(_ reservation: Reservation) throws -> ArtifactHandle {
        let digest: (hash: String, size: Int64)
        do {
            digest = try Self.sha256HexAndSize(of: reservation.fileURL)
        } catch {
            discard(reservation)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }
        // The estimate can be low: a file that grew while it was copied, or a
        // zip that came out larger than its contents.
        guard digest.size <= maxSizeBytes else {
            discard(reservation)
            throw ArtifactStoreError.artifactTooLarge
        }

        let token = Self.randomToken(byteCount: 32)
        lock.withLock {
            reservedBytes.removeValue(forKey: reservation.directory)
            entries[token] = Entry(
                directory: reservation.directory,
                fileURL: reservation.fileURL,
                filename: reservation.filename,
                sizeBytes: digest.size,
                expiresAt: clock().addingTimeInterval(expiryInterval),
                remainingDownloads: maxDownloads
            )
        }
        scheduleSweepAfterExpiry()

        return ArtifactHandle(
            token: token,
            artifactPath: "/artifact/\(token)",
            filename: reservation.filename,
            sizeBytes: digest.size,
            sha256: digest.hash,
            expiresInSeconds: Int(expiryInterval),
            downloadsAllowed: maxDownloads
        )
    }

    /// Gives up a reservation and deletes whatever was written to it.
    func discard(_ reservation: Reservation) {
        try? FileManager.default.removeItem(at: reservation.directory)
        lock.withLock {
            _ = reservedBytes.removeValue(forKey: reservation.directory)
        }
    }

    func resolve(token: String) -> (fileURL: URL, filename: String, remainingDownloads: Int)? {
        lock.lock()
        defer { lock.unlock() }

        sweepLocked(now: clock())
        guard let entry = entries[token] else { return nil }
        guard entry.expiresAt > clock(), entry.remainingDownloads > 0 else { return nil }
        return (entry.fileURL, entry.filename, entry.remainingDownloads)
    }

    func consume(token: String) -> (fileURL: URL, filename: String, remainingDownloads: Int)? {
        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        sweepLocked(now: now)
        guard var entry = entries[token] else { return nil }
        guard entry.expiresAt > now, entry.remainingDownloads > 0 else { return nil }

        entry.remainingDownloads -= 1
        entries[token] = entry
        return (entry.fileURL, entry.filename, entry.remainingDownloads)
    }

    /// Forgets every download and deletes its file. The staging folder itself
    /// stays: other stores, and tool output still being collected, share it.
    func purgeAll() {
        lock.lock()
        defer { lock.unlock() }

        for entry in entries.values {
            try? FileManager.default.removeItem(at: entry.directory)
        }
        entries.removeAll()
    }

    /// Deletes a download's file when it expires, even if nothing else
    /// touches the store by then. Otherwise an expired file would stay on
    /// disk until the next download or the next launch.
    private func scheduleSweepAfterExpiry() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + expiryInterval + 1) { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.sweepLocked(now: self.clock()) }
        }
    }

    private func sweepLocked(now: Date) {
        for (token, entry) in entries where entry.expiresAt <= now || entry.remainingDownloads <= 0 {
            try? FileManager.default.removeItem(at: entry.directory)
            entries.removeValue(forKey: token)
        }
    }

    private static func sha256HexAndSize(of fileURL: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        // The throwing read: the older call raises an exception Swift cannot
        // catch when the volume fails mid-read.
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            size += Int64(chunk.count)
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, size)
    }

    static func sanitizedFilename(_ value: String) -> String {
        let basename = (value as NSString).lastPathComponent
        let filteredScalars = basename.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && scalar != "/"
                && scalar != "\\"
                && scalar != "\""
        }
        let sanitized = String(String.UnicodeScalarView(filteredScalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        // "." and ".." are not file names: inside a download's folder they
        // would name the folder itself or the one above it.
        return ["", ".", ".."].contains(sanitized) ? "download" : sanitized
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed.")
        return Data(bytes).artifactBase64URLEncodedString()
    }
}

private extension Data {
    func artifactBase64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
