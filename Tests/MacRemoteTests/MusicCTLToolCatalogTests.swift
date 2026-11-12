import Foundation
import Testing
@testable import MacRemote

@Suite("MusicCTL semantic catalog")
struct MusicCTLToolCatalogTests {
    @Test("Catalog exposes exactly 15 Fixed Commands plus one Flexible Command")
    func exactSurface() throws {
        #expect(MusicCTLToolCatalog.builtInTools.map(\.id) == [
            "musicctl_doctor",
            "musicctl_search",
            "musicctl_list_library",
            "musicctl_new_releases",
            "musicctl_list_playlists",
            "musicctl_playlist_tracks",
            "musicctl_listening_history",
            "musicctl_player_status",
            "musicctl_list_output_routes",
            "musicctl_player_control",
            "musicctl_seek",
            "musicctl_set_volume",
            "musicctl_set_shuffle",
            "musicctl_set_repeat",
            "musicctl_select_output_routes",
            "musicctl_run"
        ])
        #expect(MusicCTLToolCatalog.dedicatedTools.count == 15)
        #expect(MusicCTLToolCatalog.dedicatedTools.count(where: { $0.capability == .readOnly }) == 9)
        #expect(MusicCTLToolCatalog.dedicatedTools.count(where: { $0.capability == .write }) == 6)
        #expect(MusicCTLToolCatalog.builtInTools.allSatisfy { $0.category == .music })
        #expect(MusicCTLToolCatalog.builtInTools.allSatisfy { $0.permissionRequirements.isEmpty })
        #expect(MusicCTLToolCatalog.builtInTools.allSatisfy { $0.uiActions == nil })
        #expect(MusicCTLToolCatalog.builtInTools.allSatisfy { $0.widgetPresentation == nil })

        let run = MusicCTLToolCatalog.fullCLITool
        #expect(run.capability == .destructive)
        #expect(run.approvalPolicy == .everyCall)
        #expect(run.isGenericCLIAdapter)
        #expect(run.summary.contains("Authentication setup, configuration writes, onboarding, and raw request commands are blocked by policy."))
    }

    @Test("REST recipes preserve exact installed limits and useful global options")
    func readRecipes() throws {
        #expect(try MusicCTLToolCatalog.arguments(for: "musicctl_search", parameters: [
            "query": .string("The National"),
            "scope": .string("library"),
            "limit": .json(.number(12)),
            "profile": .string("work"),
            "storefront": .string("it"),
            "language": .string("it-IT")
        ]) == [
            "search", "The National",
            "--types", "albums,artists,songs,playlists",
            "--scope", "library", "--limit", "12",
            "--profile", "work", "--storefront", "it", "--language", "it-IT",
            "--json"
        ])

        #expect(try MusicCTLToolCatalog.arguments(for: "musicctl_list_library", parameters: [
            "resource": .string("songs"),
            "limit": .json(.number(100))
        ]) == ["library", "list", "songs", "--limit", "100", "--json"])

        #expect(try MusicCTLToolCatalog.arguments(for: "musicctl_new_releases", parameters: [
            "min_songs": .json(.number(7)),
            "since": .string("12w"),
            "types": .string("albums,singles,compilations"),
            "include_owned": .json(.bool(true)),
            "storefront": .string("it")
        ]) == [
            "library", "new-releases", "--min-songs", "7", "--since", "12w",
            "--types", "albums,singles,compilations", "--include-owned",
            "--storefront", "it", "--json"
        ])

        #expect(throws: ToolValidationError.self) {
            try MusicCTLToolCatalog.arguments(for: "musicctl_search", parameters: [
                "query": .string("test"), "limit": .json(.number(26))
            ])
        }
        #expect(throws: ToolValidationError.self) {
            try MusicCTLToolCatalog.arguments(for: "musicctl_new_releases", parameters: [
                "min_songs": .json(.number(100_001))
            ])
        }
    }

    @Test("History choices remain valid across all three installed endpoints")
    func listeningHistory() throws {
        let mappings: [(String, String)] = [
            ("recently_played", "recently-played"),
            ("heavy_rotation", "heavy-rotation"),
            ("recently_added", "recently-added")
        ]
        for (choice, command) in mappings {
            #expect(try MusicCTLToolCatalog.arguments(for: "musicctl_listening_history", parameters: [
                "history": .string(choice),
                "limit": .json(.number(10)),
                "profile": .string("default")
            ]) == [
                "history", command, "--limit", "10", "--profile", "default", "--json"
            ])
        }
        #expect(throws: ToolValidationError.self) {
            try MusicCTLToolCatalog.arguments(for: "musicctl_listening_history", parameters: [
                "history": .string("recently_played"), "limit": .json(.number(11))
            ])
        }
    }

    @Test("Doctor can check credentials but cannot request a live probe")
    func doctorStaysOffline() throws {
        let doctor = try #require(MusicCTLToolCatalog.tool(id: "musicctl_doctor"))
        #expect(doctor.parameters.map(\.name) == ["check_credentials", "profile"])
        #expect(doctor.parameters.contains(where: { $0.name == "live" }) == false)
        #expect(try ToolArgumentResolver.arguments(for: doctor, parameters: [
            "check_credentials": .json(.bool(true)),
            "profile": .string("default")
        ]) == ["doctor", "--check-credentials", "--profile", "default", "--json"])
    }

    @Test("Every Music.app write previews without apply before the real argv")
    func mutationPreflights() throws {
        let cases: [(String, [String: ToolArgumentValue], [String])] = [
            ("musicctl_player_control", ["action": .string("next")], ["player", "next", "--apply", "--json"]),
            ("musicctl_seek", ["seconds": .json(.number(42.5))], ["player", "seek", "42.5", "--apply", "--json"]),
            ("musicctl_set_volume", ["value": .json(.number(75))], ["player", "volume", "75", "--apply", "--json"]),
            ("musicctl_set_shuffle", ["enabled": .json(.bool(false)), "mode": .string("albums")], ["player", "shuffle", "false", "--mode", "albums", "--apply", "--json"]),
            ("musicctl_set_repeat", ["mode": .string("all")], ["player", "repeat", "all", "--apply", "--json"]),
            ("musicctl_select_output_routes", ["output_ids": .stringArray(["BuiltIn", "AirPlay-1"])], ["output-route", "select", "BuiltIn", "AirPlay-1", "--apply", "--json"])
        ]

        for (id, parameters, expectedApply) in cases {
            let tool = try #require(MusicCTLToolCatalog.tool(id: id))
            let apply = try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
            #expect(apply == expectedApply)
            #expect(tool.processInvocation?.preflightSuffix == ["--json"])
            #expect(tool.processInvocation?.preflightRemovingArguments == ["--apply", "--json"])
            let removed = Set(tool.processInvocation?.preflightRemovingArguments ?? [])
            let preview = apply.filter { !removed.contains($0) }
                + (tool.processInvocation?.preflightSuffix ?? [])
            #expect(preview == Array(expectedApply.dropLast(2)) + ["--json"])
        }

        for id in [
            "musicctl_set_volume", "musicctl_set_shuffle",
            "musicctl_set_repeat", "musicctl_select_output_routes"
        ] {
            #expect(MusicCTLToolCatalog.tool(id: id)?.annotationOverrides?.idempotentHint == true)
        }
        #expect(MusicCTLToolCatalog.tool(id: "musicctl_player_control")?.annotationOverrides?.idempotentHint == nil)
        #expect(MusicCTLToolCatalog.tool(id: "musicctl_seek")?.annotationOverrides?.idempotentHint == nil)
    }

    @Test("Catalog registration owns one complete Music group and set")
    func registration() throws {
        let presets = DefaultToolPresetCatalog.presets.filter { $0.id.hasPrefix("preset.musicctl.") }
        #expect(presets.count == 16)
        #expect(presets.allSatisfy { $0.publisher == .federicoViticci })
        #expect(presets.allSatisfy { $0.category == .music })
        #expect(DefaultToolPresetCatalog.appGroups(in: .music) == [
            DefaultToolPresetProviderGroup(
                id: "provider.musicctl",
                name: "MusicCTL",
                category: .music,
                presets: presets
            )
        ])
        let set = try #require(DefaultToolPresetCatalog.presetSets.first { $0.id == "set.music" })
        #expect(set.presets == presets)
        let newReleases = try #require(DefaultToolPresetCatalog.preset(id: "preset.musicctl.new_releases"))
        #expect(newReleases.timeoutSeconds == 3_600)
    }

    @Test(
        "Installed MusicCTL schemas still advertise every dedicated leaf and bound",
        .enabled(if: MusicCTLToolCatalog.detectedExecutablePath != nil, "MusicCTL is not installed on this Mac.")
    )
    func installedSchemas() async throws {
        let executable = try #require(MusicCTLToolCatalog.detectedExecutablePath)
        let checks: [(String, [String])] = [
            ("doctor", ["check_credentials", "live"]),
            ("search", ["query", "types", "scope", "limit", "25"]),
            ("library list", ["resource", "limit", "100"]),
            ("library new-releases", ["min_songs", "100000", "since", "types", "include_owned"]),
            ("playlist list", ["limit", "100"]),
            ("playlist tracks", ["identifier", "limit", "100"]),
            ("history recently-played", ["limit", "10"]),
            ("history heavy-rotation", ["limit", "100"]),
            ("history recently-added", ["limit", "100"]),
            ("player status", []),
            ("output-route list", []),
            ("player play", ["apply"]),
            ("player pause", ["apply"]),
            ("player toggle", ["apply"]),
            ("player stop", ["apply"]),
            ("player next", ["apply"]),
            ("player previous", ["apply"]),
            ("player seek", ["seconds", "86400", "apply"]),
            ("player volume", ["value", "100", "apply"]),
            ("player shuffle", ["enabled", "songs", "albums", "groupings", "apply"]),
            ("player repeat", ["off", "one", "all", "apply"]),
            ("output-route select", ["output_ids", "apply"])
        ]

        for (command, expected) in checks {
            let result = try await ProcessRunner().run(
                executablePath: executable,
                arguments: ["schema", command, "--json"],
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: ExecutableLocator.toolEnvironment
            )
            #expect(result.succeeded, "MusicCTL schema \(command) failed: \(result.stderr)")
            for value in expected {
                #expect(result.stdout.contains(value), "MusicCTL schema \(command) is missing \(value)")
            }
        }
    }
}
