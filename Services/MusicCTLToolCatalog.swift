import Foundation

/// Sparse semantic Apple Music workflows. MusicKit REST reads use typed,
/// bounded inputs; Music.app writes always pass MusicCTL's own non-applying
/// preview before MacRemote launches the identical command with `--apply`.
enum MusicCTLToolCatalog {
    private static let maximumOutputBytes = 64 * 1024 * 1024
    static let maximumInlineArgumentLength = 64 * 1024
    static let maximumStandardInputLength = 64 * 1024

    static var detectedExecutablePath: String? {
        detectedExecutablePath { name in
            ExecutableLocator.executablePath(named: name)
        }
    }

    static func detectedExecutablePath(
        using locate: (String) -> String?
    ) -> String? {
        locate("musicctl")
            ?? locate("mctl")
            ?? locate("applemusic")
    }

    static var executablePath: String {
        detectedExecutablePath ?? "\(ExecutableLocator.homeDirectory)/.local/bin/musicctl"
    }

    static var fullCLITool: ToolDefinition {
        tool(
            id: "musicctl_run",
            name: "MusicCTL Flexible Command",
            summary: "Advanced fallback; prefer the dedicated MusicCTL tools. Pass exact argv items with no shell for uncommon Apple Music workflows. Authentication setup, configuration writes, onboarding, and raw request commands are blocked by policy. Prefer --json. This tool asks for every call.",
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    description: "Exact MusicCTL argv items. No shell syntax or expansion is available.",
                    kind: .stringArray,
                    required: false,
                    maximumLength: maximumInlineArgumentLength
                ),
                ToolParameter(
                    name: "stdin",
                    title: "Standard Input",
                    description: "Optional UTF-8 input passed directly to MusicCTL standard input.",
                    kind: .string,
                    required: false,
                    maximumLength: maximumStandardInputLength
                )
            ],
            argumentPattern: ["{args}"],
            capability: .destructive,
            timeoutSeconds: 600,
            approvalPolicy: .everyCall,
            annotationOverrides: ToolAnnotationOverrides(openWorldHint: true)
        )
    }

    static var dedicatedTools: [ToolDefinition] {
        [
            tool(
                id: "musicctl_doctor",
                name: "Check MusicCTL",
                summary: "Check MusicCTL configuration, Capability Host readiness, permissions, and optional saved credentials without making a live Apple request.",
                parameters: [
                    ToolParameter(
                        name: "check_credentials",
                        title: "Check Credentials",
                        description: "Check saved credentials and host readiness while staying offline.",
                        kind: .boolean,
                        required: false,
                        defaultValue: "false"
                    ),
                    profileParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("doctor"),
                    .flag("--check-credentials", "check_credentials"),
                    .option("--profile", "profile"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 30,
                annotationOverrides: localReadAnnotations
            ),
            tool(
                id: "musicctl_search",
                name: "Search Apple Music",
                summary: "Search the Apple Music catalog or authorized cloud library for albums, artists, songs, and playlists.",
                parameters: [
                    ToolParameter(
                        name: "query",
                        title: "Query",
                        description: "Album, artist, song, playlist, or topic text.",
                        kind: .string
                    ),
                    ToolParameter(
                        name: "types",
                        title: "Resource Types",
                        description: "Comma-separated Apple Music resource types.",
                        kind: .string,
                        required: false,
                        defaultValue: "albums,artists,songs,playlists"
                    ),
                    ToolParameter(
                        name: "scope",
                        title: "Scope",
                        description: "Search the public catalog or the authorized cloud library.",
                        kind: .string,
                        required: false,
                        defaultValue: "catalog",
                        allowedValues: ["catalog", "library"]
                    ),
                    ToolParameter(
                        name: "limit",
                        title: "Result Limit",
                        description: "Maximum results per resource type.",
                        kind: .integer,
                        required: false,
                        defaultValue: "25",
                        integerRange: 1...25
                    ),
                    profileParameter,
                    storefrontParameter,
                    languageParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("search"), .value("query"),
                    .option("--types", "types"),
                    .option("--scope", "scope"),
                    .option("--limit", "limit"),
                    .option("--profile", "profile"),
                    .option("--storefront", "storefront"),
                    .option("--language", "language"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                annotationOverrides: restReadAnnotations
            ),
            tool(
                id: "musicctl_list_library",
                name: "List Apple Music Library",
                summary: "List one resource collection from the authorized Apple Music cloud library.",
                parameters: [
                    ToolParameter(
                        name: "resource",
                        title: "Resource",
                        description: "Apple Music library resource collection to list.",
                        kind: .string
                    ),
                    ToolParameter(
                        name: "limit",
                        title: "Result Limit",
                        description: "Maximum resources in this page.",
                        kind: .integer,
                        required: false,
                        defaultValue: "25",
                        integerRange: 1...100
                    ),
                    profileParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("library"), .literal("list"), .value("resource"),
                    .option("--limit", "limit"),
                    .option("--profile", "profile"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                annotationOverrides: restReadAnnotations
            ),
            tool(
                id: "musicctl_new_releases",
                name: "Find New Music Releases",
                summary: "Scan the complete cloud library, find qualifying artists, and return recent Apple Music catalog releases not already represented by owned albums unless requested.",
                parameters: [
                    ToolParameter(
                        name: "min_songs",
                        title: "Minimum Songs",
                        description: "Minimum distinct library recordings required per artist.",
                        kind: .integer,
                        required: false,
                        defaultValue: "5",
                        integerRange: 1...100_000
                    ),
                    ToolParameter(
                        name: "since",
                        title: "Since",
                        description: "Inclusive YYYY-MM-DD date, Nd window, or Nw window, up to 3650 days.",
                        kind: .string,
                        required: false,
                        defaultValue: "30d"
                    ),
                    ToolParameter(
                        name: "types",
                        title: "Release Types",
                        description: "Comma-separated albums, singles, or compilations.",
                        kind: .string,
                        required: false,
                        defaultValue: "albums,singles"
                    ),
                    ToolParameter(
                        name: "include_owned",
                        title: "Include Owned",
                        description: "Include exact catalog releases already represented by library albums.",
                        kind: .boolean,
                        required: false,
                        defaultValue: "false"
                    ),
                    profileParameter,
                    storefrontParameter,
                    languageParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("library"), .literal("new-releases"),
                    .option("--min-songs", "min_songs"),
                    .option("--since", "since"),
                    .option("--types", "types"),
                    .flag("--include-owned", "include_owned"),
                    .option("--profile", "profile"),
                    .option("--storefront", "storefront"),
                    .option("--language", "language"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 3_600,
                annotationOverrides: restReadAnnotations
            ),
            tool(
                id: "musicctl_list_playlists",
                name: "List Apple Music Playlists",
                summary: "List playlists from the authorized Apple Music cloud library.",
                parameters: [
                    ToolParameter(
                        name: "limit",
                        title: "Result Limit",
                        description: "Maximum playlists in this page.",
                        kind: .integer,
                        required: false,
                        defaultValue: "25",
                        integerRange: 1...100
                    ),
                    profileParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("playlist"), .literal("list"),
                    .option("--limit", "limit"),
                    .option("--profile", "profile"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                annotationOverrides: restReadAnnotations
            ),
            tool(
                id: "musicctl_playlist_tracks",
                name: "Get Apple Music Playlist Tracks",
                summary: "Return tracks from one exact authorized cloud-library playlist identifier.",
                parameters: [
                    ToolParameter(
                        name: "identifier",
                        title: "Playlist Identifier",
                        description: "Exact Apple Music playlist identifier from a fresh read.",
                        kind: .string
                    ),
                    ToolParameter(
                        name: "limit",
                        title: "Result Limit",
                        description: "Maximum tracks in this page.",
                        kind: .integer,
                        required: false,
                        defaultValue: "25",
                        integerRange: 1...100
                    ),
                    profileParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("playlist"), .literal("tracks"), .value("identifier"),
                    .option("--limit", "limit"),
                    .option("--profile", "profile"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                annotationOverrides: restReadAnnotations
            ),
            tool(
                id: "musicctl_listening_history",
                name: "Get Apple Music Listening History",
                summary: "Return recently played, heavy-rotation, or recently added Apple Music resources. The shared limit stays within every selected endpoint's supported range.",
                parameters: [
                    ToolParameter(
                        name: "history",
                        title: "History",
                        description: "Apple Music history collection to return.",
                        kind: .string,
                        allowedValues: ["recently_played", "heavy_rotation", "recently_added"]
                    ),
                    ToolParameter(
                        name: "limit",
                        title: "Result Limit",
                        description: "Maximum resources in this page; 10 is the shared endpoint maximum.",
                        kind: .integer,
                        required: false,
                        defaultValue: "10",
                        integerRange: 1...10
                    ),
                    profileParameter
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("history"),
                    .choice("history", [
                        "recently_played": ["recently-played"],
                        "heavy_rotation": ["heavy-rotation"],
                        "recently_added": ["recently-added"]
                    ]),
                    .option("--limit", "limit"),
                    .option("--profile", "profile"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                annotationOverrides: restReadAnnotations
            ),
            tool(
                id: "musicctl_player_status",
                name: "Get Music Player Status",
                summary: "Return Music.app player state, current track metadata, position, volume, shuffle, and repeat state.",
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("player"), .literal("status"), .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 30,
                annotationOverrides: localReadAnnotations
            ),
            tool(
                id: "musicctl_list_output_routes",
                name: "List Music Output Routes",
                summary: "List Music.app audio output routes and exact persistent identifiers.",
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("output-route"), .literal("list"), .literal("--json")
                ]),
                capability: .readOnly,
                timeoutSeconds: 30,
                annotationOverrides: localReadAnnotations
            ),
            tool(
                id: "musicctl_player_control",
                name: "Control Music Playback",
                summary: "Play, pause, toggle, stop, skip, or return to the previous Music.app track after MusicCTL's non-applying preview succeeds.",
                parameters: [
                    ToolParameter(
                        name: "action",
                        title: "Action",
                        description: "Music.app playback action.",
                        kind: .string,
                        allowedValues: ["play", "pause", "toggle", "stop", "next", "previous"]
                    )
                ],
                invocation: applyingInvocation(arguments: [
                    .literal("player"),
                    .choice("action", [
                        "play": ["play"],
                        "pause": ["pause"],
                        "toggle": ["toggle"],
                        "stop": ["stop"],
                        "next": ["next"],
                        "previous": ["previous"]
                    ])
                ]),
                capability: .write,
                timeoutSeconds: 30,
                annotationOverrides: localWriteAnnotations
            ),
            tool(
                id: "musicctl_seek",
                name: "Seek Music Playback",
                summary: "Set Music.app playback to an absolute position after MusicCTL's non-applying preview succeeds.",
                parameters: [
                    ToolParameter(
                        name: "seconds",
                        title: "Position Seconds",
                        description: "Absolute playback position in seconds.",
                        kind: .number,
                        numberRange: 0...86_400
                    )
                ],
                invocation: applyingInvocation(arguments: [
                    .literal("player"), .literal("seek"), .value("seconds")
                ]),
                capability: .write,
                timeoutSeconds: 30,
                annotationOverrides: localWriteAnnotations
            ),
            tool(
                id: "musicctl_set_volume",
                name: "Set Music Volume",
                summary: "Set Music.app volume after MusicCTL's non-applying preview succeeds.",
                parameters: [
                    ToolParameter(
                        name: "value",
                        title: "Volume",
                        description: "Music.app volume from 0 through 100.",
                        kind: .integer,
                        integerRange: 0...100
                    )
                ],
                invocation: applyingInvocation(arguments: [
                    .literal("player"), .literal("volume"), .value("value")
                ]),
                capability: .write,
                timeoutSeconds: 30,
                annotationOverrides: localIdempotentWriteAnnotations
            ),
            tool(
                id: "musicctl_set_shuffle",
                name: "Set Music Shuffle",
                summary: "Enable or disable Music.app shuffle, with an optional grouping mode, after MusicCTL's non-applying preview succeeds.",
                parameters: [
                    ToolParameter(
                        name: "enabled",
                        title: "Enabled",
                        description: "Enable or disable Music.app shuffle.",
                        kind: .boolean
                    ),
                    ToolParameter(
                        name: "mode",
                        title: "Mode",
                        description: "Optional Music.app shuffle grouping.",
                        kind: .string,
                        required: false,
                        allowedValues: ["songs", "albums", "groupings"]
                    )
                ],
                invocation: applyingInvocation(arguments: [
                    .literal("player"), .literal("shuffle"), .value("enabled"),
                    .option("--mode", "mode")
                ]),
                capability: .write,
                timeoutSeconds: 30,
                annotationOverrides: localIdempotentWriteAnnotations
            ),
            tool(
                id: "musicctl_set_repeat",
                name: "Set Music Repeat",
                summary: "Set Music.app repeat mode after MusicCTL's non-applying preview succeeds.",
                parameters: [
                    ToolParameter(
                        name: "mode",
                        title: "Mode",
                        description: "Music.app repeat mode.",
                        kind: .string,
                        allowedValues: ["off", "one", "all"]
                    )
                ],
                invocation: applyingInvocation(arguments: [
                    .literal("player"), .literal("repeat"), .value("mode")
                ]),
                capability: .write,
                timeoutSeconds: 30,
                annotationOverrides: localIdempotentWriteAnnotations
            ),
            tool(
                id: "musicctl_select_output_routes",
                name: "Select Music Output Routes",
                summary: "Select one or more exact Music.app output-route identifiers after MusicCTL's non-applying preview succeeds.",
                parameters: [
                    ToolParameter(
                        name: "output_ids",
                        title: "Output Route Identifiers",
                        description: "One or more exact output persistent identifiers from a fresh route list.",
                        kind: .stringArray
                    )
                ],
                invocation: applyingInvocation(arguments: [
                    .literal("output-route"), .literal("select"), .value("output_ids")
                ]),
                capability: .write,
                timeoutSeconds: 30,
                annotationOverrides: localIdempotentWriteAnnotations
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

    private static let profileParameter = ToolParameter(
        name: "profile",
        title: "Profile",
        description: "Optional MusicCTL credential profile.",
        kind: .string,
        required: false
    )

    private static let storefrontParameter = ToolParameter(
        name: "storefront",
        title: "Storefront",
        description: "Apple Music storefront code.",
        kind: .string,
        required: false,
        defaultValue: "us"
    )

    private static let languageParameter = ToolParameter(
        name: "language",
        title: "Language",
        description: "Optional Apple Music localization language tag.",
        kind: .string,
        required: false
    )

    private static let restReadAnnotations = ToolAnnotationOverrides(openWorldHint: true)
    private static let localReadAnnotations = ToolAnnotationOverrides(openWorldHint: false)
    private static let localWriteAnnotations = ToolAnnotationOverrides(openWorldHint: false)
    private static let localIdempotentWriteAnnotations = ToolAnnotationOverrides(
        idempotentHint: true,
        openWorldHint: false
    )

    private static func applyingInvocation(
        arguments: [ProcessArgumentRule]
    ) -> ProcessInvocation {
        ProcessInvocation(
            arguments: arguments + [.literal("--apply"), .literal("--json")],
            preflightSuffix: ["--json"],
            preflightRemovingArguments: ["--apply", "--json"]
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
        annotationOverrides: ToolAnnotationOverrides
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
            category: .music,
            permissionRequirements: [],
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotationOverrides,
            uiActions: nil,
            widgetPresentation: nil
        )
    }
}
