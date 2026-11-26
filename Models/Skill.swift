import Foundation

/// One skill MacRemote knows (SPEC D84): instructions for an assistant, in the
/// Agent Skills format, that the server can offer through the MCP Skills
/// extension once the owner shares it.
///
/// A skill is checked once, when it is built from its source. After that the
/// server trusts it and only reads from it. A skill that failed a check keeps
/// its `refusal` and no files, so the owner can see why it is not offered.
struct Skill: Identifiable, Hashable, Sendable {
    enum Origin: Hashable, Sendable {
        /// Shipped inside MacRemote (`Resources/Skills`).
        case builtIn
        /// Read from a bridged MCP server that declares the Skills extension.
        /// `familyID` is the server's `ToolFamily.id`; `uri` is the skill's
        /// SKILL.md address on that server.
        case bridgedServer(familyID: String, serverName: String, uri: String)
        /// Found in a skills folder on this Mac for a tool family MacRemote
        /// has. `folder` is the skill's real folder, links resolved.
        case foundOnDisk(familyID: String, source: FoundSkillSource, folder: String)
    }

    struct File: Codable, Hashable, Sendable {
        /// Relative to the skill's folder, with `/`, as its served address
        /// spells it: a character an address can't hold is percent-encoded.
        /// `SKILL.md` for the main file.
        let path: String
        let data: Data
        let mediaType: String
    }

    /// Claude's limits for a skill from an MCP server. A skill over them does
    /// not load there, so MacRemote refuses it up front.
    static let maximumFileBytes = 100_000
    static let maximumSkillBytes = 400_000
    static let skillFileName = "SKILL.md"

    let origin: Origin
    let name: String
    /// The SKILL.md frontmatter as JSON, exactly as the served file states it.
    let frontmatter: [String: JSONValue]
    /// `SKILL.md` first, then the supporting files. Empty when refused.
    let files: [File]
    /// Why the skill cannot be shared, in words the owner can read.
    let refusal: String?
    /// Why apps don't get the skill even while it is shared, for a reason
    /// the owner fixes elsewhere: none of its family's tools are shared, so
    /// its note would name nothing an app can run. `ServedSkillCatalog`
    /// leaves it out with this reason; `files` then hold the skill as read,
    /// without a note.
    let omission: String?

    /// The stable key for the owner's Shared choice. It names the source and
    /// where the skill sits in it (a server's SKILL.md address, a folder on
    /// this Mac), never the bytes, so a refreshed skill keeps its choice and
    /// two skills with one name never share one.
    var id: String {
        switch origin {
        case .builtIn:
            "builtin:\(name)"
        case .bridgedServer(let familyID, _, let uri):
            "bridge:\(familyID):\(uri)"
        case .foundOnDisk(_, let source, let folder):
            "found:\(source.id):\(folder)"
        }
    }

    /// The tool family the skill belongs to; nil for MacRemote's own.
    var familyID: String? {
        switch origin {
        case .builtIn: nil
        case .bridgedServer(let familyID, _, _), .foundOnDisk(let familyID, _, _): familyID
        }
    }

    /// Where the skill comes from, as a connected app may show it (the
    /// `_meta` origin on a served entry). Nil for MacRemote's own.
    var originName: String? {
        switch origin {
        case .builtIn: nil
        case .bridgedServer(_, let serverName, _): "\(serverName) MCP server"
        case .foundOnDisk(_, let source, _): source.originName
        }
    }

    /// The first segment of the skill's served address; nil for MacRemote's
    /// own, which is served at `skill://<name>/`.
    var uriAuthority: String? {
        switch origin {
        case .builtIn: nil
        case .bridgedServer(_, let serverName, _): Self.slug(serverName)
        case .foundOnDisk(_, let source, _): source.slug
        }
    }

    var description: String {
        if case .string(let text) = frontmatter["description"] { return text }
        return ""
    }

    var byteCount: Int {
        files.reduce(0) { $0 + $1.data.count }
    }

    /// Builds a skill from its files and refuses it when a limit fails.
    init(
        origin: Origin,
        name: String,
        frontmatter: [String: JSONValue],
        files: [File],
        refusal: String? = nil,
        omission: String? = nil
    ) {
        self.origin = origin
        self.name = name
        self.frontmatter = frontmatter
        let reason = refusal ?? Self.limitRefusal(name: name, files: files)
        self.files = reason == nil ? files : []
        self.refusal = reason
        self.omission = reason == nil ? omission : nil
    }

    /// The `omission` of a skill whose family has no shared tool.
    static let noSharedToolsOmission = "None of its tools are shared."

    // MARK: Checks

    /// Agent Skills naming: 1 to 64 of `a-z`, `0-9`, `-`, with no leading,
    /// trailing, or doubled hyphen.
    static func isValidName(_ name: String) -> Bool {
        guard (1...64).contains(name.utf8.count),
              name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
              !name.hasPrefix("-"), !name.hasSuffix("-"), !name.contains("--") else {
            return false
        }
        return true
    }

    /// A relative file path inside a skill folder: no empty, `.`, or `..`
    /// segment, and no leading slash.
    static func isValidRelativePath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return !segments.isEmpty && segments.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// The reason a skill with these sizes cannot load in Claude, or nil.
    static func sizeRefusal(_ sizes: [(path: String, bytes: Int)]) -> String? {
        if let large = sizes.first(where: { $0.bytes > maximumFileBytes }) {
            return "\(large.path) is \(large.bytes.formatted()) bytes; apps load files up to \(maximumFileBytes.formatted()) bytes."
        }
        let total = sizes.reduce(0) { $0 + $1.bytes }
        if total > maximumSkillBytes {
            return "The skill is \(total.formatted()) bytes; apps load skills up to \(maximumSkillBytes.formatted()) bytes."
        }
        return nil
    }

    private static func limitRefusal(name: String, files: [File]) -> String? {
        guard isValidName(name) else {
            return "Its name is not a valid skill name."
        }
        guard files.first?.path == skillFileName else {
            return "It has no SKILL.md."
        }
        if let reason = sizeRefusal(files.map { ($0.path, $0.data.count) }) {
            return reason
        }
        // Served as text, so the bytes must survive a round trip through a
        // string unchanged; the listed digest is over these exact bytes.
        if let binary = files.first(where: { file in
            guard let text = String(validating: file.data, as: UTF8.self) else { return true }
            return Data(text.utf8) != file.data
        }) {
            return "\(binary.path) is not UTF-8 text."
        }
        return nil
    }

    // MARK: Order

    /// The fixed order the server lists shared skills in, and so the order
    /// that decides which of two same-name skills keeps its name: built in
    /// first, then bridged servers by name, then skills found on this Mac.
    static func servingOrder(_ lhs: Skill, _ rhs: Skill) -> Bool {
        lhs.orderKey.lexicographicallyPrecedes(rhs.orderKey)
    }

    private var orderKey: [String] {
        switch origin {
        case .builtIn:
            ["0", name]
        case .bridgedServer(let familyID, let serverName, let uri):
            ["1", serverName.lowercased(), familyID, name, uri]
        case .foundOnDisk(_, let source, let folder):
            ["2", source.id, name, folder]
        }
    }

    // MARK: Built in

    /// MacRemote's own skill, read once from the app's resources.
    static let builtIn: Skill? = {
        guard let url = Bundle.module.url(
            forResource: "SKILL",
            withExtension: "md",
            subdirectory: "Skills/macremote"
        ),
            let data = try? Data(contentsOf: url),
            let text = String(validating: data, as: UTF8.self),
            case .success(let header) = SkillFrontmatter.parse(text),
            let name = header.name else {
            return nil
        }
        return Skill(
            origin: .builtIn,
            name: name,
            frontmatter: header.fields,
            files: [File(path: skillFileName, data: data, mediaType: "text/markdown")]
        )
    }()

    // MARK: Bridged

    /// A bridged server's skill as MacRemote serves it: its SKILL.md gains one
    /// paragraph after the frontmatter that says where it comes from and how
    /// that server's tool names map to MacRemote's ids. Supporting files pass
    /// through unchanged.
    ///
    /// The file's frontmatter must equal what the server listed, field by
    /// field, or the skill is refused: the listing is what an app shows, and
    /// the file is what its model reads.
    ///
    /// `toolNames` pairs each upstream tool name with its MacRemote id, for
    /// the tools of that server the owner shares: the ones apps can call.
    /// With none, the skill keeps its files as read and an `omission`. The
    /// note depends only on these inputs, so the same inputs give the same
    /// bytes and the same digest.
    init(
        bridged upstream: MCPUpstreamSkill,
        familyID: String,
        serverName: String,
        toolNames: [(upstream: String, id: String)]
    ) {
        let origin = Origin.bridgedServer(familyID: familyID, serverName: serverName, uri: upstream.uri)
        func refused(_ reason: String) -> Skill {
            Skill(origin: origin, name: upstream.name, frontmatter: upstream.frontmatter, files: [], refusal: reason)
        }
        if let refusal = upstream.refusal {
            self = refused(refusal)
            return
        }
        guard let main = upstream.files.first, main.path == Self.skillFileName else {
            self = refused("It has no SKILL.md.")
            return
        }
        guard let text = String(validating: main.data, as: UTF8.self) else {
            self = refused("SKILL.md is not UTF-8 text.")
            return
        }
        let header: SkillFrontmatter
        switch SkillFrontmatter.parse(text) {
        case .success(let parsed):
            header = parsed
        case .failure(let refusal):
            self = refused(refusal.reason)
            return
        }
        guard header.fields == upstream.frontmatter else {
            self = refused("Its SKILL.md header does not match what the server listed.")
            return
        }
        guard !toolNames.isEmpty else {
            self.init(
                origin: origin,
                name: upstream.name,
                frontmatter: upstream.frontmatter,
                files: upstream.files,
                omission: Self.noSharedToolsOmission
            )
            return
        }
        let noted = header.insertingParagraph(
            Self.bridgeNote(serverName: serverName, toolNames: toolNames),
            into: text
        )
        let files = [File(path: main.path, data: Data(noted.utf8), mediaType: "text/markdown")]
            + upstream.files.dropFirst()
        self.init(origin: origin, name: upstream.name, frontmatter: upstream.frontmatter, files: files)
    }

    /// One short paragraph built from the real mapping between a server's
    /// tool names and MacRemote's ids: the common prefix, an example, and
    /// every tool that does not follow the prefix.
    static func bridgeNote(serverName: String, toolNames: [(upstream: String, id: String)]) -> String {
        let pairs = toolNames.sorted { ($0.upstream, $0.id) < ($1.upstream, $1.id) }
        var prefixCounts = [String: Int]()
        for pair in pairs where pair.id.hasSuffix(pair.upstream) {
            prefixCounts[String(pair.id.dropLast(pair.upstream.count)), default: 0] += 1
        }
        let prefix = prefixCounts.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key ?? ""
        let exceptions = pairs.filter { $0.id != prefix + $0.upstream }
        let server = singleLine(serverName)

        var note = "This skill comes from the \(server) MCP server, shared through MacRemote."
        if prefix.isEmpty {
            note += exceptions.isEmpty
                ? " Its tool names are the same here."
                : " Its tools keep their names here, except:"
        } else if let example = pairs.first(where: { $0.id == prefix + $0.upstream }) {
            note += " MacRemote names that server's tools with a `\(prefix)` prefix,"
                + " so `\(example.upstream)` in this skill is `\(example.id)` here."
            if !exceptions.isEmpty {
                note += " These are named differently:"
            }
        }
        if !exceptions.isEmpty {
            note += " " + exceptions.map { "`\($0.upstream)` is `\($0.id)`" }.joined(separator: ", ") + "."
        }
        return note
    }

    // MARK: Found on this Mac

    /// A skill found on this Mac as MacRemote serves it: its SKILL.md gains
    /// one paragraph after the frontmatter (`foundNote`), built from `tools`,
    /// the family's tools the owner shares. With none, the skill keeps its
    /// files as read and an `omission`. Supporting files pass through
    /// unchanged.
    init(found: FoundSkill, tools: [ToolDefinition]) {
        let origin = Origin.foundOnDisk(familyID: found.familyID, source: found.source, folder: found.folder)
        guard found.refusal == nil,
              let main = found.files.first,
              let text = String(validating: main.data, as: UTF8.self),
              case .success(let header) = SkillFrontmatter.parse(text) else {
            self.init(
                origin: origin,
                name: found.name,
                frontmatter: found.frontmatter,
                files: [],
                refusal: found.refusal ?? "Its SKILL.md can't be read."
            )
            return
        }
        guard !tools.isEmpty else {
            self.init(
                origin: origin,
                name: found.name,
                frontmatter: found.frontmatter,
                files: found.files,
                omission: Self.noSharedToolsOmission
            )
            return
        }
        let noted = header.insertingParagraph(Self.foundNote(tools: tools), into: text)
        let files = [File(path: main.path, data: Data(noted.utf8), mediaType: main.mediaType)]
            + found.files.dropFirst()
        self.init(origin: origin, name: found.name, frontmatter: found.frontmatter, files: files)
    }

    /// One short paragraph for a skill written for a terminal: through
    /// MacRemote there is no shell, so it names the tool's command and the
    /// MacRemote tools that run it, Flexible Commands first, then by id. The
    /// same tools give the same bytes.
    static func foundNote(tools: [ToolDefinition]) -> String {
        let ordered = tools.sorted { lhs, rhs in
            lhs.isGenericCLIAdapter != rhs.isGenericCLIAdapter ? lhs.isGenericCLIAdapter : lhs.id < rhs.id
        }
        let command = singleLine(ToolFamily.skillCommandName(of: tools))
        return "This skill was written for a terminal on the Mac. Through MacRemote there is no shell:"
            + " run `\(command)` with these MacRemote tools instead: "
            + ordered.map { "`\($0.id)`" }.joined(separator: ", ") + "."
    }

    /// The URI authority for a bridged server or a skills folder: its name
    /// lowercased and reduced to `a-z`, `0-9`, and single hyphens.
    static func slug(_ serverName: String) -> String {
        var slug = ""
        for byte in serverName.lowercased().utf8 {
            if (97...122).contains(byte) || (48...57).contains(byte) {
                slug.append(Character(UnicodeScalar(byte)))
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "server" : slug
    }

    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}

/// A skills folder on this Mac that MacRemote reads (SPEC D84).
enum FoundSkillSource: Hashable, Sendable {
    /// `~/.claude/skills`
    case claudeSkills
    /// `~/.codex/skills`
    case codexSkills
    /// `~/.agents/skills`
    case agentSkills
    /// A Claude Code plugin's `skills` folder, by plugin name.
    case claudePlugin(String)

    /// Part of the sharing key; stable across launches.
    var id: String {
        switch self {
        case .claudeSkills: "claude"
        case .codexSkills: "codex"
        case .agentSkills: "agents"
        case .claudePlugin(let plugin): "claude-plugin:\(plugin)"
        }
    }

    /// The first segment of the served `skill://` address.
    var slug: String {
        switch self {
        case .claudeSkills: "claude-skills"
        case .codexSkills: "codex-skills"
        case .agentSkills: "agent-skills"
        case .claudePlugin(let plugin): Skill.slug(plugin + "-plugin")
        }
    }

    /// Where the skill comes from, for a connected app.
    var originName: String {
        switch self {
        case .claudeSkills: "Claude skills on the Mac"
        case .codexSkills: "Codex skills on the Mac"
        case .agentSkills: "Agent skills on the Mac"
        case .claudePlugin(let plugin): "\(plugin) plugin for Claude on the Mac"
        }
    }
}
