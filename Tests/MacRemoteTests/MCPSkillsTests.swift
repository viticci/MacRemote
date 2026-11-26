import CryptoKit
import Foundation
import Testing
@testable import MacRemote

/// Skills over MCP (SPEC D84), as a connected app sees them: the capability,
/// `skills/list`, `skills/get`, and `resources/read` of `skill://` URIs, on
/// a real `LocalMCPServer` over loopback HTTP.
@Suite(.serialized)
struct MCPSkillsTests {
    @Test func discoveryDeclaresSkillsAndTheBuiltInSkillReadsBack() async throws {
        let harness = try await SkillsServerHarness(catalog: { .builtInOnly })
        defer { harness.server.stop() }
        let client = harness.client()

        let discover = try #require(try await client.discover().result)
        let capabilities = try #require(discover["capabilities"] as? [String: Any])
        #expect(capabilities["resources"] != nil)
        let extensions = try #require(capabilities["extensions"] as? [String: Any])
        #expect(extensions["io.modelcontextprotocol/skills"] as? [String: Any] != nil)

        let list = try #require(try await client.send(method: "skills/list", params: [:]).result)
        expectCacheable(list)
        let skills = try #require(list["skills"] as? [[String: Any]])
        #expect(skills.count == 1)
        let entry = try #require(skills.first)
        #expect(entry["uri"] as? String == "skill://macremote/SKILL.md")
        let frontmatter = try #require(entry["frontmatter"] as? [String: Any])
        #expect(frontmatter["name"] as? String == "macremote")
        #expect((frontmatter["description"] as? String)?.isEmpty == false)

        let get = try #require(
            try await client.send(method: "skills/get", params: ["uri": "skill://macremote/SKILL.md"]).result
        )
        expectCacheable(get)
        #expect(NSDictionary(dictionary: try #require(get["skill"] as? [String: Any])).isEqual(to: entry))

        let resources = try #require(entry["resources"] as? [[String: Any]])
        #expect(resources.count == 1)
        let read = try await readSkillFile(client, uri: "skill://macremote/SKILL.md")
        #expect(read.mimeType == "text/markdown")
        #expect(resources[0]["size"] as? Int == read.data.count)
        #expect(resources[0]["digest"] as? String == sha256(read.data))
        #expect((3_000...8_000).contains(read.data.count))
        #expect(String(decoding: read.data, as: UTF8.self).hasPrefix("---\nname: macremote\n"))

        let missing = "skill://nope/SKILL.md"
        #expect(try await client.send(method: "skills/get", params: ["uri": missing]).error?["code"] as? Int == -32602)
        #expect(try await client.send(method: "resources/read", params: ["uri": missing]).error?["code"] as? Int == -32602)
    }

    @Test func turningOffTheBuiltInSkillRemovesItFromListGetAndRead() async throws {
        let builtIn = try #require(Skill.builtIn)
        let sharing = SkillSharingPreferences(choices: [builtIn.id: false])
        let registry = SkillRegistry(fileURL: temporaryDirectory().appendingPathComponent("bridged-skills.json"))
        registry.rebuild(tools: [], sharedToolIDs: [], pruning: false)
        let harness = try await SkillsServerHarness(catalog: { registry.servedCatalog(sharing: sharing) })
        defer { harness.server.stop() }
        let client = harness.client()

        let list = try #require(try await client.send(method: "skills/list", params: [:]).result)
        #expect((list["skills"] as? [[String: Any]])?.isEmpty == true)
        let uri = "skill://macremote/SKILL.md"
        #expect(try await client.send(method: "skills/get", params: ["uri": uri]).error?["code"] as? Int == -32602)
        #expect(try await client.send(method: "resources/read", params: ["uri": uri]).error?["code"] as? Int == -32602)
    }

    /// The whole bridged path: a stdio probe reads and verifies the upstream
    /// skills, the registry builds them with the note, and the server serves
    /// one only after the owner shares it.
    @Test func bridgedSkillIsVerifiedAndServedWithItsNoteOnceShared() async throws {
        let upstream = try UpstreamSkillsFixture()
        defer { upstream.remove() }
        let probe = try await upstream.probe(mode: "skills")
        #expect(probe.skills.map(\.name) == ["reminders", "tampered"])
        let tampered = try #require(probe.skills.first { $0.name == "tampered" })
        #expect(tampered.refusal != nil)
        #expect(tampered.files.isEmpty)

        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = SkillRegistry(fileURL: directory.appendingPathComponent("bridged-skills.json"))
        let tools = [
            bridgeTool(id: "remctl_lists", upstream: "lists"),
            bridgeTool(id: "remctl_get_list", upstream: "get-list")
        ]
        let family = ToolFamily(tools[0])
        try registry.replaceBridgedSkills(probe.skills, familyID: family.id, serverName: family.name)
        let known = registry.rebuild(tools: tools, sharedToolIDs: Set(tools.map(\.id)), pruning: true)
        let reminders = try #require(known.first { $0.name == "reminders" })
        #expect(known.first { $0.name == "tampered" }?.refusal != nil)

        let suiteName = "MacRemoteSkillsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        nonisolated(unsafe) let sharedDefaults = defaults
        let harness = try await SkillsServerHarness(catalog: {
            registry.servedCatalog(sharing: SkillSharingPreferences(userDefaults: sharedDefaults))
        })
        defer { harness.server.stop() }
        let client = harness.client()
        let uri = "skill://remctl/reminders/SKILL.md"

        // Not shared until the owner turns it on: absent from all three.
        #expect(try await listedURIs(client) == ["skill://macremote/SKILL.md"])
        #expect(try await client.send(method: "skills/get", params: ["uri": uri]).error?["code"] as? Int == -32602)
        #expect(try await client.send(method: "resources/read", params: ["uri": uri]).error?["code"] as? Int == -32602)

        SkillSharingPreferences(choices: [reminders.id: true]).save(to: defaults)
        #expect(try await listedURIs(client) == ["skill://macremote/SKILL.md", uri])
        let get = try #require(try await client.send(method: "skills/get", params: ["uri": uri]).result)
        let entry = try #require(get["skill"] as? [String: Any])
        let resources = try #require(entry["resources"] as? [[String: Any]])
        #expect(resources.map { $0["uri"] as? String } == [uri, "skill://remctl/reminders/references/guide.md"])
        for resource in resources {
            let read = try await readSkillFile(client, uri: try #require(resource["uri"] as? String))
            #expect(resource["size"] as? Int == read.data.count)
            #expect(resource["digest"] as? String == sha256(read.data))
        }

        let served = String(decoding: try await readSkillFile(client, uri: uri).data, as: UTF8.self)
        let note = "This skill comes from the RemCTL MCP server, shared through MacRemote."
            + " MacRemote names that server's tools with a `remctl_` prefix, so `lists` in this skill is"
            + " `remctl_lists` here. These are named differently: `get-list` is `remctl_get_list`."
        #expect(served == "---\nname: reminders\ndescription: Work with reminders.\n---\n\n\(note)\n\n# Reminders\n\nCall `lists` first.\n")
        let guide = try await readSkillFile(client, uri: "skill://remctl/reminders/references/guide.md")
        #expect(guide.data == Data(UpstreamSkillsFixture.guide.utf8))
    }

    @Test func aServerThatDoesNotDeclareSkillsIsNeverAskedForThem() async throws {
        let upstream = try UpstreamSkillsFixture()
        defer { upstream.remove() }
        let probe = try await upstream.probe(mode: "plain")
        #expect(probe.tools.map(\.name) == ["lists"])
        #expect(probe.skills.isEmpty)
        #expect(try upstream.methods() == ["server/discover", "tools/list"])
    }

    @Test func sameNameSkillIsRenamedInItsListingAddressAndBytes() async throws {
        let first = Skill(
            bridged: upstreamSkill(name: "notes"),
            familyID: "family-a",
            serverName: "Apple Notes",
            toolNames: [("search", "apple_notes_search")]
        )
        let second = Skill(
            bridged: upstreamSkill(name: "notes"),
            familyID: "family-b",
            serverName: "NotesCTL",
            toolNames: [("notesctl_search", "notesctl_search")]
        )
        let harness = try await SkillsServerHarness(catalog: { ServedSkillCatalog(skills: [second, first]) })
        defer { harness.server.stop() }
        let client = harness.client()

        #expect(try await listedURIs(client) == [
            "skill://apple-notes/notes/SKILL.md",
            "skill://notesctl/notesctl-notes/SKILL.md"
        ])
        let renamedURI = "skill://notesctl/notesctl-notes/SKILL.md"
        let get = try #require(try await client.send(method: "skills/get", params: ["uri": renamedURI]).result)
        let entry = try #require(get["skill"] as? [String: Any])
        #expect((entry["frontmatter"] as? [String: Any])?["name"] as? String == "notesctl-notes")
        let read = try await readSkillFile(client, uri: renamedURI)
        let text = String(decoding: read.data, as: UTF8.self)
        #expect(text.hasPrefix("---\nname: notesctl-notes\ndescription: Test skill notes.\n---\n"))
        #expect(text.contains("Its tool names are the same here."))
        let resources = try #require(entry["resources"] as? [[String: Any]])
        #expect(resources.first?["digest"] as? String == sha256(read.data))
    }

    @Test func legacySessionsSeeNoSkills() async throws {
        let harness = try await SkillsServerHarness(catalog: { .builtInOnly })
        defer { harness.server.stop() }
        let client = harness.client(.legacy(protocolVersion: "2025-06-18"))

        let initialized = try #require(try await client.initializeLegacy().result)
        let extensions = (initialized["capabilities"] as? [String: Any])?["extensions"] as? [String: Any]
        #expect(extensions?["io.modelcontextprotocol/skills"] == nil)
        #expect(try await client.send(method: "skills/list", params: [:]).error?["code"] as? Int == -32601)
        #expect(try await client.send(method: "skills/get", params: ["uri": "skill://macremote/SKILL.md"])
            .error?["code"] as? Int == -32601)
        #expect(try await client.send(method: "resources/read", params: ["uri": "skill://macremote/SKILL.md"])
            .error?["code"] as? Int == -32002)
    }

    @Test func noteIsBuiltFromTheRealToolIdsAndIsDeterministic() {
        let pairs: [(upstream: String, id: String)] = [
            ("today", "remctl_today"),
            ("lists", "remctl_lists"),
            ("remctl_doctor", "remctl_doctor"),
            ("show", "remctl_show_3f2a")
        ]
        let note = Skill.bridgeNote(serverName: "RemCTL", toolNames: pairs)
        #expect(note == Skill.bridgeNote(serverName: "RemCTL", toolNames: pairs.reversed()))
        #expect(note == "This skill comes from the RemCTL MCP server, shared through MacRemote."
            + " MacRemote names that server's tools with a `remctl_` prefix, so `lists` in this skill is"
            + " `remctl_lists` here. These are named differently:"
            + " `remctl_doctor` is `remctl_doctor`, `show` is `remctl_show_3f2a`.")
    }

    @MainActor
    @Test func bridgedSkillsStartNotSharedSurviveARelaunchAndLeaveWithTheirTools() throws {
        let suiteName = "MacRemoteSkillsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ToolRegistryStore(fileURL: directory.appendingPathComponent("tools.json"))
        let tools = [bridgeTool(id: "remctl_lists", upstream: "lists"), bridgeTool(id: "remctl_today", upstream: "today")]

        let model = makeTestAppModel(userDefaults: defaults, toolStore: store)
        _ = try model.replaceLocalMCPBridgeTools(tools, bridgeIdentity: tools[0].mcpBridgeIdentity)
        model.recordBridgedSkills([upstreamSkill(name: "reminders")], importedTools: tools)
        let builtIn = try #require(model.knownSkills.first)
        #expect(builtIn.origin == .builtIn)
        #expect(model.isSkillShared(builtIn))
        let reminders = try #require(model.knownSkills.first { $0.name == "reminders" })
        #expect(!model.isSkillShared(reminders))
        #expect(model.setSkillShared(reminders, isShared: true) == nil)

        let relaunched = makeTestAppModel(userDefaults: defaults, toolStore: store)
        let restored = try #require(relaunched.knownSkills.first { $0.name == "reminders" })
        #expect(relaunched.isSkillShared(restored))
        let served = relaunched.skillRegistry.servedCatalog(sharing: relaunched.skillSharing)
        #expect(served.entries.map(\.uri) == ["skill://macremote/SKILL.md", "skill://remctl/reminders/SKILL.md"])

        for tool in tools {
            #expect(relaunched.deleteUserTool(id: tool.id) == nil)
        }
        #expect(!relaunched.knownSkills.contains { $0.name == "reminders" })
        let afterRemoval = makeTestAppModel(userDefaults: defaults, toolStore: store)
        #expect(afterRemoval.knownSkills.map(\.name) == ["macremote"])
    }

    // MARK: Review findings on the first half

    /// Two skills with one name at different addresses are two choices:
    /// sharing one never shares the other.
    @Test func sameNameSkillsFromOneServerKeepSeparateSharingChoices() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = SkillRegistry(fileURL: directory.appendingPathComponent("bridged-skills.json"))
        let tools = [bridgeTool(id: "remctl_lists", upstream: "lists")]
        let family = ToolFamily(tools[0])
        try registry.replaceBridgedSkills([
            upstreamSkill(name: "deploy", uri: "skill://acme/team-a/deploy/SKILL.md"),
            upstreamSkill(name: "deploy", uri: "skill://acme/team-b/deploy/SKILL.md")
        ], familyID: family.id, serverName: family.name)
        let deploys = registry.rebuild(tools: tools, sharedToolIDs: Set(tools.map(\.id)), pruning: true).filter { $0.name == "deploy" }
        #expect(deploys.count == 2)
        #expect(Set(deploys.map(\.id)).count == 2)

        let teamA = try #require(deploys.first { $0.id.hasSuffix("team-a/deploy/SKILL.md") })
        let served = registry.servedCatalog(sharing: SkillSharingPreferences(choices: [teamA.id: true]))
        #expect(served.entries.map(\.skillID) == ["builtin:macremote", teamA.id])
    }

    /// The header is read exactly: the note goes after the real closing
    /// line, CRLF files and inline comments are read, and a file whose header
    /// differs from the server's listing is refused.
    @Test func bridgedHeaderIsReadExactlyAndMustMatchItsListing() throws {
        func bridged(_ text: String, _ frontmatter: [String: JSONValue]) -> Skill {
            Skill(
                bridged: upstreamSkill(name: "notes", text: text, frontmatter: frontmatter),
                familyID: "family",
                serverName: "Notes",
                toolNames: [("search", "notes_search")]
            )
        }
        let note = Skill.bridgeNote(serverName: "Notes", toolNames: [("search", "notes_search")])

        let blockHeader = "---\nname: notes\ndescription: |\n  First line.\n  ---\n  Last line.\n---\n"
        let block = bridged(blockHeader + "\n# Notes\n", [
            "name": .string("notes"),
            "description": .string("First line.\n---\nLast line.\n")
        ])
        #expect(block.refusal == nil)
        let blockText = String(decoding: try #require(block.files.first?.data), as: UTF8.self)
        #expect(blockText == blockHeader + "\n" + note + "\n\n# Notes\n")

        let crlfHeader = "---\r\nname: notes # the skill's name\r\ndescription: 'It''s a test.'\r\n---\r\n"
        let crlf = bridged(crlfHeader + "\r\n# Notes\r\n", [
            "name": .string("notes"),
            "description": .string("It's a test.")
        ])
        #expect(crlf.refusal == nil)
        let crlfText = String(decoding: try #require(crlf.files.first?.data), as: UTF8.self)
        #expect(crlfText == crlfHeader + "\r\n" + note + "\r\n\r\n# Notes\r\n")

        let file = "---\nname: notes\ndescription: Actual file description.\n---\n\n# Notes\n"
        let mismatch = bridged(file, ["name": .string("notes"), "description": .string("Listed description.")])
        #expect(mismatch.refusal == "Its SKILL.md header does not match what the server listed.")
        #expect(mismatch.files.isEmpty)
        let extraKey = bridged(
            "---\nname: notes\ndescription: Same.\nlicense: MIT\n---\n\n# Notes\n",
            ["name": .string("notes"), "description": .string("Same.")]
        )
        #expect(extraKey.refusal == "Its SKILL.md header does not match what the server listed.")
    }

    @Test(arguments: [
        ("description: >-\n  One\n  two\n\n  Three\n", ["description": JSONValue.string("One two\nThree")]),
        ("notes: |+\n  kept\n\n", ["notes": .string("kept\n\n")]),
        ("notes: |-\n  a\n    b\n", ["notes": .string("a\n  b")]),
        ("\"quoted key\" : value # comment\n", ["quoted key": .string("value")]),
        ("text: \"tab\\there \\u00e9\"\n", ["text": .string("tab\there \u{e9}")]),
        ("metadata:\n  author: Federico\n  version: '1.0'\n", ["metadata": .object([
            "author": .string("Federico"), "version": .string("1.0")
        ])]),
        ("count: 3\nenabled: true\nnothing: ~\nversion: 1.0.0\n", [
            "count": .number(3), "enabled": .bool(true), "nothing": .null, "version": .string("1.0.0")
        ]),
        // YAML separates with spaces and tabs only; a trailing no-break
        // space is part of the value, in the listing as in the file.
        ("description: Search guide.\u{a0}\n", ["description": .string("Search guide.\u{a0}")]),
        ("description: 2026-11-25 release notes\n", ["description": .string("2026-11-25 release notes")])
    ])
    func frontmatterSubsetIsReadExactly(yaml: String, expected: [String: JSONValue]) throws {
        let text = "---\n" + yaml + "---\n\nBody\n"
        guard case .success(let header) = SkillFrontmatter.parse(text) else {
            Issue.record("refused: \(yaml)")
            return
        }
        #expect(header.fields == expected)
        #expect(text[header.bodyStart...] == "\nBody\n")
    }

    @Test(arguments: [
        "version: 1.5\n", "items: [a, b]\n", "list:\n  - a\n", "when: 2026-11-25\n",
        "a: b: c\n", "answer: yes\n", "mode: 0755\n", "name: one\nname: two\n", "text: \"open\n",
        "when: 2026-11-25 10:00:00\n", "notes: |\n\tTab indented.\n", "notes: |\n  \tTab after spaces.\n",
        "metadata:\n\tauthor: Federico\n"
    ])
    func frontmatterOutsideTheSubsetIsRefused(yaml: String) {
        guard case .failure(let refusal) = SkillFrontmatter.parse("---\n" + yaml + "---\n") else {
            Issue.record("accepted: \(yaml)")
            return
        }
        #expect(!refusal.reason.isEmpty)
    }

    /// The built-in skill states File Transfer's limits and errors as the
    /// code has them.
    @Test func builtInSkillStatesFileTransferLimitsAsTheCodeHasThem() throws {
        let text = String(decoding: try #require(Skill.builtIn?.files.first?.data), as: UTF8.self)
        #expect(FileTransferToolCatalog.writeFileDataCharacterLimit == 98_304)
        #expect(text.contains("at most 98,304\n  characters per call"))
        #expect(FileTransferToolCatalog.writeFileDataCharacterLimit / 4 * 3 == 72 * 1024)
        #expect(text.contains("about 72 KiB of file bytes"))
        #expect(FileTransferToolCatalog.readFileChunkByteLimit == 16 * 1024)
        #expect(text.contains("at most 16 KiB per call"))
        #expect(text.contains("`reason: \"invalid_argument\"`"))
        #expect(!text.contains("path_denied"))
        #expect(!text.contains("saved credentials"))
        #expect(!text.contains("96 KiB"))
    }
}

/// Skills found on this Mac (SPEC D84), read from temporary home folders.
@Suite(.serialized)
struct FoundSkillTests {
    private let remctlTools = [
        bridgeTool(id: "remctl_lists", upstream: "lists"),
        bridgeTool(id: "remctl_today", upstream: "today")
    ]

    @MainActor
    @Test func aMatchingSkillInEachLocationIsFoundAndStartsNotShared() async throws {
        let home = try SkillHome()
        defer { home.remove() }
        try home.write("home/.claude/skills/remctl", ["SKILL.md": skillText("remctl")])
        try home.write("home/.codex/skills/search-helper", ["SKILL.md": skillText("rg")])
        try home.write("home/.agents/skills/castctl", ["SKILL.md": skillText("castctl")])
        try home.write("home/.claude/plugins/cache/market/castctl/1.2.0/skills/old-episodes", [
            "SKILL.md": skillText("old-episodes")
        ])
        try home.write("home/.claude/plugins/cache/market/castctl/1.10.0/skills/episodes", [
            "SKILL.md": skillText("episodes")
        ])
        try home.write("home/.claude/skills/unrelated", ["SKILL.md": skillText("unrelated")])

        let suiteName = "MacRemoteFoundSkillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ToolRegistryStore(fileURL: home.root.appendingPathComponent("tools.json"))
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: store,
            localMCPScanner: LocalMCPScanner(homeDirectory: home.home, executablePath: { _ in nil })
        )
        _ = try model.replaceLocalMCPBridgeTools(remctlTools, bridgeIdentity: remctlTools[0].mcpBridgeIdentity)
        model.tools += [
            processTool(id: "rg", executable: try home.executable("rg"), flexible: true),
            processTool(id: "castctl_up_next", executable: try home.executable("castctl"))
        ]

        await model.refreshFoundSkills().value

        let found = model.knownSkills.filter { $0.familyID != nil }
        #expect(found.map(\.name).sorted() == ["castctl", "episodes", "remctl", "rg"])
        #expect(found.map(\.originDescription).sorted() == [
            "Found in Claude's castctl plugin",
            "Found in your Claude skills",
            "Found in your Codex skills",
            "Found in your agent skills"
        ])
        #expect(found.allSatisfy { $0.refusal == nil && !model.isSkillShared($0) })
        #expect(model.skillRegistry.servedCatalog(sharing: model.skillSharing).entries.map(\.uri) == [
            "skill://macremote/SKILL.md"
        ])
        // Counts only: a log never lists what is on the owner's disk.
        #expect(model.logs.contains { $0.message.hasPrefix("Found 4 skills on this Mac") })
        #expect(!model.logs.contains { $0.message.contains("unrelated") || $0.message.contains("episodes") })

        // Removing the family removes its skill.
        for tool in remctlTools {
            #expect(model.deleteUserTool(id: tool.id) == nil)
        }
        #expect(!model.knownSkills.contains { $0.name == "remctl" })
        #expect(model.knownSkills.contains { $0.name == "rg" })
    }

    @Test func aSkillForAToolMacRemoteDoesNotHaveIsNotRead() throws {
        let home = try SkillHome()
        defer { home.remove() }
        try home.write("home/.claude/skills/unrelated", ["SKILL.md": skillText("unrelated")])
        try home.write("home/.claude/plugins/cache/market/other/1.0.0/skills/other", ["SKILL.md": skillText("other")])

        #expect(home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools)).isEmpty)
        #expect(home.scanner.scan(families: []).isEmpty)
    }

    @Test func aLinkedSkillFolderIsReadWithoutLeavingIt() throws {
        let home = try SkillHome()
        defer { home.remove() }
        let outside = try home.write("outside", ["secret.md": "Secret.\n"])
        let repository = try home.write("repository", [
            "SKILL.md": skillText("remctl"),
            "README.md": "Not part of the skill.\n",
            "references/guide.md": "Guide.\n",
            "references/notes.txt": "Not Markdown.\n"
        ])
        try home.link("home/.claude/skills/remctl", to: repository)

        let found = home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools))
        let skill = try #require(found.first)
        #expect(found.count == 1)
        #expect(skill.refusal == nil)
        #expect(skill.folder == realPath(repository))
        #expect(skill.files.map(\.path) == ["SKILL.md", "references/guide.md"])

        // A reference that links out is never followed, and the skill is
        // refused rather than served without it.
        try home.link("repository/references/escape.md", to: outside.appendingPathComponent("secret.md"))
        let linked = try #require(home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools)).first)
        #expect(linked.refusal == "references/escape.md is a link. MacRemote reads only files inside the skill's folder.")
        #expect(linked.files.isEmpty)
    }

    /// The scanner matches by the `name` the exact header reader reads, in
    /// every form that reader accepts, not by a looser reading of its own.
    @Test func aSkillMatchesByEveryNameFormTheHeaderReaderAccepts() throws {
        let home = try SkillHome()
        defer { home.remove() }
        let forms = [
            "comment": "---\nname: remctl # the CLI\ndescription: A test skill.\n---\n\nBody\n",
            "spaced": "---\nname : remctl\ndescription: A test skill.\n---\n\nBody\n",
            "quoted": "---\n\"name\": remctl\ndescription: A test skill.\n---\n\nBody\n",
            "block": "---\nname: >-\n  remctl\ndescription: A test skill.\n---\n\nBody\n",
            "crlf": "---\r\nname: remctl\r\ndescription: A test skill.\r\n---\r\n\r\nBody\r\n"
        ]
        for (folder, text) in forms {
            try home.write("home/.claude/skills/\(folder)", ["SKILL.md": text])
        }

        let found = home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools))
        #expect(found.map { URL(fileURLWithPath: $0.folder).lastPathComponent }.sorted() == forms.keys.sorted())
        #expect(found.allSatisfy { $0.name == "remctl" && $0.refusal == nil })
    }

    /// Every Markdown file directly in `references/` is served, whatever the
    /// case of its extension or the characters in its name, at an address
    /// that `resources/read` accepts exactly as listed.
    @Test func everyMarkdownReferenceIsServedAtTheAddressItIsListedAt() async throws {
        let home = try SkillHome()
        defer { home.remove() }
        try home.write("home/.claude/skills/rg", [
            "SKILL.md": skillText("rg"),
            "references/UPPER.MD": "Upper.\n",
            "references/Search Options.md": "Spaced.\n",
            "references/notes.txt": "Not Markdown.\n"
        ])
        let tools = [processTool(id: "rg", executable: "/opt/homebrew/bin/rg", flexible: true)]
        let found = try #require(home.scanner.scan(families: FoundSkillScanner.families(of: tools)).first)
        #expect(found.refusal == nil)
        let skill = Skill(found: found, tools: tools)
        let harness = try await SkillsServerHarness(catalog: { ServedSkillCatalog(skills: [skill]) })
        defer { harness.server.stop() }
        let client = harness.client()

        let list = try #require(try await client.send(method: "skills/list", params: [:]).result)
        let entry = try #require((list["skills"] as? [[String: Any]])?.first)
        let resources = try #require(entry["resources"] as? [[String: Any]])
        #expect(resources.map { $0["uri"] as? String } == [
            "skill://claude-skills/rg/SKILL.md",
            "skill://claude-skills/rg/references/Search%20Options.md",
            "skill://claude-skills/rg/references/UPPER.MD"
        ])
        for resource in resources {
            let read = try await readSkillFile(client, uri: try #require(resource["uri"] as? String))
            #expect(resource["size"] as? Int == read.data.count)
            #expect(resource["digest"] as? String == sha256(read.data))
        }
        let spaced = try await readSkillFile(client, uri: "skill://claude-skills/rg/references/Search%20Options.md")
        #expect(spaced.data == Data("Spaced.\n".utf8))
    }

    /// A skill with more files than a skill may have says so.
    @Test func aSkillWithTooManyFilesSaysSo() throws {
        let home = try SkillHome()
        defer { home.remove() }
        var files = ["SKILL.md": skillText("remctl")]
        for index in 1...MCPUpstreamSkillCollector.maximumFilesPerSkill {
            files["references/part-\(index).md"] = "Part \(index).\n"
        }
        try home.write("home/.claude/skills/remctl", files)

        let found = try #require(home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools)).first)
        #expect(found.refusal == "It has 513 files; a skill can have at most 512.")
    }

    /// The newest plugin version is chosen by semantic version before
    /// modification time: a release beats its own beta.
    @Test func aPluginReleaseBeatsItsBetaWhateverChangedLast() throws {
        let home = try SkillHome()
        defer { home.remove() }
        let plugin = "home/.claude/plugins/cache/market/remctl"
        try home.write("\(plugin)/2.1.0/skills/stable", ["SKILL.md": skillText("stable")])
        try home.write("\(plugin)/2.1.0-beta.1/skills/preview", ["SKILL.md": skillText("preview")])
        try home.write("\(plugin)/2.0.9/skills/older", ["SKILL.md": skillText("older")])
        let older = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes(
            [.modificationDate: older],
            ofItemAtPath: home.root.appendingPathComponent("\(plugin)/2.1.0").path
        )

        let found = home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools))
        #expect(found.map(\.name) == ["stable"])
    }

    /// A note names only the tools apps can call, and it follows the owner's
    /// sharing. A skill whose tools are all Not Shared stays listed but is
    /// left out of what apps get, with the reason.
    @MainActor
    @Test func notesNameOnlySharedToolsAndASkillWithNoneIsLeftOut() async throws {
        let home = try SkillHome()
        defer { home.remove() }
        try home.write("home/.claude/skills/rg", ["SKILL.md": skillText("rg")])
        let suiteName = "MacRemoteFoundSkillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: home.root.appendingPathComponent("tools.json")),
            localMCPScanner: LocalMCPScanner(homeDirectory: home.home, executablePath: { _ in nil })
        )
        let rg = try home.executable("rg")
        model.tools += [processTool(id: "rg", executable: rg, flexible: true), processTool(id: "rg_count", executable: rg)]
        _ = try model.replaceLocalMCPBridgeTools(remctlTools, bridgeIdentity: remctlTools[0].mcpBridgeIdentity)
        model.recordBridgedSkills([upstreamSkill(name: "reminders")], importedTools: remctlTools)
        await model.refreshFoundSkills().value
        for skill in model.knownSkills where skill.origin != .builtIn {
            #expect(model.setSkillShared(skill, isShared: true) == nil)
        }
        func served(_ name: String) -> ServedSkillCatalog.File? {
            model.skillRegistry.servedCatalog(sharing: model.skillSharing).entries
                .first { $0.frontmatter["name"] == .string(name) }?.files.first
        }
        let allShared = try #require(served("rg"))

        #expect(model.setToolEnabled(id: "rg", enabled: false) == nil)
        #expect(model.setToolEnabled(id: "remctl_lists", enabled: false) == nil)
        let found = try #require(served("rg"))
        #expect(found.text.contains("run `rg` with these MacRemote tools instead: `rg_count`.\n"))
        #expect(found.digest != allShared.digest)
        #expect(try #require(served("reminders")).text.contains(
            "MacRemote names that server's tools with a `remctl_` prefix, so `today` in this skill is `remctl_today` here.\n"
        ))

        #expect(model.setToolEnabled(id: "rg_count", enabled: false) == nil)
        let rgSkill = try #require(model.knownSkills.first { $0.name == "rg" })
        let catalog = model.skillRegistry.servedCatalog(sharing: model.skillSharing)
        #expect(!catalog.entries.contains { $0.skillID == rgSkill.id })
        #expect(catalog.omissions[rgSkill.id] == "None of its tools are shared.")
    }

    /// The inspector previews an unshared skill through the catalog that
    /// serves: after a name clash, the name, address, and bytes it shows are
    /// the ones sharing publishes; with no shared tool, it shows why sharing
    /// would still leave the skill out.
    @MainActor
    @Test func theInspectorPreviewsWhatSharingWouldPublish() async throws {
        let (model, done) = try await skillModel()
        defer { done() }
        let bridged = try #require(model.knownSkills.first { $0.name == "rg" && $0.uriAuthority == "remctl" })
        let found = try #require(model.knownSkills.first { $0.name == "rg" && $0.uriAuthority == "claude-skills" })
        #expect(model.setSkillShared(bridged, isShared: true) == nil)

        let preview = model.skillPreview(found)
        #expect(preview.state == .notShared)
        #expect(preview.filesHeading == "What Apps Would Read")
        #expect(preview.warning == nil)
        let entry = try #require(preview.entry)
        #expect(entry.uri == "skill://claude-skills/claude-skills-rg/SKILL.md")
        #expect(entry.frontmatter["name"] == .string("claude-skills-rg"))
        #expect(preview.files.first?.text.hasPrefix("---\nname: claude-skills-rg\n") == true)

        #expect(model.setSkillShared(found, isShared: true) == nil)
        let published = try #require(
            model.skillRegistry.servedCatalog(sharing: model.skillSharing).entries.first { $0.skillID == found.id }
        )
        #expect(published.uri == entry.uri)
        #expect(published.files.map(\.digest) == entry.files.map(\.digest))
        #expect(model.skillPreview(found).filesHeading == "What Apps Read")

        #expect(model.setSkillShared(found, isShared: false) == nil)
        #expect(model.setToolEnabled(id: "rg", enabled: false) == nil)
        let withoutTools = model.skillPreview(try #require(model.knownSkills.first { $0.id == found.id }))
        #expect(withoutTools.entry == nil)
        #expect(withoutTools.omissionIfShared == "None of its tools are shared.")
        #expect(withoutTools.warning == "If you share it, apps still won't get it. None of its tools are shared.")
        #expect(withoutTools.filesHeading == "Files")
    }

    /// A shared skill the catalog leaves out never looks shared: its state,
    /// the line under its row, the section's shared count, and the
    /// inspector's heading all say apps don't get it, and why.
    @MainActor
    @Test func aSharedSkillAppsDoNotGetNeverLooksShared() async throws {
        let (model, done) = try await skillModel()
        defer { done() }
        for skill in model.knownSkills where skill.origin != .builtIn {
            #expect(model.setSkillShared(skill, isShared: true) == nil)
        }
        let clashes = model.knownSkills.filter { $0.name == "dup" }
        #expect(clashes.count == 3)
        #expect(clashes.map(model.skillState) == [
            .served,
            .served,
            .leftOut("Another shared skill already uses the name dup.")
        ])

        #expect(model.setToolEnabled(id: "rg", enabled: false) == nil)
        let found = try #require(model.knownSkills.first { $0.uriAuthority == "claude-skills" })
        #expect(model.isSkillShared(found))
        let state = model.skillState(found)
        #expect(state == .leftOut("None of its tools are shared."))
        #expect(state.warning == "Apps don't get this skill. None of its tools are shared.")
        let preview = model.skillPreview(found)
        #expect(preview.entry == nil)
        #expect(preview.filesHeading == "Files")

        // The section's "N shared": the built-in, `rg` and two `dup` from
        // RemCTL; not the third `dup` nor the found `rg`.
        #expect(model.knownSkills.count { model.skillState($0) == .served } == 4)
        #expect(model.skillPreview(try #require(model.knownSkills.first)).filesHeading == "What Apps Read")
    }

    /// An app model in a temporary home with an `rg` command (one Flexible
    /// Command), RemCTL bridged with skills `rg` and three `dup`, and an `rg`
    /// skill in `~/.claude/skills`.
    @MainActor
    private func skillModel() async throws -> (AppModel, () -> Void) {
        let home = try SkillHome()
        try home.write("home/.claude/skills/rg", ["SKILL.md": skillText("rg")])
        let suiteName = "MacRemoteFoundSkillTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: home.root.appendingPathComponent("tools.json")),
            localMCPScanner: LocalMCPScanner(homeDirectory: home.home, executablePath: { _ in nil })
        )
        model.tools.append(processTool(id: "rg", executable: try home.executable("rg"), flexible: true))
        _ = try model.replaceLocalMCPBridgeTools(remctlTools, bridgeIdentity: remctlTools[0].mcpBridgeIdentity)
        model.recordBridgedSkills([
            upstreamSkill(name: "rg"),
            upstreamSkill(name: "dup", uri: "skill://remctl/a/dup/SKILL.md"),
            upstreamSkill(name: "dup", uri: "skill://remctl/b/dup/SKILL.md"),
            upstreamSkill(name: "dup", uri: "skill://remctl/c/dup/SKILL.md")
        ], importedTools: remctlTools)
        await model.refreshFoundSkills().value
        return (model, {
            defaults.removePersistentDomain(forName: suiteName)
            home.remove()
        })
    }

    @Test func aSkillInAProtectedLocationIsSkipped() throws {
        let home = try SkillHome()
        defer { home.remove() }
        let hidden = try home.write("home/.ssh/remctl", ["SKILL.md": skillText("remctl")])
        try home.link("home/.claude/skills/remctl", to: hidden)

        #expect(home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools)).isEmpty)
    }

    @Test func anUnreadableHeaderRefusesTheSkillWithAReason() throws {
        let home = try SkillHome()
        defer { home.remove() }
        try home.write("home/.claude/skills/remctl", [
            "SKILL.md": "---\nname: remctl\ndescription: Reminders.\nallowed-tools:\n  - Bash\n---\n\nBody\n"
        ])

        let found = home.scanner.scan(families: FoundSkillScanner.families(of: remctlTools))
        let skill = Skill(found: try #require(found.first), tools: remctlTools)
        #expect(skill.name == "remctl")
        #expect(skill.refusal == "Line 5 of its header uses YAML that MacRemote doesn't read.")
        #expect(skill.files.isEmpty)
        #expect(ServedSkillCatalog(skills: [skill]).entries.isEmpty)
    }

    /// Shared, a found skill is served with MacRemote's note, digests over
    /// the served bytes, and its origin in `_meta`.
    @Test func aSharedFoundSkillIsServedWithItsNoteDigestAndOrigin() async throws {
        let home = try SkillHome()
        defer { home.remove() }
        try home.write("home/.claude/skills/rg", [
            "SKILL.md": skillText("rg", "Search files with ripgrep.", body: "# rg\n\nRun `rg pattern`.\n"),
            "references/flags.md": "Flags.\n"
        ])
        let tools = [
            processTool(id: "rg_count", executable: "/opt/homebrew/bin/rg"),
            processTool(id: "rg", executable: "/opt/homebrew/bin/rg", flexible: true)
        ]
        let registry = SkillRegistry(fileURL: home.root.appendingPathComponent("bridged-skills.json"))
        registry.replaceFoundSkills(home.scanner.scan(families: FoundSkillScanner.families(of: tools)))
        let skill = try #require(
            registry.rebuild(tools: tools, sharedToolIDs: Set(tools.map(\.id)), pruning: true).first { $0.name == "rg" }
        )
        let sharing = SkillSharingPreferences(choices: [skill.id: true])
        let harness = try await SkillsServerHarness(catalog: { registry.servedCatalog(sharing: sharing) })
        defer { harness.server.stop() }
        let client = harness.client()

        let list = try #require(try await client.send(method: "skills/list", params: [:]).result)
        let entries = try #require(list["skills"] as? [[String: Any]])
        #expect(entries.map { $0["uri"] as? String } == ["skill://macremote/SKILL.md", "skill://claude-skills/rg/SKILL.md"])
        #expect(entries[0]["_meta"] == nil)
        let meta = try #require(entries[1]["_meta"] as? [String: Any])
        #expect(meta["net.viticci.macremote/origin"] as? String == "Claude skills on the Mac")

        let resources = try #require(entries[1]["resources"] as? [[String: Any]])
        #expect(resources.map { $0["uri"] as? String } == [
            "skill://claude-skills/rg/SKILL.md", "skill://claude-skills/rg/references/flags.md"
        ])
        for resource in resources {
            let read = try await readSkillFile(client, uri: try #require(resource["uri"] as? String))
            #expect(resource["size"] as? Int == read.data.count)
            #expect(resource["digest"] as? String == sha256(read.data))
        }
        let served = String(decoding: try await readSkillFile(client, uri: "skill://claude-skills/rg/SKILL.md").data, as: UTF8.self)
        #expect(served == "---\nname: rg\ndescription: Search files with ripgrep.\n---\n\n"
            + "This skill was written for a terminal on the Mac. Through MacRemote there is no shell:"
            + " run `rg` with these MacRemote tools instead: `rg`, `rg_count`.\n\n# rg\n\nRun `rg pattern`.\n")
    }
}

// MARK: - Fixtures

private struct SkillsServerHarness {
    static let token = "skills-test-token"
    let server: LocalMCPServer
    let mcpURL: URL

    init(catalog: @escaping @Sendable () -> ServedSkillCatalog) async throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(Self.token, clientName: "Skills Tests")
        let server = LocalMCPServer(
            instanceID: "skills-test",
            tools: [],
            skillCatalog: catalog,
            authCoordinator: coordinator,
            toolExecutor: NoToolExecutor()
        )
        let port = try server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        self.server = server
        self.mcpURL = base.appendingPathComponent("mcp/skills-test")
        for _ in 0..<50 {
            if let (_, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("health")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        server.stop()
        throw URLError(.timedOut)
    }

    func client(_ mode: MCPTestProtocolMode = .modern()) -> MCPTestClient {
        MCPTestClient(baseURL: mcpURL, bearerToken: Self.token, mode: mode)
    }
}

private struct NoToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters _: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        throw ToolValidationError.invalidMCPBridge("no tools in this test")
    }
}

/// A stdio MCP server that declares the Skills extension (mode `skills`) or
/// not (mode `plain`). Its listing spans two pages: `reminders` with one
/// reference file, `tampered` whose notes change after they are listed, and
/// `live`, whose resources are dynamic. It records every method it receives.
private final class UpstreamSkillsFixture: @unchecked Sendable {
    static let guide = "Reference notes.\n"
    private let directory = temporaryDirectory()
    private var serverURL: URL { directory.appendingPathComponent("server.py") }
    private var methodsURL: URL { directory.appendingPathComponent("methods.txt") }

    init() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(Self.script.utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
    }

    func probe(mode: String) async throws -> LocalMCPProbeResult {
        try await MCPStdioBridgeClient(environment: ProcessInfo.processInfo.environment).probe(
            command: serverURL.path,
            args: [mode, methodsURL.path],
            environmentVariables: [],
            protocolVersion: "2025-06-18",
            timeoutSeconds: 10
        )
    }

    func methods() throws -> [String] {
        try String(contentsOf: methodsURL, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static let script = #"""
    #!/usr/bin/env python3
    import hashlib, json, sys
    mode, methods_path = sys.argv[1], sys.argv[2]
    listed = {
        "skill://remctl/reminders/SKILL.md": "---\nname: reminders\ndescription: Work with reminders.\n---\n\n# Reminders\n\nCall `lists` first.\n",
        "skill://remctl/reminders/references/guide.md": "Reference notes.\n",
        "skill://remctl/tampered/SKILL.md": "---\nname: tampered\ndescription: Its notes change.\n---\n\nRead the notes.\n",
        "skill://remctl/tampered/references/notes.md": "Original notes.\n",
    }
    served = dict(listed)
    served["skill://remctl/tampered/references/notes.md"] = "Changed notes.\n"
    def entry(name, description):
        root = "skill://remctl/%s/" % name
        return {"uri": root + "SKILL.md", "frontmatter": {"name": name, "description": description},
                "resources": [{"uri": uri, "size": len(text.encode()),
                               "digest": "sha256:" + hashlib.sha256(text.encode()).hexdigest()}
                              for uri, text in listed.items() if uri.startswith(root)]}
    def result(method, params):
        if method == "server/discover":
            capabilities = {"tools": {}, "resources": {}}
            if mode == "skills":
                capabilities["extensions"] = {"io.modelcontextprotocol/skills": {}}
            return {"supportedVersions": ["2026-07-28"], "capabilities": capabilities}
        if method == "tools/list":
            return {"tools": [{"name": "lists", "inputSchema": {"type": "object"}}]}
        if method == "skills/list" and mode == "skills":
            if not params.get("cursor"):
                return {"skills": [entry("reminders", "Work with reminders.")], "nextCursor": "page-2"}
            return {"skills": [entry("tampered", "Its notes change."),
                               {"uri": "skill://remctl/live/SKILL.md",
                                "frontmatter": {"name": "live", "description": "Made on request."},
                                "resources": "dynamic"}]}
        if method == "resources/read" and params.get("uri") in served:
            uri = params["uri"]
            return {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": served[uri]}]}
        return None
    for line in sys.stdin:
        message = json.loads(line)
        if "id" not in message:
            continue
        method, params = message.get("method"), message.get("params") or {}
        with open(methods_path, "a") as log:
            log.write(method + "\n")
        value = result(method, params)
        if value is None:
            reply = {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "Method not found"}}
        else:
            value.update({"resultType": "complete", "ttlMs": 0, "cacheScope": "private"})
            reply = {"jsonrpc": "2.0", "id": message["id"], "result": value}
        print(json.dumps(reply), flush=True)
    """#
}

private func upstreamSkill(
    name: String,
    uri: String? = nil,
    text: String? = nil,
    frontmatter: [String: JSONValue]? = nil
) -> MCPUpstreamSkill {
    let text = text ?? "---\nname: \(name)\ndescription: Test skill \(name).\n---\n\n# \(name)\n"
    return MCPUpstreamSkill(
        uri: uri ?? "skill://test/\(name)/SKILL.md",
        name: name,
        frontmatter: frontmatter ?? ["name": .string(name), "description": .string("Test skill \(name).")],
        files: [Skill.File(path: "SKILL.md", data: Data(text.utf8), mediaType: "text/markdown")],
        refusal: nil
    )
}

private func processTool(id: String, executable: String, flexible: Bool = false) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: id,
        summary: "Process tool.",
        executablePath: executable,
        argumentPattern: flexible ? ["{args}"] : ["--version"],
        parameters: flexible ? [ToolParameter(name: "args", title: "Arguments", kind: .stringArray)] : [],
        capability: flexible ? .destructive : .readOnly,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined,
        category: .developer
    )
}

/// A temporary home folder for the disk scanner, with an `outside` folder
/// next to it for links that point out of a skill.
private struct SkillHome {
    let root = temporaryDirectory()
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var scanner: FoundSkillScanner { FoundSkillScanner(homeDirectory: home.path) }

    init() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    /// Writes `files` (relative path to text) under `folder`, relative to `root`.
    @discardableResult
    func write(_ folder: String, _ files: [String: String]) throws -> URL {
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        for (path, text) in files {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return directory
    }

    /// A runnable stand-in for a command-line tool, so a tool that uses it
    /// can be saved. Its file name is what a skill matches.
    func executable(_ name: String) throws -> String {
        let url = root.appendingPathComponent("bin/\(name)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    func link(_ path: String, to destination: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func skillText(_ name: String, _ description: String = "A test skill.", body: String = "# Body\n") -> String {
    "---\nname: \(name)\ndescription: \(description)\n---\n\n\(body)"
}

/// The path `realpath(3)` gives, as the scanner records it. Foundation's own
/// resolution drops `/private` from temporary paths, so it would not match.
private func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

private func bridgeTool(id: String, upstream: String) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: "RemCTL: \(upstream)",
        summary: "Bridge tool.",
        executablePath: "",
        argumentPattern: [],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined,
        category: .developer,
        backend: .mcpHTTPBridge,
        mcpBridge: MCPBridgeConfiguration(
            serverIdentity: "skills-test.remctl",
            serverName: "RemCTL",
            serverURL: "http://127.0.0.1:49123/mcp",
            toolName: upstream
        )
    )
}

private func listedURIs(_ client: MCPTestClient) async throws -> [String] {
    let result = try #require(try await client.send(method: "skills/list", params: [:]).result)
    return (result["skills"] as? [[String: Any]] ?? []).compactMap { $0["uri"] as? String }
}

private func readSkillFile(_ client: MCPTestClient, uri: String) async throws -> (data: Data, mimeType: String?) {
    let result = try #require(try await client.send(method: "resources/read", params: ["uri": uri]).result)
    expectCacheable(result)
    let contents = try #require(result["contents"] as? [[String: Any]])
    #expect(contents.count == 1)
    #expect(contents.first?["uri"] as? String == uri)
    return (Data(try #require(contents.first?["text"] as? String).utf8), contents.first?["mimeType"] as? String)
}

private func expectCacheable(_ result: [String: Any], sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result["resultType"] as? String == "complete", sourceLocation: sourceLocation)
    #expect(result["ttlMs"] as? Int == 0, sourceLocation: sourceLocation)
    #expect(result["cacheScope"] as? String == "private", sourceLocation: sourceLocation)
}

private func sha256(_ data: Data) -> String {
    "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mcp-skills-\(UUID().uuidString)", isDirectory: true)
}
