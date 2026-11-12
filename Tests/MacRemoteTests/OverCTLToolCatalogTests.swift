import Foundation
import Testing
@testable import MacRemote

@Suite("OverCTL semantic catalog")
struct OverCTLToolCatalogTests {
    @Test("Catalog exposes the exact sparse provider surface")
    func exactSurface() throws {
        #expect(OverCTLToolCatalog.builtInTools.map(\.id) == [
            "overctl_up_next",
            "overctl_search",
            "overctl_episode",
            "overctl_transcript",
            "overctl_change_queue",
            "overctl_update_episode_state",
            "overctl_set_progress",
            "overctl_archive_episode",
            "overctl_run"
        ])
        #expect(OverCTLToolCatalog.dedicatedTools.allSatisfy { $0.category == .podcasts })
        #expect(OverCTLToolCatalog.builtInTools.allSatisfy { $0.permissionRequirements.isEmpty })
        #expect(OverCTLToolCatalog.fullCLITool.approvalPolicy == .everyCall)
        #expect(OverCTLToolCatalog.fullCLITool.capability == .destructive)
        #expect(OverCTLToolCatalog.fullCLITool.widgetPresentation == nil)

        let presentation = ToolWidgetPresentation(
            profile: .episodeRows,
            accent: "light-dark(#9a4300, #ff9f0a)",
            rootPath: "data"
        )
        #expect(OverCTLToolCatalog.dedicatedTools.allSatisfy {
            $0.widgetPresentation == presentation
        })

        let presets = DefaultToolPresetCatalog.presets.filter {
            $0.id.hasPrefix("preset.overctl.")
        }
        #expect(presets.count == 9)
        #expect(presets.allSatisfy { $0.publisher == .federicoViticci })
        #expect(DefaultToolPresetCatalog.appGroups(in: .podcasts).contains {
            $0.id == "provider.overctl" && $0.presets == presets
        })
    }

    @Test("Read recipes preserve OverCTL JSON and typed source choices")
    func readArguments() throws {
        #expect(try OverCTLToolCatalog.arguments(for: "overctl_up_next", parameters: [
            "minutes": .json(.number(90)),
            "podcast": .string("ATP"),
            "exclude_played": .json(.bool(true)),
            "limit": .json(.number(8)),
            "source": .string("cache")
        ]) == [
            "up-next", "--minutes", "90", "--podcast", "ATP",
            "--exclude-played", "--limit", "8", "--source", "cache", "--json"
        ])

        #expect(try OverCTLToolCatalog.arguments(for: "overctl_search", parameters: [
            "query": .string("automation"),
            "scope": .string("directory")
        ]) == ["discover", "automation", "--json"])

        #expect(try OverCTLToolCatalog.arguments(for: "overctl_episode", parameters: [
            "episode_id": .json(.number(42))
        ]) == ["episode", "42", "--source", "auto", "--json"])
    }

    @Test("Transcript keeps fractional windows and excludes Gemini and file export")
    func transcriptArguments() throws {
        #expect(try OverCTLToolCatalog.arguments(for: "overctl_transcript", parameters: [
            "episode_id": .json(.number(42)),
            "provider": .string("generated"),
            "from_seconds": .json(.number(12.5)),
            "to_seconds": .json(.number(45.75)),
            "include_segments": .json(.bool(true))
        ]) == [
            "transcript", "42", "--provider", "generated",
            "--from", "12.5", "--to", "45.75", "--segments", "--json"
        ])
        #expect(throws: ToolValidationError.self) {
            try OverCTLToolCatalog.arguments(for: "overctl_transcript", parameters: [
                "episode_id": .json(.number(42)),
                "provider": .string("gemini")
            ])
        }
    }

    @Test("Queue and reversible episode writes always carry a dry run")
    func writeRecipes() throws {
        let queue = try #require(OverCTLToolCatalog.tool(id: "overctl_change_queue"))
        #expect(try ToolArgumentResolver.arguments(for: queue, parameters: [
            "episode_id": .json(.number(42)),
            "action": .string("add_next")
        ]) == ["queue-add", "42", "--position", "next", "--json"])
        #expect(try ToolArgumentResolver.arguments(for: queue, parameters: [
            "episode_id": .json(.number(42)),
            "action": .string("remove")
        ]) == ["queue-remove", "42", "--json"])
        #expect(queue.processInvocation?.preflightSuffix == ["--dry-run"])

        let state = try #require(OverCTLToolCatalog.tool(id: "overctl_update_episode_state"))
        let mappings = [
            "completed": "done",
            "unplayed": "unplayed",
            "saved": "save",
            "starred": "star",
            "unstarred": "unstar",
            "restored": "restore"
        ]
        for (semantic, command) in mappings {
            #expect(try ToolArgumentResolver.arguments(for: state, parameters: [
                "episode_id": .json(.number(42)),
                "state": .string(semantic)
            ]) == [command, "42", "--json"])
        }
        #expect(state.processInvocation?.preflightSuffix == ["--dry-run"])
    }

    @Test("Archive confirmation is absent from preflight and present on apply")
    func archiveRecipe() throws {
        let tool = try #require(OverCTLToolCatalog.tool(id: "overctl_archive_episode"))
        let apply = try ToolArgumentResolver.arguments(for: tool, parameters: [
            "episode_id": .json(.number(42))
        ])
        #expect(apply == ["archive", "42", "--yes", "--json"])
        #expect(tool.processInvocation?.preflightSuffix == ["--dry-run"])
        #expect(tool.processInvocation?.preflightRemovingArguments == ["--yes"])
        let removed = Set(tool.processInvocation?.preflightRemovingArguments ?? [])
        let preview = apply.filter { !removed.contains($0) }
            + (tool.processInvocation?.preflightSuffix ?? [])
        #expect(preview == ["archive", "42", "--json", "--dry-run"])
        #expect(tool.capability == .destructive)
        #expect(tool.approvalPolicy == .everyCall)
    }

    @Test("Episode actions target only dedicated dry-run tools")
    func episodeActions() throws {
        let upNext = try #require(OverCTLToolCatalog.tool(id: "overctl_up_next"))
        let episode = try #require(OverCTLToolCatalog.tool(id: "overctl_episode"))
        #expect(upNext.uiActions?.map(\.toolID) == [
            "overctl_change_queue", "overctl_change_queue",
            "overctl_update_episode_state", "overctl_archive_episode"
        ])
        #expect(upNext.uiActions?.allSatisfy { $0.requiredRowFields == ["episodeID"] } == true)
        #expect(episode.uiActions?.allSatisfy { $0.requiredRowFields == ["id"] } == true)
        #expect(upNext.uiActions?.last?.style == .destructive)
        #expect(episode.uiActions?.last?.style == .destructive)
    }

    @Test("Flexible command blocks credentials, disclosure, experiments, and receipt attestation")
    func flexiblePolicy() throws {
        for executable in ["overctl", "octl"] {
            let tool = flexibleTool(executable: executable)
            #expect(FirstPartyFlexibleCommandPolicy.blocksCredentialCommands(in: tool))
            for arguments in [
                ["login"],
                ["logout", "--yes"],
                ["audio-url", "42", "--json"],
                ["export", "--what", "account"],
                ["export-opml", "--output", "/tmp/a.opml"],
                ["upload", "/tmp/a.mp3", "--yes"],
                ["cache", "export", "--format", "json"],
                ["cache", "--json", "export"],
                ["--source", "cache", "protocol", "--json", "decode", "capture.sjt"],
                ["--", "receipts", "clear", "key", "--yes"],
                ["transcript", "42", "--show-secrets"],
                ["download", "42", "--force"]
            ] {
                #expect(throws: ToolValidationError.self) {
                    try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: arguments)
                }
            }
            #expect(throws: Never.self) {
                try FirstPartyFlexibleCommandPolicy.validate(
                    tool: tool,
                    arguments: ["search", "login", "--json"]
                )
            }
        }
    }

    @Test(
        "Installed OverCTL advertises every dedicated command and option",
        .enabled(if: OverCTLToolCatalog.detectedExecutablePath != nil, "OverCTL is not installed on this Mac.")
    )
    func installedContract() async throws {
        let executable = try #require(OverCTLToolCatalog.detectedExecutablePath)
        let runner = ProcessRunner()
        let top = try await runner.run(
            executablePath: executable,
            arguments: ["--help"],
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            environment: ExecutableLocator.toolEnvironment
        )
        #expect(top.succeeded)
        let topHelp = top.stdout + top.stderr
        for value in [
            "--json", "--source", "up-next", "search", "discover", "episode",
            "transcript", "queue-add", "queue-remove", "progress", "done",
            "unplayed", "save", "star", "unstar", "archive", "restore"
        ] {
            #expect(topHelp.contains(value), "OverCTL help is missing \(value)")
        }

        let leafChecks: [([String], [String])] = [
            (["up-next"], ["--minutes", "--podcast", "--exclude-played", "--limit"]),
            (["transcript"], ["--provider", "--from", "--to", "--segments"]),
            (["queue-add"], ["--position", "--dry-run"]),
            (["progress"], ["--position", "--dry-run"]),
            (["archive"], ["--dry-run", "--yes"])
        ]
        for (command, options) in leafChecks {
            let result = try await runner.run(
                executablePath: executable,
                arguments: command + ["--help"],
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: ExecutableLocator.toolEnvironment
            )
            #expect(result.succeeded)
            let help = result.stdout + result.stderr
            for option in options {
                #expect(help.contains(option), "OverCTL \(command.joined(separator: " ")) help is missing \(option)")
            }
        }
    }

    private func flexibleTool(executable: String) -> ToolDefinition {
        let original = OverCTLToolCatalog.fullCLITool
        return ToolDefinition(
            id: "\(executable)_run",
            name: original.name,
            summary: original.summary,
            executablePath: "/fixtures/bin/\(executable)",
            argumentPattern: original.argumentPattern,
            parameters: original.parameters,
            processInvocation: original.processInvocation,
            capability: original.capability,
            timeoutSeconds: original.timeoutSeconds,
            outputByteLimit: original.outputByteLimit,
            category: original.category,
            approvalPolicy: original.approvalPolicy,
            annotationOverrides: original.annotationOverrides
        )
    }
}
