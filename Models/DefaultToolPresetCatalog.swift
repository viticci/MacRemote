import Foundation

struct DefaultToolPreset: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let executablePath: String
    let argumentPattern: [String]
    let capability: ToolCapability
    let category: ToolCategory
    let timeoutSeconds: Double
    let outputLimitKB: Int
    let mode: ToolAdapterMode
    let permissionRequirements: [ToolPermissionRequirement]

    var requiresFullDiskAccess: Bool {
        permissionRequirements.contains(.fullDiskAccess)
    }

    var draft: ToolDefinitionDraft {
        ToolDefinitionDraft(
            mode: mode,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentsText: argumentPattern.joined(separator: "\n"),
            capability: capability,
            category: category,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            requiresFullDiskAccess: requiresFullDiskAccess,
            permissionRequirements: permissionRequirements.filter { !$0.isFullDiskAccess }
        )
    }

    init(
        id: String,
        name: String,
        summary: String,
        executablePath: String,
        argumentPattern: [String],
        capability: ToolCapability,
        category: ToolCategory,
        timeoutSeconds: Double,
        outputLimitKB: Int,
        mode: ToolAdapterMode = .commandTemplate,
        requiresFullDiskAccess: Bool = false,
        permissionRequirements: [ToolPermissionRequirement] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.executablePath = executablePath
        self.argumentPattern = argumentPattern
        self.capability = capability
        self.category = category
        self.timeoutSeconds = timeoutSeconds
        self.outputLimitKB = outputLimitKB
        self.mode = mode
        self.permissionRequirements = ToolPermissionRequirement.normalized(
            permissionRequirements + (requiresFullDiskAccess ? [.fullDiskAccess] : [])
        )
    }
}

struct DefaultToolPresetSet: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let presetIDs: [String]

    var presets: [DefaultToolPreset] {
        presetIDs.compactMap(DefaultToolPresetCatalog.preset)
    }
}

enum DefaultToolPresetCatalog {
    static var categories: [ToolCategory] {
        ToolCategory.allCases.filter { category in
            !presets(in: category).isEmpty
        }
    }

    static var presets: [DefaultToolPreset] {
        codexPresets + remCTLPresets + habitCTLPresets + pocketCTLPresets + popularCLIPresets + basePresets
    }

    static var preferredCategory: ToolCategory {
        if codexExecutablePath != nil {
            return .developer
        }
        if pocketCTLExecutablePath != nil {
            return .podcasts
        }
        if remCTLExecutablePath != nil {
            return .reminders
        }
        return .filesystem
    }

    static var featuredPresets: [DefaultToolPreset] {
        directCLIPresets
    }

    static var presetSets: [DefaultToolPresetSet] {
        let availablePresets = presets
        let allPresetIDs = availablePresets.map(\.id)
        var sets = [
            DefaultToolPresetSet(
                id: "set.all_system_presets",
                name: "All System Presets",
                summary: "Install every available preset MacRemote detected on this Mac.",
                presetIDs: allPresetIDs
            )
        ]

        let detectedCLIPresetIDs = featuredPresets.map(\.id)
        if !detectedCLIPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.detected_clis",
                name: "Detected CLIs",
                summary: "Install one direct adapter for each detected command-line tool.",
                presetIDs: detectedCLIPresetIDs
            ))
        }

        let remCTLPresetIDs = remCTLPresets.map(\.id)
        if !remCTLPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.reminders",
                name: "Reminders",
                summary: "Install the Reminders read tools plus the direct RemCTL adapter.",
                presetIDs: remCTLPresetIDs
            ))
        }

        let habitCTLPresetIDs = habitCTLPresets.map(\.id)
        if !habitCTLPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.habits",
                name: "Habits",
                summary: "Install Habitify inspection tools plus the direct HabitCTL adapter.",
                presetIDs: habitCTLPresetIDs
            ))
        }

        let pocketPresetIDs = pocketCTLPresets.map(\.id)
        if !pocketPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.podcasts",
                name: "Podcasts",
                summary: "Install Pocket Casts inspection tools plus the direct PocketCTL adapter.",
                presetIDs: pocketPresetIDs
            ))
        }

        let steipetePresetIDs = availablePresets
            .filter { preset in
                preset.id.hasPrefix("preset.peekaboo.") ||
                    preset.id.hasPrefix("preset.spogo.") ||
                    preset.id.hasPrefix("preset.summarize.") ||
                    preset.id.hasPrefix("preset.gog.")
            }
            .map(\.id)
        if !steipetePresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.steipete_openclaw",
                name: "Steipete / OpenClaw",
                summary: "Install presets for Peekaboo, Spogo, Summarize, and Gog when present.",
                presetIDs: steipetePresetIDs
            ))
        }

        let developerPresetIDs = availablePresets
            .filter { $0.category == .developer }
            .map(\.id)
        if !developerPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.developer",
                name: "Developer",
                summary: "Install developer CLIs and read-only git helpers.",
                presetIDs: developerPresetIDs
            ))
        }

        let textPresetIDs = availablePresets
            .filter { $0.category == .text }
            .map(\.id)
        if !textPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.text_data",
                name: "Text and Data",
                summary: "Install text, JSON, search, and summarization presets.",
                presetIDs: textPresetIDs
            ))
        }

        let mediaPresetIDs = availablePresets
            .filter { $0.category == .imageProcessing }
            .map(\.id)
        if !mediaPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.media",
                name: "Media",
                summary: "Install image, video, and media-processing presets.",
                presetIDs: mediaPresetIDs
            ))
        }

        let utilityPresetIDs = availablePresets
            .filter { $0.category == .utilities }
            .map(\.id)
        if !utilityPresetIDs.isEmpty {
            sets.append(DefaultToolPresetSet(
                id: "set.utilities",
                name: "Utilities",
                summary: "Install system, network, automation, and service CLIs.",
                presetIDs: utilityPresetIDs
            ))
        }

        return sets.filter { !$0.presetIDs.isEmpty }
    }

    private static var directCLIPresets: [DefaultToolPreset] {
        presets.filter { $0.mode == .cliAdapter }
    }

    private static let basePresets: [DefaultToolPreset] = [
        .filesystem,
        .utilities,
        .imageProcessing,
        .text,
        .developer
    ].flatMap { category in
        basePresetsByCategory[category] ?? []
    }

    private static let basePresetsByCategory: [ToolCategory: [DefaultToolPreset]] = [
        .filesystem: [
            DefaultToolPreset(
                id: "preset.filesystem.list_directory",
                name: "List Directory",
                summary: "List a directory without modifying it.",
                executablePath: "/bin/ls",
                argumentPattern: ["-la", "{path}"],
                capability: .readOnly,
                category: .filesystem,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            ),
            DefaultToolPreset(
                id: "preset.filesystem.file_info",
                name: "File Info",
                summary: "Return size and modification metadata for one path.",
                executablePath: "/usr/bin/stat",
                argumentPattern: ["-f", "%N %z bytes %Sm", "{path}"],
                capability: .readOnly,
                category: .filesystem,
                timeoutSeconds: 10,
                outputLimitKB: 512
            ),
            DefaultToolPreset(
                id: "preset.filesystem.read_head",
                name: "Read File Head",
                summary: "Read the first N lines of a text file.",
                executablePath: "/usr/bin/head",
                argumentPattern: ["-n", "{lines}", "{path}"],
                capability: .readOnly,
                category: .filesystem,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            ),
            DefaultToolPreset(
                id: "preset.filesystem.find_by_name",
                name: "Find By Name",
                summary: "Search filenames under a chosen root path.",
                executablePath: "/usr/bin/find",
                argumentPattern: ["{root}", "-iname", "{pattern}"],
                capability: .readOnly,
                category: .filesystem,
                timeoutSeconds: 20,
                outputLimitKB: 1024
            )
        ],
        .utilities: [
            DefaultToolPreset(
                id: "preset.utilities.current_date",
                name: "Current Date",
                summary: "Return the current local timestamp.",
                executablePath: "/bin/date",
                argumentPattern: ["+%Y-%m-%dT%H:%M:%S%z"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 5,
                outputLimitKB: 64
            ),
            DefaultToolPreset(
                id: "preset.utilities.disk_usage",
                name: "Disk Usage",
                summary: "Return mounted filesystem usage.",
                executablePath: "/bin/df",
                argumentPattern: ["-h"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 10,
                outputLimitKB: 512
            ),
            DefaultToolPreset(
                id: "preset.utilities.uptime",
                name: "System Uptime",
                summary: "Return uptime and load averages.",
                executablePath: "/usr/bin/uptime",
                argumentPattern: [],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 5,
                outputLimitKB: 64
            ),
            DefaultToolPreset(
                id: "preset.utilities.network_interfaces",
                name: "Network Interfaces",
                summary: "Return local network interface details.",
                executablePath: "/sbin/ifconfig",
                argumentPattern: [],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            )
        ],
        .imageProcessing: [
            DefaultToolPreset(
                id: "preset.image.info",
                name: "Image Info",
                summary: "Return dimensions and format for an image.",
                executablePath: "/usr/bin/sips",
                argumentPattern: ["-g", "pixelWidth", "-g", "pixelHeight", "-g", "format", "{path}"],
                capability: .readOnly,
                category: .imageProcessing,
                timeoutSeconds: 10,
                outputLimitKB: 256
            ),
            DefaultToolPreset(
                id: "preset.image.convert_png",
                name: "Convert To PNG",
                summary: "Write a PNG copy of an input image.",
                executablePath: "/usr/bin/sips",
                argumentPattern: ["-s", "format", "png", "{input}", "--out", "{output}"],
                capability: .write,
                category: .imageProcessing,
                timeoutSeconds: 20,
                outputLimitKB: 512
            ),
            DefaultToolPreset(
                id: "preset.image.resize_width",
                name: "Resize Width",
                summary: "Write a resized image copy at a target width.",
                executablePath: "/usr/bin/sips",
                argumentPattern: ["--resampleWidth", "{width}", "{input}", "--out", "{output}"],
                capability: .write,
                category: .imageProcessing,
                timeoutSeconds: 20,
                outputLimitKB: 512
            )
        ],
        .text: [
            DefaultToolPreset(
                id: "preset.text.word_count",
                name: "Word Count",
                summary: "Count words in a text file.",
                executablePath: "/usr/bin/wc",
                argumentPattern: ["-w", "{path}"],
                capability: .readOnly,
                category: .text,
                timeoutSeconds: 10,
                outputLimitKB: 128
            ),
            DefaultToolPreset(
                id: "preset.text.line_count",
                name: "Line Count",
                summary: "Count lines in a text file.",
                executablePath: "/usr/bin/wc",
                argumentPattern: ["-l", "{path}"],
                capability: .readOnly,
                category: .text,
                timeoutSeconds: 10,
                outputLimitKB: 128
            ),
            DefaultToolPreset(
                id: "preset.text.search_file",
                name: "Search Text File",
                summary: "Search one text file and return matching lines.",
                executablePath: "/usr/bin/grep",
                argumentPattern: ["-n", "{pattern}", "{path}"],
                capability: .readOnly,
                category: .text,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            )
        ],
        .developer: [
            DefaultToolPreset(
                id: "preset.developer.git_status",
                name: "Git Status",
                summary: "Return short git status for a repository path.",
                executablePath: "/usr/bin/git",
                argumentPattern: ["-C", "{path}", "status", "--short"],
                capability: .readOnly,
                category: .developer,
                timeoutSeconds: 10,
                outputLimitKB: 512
            ),
            DefaultToolPreset(
                id: "preset.developer.git_log",
                name: "Git Log",
                summary: "Return recent one-line commits for a repository path.",
                executablePath: "/usr/bin/git",
                argumentPattern: ["-C", "{path}", "log", "--oneline", "-n", "{count}"],
                capability: .readOnly,
                category: .developer,
                timeoutSeconds: 10,
                outputLimitKB: 512
            )
        ]
    ]

    static func presets(in category: ToolCategory) -> [DefaultToolPreset] {
        presets.filter { $0.category == category }
    }

    static func preset(id: String) -> DefaultToolPreset? {
        presets.first { $0.id == id }
    }

    static var codexExecutablePath: String? {
        ExecutableLocator.executablePath(named: "codex")
    }

    static var pocketCTLExecutablePath: String? {
        ExecutableLocator.executablePath(named: "pocketctl")
    }

    static var habitCTLExecutablePath: String? {
        ExecutableLocator.executablePath(named: "habitctl")
    }

    static var remCTLExecutablePath: String? {
        RemCTLToolCatalog.detectedExecutablePath
    }

    private static var codexPresets: [DefaultToolPreset] {
        guard let executablePath = codexExecutablePath else { return [] }

        return [
            DefaultToolPreset(
                id: "preset.developer.codex_read_only_exec",
                name: "Codex Read-Only Exec",
                summary: "Run Codex non-interactively in read-only mode with a model prompt.",
                executablePath: executablePath,
                argumentPattern: [
                    "--ask-for-approval", "never",
                    "--sandbox", "read-only",
                    "exec",
                    "--skip-git-repo-check",
                    "{prompt}"
                ],
                capability: .destructive,
                category: .developer,
                timeoutSeconds: 60,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.developer.codex",
                name: "Codex CLI",
                summary: "Run Codex by passing argv directly. Write-capable calls require per-call host approval.",
                executablePath: executablePath,
                argumentPattern: ["{args}"],
                capability: .destructive,
                category: .developer,
                timeoutSeconds: 60,
                outputLimitKB: 2048,
                mode: .cliAdapter
            )
        ]
    }

    private static var pocketCTLPresets: [DefaultToolPreset] {
        guard let executablePath = pocketCTLExecutablePath else { return [] }

        return [
            DefaultToolPreset(
                id: "preset.pocketctl.doctor",
                name: "PocketCTL Doctor",
                summary: "Run PocketCTL agent health checks as JSON.",
                executablePath: executablePath,
                argumentPattern: ["doctor", "--for-agent", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.triage",
                name: "PocketCTL Triage",
                summary: "Return a live Pocket Casts triage board as JSON.",
                executablePath: executablePath,
                argumentPattern: ["triage", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.now",
                name: "PocketCTL Now",
                summary: "Return the live first Up Next episode as JSON.",
                executablePath: executablePath,
                argumentPattern: ["now", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 15,
                outputLimitKB: 1024
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.up_next",
                name: "PocketCTL Up Next",
                summary: "Return the live Up Next queue as JSON.",
                executablePath: executablePath,
                argumentPattern: ["up-next", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.in_progress",
                name: "PocketCTL In Progress",
                summary: "Return in-progress episodes from Pocket Casts as JSON.",
                executablePath: executablePath,
                argumentPattern: ["in-progress", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.history",
                name: "PocketCTL History",
                summary: "Return recent Pocket Casts history as JSON.",
                executablePath: executablePath,
                argumentPattern: ["history", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.subscriptions",
                name: "PocketCTL Subscriptions",
                summary: "Return subscribed podcasts and folders as JSON.",
                executablePath: executablePath,
                argumentPattern: ["subscriptions", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.bookmarks",
                name: "PocketCTL Bookmarks",
                summary: "Return Pocket Casts bookmarks as JSON.",
                executablePath: executablePath,
                argumentPattern: ["bookmarks", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.playlists",
                name: "PocketCTL Playlists",
                summary: "Return Pocket Casts playlists and filters as JSON.",
                executablePath: executablePath,
                argumentPattern: ["playlists", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.search_online",
                name: "PocketCTL Online Search",
                summary: "Search Pocket Casts live cache and return JSON results.",
                executablePath: executablePath,
                argumentPattern: ["search-online", "{query}", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.show",
                name: "PocketCTL Show Episode",
                summary: "Return one episode with metadata, notes, and transcript status as JSON.",
                executablePath: executablePath,
                argumentPattern: ["show", "{episodeID}", "--json"],
                capability: .readOnly,
                category: .podcasts,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.pocketctl.run",
                name: "Run PocketCTL",
                summary: "Run PocketCTL by passing argv directly. Prefer `--json`; use `--dry-run --json` before queue, playlist, bookmark, archive, progress, or played-state writes.",
                executablePath: executablePath,
                argumentPattern: ["{args}"],
                capability: .destructive,
                category: .podcasts,
                timeoutSeconds: 30,
                outputLimitKB: 2048,
                mode: .cliAdapter
            )
        ]
    }

    private static var habitCTLPresets: [DefaultToolPreset] {
        guard let executablePath = habitCTLExecutablePath else { return [] }

        return [
            DefaultToolPreset(
                id: "preset.habitctl.doctor",
                name: "HabitCTL Doctor",
                summary: "Run HabitCTL agent health checks as JSON.",
                executablePath: executablePath,
                argumentPattern: ["doctor", "--for-agent", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 1024
            ),
            DefaultToolPreset(
                id: "preset.habitctl.today",
                name: "HabitCTL Today",
                summary: "Return today's Habitify journal overview as JSON.",
                executablePath: executablePath,
                argumentPattern: ["today", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.journal",
                name: "HabitCTL Journal",
                summary: "Return the Habitify journal for a date as JSON.",
                executablePath: executablePath,
                argumentPattern: ["journal", "--date", "{date}", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.habits",
                name: "HabitCTL Habits",
                summary: "List active Habitify habits as JSON.",
                executablePath: executablePath,
                argumentPattern: ["habits", "--active", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.show",
                name: "HabitCTL Show Habit",
                summary: "Inspect one Habitify habit by name or id as JSON.",
                executablePath: executablePath,
                argumentPattern: ["show", "{habit}", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.search",
                name: "HabitCTL Search",
                summary: "Find Habitify habits by name and return JSON results.",
                executablePath: executablePath,
                argumentPattern: ["search", "{query}", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.streaks",
                name: "HabitCTL Streaks",
                summary: "Return current Habitify streaks from the journal as JSON.",
                executablePath: executablePath,
                argumentPattern: ["streaks", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.stats",
                name: "HabitCTL Stats",
                summary: "Return statistics for one Habitify habit as JSON.",
                executablePath: executablePath,
                argumentPattern: ["stats", "{habit}", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ),
            DefaultToolPreset(
                id: "preset.habitctl.areas",
                name: "HabitCTL Areas",
                summary: "List Habitify areas as JSON.",
                executablePath: executablePath,
                argumentPattern: ["areas", "--json"],
                capability: .readOnly,
                category: .habits,
                timeoutSeconds: 15,
                outputLimitKB: 1024
            ),
            DefaultToolPreset(
                id: "preset.habitctl.run",
                name: "Run HabitCTL",
                summary: "Run HabitCTL by passing argv directly. Prefer `--json`; use `--dry-run --json` before creating, editing, deleting, checking, logging, archiving, or note writes.",
                executablePath: executablePath,
                argumentPattern: ["{args}"],
                capability: .destructive,
                category: .habits,
                timeoutSeconds: 30,
                outputLimitKB: 2048,
                mode: .cliAdapter
            )
        ]
    }

    private static var remCTLPresets: [DefaultToolPreset] {
        guard let executablePath = remCTLExecutablePath else { return [] }

        return RemCTLToolCatalog.builtInTools.map { tool in
            DefaultToolPreset(
                id: "preset.\(tool.id)",
                name: tool.name,
                summary: tool.summary,
                executablePath: executablePath,
                argumentPattern: tool.argumentPattern,
                capability: tool.capability,
                category: tool.category,
                timeoutSeconds: tool.timeoutSeconds,
                outputLimitKB: max(1, tool.outputByteLimit / 1024),
                mode: tool.isGenericCLIAdapter ? .cliAdapter : .commandTemplate,
                permissionRequirements: tool.permissionRequirements
            )
        }
    }

    private static var popularCLIPresets: [DefaultToolPreset] {
        peekabooPresets +
            spogoPresets +
            summarizePresets +
            gogPresets +
            llmPresets +
            githubPresets +
            textDataPresets +
            mediaPresets +
            networkPresets +
            runtimePresets +
            agentSessionPresets +
            personalWorkflowPresets +
            genericSystemCLIPresets
    }

    private struct GenericCLIAdapterDescriptor {
        let executableName: String
        let presetID: String
        let name: String
        let summary: String
        let category: ToolCategory
        let capability: ToolCapability
        let timeoutSeconds: Double
        let outputLimitKB: Int
        let permissionRequirements: [ToolPermissionRequirement]

        init(
            executableName: String,
            presetID: String,
            name: String,
            summary: String,
            category: ToolCategory,
            capability: ToolCapability = .destructive,
            timeoutSeconds: Double = 60,
            outputLimitKB: Int = 2048,
            permissionRequirements: [ToolPermissionRequirement] = []
        ) {
            self.executableName = executableName
            self.presetID = presetID
            self.name = name
            self.summary = summary
            self.category = category
            self.capability = capability
            self.timeoutSeconds = timeoutSeconds
            self.outputLimitKB = outputLimitKB
            self.permissionRequirements = permissionRequirements
        }
    }

    private static var genericSystemCLIPresets: [DefaultToolPreset] {
        let existingPresetIDs = Set(
            (peekabooPresets +
                spogoPresets +
                summarizePresets +
                gogPresets +
                llmPresets +
                githubPresets +
                textDataPresets +
                mediaPresets +
                networkPresets +
                runtimePresets +
                agentSessionPresets +
                personalWorkflowPresets)
                .map(\.id)
        )

        return genericCLIAdapterDescriptors.compactMap { descriptor in
            guard !existingPresetIDs.contains(descriptor.presetID),
                  let executablePath = ExecutableLocator.executablePath(named: descriptor.executableName) else {
                return nil
            }
            return directAdapter(
                id: descriptor.presetID,
                name: descriptor.name,
                summary: descriptor.summary,
                executablePath: executablePath,
                category: descriptor.category,
                capability: descriptor.capability,
                timeoutSeconds: descriptor.timeoutSeconds,
                outputLimitKB: descriptor.outputLimitKB,
                permissionRequirements: descriptor.permissionRequirements
            )
        }
    }

    private static let claudeCodeSummary = "Run Claude Code by passing argv directly. For remote MCP use, prefer non-interactive invocations such as `--print`, `--output-format json` or `--output-format stream-json`, explicit `--model`, `--permission-mode`, `--add-dir`, `--mcp-config`, and `--strict-mcp-config`; avoid bare interactive sessions and login flows unless the host Mac is attended."

    private static let genericCLIAdapterDescriptors: [GenericCLIAdapterDescriptor] = [
        GenericCLIAdapterDescriptor(
            executableName: "claude",
            presetID: "preset.claude.run",
            name: "Claude Code",
            summary: claudeCodeSummary,
            category: .developer,
            timeoutSeconds: 60,
            outputLimitKB: 5120
        ),
        GenericCLIAdapterDescriptor(
            executableName: "grok",
            presetID: "preset.grok.run",
            name: "Grok CLI",
            summary: "Run Grok by passing argv directly for local agent workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "swift",
            presetID: "preset.swift.run",
            name: "Swift CLI",
            summary: "Run Swift by passing argv directly for package, build, and script workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "xcodebuild",
            presetID: "preset.xcodebuild.run",
            name: "Xcodebuild CLI",
            summary: "Run xcodebuild by passing argv directly for Apple platform build workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "node",
            presetID: "preset.node.run",
            name: "Node CLI",
            summary: "Run Node.js by passing argv directly for JavaScript workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "npm",
            presetID: "preset.npm.run",
            name: "NPM CLI",
            summary: "Run npm by passing argv directly for package and script workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "pnpm",
            presetID: "preset.pnpm.run",
            name: "PNPM CLI",
            summary: "Run pnpm by passing argv directly for package and script workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "python3",
            presetID: "preset.python3.run",
            name: "Python 3 CLI",
            summary: "Run Python 3 by passing argv directly for scripts and module workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "ruby",
            presetID: "preset.ruby.run",
            name: "Ruby CLI",
            summary: "Run Ruby by passing argv directly for scripts and developer workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "perl",
            presetID: "preset.perl.run",
            name: "Perl CLI",
            summary: "Run Perl by passing argv directly for scripts and text workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "curl",
            presetID: "preset.curl.run",
            name: "Curl CLI",
            summary: "Run curl by passing argv directly for HTTP workflows. Requests that send data require host approval.",
            category: .utilities,
            capability: .destructive,
            timeoutSeconds: 45,
            permissionRequirements: [.localNetwork]
        ),
        GenericCLIAdapterDescriptor(
            executableName: "rsync",
            presetID: "preset.rsync.run",
            name: "Rsync CLI",
            summary: "Run rsync by passing argv directly for file transfer workflows.",
            category: .filesystem
        ),
        GenericCLIAdapterDescriptor(
            executableName: "sqlite3",
            presetID: "preset.sqlite3.run",
            name: "SQLite CLI",
            summary: "Run sqlite3 by passing argv directly for database inspection and mutation workflows.",
            category: .developer
        ),
        GenericCLIAdapterDescriptor(
            executableName: "shortcuts",
            presetID: "preset.shortcuts.run",
            name: "Shortcuts CLI",
            summary: "Run Shortcuts by passing argv directly. Running shortcuts may trigger app, Automation, and data-access prompts.",
            category: .utilities,
            permissionRequirements: [.automation]
        ),
        GenericCLIAdapterDescriptor(
            executableName: "osascript",
            presetID: "preset.osascript.run",
            name: "AppleScript CLI",
            summary: "Run osascript by passing argv directly for AppleScript and JavaScript for Automation workflows.",
            category: .utilities,
            permissionRequirements: [.automation, .accessibility]
        ),
        GenericCLIAdapterDescriptor(
            executableName: "automator",
            presetID: "preset.automator.run",
            name: "Automator CLI",
            summary: "Run Automator by passing argv directly for local automation workflows.",
            category: .utilities,
            permissionRequirements: [.automation, .accessibility]
        ),
        GenericCLIAdapterDescriptor(
            executableName: "screencapture",
            presetID: "preset.screencapture.run",
            name: "Screen Capture CLI",
            summary: "Run screencapture by passing argv directly for screenshot workflows.",
            category: .imageProcessing,
            permissionRequirements: [.screenRecording]
        ),
        GenericCLIAdapterDescriptor(
            executableName: "mdfind",
            presetID: "preset.mdfind.run",
            name: "Spotlight Search CLI",
            summary: "Run mdfind by passing argv directly for Spotlight metadata search.",
            category: .filesystem,
            capability: .readOnly,
            timeoutSeconds: 20
        ),
        GenericCLIAdapterDescriptor(
            executableName: "mdls",
            presetID: "preset.mdls.run",
            name: "Metadata CLI",
            summary: "Run mdls by passing argv directly for Spotlight metadata inspection.",
            category: .filesystem,
            capability: .readOnly,
            timeoutSeconds: 20
        ),
        GenericCLIAdapterDescriptor(
            executableName: "qlmanage",
            presetID: "preset.qlmanage.run",
            name: "Quick Look CLI",
            summary: "Run qlmanage by passing argv directly for Quick Look inspection and thumbnail workflows.",
            category: .filesystem,
            timeoutSeconds: 30
        ),
        GenericCLIAdapterDescriptor(
            executableName: "textutil",
            presetID: "preset.textutil.run",
            name: "Textutil CLI",
            summary: "Run textutil by passing argv directly for document conversion and inspection workflows.",
            category: .text,
            timeoutSeconds: 30
        )
    ]

    private static var peekabooPresets: [DefaultToolPreset] {
        guard let executablePath = ExecutableLocator.executablePath(named: "peekaboo") else { return [] }
        return [
            DefaultToolPreset(
                id: "preset.peekaboo.permissions",
                name: "Peekaboo Permissions",
                summary: "Return Peekaboo permission status as JSON.",
                executablePath: executablePath,
                argumentPattern: ["permissions", "status", "--json"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 10,
                outputLimitKB: 512
            ),
            DefaultToolPreset(
                id: "preset.peekaboo.apps",
                name: "Peekaboo Apps",
                summary: "List running applications visible to Peekaboo as JSON.",
                executablePath: executablePath,
                argumentPattern: ["list", "apps", "--json"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            ),
            directAdapter(
                id: "preset.peekaboo.run",
                name: "Peekaboo CLI",
                summary: "Run Peekaboo by passing argv directly. Use absolute paths; no shell expansion is performed.",
                executablePath: executablePath,
                category: .utilities,
                timeoutSeconds: 60,
                permissionRequirements: [.screenRecording, .accessibility]
            )
        ]
    }

    private static var spogoPresets: [DefaultToolPreset] {
        guard let executablePath = ExecutableLocator.executablePath(named: "spogo") else { return [] }
        return [
            DefaultToolPreset(
                id: "preset.spogo.status",
                name: "Spogo Status",
                summary: "Return current Spotify playback status as JSON.",
                executablePath: executablePath,
                argumentPattern: ["status", "--json", "--no-input"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            ),
            DefaultToolPreset(
                id: "preset.spogo.search_track",
                name: "Spogo Search Track",
                summary: "Search Spotify tracks and return JSON results.",
                executablePath: executablePath,
                argumentPattern: ["search", "track", "{query}", "--json", "--no-input"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 15,
                outputLimitKB: 1024
            ),
            directAdapter(
                id: "preset.spogo.run",
                name: "Spogo CLI",
                summary: "Run Spogo by passing argv directly. Playback and library changes require host approval.",
                executablePath: executablePath,
                category: .utilities,
                timeoutSeconds: 30,
                permissionRequirements: [.automation]
            )
        ]
    }

    private static var summarizePresets: [DefaultToolPreset] {
        guard let executablePath = ExecutableLocator.executablePath(named: "summarize") else { return [] }
        return [
            DefaultToolPreset(
                id: "preset.summarize.input",
                name: "Summarize Input",
                summary: "Summarize a URL or local file path.",
                executablePath: executablePath,
                argumentPattern: ["{input}", "--format", "md"],
                capability: .readOnly,
                category: .text,
                timeoutSeconds: 60,
                outputLimitKB: 2048
            ),
            directAdapter(
                id: "preset.summarize.run",
                name: "Summarize CLI",
                summary: "Run Summarize by passing argv directly for advanced extraction and transcript workflows.",
                executablePath: executablePath,
                category: .text,
                timeoutSeconds: 60
            )
        ]
    }

    private static var gogPresets: [DefaultToolPreset] {
        guard let executablePath = ExecutableLocator.executablePath(named: "gog") else { return [] }
        return [
            directAdapter(
                id: "preset.gog.run",
                name: "Gog CLI",
                summary: "Run Gog by passing argv directly. Prefer --json, --dry-run, --no-input, and --gmail-no-send when applicable.",
                executablePath: executablePath,
                category: .utilities,
                timeoutSeconds: 45
            )
        ]
    }

    private static var llmPresets: [DefaultToolPreset] {
        guard let executablePath = ExecutableLocator.executablePath(named: "llm") else { return [] }
        return [
            DefaultToolPreset(
                id: "preset.llm.prompt",
                name: "LLM Prompt",
                summary: "Run Simon Willison's llm CLI with a prompt.",
                executablePath: executablePath,
                argumentPattern: ["prompt", "{prompt}"],
                capability: .write,
                category: .developer,
                timeoutSeconds: 60,
                outputLimitKB: 2048
            ),
            directAdapter(
                id: "preset.llm.run",
                name: "LLM CLI",
                summary: "Run llm by passing argv directly for model, embedding, plugin, and log workflows.",
                executablePath: executablePath,
                category: .developer,
                timeoutSeconds: 60
            )
        ]
    }

    private static var githubPresets: [DefaultToolPreset] {
        guard let executablePath = ExecutableLocator.executablePath(named: "gh") else { return [] }
        return [
            DefaultToolPreset(
                id: "preset.gh.repo_view",
                name: "GitHub Repo View",
                summary: "Return selected GitHub repository metadata as JSON.",
                executablePath: executablePath,
                argumentPattern: ["repo", "view", "{repository}", "--json", "nameWithOwner,description,url,isPrivate,defaultBranchRef"],
                capability: .readOnly,
                category: .developer,
                timeoutSeconds: 15,
                outputLimitKB: 1024
            ),
            directAdapter(
                id: "preset.gh.run",
                name: "GitHub CLI",
                summary: "Run GitHub CLI by passing argv directly. Repository mutations require host approval.",
                executablePath: executablePath,
                category: .developer,
                timeoutSeconds: 45
            )
        ]
    }

    private static var textDataPresets: [DefaultToolPreset] {
        var presets: [DefaultToolPreset] = []

        if let jq = ExecutableLocator.executablePath(named: "jq") {
            presets.append(DefaultToolPreset(
                id: "preset.jq.file",
                name: "JQ File",
                summary: "Apply a jq filter to a JSON file.",
                executablePath: jq,
                argumentPattern: ["{filter}", "{path}"],
                capability: .readOnly,
                category: .text,
                timeoutSeconds: 10,
                outputLimitKB: 2048
            ))
            presets.append(directAdapter(
                id: "preset.jq.run",
                name: "JQ CLI",
                summary: "Run jq by passing argv directly.",
                executablePath: jq,
                category: .text,
                capability: .readOnly,
                timeoutSeconds: 15
            ))
        }

        if let rg = ExecutableLocator.executablePath(named: "rg") {
            presets.append(DefaultToolPreset(
                id: "preset.rg.search",
                name: "Ripgrep Search",
                summary: "Search files with ripgrep using smart case and line numbers.",
                executablePath: rg,
                argumentPattern: ["--line-number", "--smart-case", "{pattern}", "{path}"],
                capability: .readOnly,
                category: .text,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ))
            presets.append(directAdapter(
                id: "preset.rg.run",
                name: "Ripgrep CLI",
                summary: "Run ripgrep by passing argv directly.",
                executablePath: rg,
                category: .text,
                capability: .readOnly,
                timeoutSeconds: 20
            ))
        }

        return presets
    }

    private static var mediaPresets: [DefaultToolPreset] {
        var presets: [DefaultToolPreset] = []

        if let ytDLP = ExecutableLocator.executablePath(named: "yt-dlp") {
            presets.append(DefaultToolPreset(
                id: "preset.ytdlp.metadata",
                name: "YT-DLP Metadata",
                summary: "Return video metadata without downloading media.",
                executablePath: ytDLP,
                argumentPattern: ["--dump-json", "--skip-download", "{url}"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 30,
                outputLimitKB: 2048
            ))
            presets.append(directAdapter(
                id: "preset.ytdlp.run",
                name: "YT-DLP CLI",
                summary: "Run yt-dlp by passing argv directly. Downloads require host approval.",
                executablePath: ytDLP,
                category: .utilities,
                timeoutSeconds: 60
            ))
        }

        if let ffprobe = ExecutableLocator.executablePath(named: "ffprobe") {
            presets.append(DefaultToolPreset(
                id: "preset.ffprobe.info",
                name: "FFprobe Media Info",
                summary: "Return media stream and format metadata as JSON.",
                executablePath: ffprobe,
                argumentPattern: ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", "{path}"],
                capability: .readOnly,
                category: .imageProcessing,
                timeoutSeconds: 20,
                outputLimitKB: 2048
            ))
        }

        if let ffmpeg = ExecutableLocator.executablePath(named: "ffmpeg") {
            presets.append(directAdapter(
                id: "preset.ffmpeg.run",
                name: "FFmpeg CLI",
                summary: "Run FFmpeg by passing argv directly. Media conversion writes require host approval.",
                executablePath: ffmpeg,
                category: .imageProcessing,
                timeoutSeconds: 60
            ))
        }

        return presets
    }

    private static var networkPresets: [DefaultToolPreset] {
        var presets: [DefaultToolPreset] = []

        if let cloudflared = ExecutableLocator.executablePath(named: "cloudflared") {
            presets.append(DefaultToolPreset(
                id: "preset.cloudflared.version",
                name: "Cloudflared Version",
                summary: "Return the installed cloudflared version.",
                executablePath: cloudflared,
                argumentPattern: ["version"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 5,
                outputLimitKB: 64
            ))
            presets.append(directAdapter(
                id: "preset.cloudflared.run",
                name: "Cloudflared CLI",
                summary: "Run cloudflared by passing argv directly for tunnel and network workflows.",
                executablePath: cloudflared,
                category: .utilities,
                timeoutSeconds: 60
            ))
        }

        if let tailscale = ExecutableLocator.executablePath(named: "tailscale") {
            presets.append(DefaultToolPreset(
                id: "preset.tailscale.status",
                name: "Tailscale Status",
                summary: "Return Tailscale status as JSON.",
                executablePath: tailscale,
                argumentPattern: ["status", "--json"],
                capability: .readOnly,
                category: .utilities,
                timeoutSeconds: 10,
                outputLimitKB: 2048
            ))
            presets.append(directAdapter(
                id: "preset.tailscale.run",
                name: "Tailscale CLI",
                summary: "Run Tailscale by passing argv directly. Network state changes require host approval.",
                executablePath: tailscale,
                category: .utilities,
                timeoutSeconds: 30
            ))
        }

        return presets
    }

    private static var runtimePresets: [DefaultToolPreset] {
        var presets: [DefaultToolPreset] = []

        if let uv = ExecutableLocator.executablePath(named: "uv") {
            presets.append(directAdapter(
                id: "preset.uv.run",
                name: "UV CLI",
                summary: "Run uv by passing argv directly for Python package and project workflows.",
                executablePath: uv,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        if let uvx = ExecutableLocator.executablePath(named: "uvx") {
            presets.append(directAdapter(
                id: "preset.uvx.run",
                name: "UVX CLI",
                summary: "Run uvx by passing argv directly for Python tool execution.",
                executablePath: uvx,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        if let deno = ExecutableLocator.executablePath(named: "deno") {
            presets.append(DefaultToolPreset(
                id: "preset.deno.task_list",
                name: "Deno Task List",
                summary: "List Deno tasks for a project directory.",
                executablePath: deno,
                argumentPattern: ["task", "--cwd", "{path}"],
                capability: .readOnly,
                category: .developer,
                timeoutSeconds: 10,
                outputLimitKB: 1024
            ))
            presets.append(directAdapter(
                id: "preset.deno.run",
                name: "Deno CLI",
                summary: "Run Deno by passing argv directly for JavaScript and TypeScript workflows.",
                executablePath: deno,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        if let supabase = ExecutableLocator.executablePath(named: "supabase") {
            presets.append(directAdapter(
                id: "preset.supabase.run",
                name: "Supabase CLI",
                summary: "Run Supabase CLI by passing argv directly for local and hosted project workflows.",
                executablePath: supabase,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        if let xcodegen = ExecutableLocator.executablePath(named: "xcodegen") {
            presets.append(directAdapter(
                id: "preset.xcodegen.run",
                name: "XcodeGen CLI",
                summary: "Run XcodeGen by passing argv directly. Project generation writes require host approval.",
                executablePath: xcodegen,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        return presets
    }

    private static var agentSessionPresets: [DefaultToolPreset] {
        var presets: [DefaultToolPreset] = []

        if let grokSession = ExecutableLocator.executablePath(named: "grok-session") {
            presets.append(directAdapter(
                id: "preset.grok_session.run",
                name: "Grok Session CLI",
                summary: "Run grok-session by passing argv directly for local agent-session workflows.",
                executablePath: grokSession,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        if let cora = ExecutableLocator.executablePath(named: "cora") {
            presets.append(directAdapter(
                id: "preset.cora.run",
                name: "Cora CLI",
                summary: "Run Cora by passing argv directly.",
                executablePath: cora,
                category: .developer,
                timeoutSeconds: 60
            ))
        }

        if let monologue = ExecutableLocator.executablePath(named: "monologue") {
            presets.append(directAdapter(
                id: "preset.monologue.run",
                name: "Monologue CLI",
                summary: "Run Monologue by passing argv directly.",
                executablePath: monologue,
                category: .text,
                timeoutSeconds: 60
            ))
        }

        return presets
    }

    private static var personalWorkflowPresets: [DefaultToolPreset] {
        var presets: [DefaultToolPreset] = []

        if let matter = ExecutableLocator.executablePath(named: "matter") {
            presets.append(directAdapter(
                id: "preset.matter.run",
                name: "Matter CLI",
                summary: "Run Matter by passing argv directly for read-later workflows.",
                executablePath: matter,
                category: .text,
                timeoutSeconds: 60
            ))
        }

        if let spark = ExecutableLocator.executablePath(named: "spark") {
            presets.append(directAdapter(
                id: "preset.spark.run",
                name: "Spark CLI",
                summary: "Run Spark by passing argv directly for email workflows.",
                executablePath: spark,
                category: .utilities,
                timeoutSeconds: 60
            ))
        }

        if let frames = ExecutableLocator.executablePath(named: "frames") {
            presets.append(directAdapter(
                id: "preset.frames.run",
                name: "Frames CLI",
                summary: "Run Frames by passing argv directly for screenshot and media framing workflows.",
                executablePath: frames,
                category: .imageProcessing,
                timeoutSeconds: 60
            ))
        }

        return presets
    }

    private static func directAdapter(
        id: String,
        name: String,
        summary: String,
        executablePath: String,
        category: ToolCategory,
        capability: ToolCapability = .destructive,
        timeoutSeconds: Double,
        outputLimitKB: Int = 2048,
        permissionRequirements: [ToolPermissionRequirement] = []
    ) -> DefaultToolPreset {
        DefaultToolPreset(
            id: id,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: ["{args}"],
            capability: capability,
            category: category,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            mode: .cliAdapter,
            permissionRequirements: permissionRequirements
        )
    }
}
