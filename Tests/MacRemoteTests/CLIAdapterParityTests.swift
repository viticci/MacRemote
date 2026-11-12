import Foundation
import Testing
@testable import MacRemote

@Suite("Federico CLI catalog parity")
struct CLIAdapterParityTests {
    private static let providers: [(String, Int, Set<String>)] = [
        ("alexandria", 10, ["browse_room", "capture_clip", "capture_in_room", "health", "list_resources", "run", "run_agent", "search_notes", "show_note", "wait_job"]),
        ("habitctl", 6, ["log_value", "record_result", "run", "search", "show", "today"]),
        ("pocketctl", 8, ["change_up_next", "run", "search_online", "set_playback_position", "show", "transcript", "triage", "update_state"]),
        ("overctl", 9, ["archive_episode", "change_queue", "episode", "run", "search", "set_progress", "transcript", "up_next", "update_episode_state"]),
        ("musicctl", 16, ["doctor", "list_library", "list_output_routes", "list_playlists", "listening_history", "new_releases", "player_control", "player_status", "playlist_tracks", "run", "seek", "select_output_routes", "set_repeat", "set_shuffle", "set_volume", "search"]),
        ("goodlinksctl", 7, ["delete", "get", "read", "run", "save", "search", "update"]),
        ("frames", 6, ["devices", "frame_image", "frame_video", "info", "run", "video_info"]),
        ("iris", 12, ["action_schema", "actions", "alarm_set", "alarms", "battery", "calendar_day", "doctor", "message_compose", "now_playing", "open_url", "run", "timer_start"])
    ]

    @Test("Swift catalog has the exact sparse first-party surface")
    func exactSurface() throws {
        let all = DefaultToolPresetCatalog.presets
        for (provider, count, suffixes) in Self.providers {
            let matching = all.filter { $0.id.hasPrefix("preset.\(provider).") }
            #expect(matching.count == count)
            #expect(Set(matching.map { String($0.id.dropFirst("preset.\(provider).".count)) }) == suffixes)
            #expect(matching.allSatisfy { $0.publisher == .federicoViticci })
            #expect(matching.count(where: { $0.mode == .cliAdapter }) == 1)
            #expect(matching.first(where: { $0.mode == .cliAdapter })?.approvalPolicy == .everyCall)
        }
        let federico = all.filter { $0.publisher == .federicoViticci }
        #expect(federico.count == 74)
        #expect(federico.count(where: { $0.mode == .commandTemplate }) == 66)
        #expect(federico.count(where: { $0.mode == .cliAdapter }) == 8)
        #expect(!all.contains(where: { $0.id.hasPrefix("preset.matter.") }))
        #expect(!all.contains(where: { $0.id.hasPrefix("preset.readwise.") }))
    }

    @Test("Every installed first-party executable still advertises required command families")
    func installedHelp() async throws {
        let checks: [(String?, [String])] = [
            (DefaultToolPresetCatalog.alexandriaExecutablePath, ["views", "agents", "jobs", "notes", "health"]),
            (DefaultToolPresetCatalog.habitCTLExecutablePath, ["today", "search", "show", "check", "fail", "skip", "undo", "log"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["triage", "search-online", "show", "transcript", "play-now", "progress"]),
            (DefaultToolPresetCatalog.overCTLExecutablePath, ["up-next", "search", "discover", "episode", "transcript", "queue-add", "queue-remove", "done", "archive"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["search", "library", "playlist", "history", "player", "output-route", "doctor"]),
            (ReadLaterToolPresetCatalog.goodLinksCTLExecutablePath, ["links"]),
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["list", "info", "frame", "video-info", "video"]),
            (DefaultToolPresetCatalog.irisExecutablePath, [
                "doctor", "devices", "transport", "actions", "alarm", "calendar",
                "music", "messages", "timer", "url", "device",
                "--json", "--dry-run", "--offline", "--confirm"
            ])
        ]
        for (path, commands) in checks {
            // Each of these command-line tools is optional. On a Mac without
            // one there is nothing to compare, so that tool is skipped.
            guard let executable = path else { continue }
            let result = try await ProcessRunner().run(
                executablePath: executable,
                arguments: ["--help"],
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: ExecutableLocator.toolEnvironment
            )
            #expect(result.succeeded)
            let help = result.stdout + result.stderr
            for command in commands {
                #expect(help.contains(command), "\(executable) help is missing \(command)")
            }
        }
    }

    @Test("Installed help advertises every option used by a dedicated recipe")
    func installedRecipeOptions() async throws {
        let checks: [(String?, [String], [String])] = [
            (DefaultToolPresetCatalog.alexandriaExecutablePath, ["views", "items"], ["--tab", "--search", "--tag", "--sort", "--limit", "--offset", "--json"]),
            (DefaultToolPresetCatalog.alexandriaExecutablePath, ["agents", "run"], ["--note-uuid", "--json"]),
            (DefaultToolPresetCatalog.alexandriaExecutablePath, ["jobs", "wait"], ["--max-wait", "--json"]),
            (DefaultToolPresetCatalog.habitCTLExecutablePath, ["today"], ["--date", "--json"]),
            (DefaultToolPresetCatalog.habitCTLExecutablePath, ["search"], ["--limit", "--json"]),
            (DefaultToolPresetCatalog.habitCTLExecutablePath, ["check"], ["--date", "--dry-run", "--json"]),
            (DefaultToolPresetCatalog.habitCTLExecutablePath, ["log"], ["--date", "--dry-run", "--json"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["triage"], ["--limit", "--json"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["search-online"], ["--type", "--limit", "--json"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["show"], ["--notes-chars", "--json"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["play-now"], ["--dry-run", "--json"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["done"], ["--dry-run", "--json"]),
            (DefaultToolPresetCatalog.pocketCTLExecutablePath, ["progress"], ["--position", "--dry-run", "--json"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["doctor"], ["--check-credentials", "--live"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["search"], ["--types", "--scope", "--limit"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["library", "list"], ["--limit"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["library", "new-releases"], ["--min-songs", "--since", "--types", "--include-owned"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["playlist", "list"], ["--limit"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["playlist", "tracks"], ["--limit"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["history", "recently-played"], ["--limit"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["player", "seek"], ["--apply"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["player", "volume"], ["--apply"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["player", "shuffle"], ["--mode", "--apply"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["player", "repeat"], ["--apply"]),
            (DefaultToolPresetCatalog.musicCTLExecutablePath, ["output-route", "select"], ["--apply"]),
            (ReadLaterToolPresetCatalog.goodLinksCTLExecutablePath, ["links", "list"], ["--search", "--tag", "--read", "--starred", "--sort", "--all-pages", "--max-items"]),
            (ReadLaterToolPresetCatalog.goodLinksCTLExecutablePath, ["links", "content"], ["--format", "--no-auto-download"]),
            (ReadLaterToolPresetCatalog.goodLinksCTLExecutablePath, ["links", "add"], ["--title", "--summary", "--tag", "--read", "--unread", "--starred", "--unstarred"]),
            (ReadLaterToolPresetCatalog.goodLinksCTLExecutablePath, ["links", "update"], ["--title", "--summary", "--read", "--unread", "--starred", "--unstarred", "--add-tag", "--remove-tag", "--clear-tags"]),
            (ReadLaterToolPresetCatalog.goodLinksCTLExecutablePath, ["links", "delete"], ["--yes", "--dry-run"]),
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["frame"], ["--output", "--device", "--color", "--merge"]),
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["video-info"], ["--device", "--color", "--rotate"]),
            (AppleFramesToolPresetCatalog.detectedExecutablePath, ["video"], ["--output", "--preset", "--device", "--color", "--rotate", "--merge", "--playback-offset"]),
            (DefaultToolPresetCatalog.irisExecutablePath, ["calendar", "today"], ["--limit"]),
            (DefaultToolPresetCatalog.irisExecutablePath, ["alarm", "set"], ["--label"]),
            (DefaultToolPresetCatalog.irisExecutablePath, ["messages", "compose"], ["--to", "--body"]),
            (DefaultToolPresetCatalog.irisExecutablePath, ["actions", "list"], ["--application"])
        ]
        for (path, arguments, requiredOptions) in checks {
            // Each of these command-line tools is optional. On a Mac without
            // one there is nothing to compare, so that tool is skipped.
            guard let executable = path else { continue }
            let result = try await ProcessRunner().run(
                executablePath: executable,
                arguments: arguments + ["--help"],
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: ExecutableLocator.toolEnvironment
            )
            #expect(result.succeeded, "\(executable) \(arguments.joined(separator: " ")) --help")
            let help = result.stdout + result.stderr
            for option in requiredOptions {
                #expect(
                    help.contains(option),
                    "\(executable) \(arguments.joined(separator: " ")) help is missing \(option)"
                )
            }
        }
    }
}
