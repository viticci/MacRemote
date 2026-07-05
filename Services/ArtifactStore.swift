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

enum ArtifactStoreError: Error, Equatable, Sendable {
    case artifactTooLarge
    case stagingFailed(String)
}

final class ArtifactStore: @unchecked Sendable {
    static let defaultExpiryInterval: TimeInterval = 600
    static let defaultMaxDownloads = 3
    static let defaultMaxSizeBytes: Int64 = 512 * 1024 * 1024

    private struct Entry {
        let fileURL: URL
        let filename: String
        let sha256: String
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
    private var entries = [String: Entry]()

    init(
        rootDirectory: URL? = nil,
        clock: @escaping @Sendable () -> Date = Date.init,
        expiryInterval: TimeInterval = ArtifactStore.defaultExpiryInterval,
        maxDownloads: Int = ArtifactStore.defaultMaxDownloads,
        maxSizeBytes: Int64 = ArtifactStore.defaultMaxSizeBytes
    ) {
        let resolvedRoot = rootDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MacRemoteArtifacts", isDirectory: true)
        self.rootDirectory = resolvedRoot
        self.clock = clock
        self.expiryInterval = expiryInterval
        self.maxDownloads = maxDownloads
        self.maxSizeBytes = maxSizeBytes
        try? FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
    }

    func register(fileURL: URL, suggestedFilename: String) throws -> ArtifactHandle {
        lock.lock()
        defer { lock.unlock() }

        sweepLocked(now: clock())

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let sizeBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard sizeBytes <= maxSizeBytes else {
            throw ArtifactStoreError.artifactTooLarge
        }

        let filename = Self.sanitizedFilename(suggestedFilename)
        let artifactDirectory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let stagedURL = artifactDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: fileURL, to: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }

        return try registerStagedFileLocked(
            stagedURL: stagedURL,
            artifactDirectory: artifactDirectory,
            filename: filename
        )
    }

    func register(data: Data, suggestedFilename: String) throws -> ArtifactHandle {
        lock.lock()
        defer { lock.unlock() }

        sweepLocked(now: clock())

        let sizeBytes = Int64(data.count)
        guard sizeBytes <= maxSizeBytes else {
            throw ArtifactStoreError.artifactTooLarge
        }

        let filename = Self.sanitizedFilename(suggestedFilename)
        let artifactDirectory = rootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let stagedURL = artifactDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }

        return try registerStagedFileLocked(
            stagedURL: stagedURL,
            artifactDirectory: artifactDirectory,
            filename: filename
        )
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

    func purgeAll() {
        lock.lock()
        defer { lock.unlock() }

        for entry in entries.values {
            removeStagedFile(at: entry.fileURL)
        }
        entries.removeAll()
        try? FileManager.default.removeItem(at: rootDirectory)
        try? FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    private func registerStagedFileLocked(
        stagedURL: URL,
        artifactDirectory: URL,
        filename: String
    ) throws -> ArtifactHandle {
        let digest: (hash: String, size: Int64)
        do {
            digest = try Self.sha256HexAndSize(of: stagedURL)
        } catch {
            try? FileManager.default.removeItem(at: artifactDirectory)
            throw ArtifactStoreError.stagingFailed(error.localizedDescription)
        }

        let token = Self.randomToken(byteCount: 32)
        let now = clock()
        entries[token] = Entry(
            fileURL: stagedURL,
            filename: filename,
            sha256: digest.hash,
            sizeBytes: digest.size,
            expiresAt: now.addingTimeInterval(expiryInterval),
            remainingDownloads: maxDownloads
        )

        return ArtifactHandle(
            token: token,
            artifactPath: "/artifact/\(token)",
            filename: filename,
            sizeBytes: digest.size,
            sha256: digest.hash,
            expiresInSeconds: Int(expiryInterval),
            downloadsAllowed: maxDownloads
        )
    }

    private func sweepLocked(now: Date) {
        var tokensToRemove = [String]()
        for (token, entry) in entries {
            if entry.expiresAt <= now || entry.remainingDownloads <= 0 {
                removeStagedFile(at: entry.fileURL)
                tokensToRemove.append(token)
            }
        }
        for token in tokensToRemove {
            entries.removeValue(forKey: token)
        }
    }

    private func removeStagedFile(at fileURL: URL) {
        let artifactDirectory = fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: artifactDirectory)
    }

    private static func sha256HexAndSize(of fileURL: URL) throws -> (hash: String, size: Int64) {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            let chunk = handle.readData(ofLength: 1024 * 1024)
            if chunk.isEmpty { break }
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
        return sanitized.isEmpty ? "download" : sanitized
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
