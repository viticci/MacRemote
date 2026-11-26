import CryptoKit
import Foundation

/// A skill an upstream MCP server listed through the Skills extension, with
/// every file's bytes checked against the size and SHA-256 it listed
/// (SPEC D84). Saved next to the tool store so a relaunch can serve it
/// without starting the server.
struct MCPUpstreamSkill: Codable, Hashable, Sendable {
    /// The skill's SKILL.md address on its server.
    let uri: String
    let name: String
    let frontmatter: [String: JSONValue]
    /// `SKILL.md` first. Empty when refused.
    let files: [Skill.File]
    /// Why MacRemote will not serve it, or nil.
    let refusal: String?
}

/// Reads an upstream server's skills: every `skills/list` page, then a
/// `resources/read` for each listed file. A skill whose `resources` is
/// `"dynamic"` is skipped; one that fails a check is kept as refused.
///
/// It sends nothing itself. A bridge client asks `nextRequest()`, sends it on
/// the connection it already holds (with its own headers, sign-in, and
/// timeouts), and hands the JSON-RPC response to `receive(_:)` until there is
/// nothing left to send. Only a client that saw the server declare
/// `extensionIdentifier` on 2026-07-28 starts one.
struct MCPUpstreamSkillCollector {
    static let extensionIdentifier = "io.modelcontextprotocol/skills"
    /// Claude shows at most 100 skills per server; reading more is wasted.
    static let maximumSkills = 100
    static let maximumPages = 20
    /// The spec's per-skill file limit.
    static let maximumFilesPerSkill = 512
    /// Skills are optional, so reading them gets its own short time after the
    /// tools are read. When it runs out, the probe keeps its tools and records
    /// no skills.
    static let readDeadlineSeconds: TimeInterval = 10

    struct Request {
        let method: String
        let params: [String: Any]
    }

    enum Failure: Error {
        case invalidListing(String)
    }

    private struct ListedFile {
        let uri: String
        let path: String
        let size: Int
        let digest: String
        var file: Skill.File?
    }

    private struct ListedSkill {
        let uri: String
        let name: String
        let frontmatter: [String: JSONValue]
        var files: [ListedFile]
        var refusal: String?
    }

    private var listing = true
    private var cursor: String?
    private var pages = 0
    private var listed = [ListedSkill]()
    private var readSkill = 0
    private var readFile = 0

    /// The next request to send, or nil when every skill is read.
    mutating func nextRequest() -> Request? {
        if listing {
            return Request(method: "skills/list", params: cursor.map { ["cursor": $0] } ?? [:])
        }
        while readSkill < listed.count {
            let skill = listed[readSkill]
            if skill.refusal == nil, readFile < skill.files.count {
                return Request(method: "resources/read", params: ["uri": skill.files[readFile].uri])
            }
            readSkill += 1
            readFile = 0
        }
        return nil
    }

    /// Takes the response to the request `nextRequest()` last returned.
    /// Throws when a `skills/list` page is unusable, which ends the whole read.
    mutating func receive(_ response: [String: Any]) throws {
        if listing {
            try receiveListPage(response)
        } else {
            receiveFile(response)
        }
    }

    /// What was read, in the server's order.
    var skills: [MCPUpstreamSkill] {
        listed.map { skill in
            let files = skill.files.compactMap(\.file)
            let complete = skill.refusal == nil && files.count == skill.files.count
            return MCPUpstreamSkill(
                uri: skill.uri,
                name: skill.name,
                frontmatter: skill.frontmatter,
                files: complete ? files : [],
                refusal: complete ? nil : skill.refusal ?? "MacRemote could not read every file."
            )
        }
    }

    private mutating func receiveListPage(_ response: [String: Any]) throws {
        if let error = response["error"] {
            throw Failure.invalidListing("skills/list failed: \(MCPUpstreamProtocol.serializedJSON(error))")
        }
        let result: [String: Any]
        do {
            result = try MCPUpstreamProtocol.completeResult(from: response)
        } catch {
            throw Failure.invalidListing("skills/list returned no complete result")
        }
        guard let entries = result["skills"] as? [Any] else {
            throw Failure.invalidListing("skills/list returned no skills array")
        }
        pages += 1
        for case let entry as [String: Any] in entries where listed.count < Self.maximumSkills {
            if let skill = Self.listedSkill(entry) {
                listed.append(skill)
            }
        }
        let next = result["nextCursor"] as? String
        if let next, !next.isEmpty, next != cursor,
           pages < Self.maximumPages, listed.count < Self.maximumSkills {
            cursor = next
        } else {
            listing = false
        }
    }

    private mutating func receiveFile(_ response: [String: Any]) {
        let listedFile = listed[readSkill].files[readFile]
        if let file = Self.verifiedFile(listedFile, response: response) {
            listed[readSkill].files[readFile].file = file
            readFile += 1
        } else {
            listed[readSkill].refusal = "\(listedFile.path) did not match the size and digest the server listed."
        }
    }

    /// One `skills/list` entry, checked before any file is read. Nil for an
    /// entry with no usable name, or one with dynamic resources.
    private static func listedSkill(_ entry: [String: Any]) -> ListedSkill? {
        guard let uri = entry["uri"] as? String,
              let object = entry["frontmatter"] as? [String: Any],
              case .object(let frontmatter)? = JSONValue.fromJSONObject(object),
              case .string(let name)? = frontmatter["name"] else {
            return nil
        }
        if entry["resources"] as? String == "dynamic" {
            return nil
        }
        var skill = ListedSkill(uri: uri, name: name, frontmatter: frontmatter, files: [])
        func refused(_ reason: String) -> ListedSkill {
            skill.refusal = reason
            return skill
        }
        let suffix = "/" + Skill.skillFileName
        guard Skill.isValidName(name), uri.hasSuffix(suffix), isValidSkillURI(uri),
              uri.dropLast(suffix.count).split(separator: "/").last.map(String.init) == name else {
            return refused("Its name is not a valid skill name, or does not match its address.")
        }
        guard case .string(let description)? = frontmatter["description"],
              (1...1024).contains(description.count) else {
            return refused("It has no description.")
        }
        let root = String(uri.dropLast(Skill.skillFileName.count))
        guard let resources = entry["resources"] as? [[String: Any]],
              resources.count <= maximumFilesPerSkill else {
            return refused("The server listed its files in a form MacRemote does not read.")
        }
        for resource in resources {
            guard let fileURI = resource["uri"] as? String, fileURI.hasPrefix(root), isValidSkillURI(fileURI),
                  case let path = String(fileURI.dropFirst(root.count)), Skill.isValidRelativePath(path),
                  let size = resource["size"] as? Int, size >= 0,
                  let digest = resource["digest"] as? String, digest.hasPrefix("sha256:"),
                  !skill.files.contains(where: { $0.uri == fileURI }) else {
                return refused("The server listed a file MacRemote cannot check.")
            }
            let listedFile = ListedFile(uri: fileURI, path: path, size: size, digest: digest)
            if path == Skill.skillFileName {
                skill.files.insert(listedFile, at: 0)
            } else {
                skill.files.append(listedFile)
            }
        }
        guard skill.files.first?.path == Skill.skillFileName else {
            return refused("It has no SKILL.md.")
        }
        if let reason = Skill.sizeRefusal(skill.files.map { ($0.path, $0.size) }) {
            return refused(reason)
        }
        return skill
    }

    /// A `scheme://` address whose path segments are none of empty, `.`, or
    /// `..`. Not `file://`: a skill names files on its server, never on this Mac.
    private static func isValidSkillURI(_ uri: String) -> Bool {
        guard let separator = uri.range(of: "://"),
              case let scheme = uri[..<separator.lowerBound],
              let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
              scheme.lowercased() != "file" else {
            return false
        }
        return Skill.isValidRelativePath(String(uri[separator.upperBound...]))
    }

    /// The file's bytes when the read returned exactly what was listed.
    private static func verifiedFile(_ listed: ListedFile, response: [String: Any]) -> Skill.File? {
        guard response["error"] == nil,
              let result = try? MCPUpstreamProtocol.completeResult(from: response),
              let contents = result["contents"] as? [[String: Any]],
              let item = contents.first(where: { $0["uri"] as? String == listed.uri }) else {
            return nil
        }
        let data: Data
        if let text = item["text"] as? String {
            data = Data(text.utf8)
        } else if let blob = item["blob"] as? String, let decoded = Data(base64Encoded: blob) {
            data = decoded
        } else {
            return nil
        }
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard data.count == listed.size, digest == listed.digest.lowercased() else {
            return nil
        }
        let mediaType = listed.path == Skill.skillFileName
            ? "text/markdown"
            : (item["mimeType"] as? String) ?? "text/plain"
        return Skill.File(path: listed.path, data: data, mediaType: mediaType)
    }
}
