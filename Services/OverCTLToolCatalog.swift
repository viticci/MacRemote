import Foundation

/// Sparse semantic OverCTL workflows. Every dedicated recipe preserves
/// OverCTL's stable JSON envelope and uses its own dry-run/readback contract
/// before MacRemote submits an account write.
enum OverCTLToolCatalog {
    private static let maximumOutputBytes = 64 * 1024 * 1024
    static let maximumArgumentLength = 64 * 1024

    static var detectedExecutablePath: String? {
        detectedExecutablePath { name in
            ExecutableLocator.executablePath(named: name)
        }
    }

    static func detectedExecutablePath(
        using locate: (String) -> String?
    ) -> String? {
        locate("overctl") ?? locate("octl")
    }

    static var executablePath: String {
        detectedExecutablePath ?? "\(ExecutableLocator.homeDirectory)/.local/bin/overctl"
    }

    static var fullCLITool: ToolDefinition {
        tool(
            id: "overctl_run",
            name: "OverCTL Flexible Command",
            summary: "Advanced fallback; prefer the dedicated OverCTL tools. Pass exact argv items with no shell for subscriptions, playlists, chapters, downloads, cache, diagnostics, and uncommon verified workflows. Sign-in, session removal, experimental upload, credential-bearing exports and URLs, forced replacement, and receipt clearing stay blocked. Prefer --json. This tool asks for every call.",
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    description: "Exact OverCTL argv items. No shell syntax or expansion is available.",
                    kind: .stringArray,
                    required: false,
                    maximumLength: maximumArgumentLength
                )
            ],
            argumentPattern: ["{args}"],
            capability: .destructive,
            timeoutSeconds: 600,
            approvalPolicy: .everyCall,
            annotationOverrides: ToolAnnotationOverrides(openWorldHint: true),
            widgetPresentation: nil
        )
    }

    static var dedicatedTools: [ToolDefinition] {
        [
            tool(
                id: "overctl_up_next",
                name: "Get Overcast Up Next",
                summary: "Rank Queue episodes first, then in-progress episodes and new arrivals. An optional time budget keeps OverCTL's complete skipped-item explanation in the JSON envelope.",
                parameters: [
                    ToolParameter(
                        name: "minutes",
                        title: "Listening Minutes",
                        description: "Optional listening-time budget.",
                        kind: .integer,
                        required: false,
                        integerRange: 1...1440
                    ),
                    ToolParameter(
                        name: "podcast",
                        title: "Podcast",
                        description: "Optional exact podcast ID or title fragment.",
                        kind: .string,
                        required: false,
                        maximumLength: 512
                    ),
                    ToolParameter(
                        name: "exclude_played",
                        title: "Exclude Played",
                        description: "Drop played episodes that remain in Queue.",
                        kind: .boolean,
                        required: false,
                        defaultValue: "false"
                    ),
                    ToolParameter(
                        name: "limit",
                        title: "Result Limit",
                        description: "Maximum ranked episodes to return.",
                        kind: .integer,
                        required: false,
                        defaultValue: "20",
                        integerRange: 1...500
                    ),
                    sourceParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("up-next"),
                    .option("--minutes", "minutes"),
                    .option("--podcast", "podcast"),
                    .flag("--exclude-played", "exclude_played"),
                    .option("--limit", "limit"),
                    .option("--source", "source"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 180,
                uiActions: upNextUIActions
            ),
            tool(
                id: "overctl_search",
                name: "Search Overcast",
                summary: "Search OverCTL's network-free account cache for podcasts, episodes, and playlists, or search Overcast's live podcast directory.",
                parameters: [
                    ToolParameter(
                        name: "query",
                        title: "Query",
                        description: "Podcast, episode, playlist, author, or topic text.",
                        kind: .string,
                        maximumLength: 512
                    ),
                    ToolParameter(
                        name: "scope",
                        title: "Scope",
                        description: "Search the local account library or Overcast's live podcast directory.",
                        kind: .string,
                        required: false,
                        defaultValue: "library",
                        allowedValues: ["library", "directory"]
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .choice("scope", [
                        "library": ["search"],
                        "directory": ["discover"]
                    ]),
                    .value("query"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120
            ),
            tool(
                id: "overctl_episode",
                name: "Get Overcast Episode",
                summary: "Return one exact Overcast episode with podcast metadata, state, progress, bounded show-note fields, and redacted publisher URLs.",
                parameters: [episodeID, sourceParameter],
                invocation: ProcessInvocation(arguments: [
                    .literal("episode"), .value("episode_id"),
                    .option("--source", "source"), .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 180,
                uiActions: episodeUIActions
            ),
            tool(
                id: "overctl_transcript",
                name: "Get Overcast Transcript",
                summary: "Return a podcast-supplied or Overcast-generated transcript in OverCTL's JSON envelope. This dedicated tool never sends audio to Gemini and never writes an export file.",
                parameters: [
                    episodeID,
                    ToolParameter(
                        name: "provider",
                        title: "Provider",
                        description: "Use the feed first, require the podcast feed, or require Overcast's generated transcript.",
                        kind: .string,
                        required: false,
                        defaultValue: "auto",
                        allowedValues: ["auto", "feed", "generated"]
                    ),
                    ToolParameter(
                        name: "from_seconds",
                        title: "From Seconds",
                        description: "Optional inclusive transcript window start.",
                        kind: .number,
                        required: false,
                        numberRange: 0...1_000_000_000
                    ),
                    ToolParameter(
                        name: "to_seconds",
                        title: "To Seconds",
                        description: "Optional transcript window end. It must be greater than From Seconds.",
                        kind: .number,
                        required: false,
                        numberRange: 0...1_000_000_000
                    ),
                    ToolParameter(
                        name: "include_segments",
                        title: "Include Segments",
                        description: "Include timed segment and token arrays when the provider supplies timing.",
                        kind: .boolean,
                        required: false,
                        defaultValue: "false"
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("transcript"), .value("episode_id"),
                    .option("--provider", "provider"),
                    .option("--from", "from_seconds"),
                    .option("--to", "to_seconds"),
                    .flag("--segments", "include_segments"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 300
            ),
            tool(
                id: "overctl_change_queue",
                name: "Change Overcast Queue",
                summary: "Add one episode next or last in Overcast's exact Queue, or remove it. MacRemote runs OverCTL's fresh-bootstrap dry run before the verified write.",
                parameters: [
                    episodeID,
                    ToolParameter(
                        name: "action",
                        title: "Action",
                        description: "Desired Queue membership or placement.",
                        kind: .string,
                        allowedValues: ["add_next", "add_last", "remove"]
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .choice("action", [
                            "add_next": ["queue-add"],
                            "add_last": ["queue-add"],
                            "remove": ["queue-remove"]
                        ]),
                        .value("episode_id"),
                        .choice("action", [
                            "add_next": ["--position", "next"],
                            "add_last": ["--position", "last"],
                            "remove": []
                        ]),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                timeoutSeconds: 300
            ),
            tool(
                id: "overctl_update_episode_state",
                name: "Update Overcast Episode State",
                summary: "Set one episode's played, saved, starred, or restored state. Resetting an unsaved episode to unplayed may re-save it. MacRemote runs OverCTL's exact dry run before the write and verifies the requested field with a fresh readback.",
                parameters: [
                    episodeID,
                    ToolParameter(
                        name: "state",
                        title: "State",
                        description: "Desired reversible episode state.",
                        kind: .string,
                        allowedValues: ["completed", "unplayed", "saved", "starred", "unstarred", "restored"]
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .choice("state", [
                            "completed": ["done"],
                            "unplayed": ["unplayed"],
                            "saved": ["save"],
                            "starred": ["star"],
                            "unstarred": ["unstar"],
                            "restored": ["restore"]
                        ]),
                        .value("episode_id"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                timeoutSeconds: 300,
                annotationOverrides: ToolAnnotationOverrides(idempotentHint: true, openWorldHint: true)
            ),
            tool(
                id: "overctl_set_progress",
                name: "Set Overcast Progress",
                summary: "Set synced playback progress in seconds after OverCTL reads current state. An unsaved episode may be re-saved; the dry-run reports that side effect before MacRemote applies it.",
                parameters: [
                    episodeID,
                    ToolParameter(
                        name: "position_seconds",
                        title: "Position Seconds",
                        description: "Non-negative playback position. Use Update Overcast Episode State to mark an episode completed.",
                        kind: .integer,
                        integerRange: 0...2_147_483_646
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("progress"), .value("episode_id"),
                        .option("--position", "position_seconds"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                timeoutSeconds: 300,
                annotationOverrides: ToolAnnotationOverrides(idempotentHint: true, openWorldHint: true)
            ),
            tool(
                id: "overctl_archive_episode",
                name: "Archive Overcast Episode",
                summary: "Destructively archive one episode after OverCTL's complete native-state dry run. OverCTL verifies every logical episode field; Update Overcast Episode State with restored reverses it.",
                parameters: [episodeID],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("archive"), .value("episode_id"),
                        .literal("--yes"), .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"],
                    preflightRemovingArguments: ["--yes"]
                ),
                capability: .destructive,
                timeoutSeconds: 300,
                approvalPolicy: .everyCall,
                annotationOverrides: ToolAnnotationOverrides(idempotentHint: true, openWorldHint: true)
            )
        ]
    }

    static var builtInTools: [ToolDefinition] { dedicatedTools + [fullCLITool] }

    static func tool(id: String) -> ToolDefinition? {
        builtInTools.first { $0.id == id }
    }

    static func arguments(
        for toolID: String,
        parameters: [String: ToolArgumentValue]
    ) throws -> [String] {
        guard let tool = tool(id: toolID) else {
            throw ToolValidationError.unknownTool(toolID)
        }
        return try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
    }

    private static let episodeID = ToolParameter(
        name: "episode_id",
        title: "Episode ID",
        description: "Exact positive Overcast episode ID from a fresh read.",
        kind: .integer,
        integerRange: 1...Int.max
    )

    private static let sourceParameter = ToolParameter(
        name: "source",
        title: "Source",
        description: "Use an existing cache, require a live read, or let OverCTL choose cache then live.",
        kind: .string,
        required: false,
        defaultValue: "auto",
        allowedValues: ["auto", "cache", "live"]
    )

    private static var upNextUIActions: [ToolUIAction] {
        episodeActions(idField: "episodeID")
    }

    private static var episodeUIActions: [ToolUIAction] {
        episodeActions(idField: "id")
    }

    private static func episodeActions(idField: String) -> [ToolUIAction] {
        [
            episodeAction(
                id: "play_next", title: "Play Next", toolID: "overctl_change_queue",
                idField: idField, key: "action", value: "add_next"
            ),
            episodeAction(
                id: "play_last", title: "Play Last", toolID: "overctl_change_queue",
                idField: idField, key: "action", value: "add_last"
            ),
            episodeAction(
                id: "star", title: "Star", toolID: "overctl_update_episode_state",
                idField: idField, key: "state", value: "starred"
            ),
            ToolUIAction(
                id: "archive",
                title: "Archive",
                kind: .rowButton,
                toolID: "overctl_archive_episode",
                arguments: .object(["episode_id": .string("{\(idField)}")]),
                requiredRowFields: [idField],
                style: .destructive
            )
        ]
    }

    private static func episodeAction(
        id: String,
        title: String,
        toolID: String,
        idField: String,
        key: String,
        value: String
    ) -> ToolUIAction {
        ToolUIAction(
            id: id,
            title: title,
            kind: .rowButton,
            toolID: toolID,
            arguments: .object([
                "episode_id": .string("{\(idField)}"),
                key: .string(value)
            ]),
            requiredRowFields: [idField]
        )
    }

    private static func tool(
        id: String,
        name: String,
        summary: String,
        parameters: [ToolParameter],
        invocation: ProcessInvocation? = nil,
        argumentPattern: [String] = [],
        capability: ToolCapability,
        timeoutSeconds: Double,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotationOverrides: ToolAnnotationOverrides = ToolAnnotationOverrides(openWorldHint: true),
        uiActions: [ToolUIAction]? = nil,
        widgetPresentation: ToolWidgetPresentation? = ToolWidgetPresentation(
            profile: .episodeRows,
            accent: "light-dark(#9a4300, #ff9f0a)",
            rootPath: "data"
        )
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            parameters: parameters,
            processInvocation: invocation,
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: maximumOutputBytes,
            category: .podcasts,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotationOverrides,
            uiActions: uiActions,
            widgetPresentation: widgetPresentation
        )
    }
}
