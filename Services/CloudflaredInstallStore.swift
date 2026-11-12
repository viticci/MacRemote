import CryptoKit
import Darwin
import Foundation

/// What MacRemote installed, so a later launch can prove the file on disk is
/// still the reviewed one. Written next to the binary as `install.json` (0600).
struct CloudflaredInstallRecord: Codable, Equatable, Sendable {
    let version: String
    let architecture: CloudflaredArchitecture
    let executableSHA256: String
    let byteCount: Int
    let installedAt: Date
    let sourceURL: String
}

/// Cheap identity of a file on disk. A matching key means the same bytes are
/// still there, so the full hash does not have to be recomputed on every
/// status refresh.
struct CloudflaredIntegrityKey: Equatable, Sendable {
    let inode: UInt64
    let modifiedAt: TimeInterval
    let byteCount: Int
}

enum CloudflaredInstallStoreError: LocalizedError, Equatable {
    case notInstalled
    case unsafeLocation(String)
    case unsafePermissions(String)
    case integrityMismatch(String)
    case signatureMismatch(String)
    case commitFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "MacRemote has not installed Cloudflare's helper."
        case .unsafeLocation(let detail):
            "MacRemote's copy of Cloudflare's helper is not where it should be: \(detail)"
        case .unsafePermissions(let detail):
            "MacRemote's copy of Cloudflare's helper no longer has safe permissions: \(detail)"
        case .integrityMismatch(let detail):
            "MacRemote's copy of Cloudflare's helper changed since it was installed: \(detail)"
        case .signatureMismatch(let detail):
            "MacRemote's copy of Cloudflare's helper is no longer signed by Cloudflare: \(detail)"
        case .commitFailed(let detail):
            "MacRemote could not finish installing Cloudflare's helper: \(detail)"
        }
    }
}

/// Owns everything under
/// `~/Library/Application Support/MacRemote/CloudflaredHelper/`. Nothing
/// outside that folder is ever created, changed, or deleted — a helper the user
/// installed themselves is never touched.
struct CloudflaredInstallStore: Sendable {
    static let directoryName = "CloudflaredHelper"
    static let binaryName = "cloudflared"

    /// Every executable digest this build of MacRemote is willing to launch,
    /// taken from the compile-time manifest. `install.json` sits in the user's
    /// own Application Support folder, so anything running as this user can
    /// rewrite it — which means the record alone can never authorize a binary.
    /// Both architectures are accepted: a Mac migrated from Intel keeps running
    /// its verified copy under Rosetta.
    static let pinnedExecutableDigests: Set<String> = Set(
        CloudflaredManifest.artifacts.map(\.executableSHA256)
    ).union(CloudflaredManifest.earlierExecutableSHA256)

    let rootDirectory: URL
    /// Overridable only so tests can pin their own fixture binaries. Production
    /// always uses the manifest set.
    let expectedExecutableDigests: Set<String>

    init(
        rootDirectory: URL? = nil,
        expectedExecutableDigests: Set<String> = Self.pinnedExecutableDigests
    ) {
        self.expectedExecutableDigests = expectedExecutableDigests
        if let rootDirectory {
            self.rootDirectory = rootDirectory
            return
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.rootDirectory = base
            .appendingPathComponent("MacRemote", isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    var binaryDirectory: URL { rootDirectory.appendingPathComponent("bin", isDirectory: true) }
    var binaryURL: URL { binaryDirectory.appendingPathComponent(Self.binaryName) }
    var recordURL: URL { rootDirectory.appendingPathComponent("install.json") }
    var stagingRootDirectory: URL { rootDirectory.appendingPathComponent("staging", isDirectory: true) }
    var quarantineDirectory: URL { rootDirectory.appendingPathComponent("quarantine", isDirectory: true) }

    // MARK: - Reading

    func installedRecord() -> CloudflaredInstallRecord? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CloudflaredInstallRecord.self, from: data)
    }

    /// Full pre-launch check: layout, ownership, permissions of both the binary
    /// and its record, exact size, exact SHA-256 against *both* `install.json`
    /// and the compile-time pin, and the Developer ID team. Any failure
    /// quarantines the copy so the app can never launch it, and reports what did
    /// not match.
    func verifyInstalledBinary(
        expectedTeamIdentifier: String = CloudflaredManifest.expectedTeamIdentifier,
        signatureReader: any SignatureReading = CodeSignatureReader()
    ) throws -> CloudflaredInstallRecord {
        guard let record = installedRecord() else {
            throw CloudflaredInstallStoreError.notInstalled
        }
        do {
            try checkOwnerOnlyDirectory(rootDirectory)
            try checkOwnerOnlyDirectory(binaryDirectory)
            try checkInstallRecordFile()

            let attributes = try FileManager.default.attributesOfItem(atPath: binaryURL.path)
            if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw CloudflaredInstallStoreError.unsafeLocation("it is a symbolic link")
            }
            guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
                throw CloudflaredInstallStoreError.unsafeLocation("it is not a regular file")
            }
            guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw CloudflaredInstallStoreError.unsafePermissions("it is owned by another user")
            }
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
            guard permissions == 0o500 else {
                throw CloudflaredInstallStoreError.unsafePermissions(
                    "expected mode 500, found \(String(format: "%o", permissions))"
                )
            }
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? -1
            guard byteCount == record.byteCount else {
                throw CloudflaredInstallStoreError.integrityMismatch(
                    "expected \(record.byteCount) bytes, found \(byteCount)"
                )
            }
            let digest = try Self.sha256(ofFileAt: binaryURL)
            guard digest == record.executableSHA256 else {
                throw CloudflaredInstallStoreError.integrityMismatch("the SHA-256 does not match install.json")
            }
            // The record is rewritable; the pin is not. A binary whose digest is
            // not one MacRemote shipped never launches, however consistent the
            // record next to it looks.
            guard expectedExecutableDigests.contains(digest) else {
                throw CloudflaredInstallStoreError.integrityMismatch(
                    "the SHA-256 is not one MacRemote published"
                )
            }
            let trust = signatureReader.signatureTrust(atPath: binaryURL.path)
            guard case .developerID(let team, _) = trust, team == expectedTeamIdentifier else {
                throw CloudflaredInstallStoreError.signatureMismatch("expected Developer ID team \(expectedTeamIdentifier)")
            }
            return record
        } catch let error as CloudflaredInstallStoreError {
            quarantineInstalled(reason: error.localizedDescription)
            throw error
        } catch {
            let wrapped = CloudflaredInstallStoreError.integrityMismatch(error.localizedDescription)
            quarantineInstalled(reason: wrapped.localizedDescription)
            throw wrapped
        }
    }

    /// Cheap, status-only answer: the record exists and the binary still looks
    /// like the one it describes (regular file, this user, mode 500, exact
    /// size). Four `stat`-class calls, no hashing and no signature read, so it
    /// is safe to call on the main actor. It proves nothing about the bytes —
    /// `verifyInstalledBinary` does that, and only it authorizes a launch.
    func plausibleInstalledBinaryPath() -> String? {
        guard let record = installedRecord() else { return nil }
        var status = stat()
        guard lstat(binaryURL.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_uid == getuid(),
              (status.st_mode & 0o777) == 0o500,
              Int(status.st_size) == record.byteCount else {
            return nil
        }
        return binaryURL.path
    }

    static func integrityKey(forFileAt url: URL) -> CloudflaredIntegrityKey? {
        var status = stat()
        guard lstat(url.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return CloudflaredIntegrityKey(
            inode: UInt64(status.st_ino),
            modifiedAt: Double(status.st_mtimespec.tv_sec) + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000,
            byteCount: Int(status.st_size)
        )
    }

    // MARK: - Staging

    /// A fresh, uniquely named staging folder. Anything left behind by an
    /// interrupted install is cleared first, so a relaunch mid-install starts
    /// clean instead of reusing half-written bytes.
    func prepareStagingDirectory() throws -> URL {
        cleanStaleStaging()
        try createOwnerOnlyDirectory(rootDirectory)
        try createOwnerOnlyDirectory(stagingRootDirectory)
        let directory = stagingRootDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try createOwnerOnlyDirectory(directory)
        return directory
    }

    func discardStagingDirectory(_ directory: URL) {
        guard directory.path.hasPrefix(stagingRootDirectory.path) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    func cleanStaleStaging() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: stagingRootDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for item in contents {
            try? FileManager.default.removeItem(at: item)
        }
    }

    /// Same sweep, but only for leftovers older than `minimumAge`. Status
    /// refreshes use this so a quit mid-download stops costing tens of
    /// megabytes until the next install, without ever touching a transfer that
    /// is running right now.
    func cleanStaleStaging(olderThan minimumAge: TimeInterval) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: stagingRootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-minimumAge)
        for item in contents {
            let values = try? item.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey])
            let touchedAt = max(
                values?.contentModificationDate ?? .distantPast,
                values?.creationDate ?? .distantPast
            )
            guard touchedAt < cutoff else { continue }
            try? FileManager.default.removeItem(at: item)
        }
    }

    // MARK: - Committing

    /// Atomically publishes a verified staged binary and its record. A failure
    /// at any step leaves the previous install exactly as it was.
    func commit(stagedExecutable: URL, record: CloudflaredInstallRecord) throws {
        try createOwnerOnlyDirectory(rootDirectory)
        try createOwnerOnlyDirectory(binaryDirectory)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: stagedExecutable.path)

        let previousRecordData = try? Data(contentsOf: recordURL)
        do {
            if FileManager.default.fileExists(atPath: binaryURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    binaryURL,
                    withItemAt: stagedExecutable,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: stagedExecutable, to: binaryURL)
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: binaryURL.path)
        } catch {
            throw CloudflaredInstallStoreError.commitFailed(error.localizedDescription)
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: recordURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recordURL.path)
        } catch {
            // An unrecorded binary can never be proven again, so roll back
            // rather than leave one behind.
            try? FileManager.default.removeItem(at: binaryURL)
            if let previousRecordData {
                try? previousRecordData.write(to: recordURL, options: [.atomic])
            }
            throw CloudflaredInstallStoreError.commitFailed(error.localizedDescription)
        }
    }

    /// Moves a copy that failed its check out of the launch path. The record
    /// goes with it so the app reports "not installed" rather than pretending.
    func quarantineInstalled(reason: String) {
        guard FileManager.default.fileExists(atPath: binaryURL.path)
            || FileManager.default.fileExists(atPath: recordURL.path) else {
            return
        }
        try? createOwnerOnlyDirectory(rootDirectory)
        try? createOwnerOnlyDirectory(quarantineDirectory)
        let stamp = UUID().uuidString
        let destination = quarantineDirectory.appendingPathComponent(stamp, isDirectory: true)
        try? createOwnerOnlyDirectory(destination)
        if FileManager.default.fileExists(atPath: binaryURL.path) {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: binaryURL.path
            )
            try? FileManager.default.moveItem(
                at: binaryURL,
                to: destination.appendingPathComponent(Self.binaryName)
            )
        }
        try? FileManager.default.removeItem(at: recordURL)
        try? Data(reason.utf8).write(to: destination.appendingPathComponent("reason.txt"), options: [.atomic])
    }

    /// Deletes only MacRemote's own helper folder. The guard is deliberate: a
    /// misconfigured root must fail loudly instead of removing something else.
    func remove() throws {
        guard rootDirectory.lastPathComponent == Self.directoryName else {
            throw CloudflaredInstallStoreError.unsafeLocation(
                "the helper folder must be named \(Self.directoryName)"
            )
        }
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return }
        try FileManager.default.removeItem(at: rootDirectory)
    }

    // MARK: - Helpers

    static func sha256(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func createOwnerOnlyDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            return
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// `install.json` decides which bytes the app expects, so it has to be as
    /// well protected as the binary: this user's own file, mode 600, nothing
    /// else.
    private func checkInstallRecordFile() throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: recordURL.path)
        } catch {
            throw CloudflaredInstallStoreError.unsafeLocation("install.json is missing")
        }
        if (attributes[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw CloudflaredInstallStoreError.unsafeLocation("install.json is a symbolic link")
        }
        guard (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw CloudflaredInstallStoreError.unsafeLocation("install.json is not a regular file")
        }
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CloudflaredInstallStoreError.unsafePermissions("install.json is owned by another user")
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        guard permissions == 0o600 else {
            throw CloudflaredInstallStoreError.unsafePermissions(
                "install.json expected mode 600, found \(String(format: "%o", permissions))"
            )
        }
    }

    private func checkOwnerOnlyDirectory(_ url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw CloudflaredInstallStoreError.unsafeLocation("\(url.lastPathComponent) is missing")
        }
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw CloudflaredInstallStoreError.unsafeLocation("\(url.lastPathComponent) is not a folder")
        }
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
            throw CloudflaredInstallStoreError.unsafePermissions("\(url.lastPathComponent) is owned by another user")
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.int16Value ?? 0
        guard permissions == 0o700 else {
            throw CloudflaredInstallStoreError.unsafePermissions(
                "\(url.lastPathComponent) expected mode 700, found \(String(format: "%o", permissions))"
            )
        }
    }
}
