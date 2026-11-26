import Foundation
import Testing
@testable import MacRemote

/// SPEC D86: PhotoCTL and MusicCTL are first-party MCP providers, legacy
/// MusicCTL process tools are carried over, a plain `photoctl` family is
/// adopted, an added CLI re-imports itself when its executable changes, and
/// the Library and the Federico Viticci source follow what is installed.
/// SPEC D87: legacy RemCTL and NotesCTL process tools are carried over too,
/// a bridged tool on a suffixed id moves to its legacy row's plain id, and a
/// leftover legacy row the owner never shared is removed.
///
/// Every server here is a fake stdio MCP server in a temporary home. It lists
/// tools and runs none; each start appends a line to `<name>.launches`.
@Suite("First-party catalog follows what is installed", .serialized)
struct FirstPartyCatalogFollowsInstallTests {
    // MARK: Detection

    @Test("PhotoCTL and MusicCTL are detected, and a config row that launches their server folds into the provider")
    func detectionAndFold() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let photo = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        let music = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let mctl = fixture.bin.appendingPathComponent("mctl")
        try FileManager.default.createSymbolicLink(at: mctl, withDestinationURL: music)
        // The rows `photoctl mcp install` and `musicctl mcp install` write.
        try fixture.writeClaudeDesktopConfig([
            "photoctl": (photo.path, ["mcp", "serve"]),
            "musicctl": (mctl.path, ["mcp", "serve", "--client", "claude-desktop"])
        ])

        let detected = FirstPartyMCPProviderCatalog.detectedProviders(using: fixture.locate)
        #expect(detected.map(\.provider.id) == ["provider.photoctl", "provider.musicctl"])
        // MailCTL installs an `mctl` too, so that name alone is not MusicCTL.
        // A config row that runs an `mctl` linked to MusicCTL's own file
        // still folds below: it is the same executable.
        let aliasOnly = FirstPartyMCPProviderCatalog.detectedProviders(using: { $0 == "mctl" ? mctl.path : nil })
        #expect(aliasOnly.isEmpty)

        let candidates = await fixture.scanner().scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        let photoRows = candidates.filter { $0.name == "photoctl" }
        let musicRows = candidates.filter { $0.name == "musicctl" }
        #expect(photoRows.map(\.id) == ["first_party.photoctl"])
        #expect(musicRows.map(\.id) == ["first_party.musicctl"])
        #expect(photoRows.first?.args == ["mcp", "serve"])
        #expect(musicRows.first?.command == music.path)
        #expect(Set(photoRows.first?.configurationOwners.map(\.source) ?? []) == ["first_party", "claude_desktop"])
        #expect(Set(musicRows.first?.configurationOwners.map(\.source) ?? []) == ["first_party", "claude_desktop"])
    }

    @Test("The flexible run tools and destructive tools ask every time, and New Releases keeps its hour")
    func providerPolicy() {
        func bridged(_ provider: FirstPartyMCPProvider, _ name: String, _ capability: ToolCapability) -> ToolDefinition {
            ToolDefinition(
                id: name, name: name, summary: "Upstream.", executablePath: "", argumentPattern: [],
                parameters: [], capability: capability, timeoutSeconds: 60, outputByteLimit: 1024,
                origin: .userDefined, category: .developer, backend: .mcpStdioBridge,
                mcpStdioBridge: MCPStdioBridgeConfiguration(
                    serverName: provider.name, command: "/fake/\(provider.serverName)",
                    args: ["mcp", "serve"], toolName: name
                )
            )
        }
        let photo = FirstPartyMCPProviderCatalog.photoCTL
        let photos = Dictionary(uniqueKeysWithValues: FirstPartyMCPProviderCatalog.applyPolicy(photo, to: [
            bridged(photo, "photoctl_search", .readOnly),
            bridged(photo, "photoctl_export", .write),
            // PhotoCTL's own server marks its flexible command read-only.
            bridged(photo, "photoctl_run", .readOnly)
        ]).map { ($0.id, $0) })
        #expect(photos["photoctl_search"]?.category == .imageProcessing)
        #expect(photos["photoctl_search"]?.asksBeforeRunning == false)
        #expect(photos["photoctl_export"]?.asksBeforeRunning == true)
        #expect(photos["photoctl_export"]?.approvalPolicy == .standard)
        #expect(photos["photoctl_run"]?.asksBeforeRunning == true)
        #expect(photos["photoctl_run"]?.approvalPolicy == .everyCall)

        let music = FirstPartyMCPProviderCatalog.musicCTL
        let tracks = Dictionary(uniqueKeysWithValues: FirstPartyMCPProviderCatalog.applyPolicy(music, to: [
            bridged(music, "musicctl_search", .readOnly),
            bridged(music, "musicctl_player_control", .write),
            bridged(music, "musicctl_rating_clear", .destructive),
            bridged(music, "musicctl_run", .write),
            bridged(music, "musicctl_new_releases", .readOnly)
        ]).map { ($0.id, $0) })
        #expect(tracks["musicctl_search"]?.category == .music)
        #expect(tracks["musicctl_player_control"]?.approvalPolicy == .standard)
        #expect(tracks["musicctl_rating_clear"]?.approvalPolicy == .everyCall)
        #expect(tracks["musicctl_run"]?.approvalPolicy == .everyCall)
        #expect(tracks["musicctl_new_releases"]?.timeoutSeconds == 3_600)
        #expect(tracks["musicctl_search"]?.timeoutSeconds == 60)

        // A destructive tool no named policy lists asks every call too, for
        // every provider; a write it does not list keeps the standard rule.
        for provider in FirstPartyMCPProviderCatalog.providers {
            let unlisted = FirstPartyMCPProviderCatalog.applyPolicy(provider, to: [
                bridged(provider, "\(provider.serverName)_future_purge", .destructive),
                bridged(provider, "\(provider.serverName)_future_write", .write)
            ])
            #expect(unlisted[0].approvalPolicy == .everyCall, "\(provider.name)")
            #expect(unlisted[1].approvalPolicy == .standard, "\(provider.name)")
        }
    }

    // MARK: Carry-over

    @MainActor
    @Test("Legacy MusicCTL process tools become the bridged tools of the same ids, keeping sharing and losing Always Allow")
    func legacyMusicToolsCarryOver() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [
            ("musicctl_doctor", "ro"), ("musicctl_search", "ro"),
            ("musicctl_player_control", "write"), ("musicctl_run", "write"),
            ("musicctl_charts", "ro"), ("musicctl_rating_clear", "destructive")
        ])
        let legacy = Self.legacyMusicTools(executable: music.path)
        try fixture.saveTools(legacy)
        let model = fixture.makeModel()
        connectClient(model)
        model.disabledToolIDs.insert("musicctl_search")
        model.setToolAlwaysAllowed(true, toolID: "musicctl_player_control", clientID: "client-1")
        #expect(model.isToolAlwaysAllowed(toolID: "musicctl_player_control", clientID: "client-1"))

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 1)
        let bridged = model.tools.filter { $0.id.hasPrefix("musicctl_") }
        #expect(Set(bridged.map(\.id)) == [
            "musicctl_doctor", "musicctl_search", "musicctl_player_control",
            "musicctl_run", "musicctl_charts", "musicctl_rating_clear"
        ])
        #expect(bridged.allSatisfy { $0.mcpStdioBridge?.discoverySource == FirstPartyMCPProviderCatalog.discoverySource })
        #expect(!model.tools.contains { $0.backend == .process })
        // The owner's choices for carried ids stay; new ids start Not Shared.
        #expect(model.isToolIDExposed("musicctl_doctor"))
        #expect(model.isToolIDExposed("musicctl_player_control"))
        #expect(model.isToolIDExposed("musicctl_run"))
        #expect(!model.isToolIDExposed("musicctl_search"))
        #expect(!model.isToolIDExposed("musicctl_charts"))
        #expect(!model.isToolIDExposed("musicctl_rating_clear"))
        // The definition changed, so the grant no longer applies.
        #expect(!model.isToolAlwaysAllowed(toolID: "musicctl_player_control", clientID: "client-1"))
        #expect(model.tool(id: "musicctl_run")?.approvalPolicy == .everyCall)
        #expect(model.logs.contains { $0.message == "MusicCTL updated: 2 tools added, 4 changed." })
    }

    @MainActor
    @Test("A carry-over whose server fails to list its tools changes nothing")
    func carryOverWithFailingProbeChangesNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")], fails: true)
        let legacy = Self.legacyMusicTools(executable: music.path)
        try fixture.saveTools(legacy)
        let model = fixture.makeModel()
        connectClient(model)
        model.disabledToolIDs.insert("musicctl_search")
        model.setToolAlwaysAllowed(true, toolID: "musicctl_player_control", clientID: "client-1")
        let toolsBefore = model.tools
        let disabledBefore = model.disabledToolIDs

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 1)
        #expect(model.tools == toolsBefore)
        #expect(model.disabledToolIDs == disabledBefore)
        #expect(model.isToolAlwaysAllowed(toolID: "musicctl_player_control", clientID: "client-1"))
        #expect(try ToolRegistryStore(fileURL: fixture.storeURL).loadUserDefinedTools() == toolsBefore)
    }

    // MARK: Adoption

    @MainActor
    @Test("A photoctl family imported under a plain name becomes PhotoCTL's family with the same ids and sharing")
    func plainPhotoFamilyIsAdopted() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let photo = try fixture.installServer("photoctl", tools: [
            ("photoctl_albums", "ro"), ("photoctl_search", "ro"), ("photoctl_run", "ro")
        ])
        try fixture.writeClaudeDesktopConfig(["photoctl": (photo.path, ["mcp", "serve"])])

        // Before PhotoCTL was a provider: the Claude Desktop row is a plain
        // server, and the owner added it.
        let before = fixture.makeModel(detectsCLIs: false)
        await fixture.refresh(before)
        before.importLocalMCPServer(candidateID: "claude_desktop.photoctl", intent: .add)
        await fixture.waitForImports(before)
        #expect(Set(before.tools.map(\.id)) == ["photoctl_albums", "photoctl_search", "photoctl_run"])
        #expect(before.tools.allSatisfy { $0.mcpStdioBridge?.discoverySource == "claude_desktop" })
        #expect(before.setToolEnabled(id: "photoctl_search", enabled: false) == nil)

        // Now the catalog knows PhotoCTL: the next refresh adopts the family.
        let after = fixture.makeModel()
        await fixture.refresh(after)

        #expect(fixture.launches("photoctl") == 2)
        #expect(Set(after.tools.map(\.id)) == ["photoctl_albums", "photoctl_search", "photoctl_run"])
        #expect(after.tools.allSatisfy { $0.mcpStdioBridge?.discoverySource == FirstPartyMCPProviderCatalog.discoverySource })
        #expect(after.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.photoCTL).count == 3)
        #expect(after.isToolIDExposed("photoctl_albums"))
        #expect(!after.isToolIDExposed("photoctl_search"))
        // Provider policy applies: the flexible command now asks every time.
        #expect(after.tool(id: "photoctl_run")?.approvalPolicy == .everyCall)
        #expect(after.tool(id: "photoctl_run")?.category == .imageProcessing)
    }

    // MARK: Automatic re-import

    @MainActor
    @Test("An added CLI re-imports once when its executable changes; unchanged, never-added, and failing CLIs do not loop")
    func addedCLIReimportsWhenItsExecutableChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro"), ("musicctl_charts", "ro")])
        _ = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        let model = fixture.makeModel()

        // Installed but never added: nothing launches.
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 0)
        #expect(fixture.launches("photoctl") == 0)

        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(fixture.launches("musicctl") == 1)
        #expect(model.isToolIDExposed("musicctl_search"))

        // Unchanged executable: no process starts.
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 1)

        // The CLI updates: one quiet re-import with the owner's Update rules.
        _ = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro"), ("musicctl_lyrics_current", "ro")], revision: 2)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 2)
        #expect(Set(model.tools.map(\.id)) == ["musicctl_search", "musicctl_lyrics_current"])
        #expect(model.isToolIDExposed("musicctl_search"))
        #expect(!model.isToolIDExposed("musicctl_lyrics_current"))
        #expect(model.logs.contains { $0.message == "MusicCTL updated: 1 tool added, 1 removed." }, "\(model.logs.map(\.message))")

        // A failing update changes nothing and is tried once per refresh.
        let toolsBefore = model.tools
        _ = try fixture.installServer("musicctl", tools: [], revision: 3, fails: true)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 3)
        #expect(model.tools == toolsBefore)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 4)
        #expect(model.tools == toolsBefore)
        #expect(fixture.launches("photoctl") == 0)
    }

    // MARK: Live provider list and the Federico Viticci source

    @MainActor
    @Test("The Library's provider list follows a CLI installed or removed after launch")
    func providerListIsLive() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let model = fixture.makeModel()
        #expect(model.installedFirstPartyProviders.isEmpty)

        let photo = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        model.refreshInstalledFirstPartyProviders()
        #expect(model.installedFirstPartyProviders.map(\.id) == ["provider.photoctl"])
        #expect(DefaultToolPresetCatalog.categories(
            for: .federicoViticci,
            mcpProviders: model.installedFirstPartyProviders
        ).contains(.imageProcessing))

        try FileManager.default.removeItem(at: photo)
        model.refreshInstalledFirstPartyProviders()
        #expect(model.installedFirstPartyProviders.isEmpty)
    }

    @MainActor
    @Test("Federico Viticci holds bridged first-party tools and lists an installed CLI that is not added")
    func federicoSourceIncludesBridgedToolsAndUnaddedProviders() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        _ = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        _ = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        let model = fixture.makeModel()
        await fixture.refresh(model)
        #expect(model.firstPartyProvidersNotAdded.map(\.id) == ["provider.photoctl", "provider.musicctl"])

        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.firstPartyProvidersNotAdded.map(\.id) == ["provider.photoctl"])
        let bridged = try #require(model.tool(id: "musicctl_search"))
        #expect(DefaultToolPresetPublisher.isFedericoTool(bridged))

        let legacy = Self.legacyMusicTools(executable: "/fake/musicctl")[0]
        #expect(DefaultToolPresetPublisher.isFedericoTool(legacy))
        let plain = ToolDefinition(
            id: "other_echo", name: "Echo", summary: "Echo.", executablePath: "", argumentPattern: [],
            parameters: [], capability: .readOnly, timeoutSeconds: 60, outputByteLimit: 1024,
            origin: .userDefined, category: .developer, backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                discoverySource: "claude_desktop", serverName: "other", command: "/fake/other", toolName: "echo"
            )
        )
        #expect(!DefaultToolPresetPublisher.isFedericoTool(plain))
    }

    // MARK: Fix round 1

    @MainActor
    @Test("A quiet import shares no new tool, even when no legacy id carries over")
    func automaticImportSharesNothingNew() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [
            ("musicctl_charts", "ro"), ("musicctl_rating_clear", "destructive")
        ])
        // The owner kept only one retired tool, and this MusicCTL dropped it.
        try fixture.saveTools([Self.legacyMusicTools(executable: music.path)[2]])
        let model = fixture.makeModel()
        #expect(model.isToolIDExposed("musicctl_player_control"))

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 1)
        #expect(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.musicCTL).count == 2)
        #expect(!model.isToolIDExposed("musicctl_charts"))
        #expect(!model.isToolIDExposed("musicctl_rating_clear"))
        // The legacy tool nothing replaced stays exactly as it was.
        #expect(model.tool(id: "musicctl_player_control")?.backend == .process)
        #expect(model.isToolIDExposed("musicctl_player_control"))
    }

    @MainActor
    @Test("Carry-over replaces only ids a bridged tool takes, and two names for one id do not stop the import")
    func carryOverReplacesOnlyWhatItBridges() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [
            ("musicctl_search", "ro"),
            ("search", "ro"),
            // A schema MacRemote cannot mirror: the probe already drops this
            // tool, and the import must leave its legacy row alone.
            ("musicctl_player_control", "badschema"),
            // No schema at all: the probe keeps it, the bridge drops it, and
            // its legacy row must stay too.
            ("musicctl_doctor", "noschema")
        ])
        try fixture.saveTools(Array(Self.legacyMusicTools(executable: music.path)[0...2]))
        let model = fixture.makeModel()
        connectClient(model)
        model.setToolAlwaysAllowed(true, toolID: "musicctl_player_control", clientID: "client-1")
        let legacyControl = try #require(model.tool(id: "musicctl_player_control"))
        let legacyDoctor = try #require(model.tool(id: "musicctl_doctor"))

        await fixture.refresh(model)

        // The import ran: the exact name took the legacy id, the other name
        // got an id of its own.
        let search = try #require(model.tool(id: "musicctl_search"))
        #expect(search.mcpStdioBridge?.toolName == "musicctl_search")
        let other = try #require(model.tools.first { $0.mcpStdioBridge?.toolName == "search" })
        #expect(other.id != "musicctl_search")
        #expect(!model.isToolIDExposed(other.id))
        // The legacy tools whose match was skipped are untouched.
        #expect(model.tool(id: "musicctl_doctor") == legacyDoctor)
        #expect(model.tool(id: "musicctl_player_control") == legacyControl)
        #expect(model.isToolIDExposed("musicctl_player_control"))
        #expect(model.isToolAlwaysAllowed(toolID: "musicctl_player_control", clientID: "client-1"))
    }

    @MainActor
    @Test("Carry-over takes a stock legacy row and leaves one the owner pointed at another executable, shared as it was")
    func editedLegacyToolIsNotCarriedOver() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_doctor", "ro"), ("musicctl_search", "ro")])
        // The owner pointed Search at a wrapper that allows catalog searches only.
        let wrapper = fixture.bin.appendingPathComponent("music-catalog-only")
        try Data("#!/bin/sh\nexec musicctl \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let stock = Self.legacyMusicTools(executable: music.path)[0]
        let edited = Self.legacyMusicTools(executable: wrapper.path)[1]
        try fixture.saveTools([stock, edited])
        let model = fixture.makeModel()
        let editedBefore = try #require(model.tool(id: "musicctl_search"))
        #expect(editedBefore.executablePath == edited.executablePath)
        #expect(model.isToolIDExposed("musicctl_doctor"))
        #expect(model.isToolIDExposed("musicctl_search"))

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 1)
        #expect(model.tool(id: "musicctl_doctor")?.backend == .mcpStdioBridge)
        #expect(model.isToolIDExposed("musicctl_doctor"))
        #expect(model.tool(id: "musicctl_search") == editedBefore)
        #expect(model.isToolIDExposed("musicctl_search"))
        let upstream = try #require(model.tools.first { $0.mcpStdioBridge?.toolName == "musicctl_search" })
        #expect(upstream.id != "musicctl_search")
        #expect(!model.isToolIDExposed(upstream.id))
    }

    @MainActor
    @Test("Carry-over leaves a MusicCTL Flexible Command the owner turned into a fixed command, shared as it was")
    func legacyRunTurnedFixedIsNotCarriedOver() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_doctor", "ro"), ("musicctl_run", "destructive")])
        let legacy = Self.legacyMusicTools(executable: music.path)
        // The owner switched the preset to a fixed command that only reads
        // the player status. It has no typed invocation, like the stock row.
        let statusOnly = ToolDefinition(
            id: "musicctl_run", name: "musicctl_run", summary: "Player status only.", executablePath: music.path,
            argumentPattern: ["player", "status", "--json"], parameters: [], processInvocation: nil,
            capability: .destructive, timeoutSeconds: 30, outputByteLimit: 1024, origin: .userDefined,
            category: .music, approvalPolicy: .everyCall
        )
        try fixture.saveTools([legacy[0], statusOnly])
        let model = fixture.makeModel()
        let editedBefore = try #require(model.tool(id: "musicctl_run"))
        #expect(model.isToolIDExposed("musicctl_run"))

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 1)
        #expect(model.tool(id: "musicctl_doctor")?.backend == .mcpStdioBridge)
        #expect(model.tool(id: "musicctl_run") == editedBefore)
        #expect(model.isToolIDExposed("musicctl_run"))
        let upstream = try #require(model.tools.first { $0.mcpStdioBridge?.toolName == "musicctl_run" })
        #expect(upstream.id != "musicctl_run")
        #expect(!model.isToolIDExposed(upstream.id))
    }

    @MainActor
    @Test("A config row repointed from MusicCTL to PhotoCTL leaves MusicCTL's tools alone and does not add PhotoCTL")
    func repointedConfigRowDoesNotMoveAFamily() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let photo = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        try fixture.writeClaudeDesktopConfig(["local-tools": (music.path, ["mcp", "serve"])])
        let model = fixture.makeModel()
        await fixture.refresh(model)
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        let search = try #require(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.musicCTL).first)
        #expect(model.isToolIDExposed(search.id))

        // The same Claude Desktop row now runs PhotoCTL's server.
        try fixture.writeClaudeDesktopConfig(["local-tools": (photo.path, ["mcp", "serve"])])
        await fixture.refresh(model)

        #expect(fixture.launches("photoctl") == 0)
        #expect(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.photoCTL).isEmpty)
        #expect(model.tool(id: search.id)?.mcpStdioBridge?.serverName == "MusicCTL")
        #expect(model.isToolIDExposed(search.id))

        // The owner adds PhotoCTL: it gets its own tools, and MusicCTL keeps its.
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.photoCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(fixture.launches("photoctl") == 1)
        #expect(!model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.photoCTL).isEmpty)
        #expect(model.tool(id: search.id)?.mcpStdioBridge?.serverName == "MusicCTL")
        #expect(model.isToolIDExposed(search.id))
    }

    @MainActor
    @Test("A never-added MusicCTL whose only legacy tool the owner edited is not imported")
    func onlyEditedLegacyToolsDoNotImport() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_run", "destructive")])
        let statusOnly = ToolDefinition(
            id: "musicctl_run", name: "musicctl_run", summary: "Player status only.", executablePath: music.path,
            argumentPattern: ["player", "status", "--json"], parameters: [], processInvocation: nil,
            capability: .destructive, timeoutSeconds: 30, outputByteLimit: 1024, origin: .userDefined,
            category: .music, approvalPolicy: .everyCall
        )
        try fixture.saveTools([statusOnly])
        let model = fixture.makeModel()

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 0)
        #expect(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.musicCTL).isEmpty)
        #expect(model.tool(id: "musicctl_run")?.argumentPattern == ["player", "status", "--json"])
    }

    @MainActor
    @Test("A CLI that moves keeps its tools and sharing; the import from the new path drops Always Allow")
    func movedExecutableKeepsTheFamily() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("remctl", tools: [("remctl_today", "ro"), ("remctl_search", "ro")])
        let first = fixture.makeModel()
        first.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        await fixture.waitForImports(first)
        #expect(first.setToolEnabled(id: "remctl_search", enabled: false) == nil)
        connectClient(first)
        first.setToolAlwaysAllowed(true, toolID: "remctl_today", clientID: "client-1")
        // Save the owner the way 226a2d0 did: keyed by the executable path.
        try fixture.rewriteStoredTools(
            replacing: FirstPartyMCPProviderCatalog.ownerIdentity(for: FirstPartyMCPProviderCatalog.remCTL),
            with: "first_party.remctl.0123456789abcdef"
        )

        // `~/bin/remctl` moves to `~/.local/bin/remctl`, and its first
        // listing there fails.
        try FileManager.default.removeItem(at: fixture.bin.appendingPathComponent("remctl"))
        let moved = try fixture.installServer("remctl", tools: [("remctl_today", "ro"), ("remctl_search", "ro")], fails: true, in: fixture.localBin)
        let model = fixture.makeModel()
        connectClient(model)
        await fixture.refresh(model)
        #expect(fixture.launches("remctl", in: fixture.localBin) == 1)
        #expect(Set(model.tools.map(\.id)) == ["remctl_today", "remctl_search"])
        #expect(model.isToolIDExposed("remctl_today"))
        #expect(!model.isToolIDExposed("remctl_search"))

        // The next listing works: same ids and sharing, the new path, and no
        // Always Allow for a tool that now runs another file.
        try fixture.setTools("remctl", [("remctl_today", "ro"), ("remctl_search", "ro")], in: fixture.localBin)
        await fixture.refresh(model)
        #expect(fixture.launches("remctl", in: fixture.localBin) == 2)
        #expect(Set(model.tools.map(\.id)) == ["remctl_today", "remctl_search"])
        #expect(model.tools.allSatisfy { $0.mcpStdioBridge?.command == moved.path })
        #expect(model.isToolIDExposed("remctl_today"))
        #expect(!model.isToolIDExposed("remctl_search"))
        #expect(!model.isToolAlwaysAllowed(toolID: "remctl_today", clientID: "client-1"))
    }

    @MainActor
    @Test("A failed quiet import is tried again on the next activation, once, with nothing changed on disk")
    func failedImportRetriesOnActivation() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(fixture.launches("musicctl") == 1)

        try fixture.installServer("musicctl", tools: [], revision: 2, fails: true)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 2)

        // No config or executable changed since that refresh.
        await fixture.activate(model)
        #expect(fixture.launches("musicctl") == 3)
        await fixture.activate(model)
        #expect(fixture.launches("musicctl") == 4)

        // Once it works, an activation with nothing new starts nothing.
        try fixture.setTools("musicctl", [("musicctl_search", "ro")])
        await fixture.activate(model)
        #expect(fixture.launches("musicctl") == 5)
        await fixture.activate(model)
        #expect(fixture.launches("musicctl") == 5)
    }

    @MainActor
    @Test("Update lists the installed CLI's tools again instead of reusing the last listing")
    func updateListsFresh() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)

        // A wrapper upgrade: the listing changes, the launcher file does not.
        try fixture.setTools("musicctl", [("musicctl_search", "ro"), ("musicctl_charts", "ro")])
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .update)
        await fixture.waitForImports(model)

        #expect(fixture.launches("musicctl") == 2)
        #expect(Set(model.tools.map(\.id)) == ["musicctl_search", "musicctl_charts"])
        #expect(!model.isToolIDExposed("musicctl_charts"))
    }

    @MainActor
    @Test("An Add that waits for a scan or another import runs in turn, and a failed Add says why on its row")
    func queuedImportsWaitTheirTurn() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        try fixture.installServer("remctl", tools: [("remctl_today", "ro")])
        try fixture.installServer("mailctl", tools: [], fails: true)
        let model = fixture.makeModel()

        // Two Adds back to back: the second waits for the first.
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.photoCTL, intent: .add)
        #expect(model.hasPendingFirstPartyImports)
        await fixture.waitForImports(model)
        #expect(model.tool(id: "musicctl_search") != nil)
        #expect(model.tool(id: "photoctl_albums") != nil)

        // An Add pressed while a scan runs waits for the scan.
        model.scanLocalMCPServers()
        #expect(model.localMCPScanState.isScanning)
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.tool(id: "remctl_today") != nil)

        // A failed Add leaves its reason with that provider only.
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.mailCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.firstPartyImportErrors["provider.mailctl"] != nil)
        #expect(model.firstPartyImportErrors["provider.remctl"] == nil)
        try fixture.setTools("mailctl", [("mailctl_inbox", "ro")])
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.mailCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.firstPartyImportErrors["provider.mailctl"] == nil)
    }

    @MainActor
    @Test("A quiet import writes one Activity line when its tools changed, counting a title change, and none otherwise")
    func quietImportWritesOneLine() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro"), ("musicctl_charts", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        model.serverStatus = .running(URL(string: "http://127.0.0.1:61234")!)
        // Activity is newest first: the lines since `mark` lead the list.
        func importLines(after mark: Int) -> [String] {
            model.logs.prefix(model.logs.count - mark).map(\.message).filter {
                $0.contains("MusicCTL") || $0.contains("Updated shared tools")
            }
        }

        // Only a title changes.
        var mark = model.logs.count
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro"), ("musicctl_charts", "ro")], revision: 2, titles: ["musicctl_charts": "Top Charts"])
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 2)
        #expect(importLines(after: mark) == ["MusicCTL updated: 1 tool changed."])

        // A new executable that lists the very same tools.
        mark = model.logs.count
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro"), ("musicctl_charts", "ro")], revision: 3, titles: ["musicctl_charts": "Top Charts"])
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 3)
        #expect(importLines(after: mark).isEmpty)
    }

    @MainActor
    @Test("Found on This Mac shows an installed provider once, even with a raw hit saved by an earlier scan")
    func foundFoldsSavedProviderHits() throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let photo = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        try fixture.saveCLIScan([
            Self.scanHit("photoctl", path: photo.path),
            Self.scanHit("other", path: fixture.bin.appendingPathComponent("other").path)
        ])
        let model = fixture.makeModel()

        #expect(model.cliScanState.candidates.count == 2)
        #expect(model.foundCLICandidates.map(\.binaryName) == ["other"])
    }

    @MainActor
    @Test("A refresh that adds Not Shared tools saves them as Not Shared before it records them as seen")
    func newToolsAreNotSharedOnDiskBeforeTheyAreKnown() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)

        try fixture.setTools("musicctl", [("musicctl_search", "ro"), ("musicctl_charts", "ro")])
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .update)
        await fixture.waitForImports(model)
        #expect(!model.isToolIDExposed("musicctl_charts"))

        // The first save that records musicctl_charts as seen found it
        // already on the saved Not Shared list.
        let save = try #require(fixture.defaults.fingerprintSaves.first { $0.toolIDs.contains("musicctl_charts") })
        #expect(save.notSharedOnDisk.contains("musicctl_charts"))
    }

    // MARK: Fix round 2

    @MainActor
    @Test("An Update whose family was removed before it commits brings nothing back, even merged with a quiet import")
    func updateDoesNotBringBackARemovedFamily() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.photoCTL, intent: .add)
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.setToolEnabled(id: "photoctl_albums", enabled: false) == nil)

        // The owner presses Update, then removes the family while it lists.
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.photoCTL, intent: .update)
        #expect(model.deleteUserTool(id: "photoctl_albums") == nil)
        await fixture.waitForImports(model)
        #expect(fixture.launches("photoctl") == 2)
        #expect(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.photoCTL).isEmpty)
        #expect(model.logs.contains { $0.message == "PhotoCTL has no tools here to update, so nothing changed." })

        // A quiet MusicCTL import waits behind another import; the owner's
        // Update joins it, and the family is removed before it runs.
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")], revision: 2)
        try fixture.installServer("remctl", tools: [("remctl_today", "ro")])
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        model.lastQuietMCPRefreshDate = Date()
        model.refreshLocalMCPDiscovery(trigger: .activation)
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .update)
        #expect(model.deleteUserTool(id: "musicctl_search") == nil)
        await fixture.waitForImports(model)
        #expect(fixture.launches("musicctl") == 2)
        #expect(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.musicCTL).isEmpty)
    }

    @MainActor
    @Test("A retired tool's id is not handed to a different tool whose name maps to it")
    func retiredIDGoesToNoOtherTool() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("remctl", tools: [("today", "ro"), ("remctl_search", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.tool(id: "remctl_today")?.mcpStdioBridge?.toolName == "today")
        #expect(model.isToolIDExposed("remctl_today"))

        // A new release drops `today` and adds a separate `remctl_today`.
        try fixture.installServer("remctl", tools: [("remctl_today", "ro"), ("remctl_search", "ro")], revision: 2)
        await fixture.refresh(model)

        #expect(fixture.launches("remctl") == 2)
        #expect(model.tool(id: "remctl_today") == nil)
        let newcomer = try #require(model.tools.first { $0.mcpStdioBridge?.toolName == "remctl_today" })
        #expect(!model.isToolIDExposed(newcomer.id))
        #expect(model.isToolIDExposed("remctl_search"))
    }

    @MainActor
    @Test("Only a config row that launches the same server folds into the provider; Federico's four Claude Desktop rows do")
    func onlyTheSameLaunchFolds() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let remctl = try fixture.installServer("remctl", tools: [("remctl_today", "ro")])
        let notes = try fixture.installServer("notesctl", tools: [("notesctl_search", "ro")], in: fixture.localBin)
        let photo = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        // MusicCTL as uv installs it: the config names the tool's own file,
        // and `~/bin/musicctl` links to it.
        let uvBin = fixture.home.appendingPathComponent(".local/share/uv/tools/musicctl/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: uvBin, withIntermediateDirectories: true)
        let music = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")], in: uvBin)
        try FileManager.default.createSymbolicLink(at: fixture.bin.appendingPathComponent("musicctl"), withDestinationURL: music)

        // The rows Federico's Claude Desktop has, none with `env`.
        try fixture.writeClaudeDesktopConfig([
            "remctl": ("python3.14", [remctl.path, "mcp"]),
            "notesctl": (notes.path, ["mcp", "serve", "--client", "claude-desktop"]),
            "musicctl": (music.path, ["mcp", "serve", "--client", "claude-desktop"]),
            "photoctl": (photo.path, ["mcp", "serve"])
        ])
        let folded = await fixture.scanner().scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        #expect(folded.filter { $0.source == "claude_desktop" }.isEmpty, "\(folded.map(\.id))")
        for name in ["remctl", "notesctl", "musicctl", "photoctl"] {
            let row = folded.first { $0.id == "first_party.\(name)" }
            #expect(Set(row?.configurationOwners.map(\.source) ?? []) == ["first_party", "claude_desktop"], "\(name)")
        }

        // A row with environment variables, or an argument past the serve
        // arguments and a client label, may run something else: it stays a
        // server of its own.
        try fixture.writeClaudeDesktopConfig(
            [
                "photoctl": (photo.path, ["mcp", "serve"]),
                "remctl": (remctl.path, ["mcp", "--profile", "work"])
            ],
            env: ["photoctl": ["PHOTOCTL_CAPABILITY_HOST_SOCKET": "/tmp/other.sock"]]
        )
        let apart = await fixture.scanner().scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        #expect(Set(apart.filter { $0.source == "claude_desktop" }.map(\.id)) == ["claude_desktop.photoctl", "claude_desktop.remctl"])
        #expect(apart.first { $0.id == "first_party.photoctl" }?.configurationOwners.map(\.source) == ["first_party"])

        // Its shared tools are not adopted by the default PhotoCTL server.
        let model = fixture.makeModel()
        await fixture.refresh(model)
        model.importLocalMCPServer(candidateID: "claude_desktop.photoctl", intent: .add)
        await fixture.waitForImports(model)
        #expect(model.isToolIDExposed("photoctl_albums"))
        await fixture.refresh(model)
        #expect(fixture.launches("photoctl") == 1)
        #expect(model.tool(id: "photoctl_albums")?.mcpStdioBridge?.discoverySource == "claude_desktop")
    }

    @MainActor
    @Test("A shared plain PhotoCTL saved with an override is not adopted after its config row drops the override")
    func savedOverrideIsNotAdopted() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let photo = try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        try fixture.writeClaudeDesktopConfig(
            ["photoctl": (photo.path, ["mcp", "serve"])],
            env: ["photoctl": ["PHOTOCTL_CAPABILITY_HOST_SOCKET": "/tmp/other.sock"]]
        )
        let model = fixture.makeModel()
        await fixture.refresh(model)
        model.importLocalMCPServer(candidateID: "claude_desktop.photoctl", intent: .add)
        await fixture.waitForImports(model)
        let plain = try #require(model.tool(id: "photoctl_albums"))
        #expect(model.isToolIDExposed("photoctl_albums"))

        // A config edit removes the override from the same row, which now
        // folds into PhotoCTL. The saved tool still reads the other host.
        try fixture.writeClaudeDesktopConfig(["photoctl": (photo.path, ["mcp", "serve"])])
        await fixture.refresh(model)

        #expect(fixture.launches("photoctl") == 2)
        #expect(model.tool(id: "photoctl_albums") == plain)
        #expect(model.isToolIDExposed("photoctl_albums"))
        let albums = try #require(
            model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.photoCTL)
                .first { $0.mcpStdioBridge?.toolName == "photoctl_albums" }
        )
        #expect(albums.id != "photoctl_albums")
        #expect(!model.isToolIDExposed(albums.id))

        // The override comes back, and Refresh on the plain server refreshes
        // that family alone, not PhotoCTL's own beside it.
        try fixture.writeClaudeDesktopConfig(
            ["photoctl": (photo.path, ["mcp", "serve"])],
            env: ["photoctl": ["PHOTOCTL_CAPABILITY_HOST_SOCKET": "/tmp/other.sock"]]
        )
        await fixture.refresh(model)
        let launchesBefore = fixture.launches("photoctl")
        model.importLocalMCPServer(candidateID: "claude_desktop.photoctl", intent: .update)
        await fixture.waitForImports(model)
        #expect(fixture.launches("photoctl") == launchesBefore + 1)
        #expect(model.localMCPErrorMessage == nil)
        #expect(model.tool(id: "photoctl_albums")?.mcpStdioBridge?.discoverySource == "claude_desktop")
        #expect(model.isToolIDExposed("photoctl_albums"))
        #expect(model.tool(id: albums.id) == albums)
    }

    @MainActor
    @Test("Update after the CLI moved lists the new path, before any rescan")
    func updateAfterAMoveListsTheNewPath() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("remctl", tools: [("remctl_today", "ro"), ("remctl_search", "ro")])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.setToolEnabled(id: "remctl_search", enabled: false) == nil)

        try FileManager.default.removeItem(at: fixture.bin.appendingPathComponent("remctl"))
        let moved = try fixture.installServer("remctl", tools: [("remctl_today", "ro"), ("remctl_search", "ro")], in: fixture.localBin)
        // The Library opens, then the owner presses Update.
        model.refreshInstalledFirstPartyProviders()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .update)
        await fixture.waitForImports(model)

        #expect(fixture.launches("remctl", in: fixture.localBin) == 1)
        #expect(Set(model.tools.map(\.id)) == ["remctl_today", "remctl_search"])
        #expect(model.tools.allSatisfy { $0.mcpStdioBridge?.command == moved.path })
        #expect(model.isToolIDExposed("remctl_today"))
        #expect(!model.isToolIDExposed("remctl_search"))
    }

    @MainActor
    @Test("A CLI whose link moved to another folder is imported again from there on the next activation, though its file did not change")
    func movedLinkReimports() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let shared = fixture.home.appendingPathComponent("tools", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        let real = try fixture.installServer("remctl", tools: [], in: shared)
        for folder in [fixture.bin, fixture.localBin] {
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("remctl"), withDestinationURL: real)
            try fixture.setTools("remctl", [("remctl_today", "ro")], in: folder)
        }
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        await fixture.waitForImports(model)
        await fixture.refresh(model)
        #expect(fixture.launches("remctl") == 1)

        // The `~/bin` link goes while MacRemote runs; `~/.local/bin` leads to
        // the same file. The owner switches back to MacRemote. Nothing a
        // rescan looks at changed, but the stamp saved for the old path no
        // longer matches, so the activation's due check imports from the
        // path installed now.
        try FileManager.default.removeItem(at: fixture.bin.appendingPathComponent("remctl"))
        let switchedBack = Date()
        await fixture.activate(model)
        for _ in 0..<2_000 {
            if case .loaded(_, let date) = model.localMCPScanState, date >= switchedBack { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await fixture.waitForImports(model)

        #expect(fixture.launches("remctl", in: fixture.localBin) == 1)
        #expect(model.tool(id: "remctl_today")?.mcpStdioBridge?.command == fixture.localBin.appendingPathComponent("remctl").path)
        await fixture.activate(model)
        #expect(fixture.launches("remctl", in: fixture.localBin) == 1)
    }

    @MainActor
    @Test("A due retry runs on an activation right after a refresh, and after a manual scan that was running")
    func dueRetryIsNeverSwallowed() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        try fixture.installSlowClaude()
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(model)
        try fixture.installServer("musicctl", tools: [], revision: 2, fails: true)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 2)

        // Switching back a moment later, within the rescan guard.
        model.refreshLocalMCPDiscovery(trigger: .activation)
        await fixture.waitForImports(model)
        #expect(fixture.launches("musicctl") == 3)

        // Switching back while a manual scan runs: the retry follows it.
        model.scanLocalMCPServers()
        model.refreshLocalMCPDiscovery(trigger: .activation)
        await fixture.waitForScan(model)
        await fixture.waitForImports(model)
        #expect(fixture.launches("musicctl") == 4)

        // A quiet refresh that ends while a manual scan runs leaves the scan
        // its state and its turn, and the retry follows the scan.
        let mark = model.logs.count
        model.lastQuietMCPRefreshDate = nil
        try fixture.writeClaudeDesktopConfig(["other": ("/bin/echo", ["hi"])])
        model.refreshLocalMCPDiscovery(trigger: .activation)
        model.scanLocalMCPServers()
        await fixture.waitForScan(model)
        await fixture.waitForImports(model)
        let lines = model.logs.prefix(model.logs.count - mark).map(\.message)
        #expect(!lines.contains { $0.hasPrefix("Checked MCP configs") }, "\(lines)")
        #expect(fixture.launches("musicctl") == 5)
    }

    @MainActor
    @Test("Import and Refresh on the MCP Servers page take their turn behind a first-party import")
    func mcpServersPageJoinsTheQueue() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        try fixture.installServer("photoctl", tools: [("photoctl_albums", "ro")])
        try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let model = fixture.makeModel()
        await fixture.refresh(model)
        model.importLocalMCPServer(candidateID: "first_party.photoctl", intent: .add)
        await fixture.waitForImports(model)

        // MusicCTL imports; meanwhile the owner confirms PhotoCTL's Refresh.
        try fixture.setTools("photoctl", [("photoctl_albums", "ro"), ("photoctl_search", "ro")])
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        model.importLocalMCPServer(candidateID: "first_party.photoctl", intent: .update)
        #expect(model.hasPendingFirstPartyImports)
        await fixture.waitForImports(model)

        #expect(fixture.launches("photoctl") == 2)
        #expect(model.tool(id: "photoctl_search") != nil)
        #expect(!model.isToolIDExposed("photoctl_search"))
        #expect(model.tool(id: "musicctl_search") != nil)
    }

    @MainActor
    @Test("A quiet import of a server with skills writes no line when nothing changed, and one line otherwise")
    func quietImportWithSkillsWritesOneLine() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let tools = [("remctl_today", "ro"), ("remctl_search", "ro")]
        try fixture.installServer("remctl", tools: tools, skills: ["reminders": "Call today first."])
        // A second family with skills, saved after RemCTL's.
        try fixture.installServer("notesctl", tools: [("notesctl_search", "ro")], skills: ["notes": "Search first."])
        let model = fixture.makeModel()
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.remCTL, intent: .add)
        model.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.notesCTL, intent: .add)
        await fixture.waitForImports(model)
        #expect(model.logs.contains { $0.message.hasPrefix("RemCTL offers 1 skill.") })
        func remctlLines(after mark: Int) -> [String] {
            model.logs.prefix(model.logs.count - mark).map(\.message).filter { $0.contains("RemCTL") }
        }

        // A new build with the same tools and skill.
        var mark = model.logs.count
        try fixture.installServer("remctl", tools: tools, revision: 2, skills: ["reminders": "Call today first."])
        await fixture.refresh(model)
        #expect(fixture.launches("remctl") == 2)
        #expect(remctlLines(after: mark).isEmpty)

        // A title changes, and so does the skill: still one line.
        mark = model.logs.count
        try fixture.installServer("remctl", tools: tools, revision: 3, titles: ["remctl_today": "Today"], skills: ["reminders": "Call lists first."])
        await fixture.refresh(model)
        #expect(fixture.launches("remctl") == 3)
        #expect(remctlLines(after: mark) == ["RemCTL updated: 1 tool changed; now offers 1 skill."])
    }

    @MainActor
    @Test("A policy revision this build has not imported with re-imports each added family once")
    func policyRevisionReimportsOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro")])
        let first = fixture.makeModel()
        first.importFirstPartyMCPProvider(FirstPartyMCPProviderCatalog.musicCTL, intent: .add)
        await fixture.waitForImports(first)

        // What the previous build saved: the stat line alone.
        fixture.defaults.set(
            ["provider.musicctl": MCPConfigLocator.executableStatLine(path: music.path)],
            forKey: "MacRemote.firstPartyImportStats"
        )
        let model = fixture.makeModel()
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 2)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 2)
    }

    @MainActor
    @Test("Removing the bridged family while an uncarried legacy tool stays does not re-import it")
    func legacyImportRespectsTheStamp() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_charts", "ro"), ("musicctl_rating_clear", "destructive")])
        try fixture.saveTools([Self.legacyMusicTools(executable: music.path)[2]])
        let model = fixture.makeModel()
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 1)

        #expect(model.deleteUserTool(id: "musicctl_charts") == nil)
        #expect(model.deleteUserTool(id: "musicctl_rating_clear") == nil)
        await fixture.refresh(model)
        #expect(fixture.launches("musicctl") == 1)
        #expect(model.importedFirstPartyMCPTools(for: FirstPartyMCPProviderCatalog.musicCTL).isEmpty)
        #expect(model.tool(id: "musicctl_player_control")?.backend == .process)
    }

    // MARK: RemCTL and NotesCTL legacy tools (D87)

    @MainActor
    @Test("Legacy NotesCTL tools make a never-added NotesCTL import once and carry over with their sharing; new tools start Not Shared")
    func legacyNotesToolsCarryOver() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let notes = try fixture.installServer("notesctl", tools: [
            ("notesctl_search", "ro"), ("notesctl_show", "ro"),
            ("notesctl_run", "destructive"), ("notesctl_apply_batch", "destructive")
        ], in: fixture.localBin)
        try fixture.saveTools(Self.legacyNotesTools(executable: notes.path))
        let model = fixture.makeModel()
        connectClient(model)
        model.disabledToolIDs.insert("notesctl_show")
        model.setToolAlwaysAllowed(true, toolID: "notesctl_run", clientID: "client-1")
        #expect(model.isToolAlwaysAllowed(toolID: "notesctl_run", clientID: "client-1"))

        await fixture.refresh(model)

        #expect(fixture.launches("notesctl", in: fixture.localBin) == 1)
        #expect(Set(model.tools.map(\.id)) == ["notesctl_search", "notesctl_show", "notesctl_run", "notesctl_apply_batch"])
        #expect(model.tools.allSatisfy { $0.backend == .mcpStdioBridge })
        #expect(model.isToolIDExposed("notesctl_search"))
        #expect(model.isToolIDExposed("notesctl_run"))
        #expect(!model.isToolIDExposed("notesctl_show"))
        #expect(!model.isToolIDExposed("notesctl_apply_batch"))
        #expect(!model.isToolAlwaysAllowed(toolID: "notesctl_run", clientID: "client-1"))
        #expect(model.tool(id: "notesctl_run")?.approvalPolicy == .everyCall)
        #expect(model.logs.contains { $0.message == "NotesCTL updated: 1 tool added, 3 changed." }, "\(model.logs.map(\.message))")

        await fixture.refresh(model)
        #expect(fixture.launches("notesctl", in: fixture.localBin) == 1)
    }

    @MainActor
    @Test("A RemCTL tool on a suffixed id moves to its legacy row's plain id, keeping its own sharing, and no other id changes")
    func suffixedRemCTLToolsMoveToPlainIDs() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let remctl = try fixture.installServer("remctl", tools: [
            ("today", "ro"), ("search", "ro"), ("upcoming", "ro"), ("run", "destructive")
        ])
        // As on Federico's Mac: the legacy rows, and the family an earlier
        // build imported beside them on suffixed ids.
        let legacy = Self.legacyRemTools(executable: remctl.path).filter {
            ["remctl_today", "remctl_search", "remctl_run"].contains($0.id)
        }
        let bridged = try await fixture.saveFamilyImportedBesideLegacyTools(FirstPartyMCPProviderCatalog.remCTL, legacy: legacy)
        let today = try #require(bridged.first { $0.mcpStdioBridge?.toolName == "today" })
        let search = try #require(bridged.first { $0.mcpStdioBridge?.toolName == "search" })
        let upcoming = try #require(bridged.first { $0.mcpStdioBridge?.toolName == "upcoming" })
        #expect(today.id != "remctl_today")
        #expect(upcoming.id == "remctl_upcoming")
        let model = fixture.makeModel()
        connectClient(model)
        // Legacy Today is Not Shared and its bridged tool Shared; legacy
        // Search is Shared and its bridged tool Not Shared.
        model.disabledToolIDs.formUnion(["remctl_today", "remctl_run", search.id])
        model.setToolAlwaysAllowed(true, toolID: today.id, clientID: "client-1")

        await fixture.refresh(model)

        #expect(fixture.launches("remctl") == 2)
        #expect(Set(model.tools.map(\.id)) == ["remctl_today", "remctl_search", "remctl_upcoming", "remctl_run"])
        #expect(model.tools.allSatisfy { $0.backend == .mcpStdioBridge })
        #expect(model.tool(id: "remctl_today")?.mcpStdioBridge?.toolName == "today")
        // The bridged tool's choice and epoch, not the legacy row's.
        #expect(model.isToolIDExposed("remctl_today"))
        #expect(!model.isToolIDExposed("remctl_search"))
        #expect(model.isToolIDExposed("remctl_run"))
        #expect(model.tool(id: "remctl_today")?.permissionEpoch == today.permissionEpoch)
        #expect(model.tool(id: "remctl_upcoming")?.permissionEpoch == upcoming.permissionEpoch)
        #expect(!model.isToolAlwaysAllowed(toolID: "remctl_today", clientID: "client-1"))
        #expect(!model.isToolAlwaysAllowed(toolID: today.id, clientID: "client-1"))
        #expect(model.logs.contains { $0.message == "RemCTL updated: 3 tools changed." }, "\(model.logs.map(\.message))")

        await fixture.refresh(model)
        #expect(fixture.launches("remctl") == 2)
    }

    @MainActor
    @Test("Leftover legacy rows go with a successful import only when Not Shared, and a failed import removes nothing")
    func notSharedLeftoverLegacyRowsAreRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let remctl = try fixture.installServer("remctl", tools: [("today", "ro")], fails: true)
        // `remctl_info` and `remctl_delete` have no server tool of that id.
        let legacy = Self.legacyRemTools(executable: remctl.path).filter {
            ["remctl_today", "remctl_info", "remctl_delete"].contains($0.id)
        }
        try fixture.saveTools(legacy)
        let model = fixture.makeModel()
        model.disabledToolIDs.insert("remctl_info")
        let toolsBefore = model.tools

        await fixture.refresh(model)

        #expect(fixture.launches("remctl") == 1)
        #expect(model.tools == toolsBefore)
        #expect(try ToolRegistryStore(fileURL: fixture.storeURL).loadUserDefinedTools() == toolsBefore)

        _ = try fixture.installServer("remctl", tools: [("today", "ro"), ("get_reminder", "ro")], revision: 2)
        await fixture.refresh(model)

        #expect(fixture.launches("remctl") == 2)
        #expect(model.tool(id: "remctl_info") == nil)
        #expect(model.tool(id: "remctl_delete") == legacy.first { $0.id == "remctl_delete" })
        #expect(model.isToolIDExposed("remctl_delete"))
        #expect(model.tool(id: "remctl_today")?.backend == .mcpStdioBridge)
        #expect(model.logs.contains { $0.message == "RemCTL updated: 1 tool added, 1 changed; 1 old tool removed." }, "\(model.logs.map(\.message))")
    }

    @MainActor
    @Test("An edited RemCTL legacy row keeps its id and sharing, and the bridged tool beside it keeps its suffixed id")
    func editedRemCTLLegacyRowStays() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let remctl = try fixture.installServer("remctl", tools: [("today", "ro"), ("search", "ro")])
        // The owner pointed Search at a wrapper that searches one list.
        let wrapper = fixture.bin.appendingPathComponent("remctl-work-only")
        try Data("#!/bin/sh\nexec remctl \"$@\"\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let stock = try #require(Self.legacyRemTools(executable: remctl.path).first { $0.id == "remctl_today" })
        let edited = try #require(Self.legacyRemTools(executable: wrapper.path).first { $0.id == "remctl_search" })
        let bridged = try await fixture.saveFamilyImportedBesideLegacyTools(FirstPartyMCPProviderCatalog.remCTL, legacy: [stock, edited])
        let search = try #require(bridged.first { $0.mcpStdioBridge?.toolName == "search" })
        let model = fixture.makeModel()
        let editedBefore = try #require(model.tool(id: "remctl_search"))
        #expect(model.isToolIDExposed("remctl_search"))

        await fixture.refresh(model)

        #expect(fixture.launches("remctl") == 2)
        #expect(model.tool(id: "remctl_today")?.mcpStdioBridge?.toolName == "today")
        #expect(model.tool(id: "remctl_search") == editedBefore)
        #expect(model.isToolIDExposed("remctl_search"))
        #expect(model.tool(id: search.id)?.mcpStdioBridge?.toolName == "search")
        #expect(model.isToolIDExposed(search.id))
    }

    @MainActor
    @Test("A legacy row pointed at another file with the CLI's own name stays, shared as it was")
    func sameNamedWrapperIsNotCarriedOver() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let notes = try fixture.installServer("notesctl", tools: [
            ("notesctl_search", "ro"), ("notesctl_show", "ro")
        ], in: fixture.localBin)
        // The owner pointed Search at a work-only wrapper also named notesctl.
        let work = fixture.home.appendingPathComponent("Work/Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let wrapper = work.appendingPathComponent("notesctl")
        try Data("#!/bin/sh\nexec true\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let stock = try #require(Self.legacyNotesTools(executable: notes.path).first { $0.id == "notesctl_show" })
        let edited = try #require(Self.legacyNotesTools(executable: wrapper.path).first { $0.id == "notesctl_search" })
        try fixture.saveTools([stock, edited])
        let model = fixture.makeModel()
        let editedBefore = try #require(model.tool(id: "notesctl_search"))
        #expect(model.isToolIDExposed("notesctl_search"))

        await fixture.refresh(model)

        #expect(fixture.launches("notesctl", in: fixture.localBin) == 1)
        #expect(model.tool(id: "notesctl_show")?.backend == .mcpStdioBridge)
        #expect(model.tool(id: "notesctl_search") == editedBefore)
        #expect(model.isToolIDExposed("notesctl_search"))
        let upstream = try #require(model.tools.first { $0.mcpStdioBridge?.toolName == "notesctl_search" })
        #expect(upstream.id != "notesctl_search")
        #expect(!model.isToolIDExposed(upstream.id))
    }

    @MainActor
    @Test("A Not Shared legacy row whose twin the server lists but MacRemote skips is kept")
    func leftoverWithASkippedTwinStays() async throws {
        let fixture = try Fixture()
        defer { fixture.tearDown() }
        let music = try fixture.installServer("musicctl", tools: [("musicctl_search", "ro"), ("musicctl_doctor", "badschema")])
        let legacy = Self.legacyMusicTools(executable: music.path)
        let doctor = try #require(legacy.first { $0.id == "musicctl_doctor" })
        let search = try #require(legacy.first { $0.id == "musicctl_search" })
        try fixture.saveTools([doctor, search])
        let model = fixture.makeModel()
        model.disabledToolIDs.insert("musicctl_doctor")

        await fixture.refresh(model)

        #expect(fixture.launches("musicctl") == 1)
        #expect(model.tool(id: "musicctl_search")?.backend == .mcpStdioBridge)
        #expect(model.tool(id: "musicctl_doctor") == doctor)
        #expect(!model.isToolIDExposed("musicctl_doctor"))
    }

    // MARK: Helpers

    /// A raw CLI-scan hit, as a scan saves it.
    private static func scanHit(_ name: String, path: String) -> DiscoveredCLICandidate {
        DiscoveredCLICandidate(
            id: "scan_path_\(name)", source: .looseBinary, binaryName: name, stablePath: path,
            resolvedPath: path, resolutionChain: [path], aliases: [], packageName: nil, version: nil,
            summary: nil, summaryOrigin: nil, homepage: nil, siblingExecutables: [],
            installedOnRequest: true, installDate: nil, fileKind: .script(interpreter: "python3", interpreterMissing: false),
            signature: .unsigned, isQuarantined: false, originDomain: nil, isInterpreter: false,
            isDependencyOnly: false, suggestedCategory: .utilities, isNewSinceLastScan: false
        )
    }

    /// Four of the tools the retired MusicCTL process catalog installed, with
    /// the commands it gave them (`226a2d0:Services/MusicCTLToolCatalog.swift`),
    /// so carry-over sees them as unedited.
    private static func legacyMusicTools(executable: String) -> [ToolDefinition] {
        func tool(
            _ id: String,
            _ capability: ToolCapability,
            parameters: [ToolParameter],
            invocation: ProcessInvocation? = nil,
            args: [String] = [],
            policy: ToolApprovalPolicy = .standard
        ) -> ToolDefinition {
            ToolDefinition(
                id: id, name: id, summary: "Legacy MusicCTL process tool.", executablePath: executable,
                argumentPattern: args, parameters: parameters, processInvocation: invocation,
                capability: capability, timeoutSeconds: 30, outputByteLimit: 1024, origin: .userDefined,
                category: .music, approvalPolicy: policy
            )
        }
        func text(_ name: String) -> ToolParameter {
            ToolParameter(name: name, title: name, kind: .string, required: false)
        }
        let actions = ["play", "pause", "toggle", "stop", "next", "previous"]
        return [
            tool("musicctl_doctor", .readOnly, parameters: [
                ToolParameter(name: "check_credentials", title: "Check", kind: .boolean, required: false), text("profile")
            ], invocation: ProcessInvocation(arguments: [
                .literal("doctor"), .flag("--check-credentials", "check_credentials"),
                .option("--profile", "profile"), .literal("--json")
            ])),
            tool("musicctl_search", .readOnly, parameters: [
                ToolParameter(name: "query", title: "Query", kind: .string),
                text("types"), text("scope"), text("limit"), text("profile"), text("storefront"), text("language")
            ], invocation: ProcessInvocation(arguments: [
                .literal("search"), .value("query"),
                .option("--types", "types"), .option("--scope", "scope"), .option("--limit", "limit"),
                .option("--profile", "profile"), .option("--storefront", "storefront"),
                .option("--language", "language"), .literal("--json")
            ])),
            tool("musicctl_player_control", .write, parameters: [
                ToolParameter(name: "action", title: "Action", kind: .string, allowedValues: actions)
            ], invocation: ProcessInvocation(
                arguments: [
                    .literal("player"),
                    .choice("action", Dictionary(uniqueKeysWithValues: actions.map { ($0, [$0]) })),
                    .literal("--apply"), .literal("--json")
                ],
                preflightSuffix: ["--json"],
                preflightRemovingArguments: ["--apply", "--json"]
            )),
            tool("musicctl_run", .destructive, parameters: [
                ToolParameter(name: "args", title: "Arguments", description: "Exact argv items.", kind: .stringArray, required: false)
            ], args: ["{args}"], policy: .everyCall)
        ]
    }

    /// Five of the nine tools the retired RemCTL process catalog installed,
    /// with its commands (`08e9bf4^:Services/RemCTLToolCatalog.swift`).
    private static func legacyRemTools(executable: String) -> [ToolDefinition] {
        func tool(
            _ id: String,
            _ capability: ToolCapability,
            parameters: [ToolParameter],
            invocation: ProcessInvocation? = nil,
            args: [String] = [],
            policy: ToolApprovalPolicy = .standard
        ) -> ToolDefinition {
            ToolDefinition(
                id: id, name: id, summary: "Legacy RemCTL process tool.", executablePath: executable,
                argumentPattern: args, parameters: parameters, processInvocation: invocation,
                capability: capability, timeoutSeconds: 30, outputByteLimit: 1024, origin: .userDefined,
                category: .reminders, approvalPolicy: policy
            )
        }
        let reminderID = ToolParameter(name: "reminder_id", title: "Reminder ID", kind: .integer, integerRange: 1...999_999_999)
        return [
            tool("remctl_today", .readOnly, parameters: [
                ToolParameter(name: "include_overdue", title: "Include Overdue", kind: .boolean, required: false)
            ], invocation: ProcessInvocation(arguments: [
                .literal("today"),
                .choice("include_overdue", ["true": [], "false": ["--no-overdue"]]),
                .literal("--json")
            ])),
            tool("remctl_search", .readOnly, parameters: [
                ToolParameter(name: "query", title: "Query", kind: .string),
                ToolParameter(name: "include_completed", title: "Include Completed", kind: .boolean, required: false)
            ], invocation: ProcessInvocation(arguments: [
                .literal("search"), .value("query"),
                .choice("include_completed", ["true": ["--completed"], "false": []]),
                .literal("--json")
            ])),
            tool("remctl_info", .readOnly, parameters: [reminderID], invocation: ProcessInvocation(arguments: [
                .literal("info"), .value("reminder_id"), .literal("--json")
            ])),
            tool("remctl_delete", .destructive, parameters: [reminderID], invocation: ProcessInvocation(arguments: [
                .literal("delete"), .value("reminder_id"), .literal("--force"), .literal("--json")
            ]), policy: .everyCall),
            tool("remctl_run", .destructive, parameters: [
                ToolParameter(name: "args", title: "Arguments", description: "Exact argv items.", kind: .stringArray, required: false)
            ], args: ["{args}"], policy: .everyCall)
        ]
    }

    /// Three of the 19 tools the retired NotesCTL process catalog installed,
    /// with its commands (`08e9bf4^:Services/NotesCTLToolCatalog.swift`).
    private static func legacyNotesTools(executable: String) -> [ToolDefinition] {
        func tool(
            _ id: String,
            _ capability: ToolCapability,
            parameters: [ToolParameter],
            invocation: ProcessInvocation? = nil,
            args: [String] = [],
            policy: ToolApprovalPolicy = .standard
        ) -> ToolDefinition {
            ToolDefinition(
                id: id, name: id, summary: "Legacy NotesCTL process tool.", executablePath: executable,
                argumentPattern: args, parameters: parameters, processInvocation: invocation,
                capability: capability, timeoutSeconds: 60, outputByteLimit: 1024, origin: .userDefined,
                category: .notes, approvalPolicy: policy
            )
        }
        return [
            tool("notesctl_search", .readOnly, parameters: [
                ToolParameter(name: "query", title: "Query", kind: .string),
                ToolParameter(name: "limit", title: "Limit", kind: .integer, required: false),
                ToolParameter(name: "scan_limit", title: "Scan Limit", kind: .integer, required: false)
            ], invocation: ProcessInvocation(arguments: [
                .literal("search"), .option("--query", "query"), .option("--limit", "limit"),
                .option("--scan-limit", "scan_limit"), .literal("--json")
            ])),
            tool("notesctl_show", .readOnly, parameters: [
                ToolParameter(name: "note_id", title: "Note ID", kind: .string)
            ], invocation: ProcessInvocation(arguments: [
                .literal("export"), .literal("--note"), .value("note_id"),
                .literal("--export-format"), .literal("markdown"), .literal("--json")
            ])),
            tool("notesctl_run", .destructive, parameters: [
                ToolParameter(name: "args", title: "Arguments", description: "Exact argv items.", kind: .stringArray, required: false)
            ], args: ["{args}"], policy: .everyCall)
        ]
    }
}

@MainActor
private func connectClient(_ model: AppModel) {
    model.connectedClients = [
        ConnectedClient(
            id: "client-1",
            trustID: "trust-1",
            name: "Test Client",
            redirectURIs: ["https://example.com/callback"],
            issuer: nil,
            resource: nil,
            scopes: ["mcp"],
            createdAt: Date(timeIntervalSince1970: 1),
            lastAuthorizedAt: Date(timeIntervalSince1970: 2),
            activeAccessTokens: 1,
            activeRefreshTokens: 1
        )
    ]
}

/// Defaults that note, at each save of the seen-tool fingerprints, which
/// tools the saved Not Shared list held at that moment.
private final class SaveOrderDefaults: UserDefaults, @unchecked Sendable {
    private(set) var fingerprintSaves: [(toolIDs: Set<String>, notSharedOnDisk: Set<String>)] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "MacRemote.knownToolFingerprints", let fingerprints = value as? [String: String] {
            let notShared = Set(stringArray(forKey: "MacRemote.disabledToolIDs") ?? [])
            fingerprintSaves.append((Set(fingerprints.keys), notShared))
        }
        super.set(value, forKey: defaultName)
    }
}

/// A temporary home with `bin` and `.local/bin` folders of fake CLIs and
/// isolated defaults. A CLI is found in `bin` first, as on Federico's Mac.
private struct Fixture {
    let root: URL
    let home: URL
    let bin: URL
    let localBin: URL
    let storeURL: URL
    let suiteName: String
    let defaults: SaveOrderDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        bin = home.appendingPathComponent("bin", isDirectory: true)
        localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        storeURL = root.appendingPathComponent("tools.json")
        suiteName = "FirstPartyCatalogFollowsInstallTests.\(UUID().uuidString)"
        defaults = try #require(SaveOrderDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    /// Finds an executable in this fixture's `bin`, then `.local/bin`.
    var locate: @Sendable (String) -> String? {
        let folders = [bin, localBin]
        return { name in
            folders.lazy
                .map { $0.appendingPathComponent(name).path }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
        }
    }

    func scanner(detectsCLIs: Bool = true) -> LocalMCPScanner {
        let none: @Sendable (String) -> String? = { _ in nil }
        return LocalMCPScanner(
            homeDirectory: home,
            executablePath: detectsCLIs ? locate : none,
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )
    }

    @MainActor
    func makeModel(detectsCLIs: Bool = true) -> AppModel {
        makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: storeURL),
            localMCPScanner: scanner(detectsCLIs: detectsCLIs)
        )
    }

    func saveTools(_ tools: [ToolDefinition]) throws {
        try ToolRegistryStore(fileURL: storeURL).saveUserDefinedTools(tools)
    }

    /// Saves `legacy` with the provider's family as a build before D87
    /// imported it beside them, with that build's import stamp: a bridged
    /// tool whose plain id a legacy row held got a suffixed id. Returns the
    /// bridged tools as saved.
    func saveFamilyImportedBesideLegacyTools(
        _ provider: FirstPartyMCPProvider,
        legacy: [ToolDefinition]
    ) async throws -> [ToolDefinition] {
        let scanner = scanner()
        var candidate = try #require(scanner.firstPartyCandidate(for: provider))
        candidate.probe = try await scanner.probe(candidate: candidate)
        let bridged = try scanner.bridgeTools(for: candidate, existingIDs: Set(legacy.map(\.id)))
        try saveTools(legacy + bridged)
        let command = try #require(candidate.command)
        defaults.set(
            [provider.id: "policy 1;\(MCPConfigLocator.executableStatLine(path: command))"],
            forKey: "MacRemote.firstPartyImportStats"
        )
        return bridged
    }

    /// Edits the saved tools file as text, as an older build would have
    /// written it.
    func rewriteStoredTools(replacing old: String, with new: String) throws {
        let text = try String(contentsOf: storeURL, encoding: .utf8)
        #expect(text.contains(old))
        try text.replacingOccurrences(of: old, with: new).write(to: storeURL, atomically: true, encoding: .utf8)
    }

    /// Saves a CLI scan the next model restores, as an earlier run would.
    func saveCLIScan(_ candidates: [DiscoveredCLICandidate]) throws {
        let cache = CLIScanCache(candidates: candidates, lastScanDate: Date(), seenStablePaths: [])
        try JSONEncoder().encode(cache).write(to: root.appendingPathComponent("cli-scan-cache.json"))
    }

    /// Writes a fake server named `name` that lists `tools` (name, hint) and
    /// answers nothing else. Hints: `ro`, `write`, `destructive`,
    /// `badschema` (an input schema MacRemote cannot mirror), and `noschema`
    /// (no input schema at all). `revision` changes the file's size and so
    /// its stat line; `fails` makes it exit before answering; `titles` gives
    /// tools a title; `skills` (name → body) makes it a 2026-07-28 server
    /// that offers those skills.
    @discardableResult
    func installServer(
        _ name: String,
        tools: [(String, String)],
        revision: Int = 1,
        fails: Bool = false,
        titles: [String: String] = [:],
        skills: [String: String]? = nil,
        in folder: URL? = nil
    ) throws -> URL {
        let folder = folder ?? bin
        try setTools(name, tools, fails: fails, titles: titles, skills: skills, in: folder)
        let url = folder.appendingPathComponent(name)
        try Data((Self.serverScript + String(repeating: "#\n", count: revision)).utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Changes what an installed fake server lists without touching the
    /// executable, as a wrapper whose target was upgraded would.
    func setTools(
        _ name: String,
        _ tools: [(String, String)],
        fails: Bool = false,
        titles: [String: String] = [:],
        skills: [String: String]? = nil,
        in folder: URL? = nil
    ) throws {
        let listed = tools.map { tool, hint -> [String: Any] in
            var annotations: [String: Any] = [:]
            if hint == "ro" { annotations["readOnlyHint"] = true }
            if hint == "destructive" { annotations["destructiveHint"] = true }
            let mirrorable: [String: Any] = ["type": "object", "properties": [String: Any]()]
            let unmirrorable: [String: Any] = ["type": "string"]
            var row: [String: Any] = [
                "name": tool,
                "description": "Fake \(tool).",
                "inputSchema": hint == "badschema" ? unmirrorable : mirrorable,
                "annotations": annotations
            ]
            row["title"] = titles[tool]
            if hint == "noschema" { row["inputSchema"] = nil }
            return row
        }
        var server: [String: Any] = ["tools": listed, "fail": fails]
        server["skills"] = skills
        let config = try JSONSerialization.data(withJSONObject: server)
        try config.write(to: (folder ?? bin).appendingPathComponent("\(name).json"))
    }

    func writeClaudeDesktopConfig(
        _ servers: [String: (command: String, args: [String])],
        env: [String: [String: String]] = [:]
    ) throws {
        let folder = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var rows = servers.mapValues { ["command": $0.command, "args": $0.args] as [String: Any] }
        for (name, variables) in env { rows[name]?["env"] = variables }
        try JSONSerialization.data(withJSONObject: ["mcpServers": rows])
            .write(to: folder.appendingPathComponent("claude_desktop_config.json"))
    }

    func launches(_ name: String, in folder: URL? = nil) -> Int {
        let url = (folder ?? bin).appendingPathComponent("\(name).launches")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return text.split(separator: "\n").count
    }

    /// Runs one quiet refresh and waits for it and every import it queued.
    @MainActor
    func refresh(_ model: AppModel) async {
        let started = Date()
        model.refreshLocalMCPDiscovery(trigger: .launch)
        for _ in 0..<2_000 {
            if case .loaded(_, let date) = model.localMCPScanState, date >= started { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await waitForImports(model)
    }

    /// One app activation past the five-second guard, and every import it
    /// queued.
    @MainActor
    func activate(_ model: AppModel) async {
        model.lastQuietMCPRefreshDate = nil
        model.refreshLocalMCPDiscovery(trigger: .activation)
        // An activation that rescans finishes in a task; let it start.
        try? await Task.sleep(nanoseconds: 20_000_000)
        await waitForImports(model)
    }

    /// Waits for a manual scan to finish.
    @MainActor
    func waitForScan(_ model: AppModel) async {
        for _ in 0..<2_000 where model.localMCPScanState.isScanning {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// A `claude` whose `claude mcp list` takes half a second, so a manual
    /// scan, which asks it, is still running when a quiet refresh is done.
    func installSlowClaude() throws {
        let url = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nsleep 0.5\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @MainActor
    func waitForImports(_ model: AppModel) async {
        for _ in 0..<3_000 {
            if !model.hasPendingFirstPartyImports { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static let serverScript = """
    #!/usr/bin/env python3
    import hashlib
    import json
    import os
    import sys

    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    name = os.path.basename(sys.argv[0])
    with open(os.path.join(here, name + ".launches"), "a") as launches:
        launches.write("launch\\n")
    with open(os.path.join(here, name + ".json")) as handle:
        config = json.load(handle)
    if config.get("fail"):
        sys.exit(3)
    skills = config.get("skills")
    files = {}
    for skill, body in (skills or {}).items():
        files["skill://%s/%s/SKILL.md" % (name, skill)] = (
            "---\\nname: %s\\ndescription: Fake %s.\\n---\\n\\n%s\\n" % (skill, skill, body))

    def skill_entry(skill):
        uri = "skill://%s/%s/SKILL.md" % (name, skill)
        text = files[uri].encode()
        return {"uri": uri, "frontmatter": {"name": skill, "description": "Fake %s." % skill},
                "resources": [{"uri": uri, "size": len(text),
                               "digest": "sha256:" + hashlib.sha256(text).hexdigest()}]}

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        request_id = message.get("id")
        if request_id is None:
            continue
        if method == "server/discover" and skills is not None:
            result = {
                "supportedVersions": ["2026-07-28"],
                "capabilities": {"tools": {}, "resources": {},
                                 "extensions": {"io.modelcontextprotocol/skills": {}}}
            }
        elif method == "skills/list" and skills is not None:
            result = {"skills": [skill_entry(skill) for skill in skills]}
        elif method == "resources/read" and (message.get("params") or {}).get("uri") in files:
            uri = message["params"]["uri"]
            result = {"contents": [{"uri": uri, "mimeType": "text/markdown", "text": files[uri]}]}
        elif method == "initialize":
            result = {
                "protocolVersion": "2025-06-18",
                "serverInfo": {"name": name, "version": "1.0.0"},
                "capabilities": {"tools": {}}
            }
        elif method == "tools/list":
            result = {"tools": config["tools"]}
        else:
            print(json.dumps({
                "jsonrpc": "2.0", "id": request_id,
                "error": {"code": -32601, "message": "Method not found"}
            }), flush=True)
            continue
        if skills is not None:
            result.update({"resultType": "complete", "ttlMs": 0, "cacheScope": "private"})
        print(json.dumps({"jsonrpc": "2.0", "id": request_id, "result": result}), flush=True)

    """
}
