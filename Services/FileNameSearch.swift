import CoreServices
import Darwin
import Foundation

/// Finds files and folders by name for the Find Files tool.
///
/// There are two ways to search because neither is enough alone. Walking a
/// folder is exact and sees hidden files, but a whole disk holds millions of
/// entries and cannot be walked within one call. Spotlight answers for a whole
/// disk at once, but only knows the files it has indexed.
struct FileNameSearch: Sendable {
    /// What kinds of entries a search returns.
    enum Kind: String, Sendable {
        case any
        case file
        case directory
    }

    struct Match: Sendable, Equatable {
        let path: String
        /// "file", "directory", "symlink", or "other".
        let type: String
        let sizeBytes: Int64?
        let modified: Date
    }

    struct Outcome: Sendable, Equatable {
        var matches: [Match]
        /// Why the search stopped before it had seen everything, or nil when
        /// the result is complete: "max_results" or "time_limit".
        var stoppedEarly: String?
    }

    /// Asks Spotlight for paths whose name matches a pattern, inside the given
    /// folders. Tests replace it, because Spotlight does not index the
    /// temporary folders tests run in.
    typealias SpotlightLookup = @Sendable (_ pattern: String, _ folders: [String], _ limit: Int) -> [String]

    let policy: FileTransferPathPolicy
    let name: String
    let kind: Kind
    let limit: Int

    /// Plain text matches any name that contains it. Text with `*` or `?` is
    /// a wildcard pattern that must match the whole name. Both ignore case.
    private var isWildcard: Bool {
        name.contains("*") || name.contains("?")
    }

    func matches(fileName: String) -> Bool {
        if isWildcard {
            // The same Unicode form on both sides: `fnmatch` compares bytes,
            // and the file system may store an accented name either way.
            return fnmatch(
                name.precomposedStringWithCanonicalMapping,
                fileName.precomposedStringWithCanonicalMapping,
                FNM_CASEFOLD
            ) == 0
        }
        return fileName.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Walking a folder

    /// Walks `root` and everything under it. Protected locations are skipped
    /// whole, and symbolic links are reported but never followed, so the walk
    /// cannot leave the folder it was given. `shouldStop` is asked at every
    /// folder and every few thousand entries, for the deadline and for
    /// cancellation.
    ///
    /// The walk goes level by level and reads the folders of one level on a
    /// few threads at once. Nearly all the time goes to the file system, and
    /// one thread needed twenty seconds for a folder that six read in four.
    func walk(root: String, shouldStop: @escaping @Sendable () -> Bool) -> Outcome {
        let progress = WalkProgress()
        let workers = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount))
        var level = [root]
        while !level.isEmpty, !progress.isStopped {
            if shouldStop() {
                progress.stop("time_limit")
                break
            }
            let folders = level
            progress.startLevel()
            DispatchQueue.concurrentPerform(iterations: min(workers, folders.count)) { _ in
                // Each thread takes the next unread folder, so one huge folder
                // does not leave the other threads idle.
                while !progress.isStopped, let index = progress.claimNext(below: folders.count) {
                    if shouldStop() {
                        progress.stop("time_limit")
                        return
                    }
                    read(folder: folders[index], into: progress, shouldStop: shouldStop)
                }
            }
            level = progress.takeNextLevel()
        }
        let result = progress.result()
        return Outcome(matches: Array(Self.sorted(result.matches).prefix(limit)), stoppedEarly: result.stoppedEarly)
    }

    /// Reads one folder: collects its matches and the folders below it.
    private func read(folder: String, into progress: WalkProgress, shouldStop: () -> Bool) {
        let prefix = folder == "/" ? "/" : folder + "/"
        var found: [Match] = []
        var subfolders: [String] = []
        var seen = 0
        Self.forEachEntry(inDirectory: folder) { entry in
            seen += 1
            if seen % 4096 == 0, shouldStop() {
                progress.stop("time_limit")
                return false
            }
            guard !policy.isProtectedEntry(device: entry.device, inode: entry.inode) else {
                return true
            }
            if entry.type == "directory" {
                subfolders.append(prefix + entry.name)
            }
            if accepts(name: entry.name, type: entry.type) {
                found.append(Match(
                    path: prefix + entry.name,
                    type: entry.type,
                    sizeBytes: entry.type == "file" ? entry.size : nil,
                    modified: entry.modified
                ))
            }
            return true
        }
        progress.add(matches: found, subfolders: subfolders, limit: limit)
    }

    /// What the threads of one walk share: the matches so far, the folders of
    /// the next level, and why the walk stopped, if it did.
    private final class WalkProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var matches: [Match] = []
        private var nextLevel: [String] = []
        private var nextIndex = 0
        private var stoppedEarly: String?

        func startLevel() {
            lock.withLock { nextIndex = 0 }
        }

        func claimNext(below count: Int) -> Int? {
            lock.withLock {
                guard nextIndex < count else { return nil }
                defer { nextIndex += 1 }
                return nextIndex
            }
        }

        var isStopped: Bool {
            lock.withLock { stoppedEarly != nil }
        }

        /// The first reason wins: a walk that hit the result limit did not
        /// also run out of time.
        func stop(_ reason: String) {
            lock.withLock { stoppedEarly = stoppedEarly ?? reason }
        }

        func add(matches found: [Match], subfolders: [String], limit: Int) {
            lock.withLock {
                matches += found
                nextLevel += subfolders
                if matches.count >= limit {
                    stoppedEarly = stoppedEarly ?? "max_results"
                }
            }
        }

        func takeNextLevel() -> [String] {
            lock.withLock {
                defer { nextLevel = [] }
                return nextLevel
            }
        }

        func result() -> (matches: [Match], stoppedEarly: String?) {
            lock.withLock { (matches, stoppedEarly) }
        }
    }

    /// One directory entry with the attributes a search needs.
    private struct Entry {
        let name: String
        let type: String
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let modified: Date
    }

    /// Reads a directory with `getattrlistbulk`, which returns every entry
    /// together with its attributes in a few system calls. Asking for each
    /// entry's attributes one at a time took over a minute on a folder with a
    /// million and a half files; this takes a few seconds. `body` returns
    /// false to stop early. A folder that cannot be opened is skipped.
    private static func forEachEntry(inDirectory path: String, _ body: (Entry) -> Bool) {
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        let name = attrgroup_t(ATTR_CMN_NAME)
        let device = attrgroup_t(ATTR_CMN_DEVID)
        let objectType = attrgroup_t(ATTR_CMN_OBJTYPE)
        let modified = attrgroup_t(ATTR_CMN_MODTIME)
        let fileID = attrgroup_t(ATTR_CMN_FILEID)
        let dataLength = attrgroup_t(ATTR_FILE_DATALENGTH)
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | name | device | objectType | modified | fileID
        request.fileattr = dataLength

        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(descriptor, &request, buffer, capacity, 0)
            guard count > 0 else { return }
            var record = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                // Each record starts with its own length, then says which of
                // the requested attributes follow, in a fixed order. They are
                // packed on four-byte boundaries, hence the unaligned loads.
                let length = Int(record.loadUnaligned(as: UInt32.self))
                var field = record + MemoryLayout<UInt32>.size
                record += length
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // Without a name and an identity the entry can be neither
                // matched nor checked against the protected locations.
                let required = name | device | objectType | fileID
                guard returned.commonattr & required == required else { continue }

                let nameReference = field.loadUnaligned(as: attrreference_t.self)
                let entryName = String(
                    validatingCString: (field + Int(nameReference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                )
                field += MemoryLayout<attrreference_t>.size
                let entryDevice = field.loadUnaligned(as: dev_t.self)
                field += MemoryLayout<dev_t>.size
                let entryType = field.loadUnaligned(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size
                var entryModified = timespec()
                if returned.commonattr & modified != 0 {
                    entryModified = field.loadUnaligned(as: timespec.self)
                    field += MemoryLayout<timespec>.size
                }
                let entryInode = field.loadUnaligned(as: UInt64.self)
                field += MemoryLayout<UInt64>.size
                let entrySize = returned.fileattr & dataLength != 0 ? field.loadUnaligned(as: off_t.self) : 0

                guard let entryName else { continue }
                let entry = Entry(
                    name: entryName,
                    type: typeName(forVnodeType: entryType),
                    device: entryDevice,
                    inode: ino_t(entryInode),
                    size: entrySize,
                    modified: date(entryModified)
                )
                guard body(entry) else { return }
            }
        }
    }

    /// The kernel's file type numbers (`enum vtype`): 1 is a regular file, 2 a
    /// directory, 5 a symbolic link.
    private static func typeName(forVnodeType type: fsobj_type_t) -> String {
        switch type {
        case 1: "file"
        case 2: "directory"
        case 5: "symlink"
        default: "other"
        }
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000)
    }

    // MARK: - Asking Spotlight

    /// Searches every folder File Transfer reaches through Spotlight, then
    /// keeps only results the path policy allows: Spotlight knows nothing
    /// about the protected locations.
    func spotlight(lookup: SpotlightLookup) -> Outcome {
        let folders = policy.reachesWholeMac ? ["/"] : policy.allowedFolders
        // Ask for more than the limit, because some results are filtered out.
        let candidateLimit = min(limit * 10, 5000)
        let candidates = lookup(Self.spotlightPattern(for: name, isWildcard: isWildcard), folders, candidateLimit)

        var matches: [Match] = []
        for candidate in candidates {
            guard let path = try? policy.resolveUserPath(candidate) else { continue }
            var status = stat()
            guard lstat(path, &status) == 0 else { continue }
            let match = Self.match(path: path, status: status)
            if accepts(match) {
                matches.append(match)
            }
        }
        matches = Self.sorted(matches)
        let cutShort = matches.count > limit || candidates.count >= candidateLimit
        return Outcome(matches: Array(matches.prefix(limit)), stoppedEarly: cutShort ? "max_results" : nil)
    }

    /// The pattern in Spotlight's query syntax, where `*` is the only wildcard
    /// and `\` escapes. `?` becomes `*`; `matches(fileName:)` then applies the
    /// exact rule to each result.
    static func spotlightPattern(for name: String, isWildcard: Bool) -> String {
        var pattern = ""
        for character in name {
            switch character {
            case "\\", "\"", "'":
                pattern += "\\" + String(character)
            case "*" where isWildcard, "?" where isWildcard:
                pattern += "*"
            case "*":
                pattern += "\\*"
            default:
                pattern.append(character)
            }
        }
        return isWildcard ? pattern : "*" + pattern + "*"
    }

    /// The real Spotlight lookup: a synchronous metadata query on file names.
    static let systemSpotlight: SpotlightLookup = { pattern, folders, limit in
        let text = "kMDItemFSName == \"\(pattern)\"cd" as CFString
        guard let query = MDQueryCreate(kCFAllocatorDefault, text, nil, nil) else { return [] }
        MDQuerySetSearchScope(query, folders as CFArray, 0)
        MDQuerySetMaxCount(query, limit)
        guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
        var paths: [String] = []
        for index in 0..<MDQueryGetResultCount(query) {
            guard let raw = MDQueryGetResultAtIndex(query, index) else { continue }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            if let path = MDItemCopyAttribute(item, kMDItemPath) as? String {
                paths.append(path)
            }
        }
        return paths
    }

    // MARK: - Shared

    private func accepts(name: String, type: String) -> Bool {
        switch kind {
        case .any: break
        case .file: guard type == "file" else { return false }
        case .directory: guard type == "directory" else { return false }
        }
        return matches(fileName: name)
    }

    private func accepts(_ match: Match) -> Bool {
        accepts(name: (match.path as NSString).lastPathComponent, type: match.type)
    }

    private static func match(path: String, status: stat) -> Match {
        let type: String
        switch status.st_mode & S_IFMT {
        case S_IFREG: type = "file"
        case S_IFDIR: type = "directory"
        case S_IFLNK: type = "symlink"
        default: type = "other"
        }
        return Match(
            path: path,
            type: type,
            sizeBytes: type == "file" ? Int64(status.st_size) : nil,
            modified: date(status.st_mtimespec)
        )
    }

    /// Newest first, so the latest version of a file leads the list; then by
    /// path, so equal dates always come out in the same order.
    private static func sorted(_ matches: [Match]) -> [Match] {
        matches.sorted { ($1.modified, $0.path) < ($0.modified, $1.path) }
    }
}
