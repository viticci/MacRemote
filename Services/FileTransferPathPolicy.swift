import Darwin
import Foundation

/// Decides which paths the built-in File Transfer tools may touch.
///
/// A path is reachable only when it is inside a folder the owner allowed, and
/// never when it is a protected location (keys, keychains, saved credentials,
/// MacRemote's own data), even if an allowed folder contains it. The owner may
/// allow any folder, up to the whole Mac ("/"); the protected locations are
/// then the only limit.
///
/// Both tests compare where a path really is on disk, by file identity, rather
/// than how it is spelled. Spelling is not reliable: APFS ignores letter case,
/// the boot volume is also reachable under `/System/Volumes/Data` and
/// `/Volumes/<name>`, and a path with a missing component cannot be resolved by
/// the system at all.
struct FileTransferPathPolicy: Sendable {
    enum PathError: Error, Equatable {
        case invalidPath
        case pathDenied
    }

    static let allowedFoldersDefaultsKey = "MacRemote.fileTransfer.allowedFolders"

    let homeDirectory: String
    /// Folders the tools may reach, as the owner chose them.
    let allowedFolders: [String]
    /// Where the allowed and protected locations are on disk, read once so a
    /// listing or a search can test thousands of entries cheaply.
    private let allowedIdentities: Set<FileIdentity>
    private let protectedIdentities: Set<FileIdentity>

    /// With no `allowedFolders`, reads the owner's saved choice, falling back to
    /// the everyday document folders.
    init(
        homeDirectory: String? = nil,
        allowedFolders: [String]? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        // The real path, so spelling comparisons against resolved paths agree
        // even when the home folder is reached through a symbolic link.
        let named = homeDirectory ?? ExecutableLocator.homeDirectory
        let home = Self.realPath(named) ?? (named as NSString).standardizingPath
        self.homeDirectory = home
        let allowed = allowedFolders
            ?? userDefaults.stringArray(forKey: Self.allowedFoldersDefaultsKey)
            ?? Self.defaultAllowedFolders(homeDirectory: home)
        self.allowedFolders = allowed
        self.allowedIdentities = Set(allowed.compactMap(Self.identity))
        self.protectedIdentities = Set(Self.protectedLocations(homeDirectory: home).compactMap(Self.identity))
    }

    static func defaultAllowedFolders(homeDirectory: String) -> [String] {
        ["Desktop", "Documents", "Downloads"].map { homeDirectory + "/" + $0 }
    }

    /// Never reachable, whatever the owner allowed: the credential stores of
    /// common tools, MacRemote's own tool registry, and the places where a
    /// written file would later run or change what apps are trusted.
    ///
    /// This list is the only limit once the owner allows the whole Mac. It
    /// cannot name every file that holds a secret, so the app tells the owner
    /// that allowing the whole Mac means trusting every connected app.
    var protectedLocations: [String] {
        Self.protectedLocations(homeDirectory: homeDirectory)
    }

    private static func protectedLocations(homeDirectory: String) -> [String] {
        [
            ".ssh",
            ".gnupg",
            ".aws",
            ".azure",
            ".kube",
            ".docker",
            ".cloudflared",
            ".config/gh",
            ".config/gcloud",
            ".netrc",
            ".npmrc",
            ".pypirc",
            ".codex/auth.json",
            "Library/Keychains",
            "Library/LaunchAgents",
            "Library/Preferences",
            "Library/Application Support/MacRemote"
        ].map { homeDirectory + "/" + $0 }
    }

    /// True when the owner allowed the whole Mac, so only the protected
    /// locations are out of reach.
    var reachesWholeMac: Bool {
        Self.identity("/").map(allowedIdentities.contains) ?? false
    }

    /// Why a folder cannot be added to the allowed list, or nil when it can.
    /// Any folder that exists can be added, the whole Mac included: how far
    /// File Transfer reaches is the owner's choice. Only a protected location
    /// is refused.
    func reasonFolderCannotBeAllowed(_ folder: String) -> String? {
        guard let canonical = try? canonicalize(folder), isDirectory(canonical.path) else {
            return "Choose a folder that exists."
        }
        if isProtected(canonical) {
            return "MacRemote never shares this folder."
        }
        return nil
    }

    /// Returns the real path for `rawPath`, or throws when it is not absolute,
    /// climbs with `..`, lies outside every allowed folder, or is protected.
    func resolveUserPath(_ rawPath: String) throws -> String {
        let canonical = try canonicalize(rawPath)
        guard !isProtected(canonical), isAllowed(canonical) else {
            throw PathError.pathDenied
        }
        return canonical.path
    }

    /// The allowed folders as the owner would write them, for messages that
    /// tell a calling app where it may go instead of leaving it to probe.
    var allowedFoldersDescription: String {
        if reachesWholeMac {
            return "the whole Mac"
        }
        let folders = allowedFolders.map {
            $0.hasPrefix(homeDirectory + "/") ? "~" + $0.dropFirst(homeDirectory.count) : $0
        }
        return folders.isEmpty ? "none" : folders.joined(separator: ", ")
    }

    /// Checks a value an app supplied to a tool that runs without asking. Such
    /// a tool may only be pointed at files inside the allowed folders, or one
    /// "read-only" command would read any file on the Mac unasked.
    ///
    /// The app cannot know which values a program treats as paths, so the rule
    /// is by shape: an absolute path must be reachable, and a value with a
    /// `..` component is refused because it could climb out of the empty
    /// folder these tools run in. Any other value names nothing outside it.
    func requireReachable(pathLikeValue value: String) throws {
        if value.split(separator: "/", omittingEmptySubsequences: false).contains("..") {
            throw PathError.invalidPath
        }
        if value.hasPrefix("/") {
            _ = try resolveUserPath(value)
        }
    }

    /// True when `path` is a protected location or inside one. Directory
    /// listings use this to leave protected entries out.
    func isProtected(path: String) -> Bool {
        guard let canonical = try? canonicalize(path) else { return true }
        return isProtected(canonical)
    }

    /// True when the file or folder with this identity is itself a protected
    /// location. A search that walks a tree asks this for each entry it meets
    /// and never steps into one, so it needs no check of the folders above.
    func isProtectedEntry(device: dev_t, inode: ino_t) -> Bool {
        protectedIdentities.contains(FileIdentity(device: device, inode: inode))
    }

    /// True when a protected location sits inside `directory`, so archiving the
    /// whole directory would carry protected files out with it.
    func containsProtectedFolder(_ directory: String) -> Bool {
        guard let canonical = try? canonicalize(directory) else { return true }
        return protectedLocations.contains { protected in
            // The home folder is also reachable under the data volume's own
            // mount point, whose top folders are not above `/Users` by name.
            [protected, Self.dataVolume + protected].contains { route in
                Self.ancestors(of: route).dropFirst().contains { Self.sameLocation($0, canonical.path) }
            } || Self.hasPathPrefix(protected, canonical.path)
        }
    }

    /// Where macOS mounts the volume that holds user data. Everything under
    /// `/Users` is on it and can be named through it.
    private static let dataVolume = "/System/Volumes/Data"

    // MARK: - Resolution

    private struct CanonicalPath {
        /// The real path: the deepest part that exists, resolved by the system,
        /// plus any trailing components that do not exist yet.
        let path: String
        /// The part of `path` that exists.
        let existingPath: String
    }

    private func canonicalize(_ rawPath: String) throws -> CanonicalPath {
        let expanded = expandTilde(in: rawPath)
        guard expanded.hasPrefix("/"), !expanded.utf8.contains(0) else {
            throw PathError.invalidPath
        }
        var components = expanded.split(separator: "/").map(String.init).filter { $0 != "." }
        // Refused outright. `x/..` behind a missing component is how a path
        // used to slip past resolution while still naming an existing file.
        guard !components.contains("..") else {
            throw PathError.invalidPath
        }

        var missing: [String] = []
        while true {
            let candidate = "/" + components.joined(separator: "/")
            if let real = Self.realPath(candidate) {
                let full = missing.isEmpty
                    ? real
                    : (real == "/" ? "" : real) + "/" + missing.joined(separator: "/")
                return CanonicalPath(path: full, existingPath: real)
            }
            guard let last = components.popLast() else {
                throw PathError.invalidPath
            }
            missing.insert(last, at: 0)
        }
    }

    private func isAllowed(_ canonical: CanonicalPath) -> Bool {
        Self.ancestors(of: canonical.existingPath)
            .contains { Self.identity($0).map(allowedIdentities.contains) ?? false }
    }

    private func isProtected(_ canonical: CanonicalPath) -> Bool {
        // By identity for what exists; by spelling for a protected location
        // that would be created by this very call.
        Self.ancestors(of: canonical.existingPath)
            .contains { Self.identity($0).map(protectedIdentities.contains) ?? false }
            || protectedLocations.contains { Self.hasPathPrefix(canonical.path, $0) }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func expandTilde(in path: String) -> String {
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst())
        }
        return path
    }

    // MARK: - Path primitives

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `path` and every folder above it, nearest first.
    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var current = (path as NSString).standardizingPath
        while true {
            result.append(current)
            guard current != "/" else { return result }
            current = (current as NSString).deletingLastPathComponent
        }
    }

    /// Which file or folder a path is on disk, whatever it is called.
    private struct FileIdentity: Hashable, Sendable {
        let device: dev_t
        let inode: ino_t
    }

    private static func identity(_ path: String) -> FileIdentity? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return FileIdentity(device: info.st_dev, inode: info.st_ino)
    }

    /// True when both paths exist and are the same file or folder on disk.
    private static func sameLocation(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = identity(lhs), let right = identity(rhs) else { return false }
        return left == right
    }

    /// Spelling comparison that ignores case and Unicode composition, as the
    /// default macOS file system does.
    private static func hasPathPrefix(_ path: String, _ prefix: String) -> Bool {
        let path = path.precomposedStringWithCanonicalMapping.lowercased()
        let prefix = prefix.precomposedStringWithCanonicalMapping.lowercased()
        return path == prefix || path.hasPrefix(prefix + "/")
    }
}
