import CryptoKit
import Foundation

/// What the server offers through the MCP Skills extension (SPEC D84): the
/// shared skills in their fixed order, each with its `skill://` URI and every
/// file's size and digest, computed once from the exact bytes it returns.
///
/// Built from skills that already passed their checks. Answers modern
/// `skills/list`, `skills/get`, and `resources/read` of a `skill://` URI;
/// the server wraps each answer in its usual result envelope.
struct ServedSkillCatalog: Sendable {
    static let uriScheme = "skill://"
    /// Claude loads at most 100 skills from one server.
    static let maximumSkills = 100
    static var serverExtensionCapability: [String: Any] {
        [MCPUpstreamSkillCollector.extensionIdentifier: [String: Any]()]
    }

    struct File: Sendable {
        let uri: String
        let text: String
        let mediaType: String
        let size: Int
        let digest: String
    }

    struct Entry: Sendable {
        /// The `Skill.id` this entry serves.
        let skillID: String
        let uri: String
        let frontmatter: [String: JSONValue]
        let files: [File]
        /// Where a re-served skill comes from (`Skill.originName`).
        let origin: String?

        var listing: [String: Any] {
            var listing: [String: Any] = [
                "uri": uri,
                "frontmatter": frontmatter.mapValues(\.anyValue),
                "resources": files.map { ["uri": $0.uri, "digest": $0.digest, "size": $0.size] }
            ]
            // An intermediary may add `_meta` under its own prefix; a client
            // can show where a skill MacRemote re-serves comes from.
            if let origin {
                listing["_meta"] = [Self.originMetaKey: origin]
            }
            return listing
        }

        static let originMetaKey = "net.viticci.macremote/origin"
    }

    struct Failure: Error {
        let code: Int
        let message: String
    }

    let entries: [Entry]
    /// Why a shared skill is left out, by `Skill.id`, for the owner to read.
    let omissions: [String: String]
    private let entriesByURI: [String: Entry]
    private let filesByURI: [String: File]

    static let builtInOnly = ServedSkillCatalog(skills: Skill.builtIn.map { [$0] } ?? [])

    /// Serves `skills` (the shared ones) in the fixed order. Claude names a
    /// skill by its name alone, so a later skill whose name is taken is served
    /// as `<authority>-<name>`, with the `name` entry of its served SKILL.md
    /// rewritten to match. A skill with an `omission` (none of its tools are
    /// shared), one that still cannot get a unique name and address, or one
    /// that the rename takes past the size limits, is left out with a reason
    /// in `omissions`.
    init(skills: [Skill]) {
        var entries = [Entry]()
        var omissions = [String: String]()
        var usedNames = Set<String>()
        var filesByURI = [String: File]()
        for skill in skills.sorted(by: Skill.servingOrder) where skill.refusal == nil {
            if let omission = skill.omission {
                omissions[skill.id] = omission
                continue
            }
            guard entries.count < Self.maximumSkills else {
                omissions[skill.id] = "Apps load at most \(Self.maximumSkills) skills from MacRemote."
                continue
            }
            guard let main = skill.files.first else { continue }
            var name = skill.name
            var frontmatter = skill.frontmatter
            var mainData = main.data
            let pathPrefix = skill.uriAuthority.map { [$0] } ?? []
            if usedNames.contains(name), let authority = skill.uriAuthority {
                name = "\(authority)-\(skill.name)"
                let text = String(decoding: main.data, as: UTF8.self)
                guard Skill.isValidName(name), !usedNames.contains(name),
                      case .success(let header) = SkillFrontmatter.parse(text),
                      let renamed = header.renaming(text, to: name) else {
                    omissions[skill.id] = "Another shared skill already uses the name \(skill.name)."
                    continue
                }
                mainData = Data(renamed.utf8)
                frontmatter["name"] = .string(name)
                let sizes = [(main.path, mainData.count)] + skill.files.dropFirst().map { ($0.path, $0.data.count) }
                if let reason = Skill.sizeRefusal(sizes) {
                    omissions[skill.id] = "Renamed to \(name) because another shared skill uses its name: \(reason)"
                    continue
                }
            }
            guard !usedNames.contains(name) else {
                omissions[skill.id] = "Another shared skill already uses the name \(skill.name)."
                continue
            }
            let root = Self.uriScheme + (pathPrefix + [name]).joined(separator: "/") + "/"
            let files = skill.files.enumerated().map { index, file in
                let data = index == 0 ? mainData : file.data
                return File(
                    uri: root + file.path,
                    text: String(decoding: data, as: UTF8.self),
                    mediaType: file.mediaType,
                    size: data.count,
                    digest: "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                )
            }
            guard files.allSatisfy({ filesByURI[$0.uri] == nil }) else {
                omissions[skill.id] = "Another shared skill already uses its address."
                continue
            }
            usedNames.insert(name)
            for file in files { filesByURI[file.uri] = file }
            entries.append(Entry(
                skillID: skill.id,
                uri: files[0].uri,
                frontmatter: frontmatter,
                files: files,
                origin: skill.originName
            ))
        }
        self.entries = entries
        self.omissions = omissions
        self.entriesByURI = Dictionary(uniqueKeysWithValues: entries.map { ($0.uri, $0) })
        self.filesByURI = filesByURI
    }

    /// The result for one Skills request, before the server's envelope.
    /// Every listed skill fits on one page, so a `cursor` is never needed.
    func reply(method: String, params: [String: Any]) -> Result<[String: Any], Failure> {
        switch method {
        case "skills/list":
            return .success(["skills": entries.map(\.listing)])
        case "skills/get":
            guard let uri = params["uri"] as? String else {
                return .failure(Failure(code: -32602, message: "Missing skill uri."))
            }
            guard let entry = entriesByURI[uri] else {
                return .failure(Failure(code: -32602, message: "No skill is served at \(uri)"))
            }
            return .success(["skill": entry.listing])
        default:
            guard let uri = params["uri"] as? String, let file = filesByURI[uri] else {
                return .failure(Failure(code: -32602, message: "Unknown resource: \(params["uri"] as? String ?? "")"))
            }
            return .success(["contents": [["uri": file.uri, "mimeType": file.mediaType, "text": file.text]]])
        }
    }
}

/// Every skill MacRemote knows, and what the server may serve of them.
///
/// AppModel rebuilds it on the main actor whenever tools or their sharing
/// change; the server
/// asks `servedCatalog(sharing:)` on every Skills request from its own
/// threads. Bridged skills are saved in one JSON file next to the tool store,
/// so a relaunch serves them without starting any server. Skills found on
/// this Mac are kept in memory only: MacRemote looks for them again at
/// launch. Either kind is known only while its family still has tools.
final class SkillRegistry: @unchecked Sendable {
    /// One bridged server's skills, as saved.
    struct BridgedSkillSet: Codable, Hashable, Sendable {
        let familyID: String
        let serverName: String
        let skills: [MCPUpstreamSkill]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var bridgedSets: [BridgedSkillSet]
    private var foundSkills: [FoundSkill] = []
    private var skills: [Skill] = []
    private var cached: (keys: [String], catalog: ServedSkillCatalog)?

    init(fileURL: URL) {
        self.fileURL = fileURL
        bridgedSets = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([BridgedSkillSet].self, from: $0) } ?? []
    }

    /// Replaces one bridged server's saved skills with what a probe just read.
    /// Returns true when that changed what is saved.
    @discardableResult
    func replaceBridgedSkills(_ skills: [MCPUpstreamSkill], familyID: String, serverName: String) throws -> Bool {
        try lock.withLock {
            var sets = bridgedSets.filter { $0.familyID != familyID }
            if !skills.isEmpty {
                sets.append(BridgedSkillSet(familyID: familyID, serverName: serverName, skills: skills))
            }
            guard Set(sets) != Set(bridgedSets) else { return false }
            try save(sets)
            return true
        }
    }

    /// Replaces the skills found on this Mac with what a scan just read.
    func replaceFoundSkills(_ skills: [FoundSkill]) {
        lock.withLock {
            foundSkills = skills
        }
    }

    /// The known skills for these tools, built in first. A bridged or found
    /// skill is known while its family has tools; its note is built from the
    /// family's tools in `sharedToolIDs`, the set `tools/list` serves, so it
    /// names only tools an app can call. Call again when that set changes:
    /// the served bytes and digests follow it. With `pruning`, the skills of
    /// families that no longer have tools are deleted.
    @discardableResult
    func rebuild(tools: [ToolDefinition], sharedToolIDs: Set<String>, pruning: Bool) -> [Skill] {
        let toolsByFamily = Dictionary(grouping: tools) { ToolFamily($0).id }
        let sharedByFamily = toolsByFamily.mapValues { $0.filter { sharedToolIDs.contains($0.id) } }
        return lock.withLock {
            let present = bridgedSets.filter { toolsByFamily[$0.familyID]?.contains(where: \.isMCPBridge) == true }
            if pruning, present.count != bridgedSets.count {
                try? save(present)
            }
            let presentFound = foundSkills.filter { toolsByFamily[$0.familyID] != nil }
            if pruning {
                foundSkills = presentFound
            }
            let found = presentFound.map { Skill(found: $0, tools: sharedByFamily[$0.familyID] ?? []) }
            let bridged = present.flatMap { set in
                let toolNames = (sharedByFamily[set.familyID] ?? []).compactMap { tool in
                    tool.mcpBridgeToolName.map { (upstream: $0, id: tool.id) }
                }
                return set.skills.map { upstream in
                    Skill(bridged: upstream, familyID: set.familyID, serverName: set.serverName, toolNames: toolNames)
                }
            }
            skills = ((Skill.builtIn.map { [$0] } ?? []) + bridged + found).sorted(by: Skill.servingOrder)
            cached = nil
            return skills
        }
    }

    /// The catalog for the owner's current Shared choices, reused until the
    /// skills or the choices change.
    func servedCatalog(sharing: SkillSharingPreferences) -> ServedSkillCatalog {
        lock.withLock {
            let shared = skills.filter { $0.refusal == nil && sharing.isShared($0) }
            let keys = shared.map(\.id)
            if let cached, cached.keys == keys { return cached.catalog }
            let catalog = ServedSkillCatalog(skills: shared)
            cached = (keys, catalog)
            return catalog
        }
    }

    /// The catalog these choices would serve, built fresh, so a preview of a
    /// choice the owner has not made never displaces the server's copy.
    func catalog(sharing: SkillSharingPreferences) -> ServedSkillCatalog {
        ServedSkillCatalog(skills: lock.withLock {
            skills.filter { $0.refusal == nil && sharing.isShared($0) }
        })
    }

    /// Call with `lock` held.
    private func save(_ sets: [BridgedSkillSet]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(sets).write(to: fileURL, options: [.atomic])
        bridgedSets = sets
    }
}
