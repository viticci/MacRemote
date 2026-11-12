import Foundation

enum PocketCTLToolPresetCatalog {
    static var presets: [DefaultToolPreset] {
        presets(executablePath: pocketExecutablePath)
    }

    static func presets(executablePath: String?) -> [DefaultToolPreset] {
        guard let executablePath else { return [] }
        let openWorld = ToolAnnotationOverrides(openWorldHint: true)
        let episode = ToolParameter(
            name: "episode_uuid",
            title: "Episode UUID",
            description: "Full Pocket Casts episode UUID from a fresh read.",
            kind: .string,
            maximumLength: 128
        )

        return [
            preset(
                id: "triage",
                name: "Get Podcast Triage",
                summary: "Return bounded Now, Up Next, In Progress, and New Releases episode groups as JSON.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "limit", title: "Limit", description: "Maximum items per triage group.", kind: .integer, required: false, defaultValue: "8", integerRange: 1...50)
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("triage"), .option("--limit", "limit"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld,
                uiActions: episodeRowUIActions
            ),
            preset(
                id: "search_online",
                name: "Search Pocket Casts",
                summary: "Search Pocket Casts for podcasts and episodes without downloading media.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "query", title: "Query", description: "Podcast or episode search text.", kind: .string, maximumLength: 512),
                    ToolParameter(
                        name: "result_type",
                        title: "Result Type",
                        description: "Return combined podcast and episode results, or episodes only.",
                        kind: .string,
                        required: false,
                        defaultValue: "combined",
                        allowedValues: ["combined", "episodes"]
                    ),
                    ToolParameter(name: "limit", title: "Limit", description: "Maximum search results.", kind: .integer, required: false, defaultValue: "25", integerRange: 1...100)
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("search-online"), .value("query"),
                    .option("--type", "result_type"),
                    .option("--limit", "limit"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                outputLimitKB: 4096,
                annotations: openWorld
            ),
            preset(
                id: "show",
                name: "Get Episode",
                summary: "Return one Pocket Casts episode with metadata, bounded show notes, bookmarks, and transcript status.",
                executablePath: executablePath,
                parameters: [
                    episode,
                    ToolParameter(
                        name: "show_notes_characters",
                        title: "Show Notes Characters",
                        description: "Maximum show-notes characters to include.",
                        kind: .integer,
                        required: false,
                        defaultValue: "1200",
                        integerRange: 0...20_000
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("show"), .value("episode_uuid"),
                    .option("--notes-chars", "show_notes_characters"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                outputLimitKB: 4096,
                annotations: openWorld,
                uiActions: episodeRowUIActions
            ),
            preset(
                id: "transcript",
                name: "Get Episode Transcript",
                summary: "Return the full Pocket Casts transcript for one episode without Gemini, forced refresh, chapter extraction, or media downloads.",
                executablePath: executablePath,
                parameters: [episode],
                invocation: ProcessInvocation(arguments: [
                    .literal("transcript"), .value("episode_uuid"), .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                outputLimitKB: 64 * 1024,
                annotations: openWorld
            ),
            preset(
                id: "change_up_next",
                name: "Change Up Next",
                summary: "Place an episode at Now, Next, or Last, or remove it from Up Next. MacRemote runs PocketCTL’s dry-run before applying.",
                executablePath: executablePath,
                parameters: [
                    episode,
                    ToolParameter(
                        name: "placement",
                        title: "Placement",
                        description: "Desired Up Next placement.",
                        kind: .string,
                        allowedValues: ["now", "next", "last", "remove"]
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .choice("placement", [
                            "now": ["play-now"],
                            "next": ["play-next"],
                            "last": ["play-last"],
                            "remove": ["remove-up-next"]
                        ]),
                        .value("episode_uuid"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                annotations: openWorld
            ),
            preset(
                id: "update_state",
                name: "Update Episode State",
                summary: "Set one episode’s played, archive, or starred state. Archiving also removes it from Up Next. MacRemote runs a dry-run first.",
                executablePath: executablePath,
                parameters: [
                    episode,
                    ToolParameter(
                        name: "state",
                        title: "State",
                        description: "Desired state transition.",
                        kind: .string,
                        allowedValues: ["completed", "unplayed", "archived", "unarchived", "starred", "unstarred"]
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .choice("state", [
                            "completed": ["done"],
                            "unplayed": ["unplayed"],
                            "archived": ["archive"],
                            "unarchived": ["unarchive"],
                            "starred": ["star"],
                            "unstarred": ["unstar"]
                        ]),
                        .value("episode_uuid"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                annotations: ToolAnnotationOverrides(idempotentHint: true, openWorldHint: true)
            ),
            preset(
                id: "set_playback_position",
                name: "Set Playback Position",
                summary: "Set one episode’s playback position in seconds after a successful PocketCTL dry-run.",
                executablePath: executablePath,
                parameters: [
                    episode,
                    ToolParameter(
                        name: "position_seconds",
                        title: "Position Seconds",
                        description: "Non-negative playback position.",
                        kind: .integer,
                        integerRange: 0...10_000_000
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("progress"), .value("episode_uuid"),
                        .option("--position", "position_seconds"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                annotations: ToolAnnotationOverrides(idempotentHint: true, openWorldHint: true)
            ),
            preset(
                id: "run",
                name: "PocketCTL Flexible Command",
                summary: "Advanced fallback; prefer the dedicated PocketCTL tools. Pass exact argv items with no shell for playlists, bookmarks, chapters, downloads, cache, exports, and uncommon workflows. Login, Gemini key management, and secret-file arguments are blocked remotely. This tool asks for every call.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "args", title: "Arguments", description: "Exact PocketCTL argv items. No shell syntax or expansion is available.", kind: .stringArray, required: false)
                ],
                argumentPattern: ["{args}"],
                capability: .destructive,
                timeoutSeconds: 600,
                outputLimitKB: 64 * 1024,
                mode: .cliAdapter,
                approvalPolicy: .everyCall,
                annotations: openWorld
            )
        ]
    }

    /// Widget affordances for episode-shaped results, in render order. Each
    /// one re-enters the dedicated write tool by its stable semantic id, so
    /// the call still passes the approval gate and PocketCTL's own dry-run
    /// preflight. Archive is reversible (`unarchive`), so none of these are
    /// styled destructive.
    ///
    /// Attached to the two tools that return episodes the person already
    /// owns — triage rows and a single episode card. `search_online`
    /// deliberately opts out: its result set mixes podcast records (which
    /// also carry a `uuid`) with episodes from the whole Pocket Casts
    /// catalogue, and firing an Up Next or state change with a podcast uuid
    /// — or with an episode nobody is subscribed to — is a guaranteed error
    /// wearing a friendly button.
    static var episodeRowUIActions: [ToolUIAction] {
        [
            episodeAction(id: "play_next", title: "Play Next", toolID: "pocketctl_change_up_next", key: "placement", value: "next"),
            episodeAction(id: "play_last", title: "Play Last", toolID: "pocketctl_change_up_next", key: "placement", value: "last"),
            episodeAction(id: "star", title: "Star", toolID: "pocketctl_update_state", key: "state", value: "starred"),
            episodeAction(id: "archive", title: "Archive", toolID: "pocketctl_update_state", key: "state", value: "archived")
        ]
    }

    private static func episodeAction(
        id: String,
        title: String,
        toolID: String,
        key: String,
        value: String
    ) -> ToolUIAction {
        ToolUIAction(
            id: id,
            title: title,
            kind: .rowButton,
            toolID: toolID,
            arguments: .object([
                "episode_uuid": .string("{uuid}"),
                key: .string(value)
            ]),
            requiredRowFields: ["uuid"]
        )
    }

    private static var pocketExecutablePath: String? {
        for name in ["pocketctl", "pocketcasts", "pctl"] {
            if let path = ExecutableLocator.executablePath(named: name) {
                return path
            }
        }
        return nil
    }

    private static func preset(
        id: String,
        name: String,
        summary: String,
        executablePath: String,
        parameters: [ToolParameter],
        invocation: ProcessInvocation? = nil,
        argumentPattern: [String] = [],
        capability: ToolCapability,
        timeoutSeconds: Double = 60,
        outputLimitKB: Int = 8192,
        mode: ToolAdapterMode = .commandTemplate,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotations: ToolAnnotationOverrides?,
        uiActions: [ToolUIAction]? = nil,
        widgetPresentation: ToolWidgetPresentation? = ToolWidgetPresentation(
            profile: .episodeRows,
            accent: "#f43e37"
        )
    ) -> DefaultToolPreset {
        DefaultToolPreset(
            id: "preset.pocketctl.\(id)",
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            capability: capability,
            category: .podcasts,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            mode: mode,
            parameters: parameters,
            processInvocation: invocation,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotations,
            uiActions: uiActions,
            widgetPresentation: mode == .cliAdapter ? nil : widgetPresentation
        )
    }
}
