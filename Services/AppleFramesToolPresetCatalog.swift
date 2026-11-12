import Foundation

enum AppleFramesToolPresetCatalog {
    static var detectedExecutablePath: String? {
        ExecutableLocator.executablePath(named: "frames")
    }

    static var presets: [DefaultToolPreset] {
        presets(executablePath: detectedExecutablePath)
    }

    static func presets(executablePath: String?) -> [DefaultToolPreset] {
        guard let executablePath else { return [] }
        let local = ToolAnnotationOverrides(openWorldHint: false)

        return [
            preset(
                id: "devices",
                name: "List Supported Apple Frames",
                summary: "List every Apple device frame supported by the installed Apple Frames assets.",
                executablePath: executablePath,
                parameters: [],
                invocation: ProcessInvocation(arguments: [.literal("list")]),
                capability: .readOnly,
                annotations: local
            ),
            preset(
                id: "info",
                name: "Inspect Screenshot Matches",
                summary: "Inspect screenshots or folders and return matched devices, frame variants, colors, masks, and resizing as JSON.",
                executablePath: executablePath,
                parameters: [paths("paths", "Screenshots or Folders", "Absolute screenshot files or folders to inspect.")],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("info"), .value("paths")
                ]),
                capability: .readOnly,
                timeoutSeconds: 60,
                outputLimitKB: 4096,
                annotations: local
            ),
            preset(
                id: "frame_image",
                name: "Frame Screenshots",
                summary: "Render one or more screenshots with matched Apple device frames. Existing deterministic output files may be overwritten, so this tool asks for every call.",
                executablePath: executablePath,
                parameters: [
                    paths("paths", "Screenshots", "Absolute screenshot files to frame."),
                    absolutePath("output_directory", "Output Directory", "Absolute destination directory."),
                    optionalString("device", "Device", "Optional forced Apple Frames device name."),
                    optionalString("color", "Color", "Optional frame color name, index, or random."),
                    ToolParameter(
                        name: "layout",
                        title: "Layout",
                        description: "Write individual framed images or one side-by-side merged image.",
                        kind: .string,
                        required: false,
                        defaultValue: "individual",
                        allowedValues: ["individual", "merged"]
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("frame"),
                    .option("--output", "output_directory"),
                    .option("--device", "device"),
                    .option("--color", "color"),
                    .choice("layout", ["individual": [], "merged": ["--merge"]]),
                    .value("paths")
                ]),
                capability: .destructive,
                timeoutSeconds: 180,
                approvalPolicy: .everyCall,
                annotations: local
            ),
            preset(
                id: "video_info",
                name: "Inspect Video Matches",
                summary: "Inspect videos or folders and return dimensions, duration, codec, audio, matched device, mask, resize, padding, and rotation as JSON.",
                executablePath: executablePath,
                parameters: [
                    paths("paths", "Videos or Folders", "Absolute video files or folders to inspect."),
                    optionalString("device", "Device", "Optional forced Apple Frames device name."),
                    optionalString("color", "Color", "Optional frame color name, index, or random."),
                    rotation
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("video-info"),
                    .option("--device", "device"),
                    .option("--color", "color"),
                    .option("--rotate", "rotation"),
                    .value("paths")
                ]),
                capability: .readOnly,
                timeoutSeconds: 120,
                outputLimitKB: 4096,
                annotations: local
            ),
            preset(
                id: "frame_video",
                name: "Frame Videos",
                summary: "Render one or more videos with matched Apple device frames. Existing output may be overwritten, so this tool asks for every call.",
                executablePath: executablePath,
                parameters: [
                    paths("paths", "Videos", "Absolute video files to frame."),
                    absolutePath("output", "Output", "Absolute output directory or single output file."),
                    ToolParameter(
                        name: "preset",
                        title: "Export Preset",
                        description: "Apple Frames video export preset.",
                        kind: .string,
                        required: false,
                        defaultValue: "best",
                        allowedValues: ["compact", "balanced", "best"]
                    ),
                    optionalString("device", "Device", "Optional forced Apple Frames device name."),
                    optionalString("color", "Color", "Optional frame color name, index, or random."),
                    rotation,
                    ToolParameter(
                        name: "layout",
                        title: "Layout",
                        description: "Write individual videos, merge simultaneous playback, or merge sequential playback.",
                        kind: .string,
                        required: false,
                        defaultValue: "individual",
                        allowedValues: ["individual", "simultaneous", "sequential"]
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("--json"), .literal("video"),
                    .option("--output", "output"),
                    .option("--preset", "preset"),
                    .option("--device", "device"),
                    .option("--color", "color"),
                    .option("--rotate", "rotation"),
                    .choice("layout", [
                        "individual": [],
                        "simultaneous": ["--merge"],
                        "sequential": ["--merge", "--playback-offset"]
                    ]),
                    .value("paths")
                ]),
                capability: .destructive,
                timeoutSeconds: 600,
                outputLimitKB: 4096,
                approvalPolicy: .everyCall,
                annotations: local
            ),
            preset(
                id: "run",
                name: "Apple Frames Flexible Command",
                summary: "Advanced fallback; prefer the dedicated Apple Frames tools. Pass exact argv items with no shell for asset setup, interactive color defaults, clipboard output, batching, codec tuning, alpha, backgrounds, and uncommon layouts. This tool asks for every call.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "args", title: "Arguments", description: "Exact Apple Frames argv items. No shell syntax or expansion is available.", kind: .stringArray, required: false)
                ],
                argumentPattern: ["{args}"],
                capability: .destructive,
                timeoutSeconds: 600,
                outputLimitKB: 8192,
                mode: .cliAdapter,
                approvalPolicy: .everyCall,
                annotations: local
            )
        ]
    }

    private static let rotation = ToolParameter(
        name: "rotation",
        title: "Rotation",
        description: "Rotate before device detection.",
        kind: .string,
        required: false,
        defaultValue: "none",
        allowedValues: ["none", "clockwise", "counterclockwise", "180"]
    )

    private static func paths(
        _ name: String,
        _ title: String,
        _ description: String
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .stringArray,
            maximumLength: 4096,
            stringFormat: "absolute-path"
        )
    }

    private static func absolutePath(
        _ name: String,
        _ title: String,
        _ description: String
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .string,
            maximumLength: 4096,
            stringFormat: "absolute-path"
        )
    }

    private static func optionalString(
        _ name: String,
        _ title: String,
        _ description: String
    ) -> ToolParameter {
        ToolParameter(
            name: name,
            title: title,
            description: description,
            kind: .string,
            required: false,
            maximumLength: 256
        )
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
        outputLimitKB: Int = 2048,
        mode: ToolAdapterMode = .commandTemplate,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotations: ToolAnnotationOverrides?
    ) -> DefaultToolPreset {
        DefaultToolPreset(
            id: "preset.frames.\(id)",
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            capability: capability,
            category: .imageProcessing,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            mode: mode,
            parameters: parameters,
            processInvocation: invocation,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotations
        )
    }
}
