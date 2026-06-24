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
    let requiresFullDiskAccess: Bool

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
            requiresFullDiskAccess: requiresFullDiskAccess
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
        requiresFullDiskAccess: Bool = false
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
        self.requiresFullDiskAccess = requiresFullDiskAccess
    }
}

enum DefaultToolPresetCatalog {
    static var categories: [ToolCategory] {
        ToolCategory.allCases.filter { category in
            !presets(in: category).isEmpty
        }
    }

    static var presets: [DefaultToolPreset] {
        basePresets + pocketCTLPresets
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

    static var pocketCTLExecutablePath: String? {
        [
            "\(NSHomeDirectory())/.local/bin/pocketctl",
            "/opt/homebrew/bin/pocketctl",
            "/usr/local/bin/pocketctl"
        ].first { path in
            FileManager.default.isExecutableFile(atPath: path)
        }
    }

    private static var pocketCTLPresets: [DefaultToolPreset] {
        guard let executablePath = pocketCTLExecutablePath else { return [] }

        return [
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
                id: "preset.pocketctl.run",
                name: "Run PocketCTL",
                summary: "Run PocketCTL by passing argv directly. Write-capable calls require per-call host approval.",
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
}
