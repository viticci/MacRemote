import Darwin
import Foundation

/// A skill read from a skills folder on this Mac (SPEC D84), as the scanner
/// found it. `Skill(found:tools:)` adds MacRemote's note when the registry
/// builds it from the family's current tools.
struct FoundSkill: Hashable, Sendable {
    let familyID: String
    let source: FoundSkillSource
    /// The skill's real folder, links resolved.
    let folder: String
    /// Its frontmatter `name`, or the folder's name when the header is unreadable.
    let name: String
    let frontmatter: [String: JSONValue]
    /// `SKILL.md` first, then the Markdown files in `references/`. Empty when refused.
    let files: [Skill.File]
    let refusal: String?
}

/// Finds skills already on this Mac for the tool families MacRemote has
/// (SPEC D84), so a skill written for a CLI or MCP server the owner uses can
/// travel with that tool's MacRemote tools.
///
/// It looks in four places and nowhere else: `~/.claude/skills`,
/// `~/.codex/skills`, `~/.agents/skills`, and the newest version of each
/// Claude Code plugin under `~/.claude/plugins/cache`. A skill counts only when
/// its folder name, its frontmatter `name`, or its plugin's name matches one
/// of a family's names (`ToolFamily.skillMatchKeys`). Any other skill is
/// passed over as soon as it fails to match: never kept, logged, or shown.
///
/// Like every scanner it runs nothing and opens no connection
/// (CLI-DISCOVERY-SPEC R1, R2). A skill folder may be a link: the scanner
/// resolves it, then reads only `SKILL.md` and the Markdown files directly in
/// its `references` folder, opening each without following a link, so it
/// never reads outside that folder. Folders in protected locations
/// (`FileTransferPathPolicy.isProtected(path:)`) are skipped.
struct FoundSkillScanner: Sendable {
    /// A tool family as the scanner matches it.
    struct Family: Sendable {
        let id: String
        let keys: Set<String>
    }

    private struct Location {
        let skillsFolder: String
        let source: FoundSkillSource
        /// The plugin's match key, for plugin skills.
        let pluginKey: String?
    }

    let homeDirectory: String

    /// Enough of a SKILL.md to find its `name` when the folder name does not match.
    static let headerReadBytes = 8_192

    /// The families of `tools` a skill can belong to, in a fixed order.
    static func families(of tools: [ToolDefinition]) -> [Family] {
        Dictionary(grouping: tools) { ToolFamily($0).id }
            .compactMap { id, familyTools in
                let keys = ToolFamily.skillMatchKeys(of: familyTools)
                return keys.isEmpty ? nil : Family(id: id, keys: keys)
            }
            .sorted { $0.id < $1.id }
    }

    /// Every matching skill, each read once even when several folders link to it.
    func scan(families: [Family]) -> [FoundSkill] {
        guard !families.isEmpty else { return [] }
        var familyByKey = [String: String]()
        for family in families {
            for key in family.keys where familyByKey[key] == nil {
                familyByKey[key] = family.id
            }
        }
        let policy = FileTransferPathPolicy(homeDirectory: homeDirectory, allowedFolders: [])
        var readFolders = Set<String>()
        var found = [FoundSkill]()
        for location in locations() {
            for entry in Self.entries(in: location.skillsFolder) {
                guard let folder = Self.realDirectory(location.skillsFolder + "/" + entry),
                      !readFolders.contains(folder),
                      !policy.isProtected(path: folder) else {
                    continue
                }
                let familyID = location.pluginKey.flatMap { familyByKey[$0] }
                    ?? familyByKey[ToolFamily.skillMatchKey(entry)]
                    ?? Self.readRegularFile(folder + "/" + Skill.skillFileName, limit: Self.headerReadBytes)
                        .flatMap { Self.declaredName($0.data) }
                        .flatMap { familyByKey[ToolFamily.skillMatchKey($0)] }
                guard let familyID else { continue }
                readFolders.insert(folder)
                found.append(Self.read(folder: folder, entry: entry, familyID: familyID, source: location.source))
            }
        }
        return found
    }

    private func locations() -> [Location] {
        var locations = [
            Location(skillsFolder: homeDirectory + "/.claude/skills", source: .claudeSkills, pluginKey: nil),
            Location(skillsFolder: homeDirectory + "/.codex/skills", source: .codexSkills, pluginKey: nil),
            Location(skillsFolder: homeDirectory + "/.agents/skills", source: .agentSkills, pluginKey: nil)
        ]
        let cache = homeDirectory + "/.claude/plugins/cache"
        for marketplace in Self.entries(in: cache) {
            for plugin in Self.entries(in: cache + "/" + marketplace) {
                let pluginFolder = cache + "/" + marketplace + "/" + plugin
                guard let version = Self.newestVersion(in: pluginFolder) else { continue }
                locations.append(Location(
                    skillsFolder: pluginFolder + "/" + version + "/skills",
                    source: .claudePlugin(plugin),
                    pluginKey: ToolFamily.skillMatchKey(plugin)
                ))
            }
        }
        return locations
    }

    // MARK: Reading one skill

    /// Reads a matching skill's files and header. A skill that fails a check
    /// is kept with a reason and no files, so the owner sees why.
    private static func read(folder: String, entry: String, familyID: String, source: FoundSkillSource) -> FoundSkill {
        var displayName = entry
        func refused(_ reason: String) -> FoundSkill {
            FoundSkill(
                familyID: familyID,
                source: source,
                folder: folder,
                name: displayName,
                frontmatter: [:],
                files: [],
                refusal: reason
            )
        }
        // One byte past the limit, so a file that grew after `fstat` is still caught.
        let limit = Skill.maximumFileBytes + 1
        guard let main = readRegularFile(folder + "/" + Skill.skillFileName, limit: limit) else {
            return refused("Its SKILL.md can't be read.")
        }
        if let declared = declaredName(main.data), Skill.isValidName(declared) {
            displayName = declared
        }
        let names = referenceFileNames(in: folder)
        guard names.count < MCPUpstreamSkillCollector.maximumFilesPerSkill else {
            return refused(
                "It has \((names.count + 1).formatted()) files; a skill can have at most \(MCPUpstreamSkillCollector.maximumFilesPerSkill.formatted())."
            )
        }
        var sizes = [(path: Skill.skillFileName, bytes: main.size)]
        var references = [Skill.File]()
        for name in names {
            let path = "references/" + name
            var info = stat()
            guard lstat(folder + "/" + path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
                return refused("\(path) is a link. MacRemote reads only files inside the skill's folder.")
            }
            guard let file = readRegularFile(folder + "/" + path, limit: limit),
                  let encoded = name.addingPercentEncoding(withAllowedCharacters: Self.pathSegmentAllowed) else {
                return refused("\(path) can't be read.")
            }
            sizes.append((path, file.size))
            references.append(Skill.File(path: "references/" + encoded, data: file.data, mediaType: "text/markdown"))
        }
        if let reason = Skill.sizeRefusal(sizes) {
            return refused(reason)
        }
        guard let text = String(validating: main.data, as: UTF8.self) else {
            return refused("SKILL.md is not UTF-8 text.")
        }
        let header: SkillFrontmatter
        switch SkillFrontmatter.parse(text) {
        case .success(let parsed):
            header = parsed
        case .failure(let refusal):
            return refused(refusal.reason)
        }
        guard let name = header.name, Skill.isValidName(name) else {
            return refused("Its header has no valid skill name.")
        }
        displayName = name
        guard let description = header.description, (1...1024).contains(description.count) else {
            return refused("Its header needs a description of 1 to 1,024 characters.")
        }
        return FoundSkill(
            familyID: familyID,
            source: source,
            folder: folder,
            name: name,
            frontmatter: header.fields,
            files: [Skill.File(path: Skill.skillFileName, data: main.data, mediaType: "text/markdown")] + references,
            refusal: nil
        )
    }

    /// The Markdown files directly in the skill's `references` folder, by
    /// name: every visible entry whose name ends in `.md` in any case, and
    /// that is not a folder. The caller refuses the skill when one of them
    /// can't be read, so a skill is never served without a reference it
    /// has. A linked `references` folder is passed over.
    private static func referenceFileNames(in folder: String) -> [String] {
        var info = stat()
        let references = folder + "/references"
        guard lstat(references, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return [] }
        return entries(in: references).filter { name in
            name.lowercased().hasSuffix(".md")
                && !(lstat(references + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR)
        }
    }

    /// The characters a file name keeps in a served `skill://` address; any
    /// other is percent-encoded, so `Search Options.md` is served as
    /// `Search%20Options.md` and `resources/read` matches it exactly.
    private static let pathSegmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    /// The `name` the exact header reader (`SkillFrontmatter`) reads from the
    /// start of a SKILL.md, or nil when there is none or the header is outside
    /// what that reader accepts. It decides whether the skill is read at all;
    /// the full read then decides whether it can be shared.
    private static func declaredName(_ data: Data) -> String? {
        guard case .success(let header) = SkillFrontmatter.parse(String(decoding: data, as: UTF8.self)) else {
            return nil
        }
        return header.name
    }

    // MARK: File system

    /// The visible names in a folder, sorted; none when it cannot be listed.
    private static func entries(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    /// The real path of a folder, through any link, or nil when it is not one.
    private static func realDirectory(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        let real = String(cString: resolved)
        var info = stat()
        guard stat(real, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return real
    }

    /// A plugin's newest version folder: the highest semantic version when
    /// every folder name is one (`2.1.0` beats `2.1.0-beta.1`), otherwise the
    /// one changed last.
    private static func newestVersion(in pluginFolder: String) -> String? {
        let versions = entries(in: pluginFolder).filter { realDirectory(pluginFolder + "/" + $0) != nil }
        let parsed = versions.compactMap { name in SemanticVersion(name).map { ($0, name) } }
        if parsed.count == versions.count {
            return parsed.max { ($0.0, $0.1) < ($1.0, $1.1) }?.1
        }
        func modified(_ version: String) -> Date {
            let attributes = try? FileManager.default.attributesOfItem(atPath: pluginFolder + "/" + version)
            return attributes?[.modificationDate] as? Date ?? .distantPast
        }
        return versions.max { (modified($0), $0) < (modified($1), $1) }
    }

    /// The first `limit` bytes of a regular file and its size, the larger of
    /// its size on disk and what was read. The last path component is opened
    /// without following a link, and a pipe or device is refused, so a read
    /// can neither leave the folder nor block.
    private static func readRegularFile(_ path: String, limit: Int) -> (data: Data, size: Int)? {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              let data = try? handle.read(upToCount: limit) ?? Data() else {
            return nil
        }
        return (data, max(Int(info.st_size), data.count))
    }
}

/// A plugin version folder's name read as a semantic version: dotted
/// numbers, an optional `-` pre-release, and an optional `+` build, which is
/// ignored. A release ranks above its own pre-releases; missing numbers
/// count as 0, so `1.10` equals `1.10.0`.
private struct SemanticVersion: Comparable {
    let numbers: [Int]
    let prerelease: [Substring]

    init?(_ text: String) {
        guard let match = text.wholeMatch(
            of: /([0-9]+(?:\.[0-9]+)*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?/
        ) else { return nil }
        let parts = match.1.split(separator: ".")
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        var trimmed = numbers
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        self.numbers = trimmed
        self.prerelease = match.2?.split(separator: ".") ?? []
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers {
            let width = max(lhs.numbers.count, rhs.numbers.count)
            let pad = { (numbers: [Int]) in numbers + Array(repeating: 0, count: width - numbers.count) }
            return pad(lhs.numbers).lexicographicallyPrecedes(pad(rhs.numbers))
        }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        // SemVer: numeric identifiers compare as numbers and rank below
        // words; words compare in ASCII order; a shorter list ranks lower.
        for (left, right) in zip(lhs.prerelease, rhs.prerelease) where left != right {
            switch (number(left), number(right)) {
            case let (left?, right?): return left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return left < right
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    private static func number(_ identifier: Substring) -> Int? {
        identifier.allSatisfy(\.isASCIIDigit) ? Int(identifier) : nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

extension ToolFamily {
    /// A name reduced for matching a skill to a family: lowercase ASCII
    /// letters and digits only, so `RemCTL`, `remctl`, and `rem-ctl` agree.
    static func skillMatchKey(_ name: String) -> String {
        String(String.UnicodeScalarView(name.lowercased().unicodeScalars.filter {
            ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }))
    }

    /// The names a skill on this Mac can carry to belong to the family of
    /// `tools` (SPEC D84): its executable's name, a bridged server's name, and,
    /// when either names a first-party provider, all of that provider's
    /// executable names. File Transfer has none.
    static func skillMatchKeys(of tools: [ToolDefinition]) -> Set<String> {
        var keys = Set<String>()
        for tool in tools {
            if tool.isMCPBridge {
                if let server = tool.mcpBridgeServerName {
                    keys.insert(skillMatchKey(server))
                }
            } else if tool.backend != .native {
                keys.insert(skillMatchKey((tool.executablePath as NSString).lastPathComponent))
            }
        }
        keys.remove("")
        for provider in FirstPartyMCPProviderCatalog.providers {
            let names = provider.executableNames.map(skillMatchKey)
            if !keys.isDisjoint(with: names + [skillMatchKey(provider.name), skillMatchKey(provider.serverName)]) {
                keys.formUnion(names)
            }
        }
        return keys
    }

    /// The command a found skill's note tells the model to run: a first-party
    /// provider's executable, else the server's name, else the executable's.
    static func skillCommandName(of tools: [ToolDefinition]) -> String {
        let ordered = tools.sorted { $0.id < $1.id }
        if let server = ordered.lazy.compactMap(\.mcpBridgeServerName).first {
            let key = skillMatchKey(server)
            let provider = FirstPartyMCPProviderCatalog.providers.first {
                skillMatchKey($0.name) == key || skillMatchKey($0.serverName) == key
            }
            return provider?.executableNames.first ?? server
        }
        if let process = ordered.first(where: { !$0.isMCPBridge && $0.backend != .native }) {
            return (process.executablePath as NSString).lastPathComponent
        }
        return ordered.first.map { ToolFamily($0).name } ?? ""
    }
}
