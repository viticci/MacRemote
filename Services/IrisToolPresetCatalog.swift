import Foundation

enum IrisToolPresetCatalog {
    static var detectedExecutablePath: String? {
        ExecutableLocator.executablePath(named: "iris")
            ?? ExecutableLocator.executablePath(named: "iphone")
    }

    static var presets: [DefaultToolPreset] {
        presets(executablePath: detectedExecutablePath)
    }

    static func presets(executablePath: String?) -> [DefaultToolPreset] {
        guard let executablePath else { return [] }
        let openWorld = ToolAnnotationOverrides(openWorldHint: true)
        let localManifest = ToolAnnotationOverrides(openWorldHint: false)

        return [
            preset(
                id: "battery",
                name: "iPhone Battery",
                summary: "Read the approved iPhone's battery percentage and charging state over Iris.",
                executablePath: executablePath,
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("device"), .literal("battery"), .literal("get"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld
            ),
            preset(
                id: "now_playing",
                name: "iPhone Now Playing",
                summary: "Read the track playing on the approved iPhone, with playback position.",
                executablePath: executablePath,
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("music"), .literal("now-playing"), .literal("get"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld
            ),
            preset(
                id: "calendar_day",
                name: "iPhone Calendar Day",
                summary: "List the approved iPhone's calendar events for today or tomorrow.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "day",
                        title: "Day",
                        description: "Which day to list.",
                        kind: .string,
                        allowedValues: ["today", "tomorrow"]
                    ),
                    ToolParameter(
                        name: "limit",
                        title: "Limit",
                        description: "Maximum events to return.",
                        kind: .integer,
                        required: false,
                        integerRange: 1...100
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("calendar"),
                    .choice("day", [
                        "today": ["today"],
                        "tomorrow": ["tomorrow"]
                    ]),
                    .option("--limit", "limit"),
                    .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld
            ),
            preset(
                id: "alarms",
                name: "iPhone Alarms",
                summary: "List the alarms configured on the approved iPhone.",
                executablePath: executablePath,
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("alarm"), .literal("list"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld
            ),
            preset(
                id: "alarm_set",
                name: "Set iPhone Alarm",
                summary: "Create an alarm on the approved iPhone at an exact time, with an optional label.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "time",
                        title: "Time",
                        description: "Alarm time, such as 07:30.",
                        kind: .string
                    ),
                    ToolParameter(
                        name: "label",
                        title: "Label",
                        description: "Optional alarm label.",
                        kind: .string,
                        required: false
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("alarm"), .literal("set"), .value("time"),
                        .option("--label", "label"), .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run", "--offline"]
                ),
                capability: .write,
                annotations: openWorld
            ),
            preset(
                id: "timer_start",
                name: "Start iPhone Timer",
                summary: "Start a timer on the approved iPhone for an exact duration such as 10m.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "duration",
                        title: "Duration",
                        description: "Duration such as 10m, 90s, or 1h.",
                        kind: .string
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("timer"), .literal("start"), .value("duration"), .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run", "--offline"]
                ),
                capability: .write,
                annotations: openWorld
            ),
            preset(
                id: "open_url",
                name: "Open URL on iPhone",
                summary: "Open an exact http or https URL on the approved iPhone. Dispatch only: a completed result proves the phone opened it, not what the user did next.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "url",
                        title: "URL",
                        description: "Exact http or https URL.",
                        kind: .string
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("url"), .literal("open"), .value("url"), .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run", "--offline"]
                ),
                capability: .write,
                annotations: openWorld
            ),
            preset(
                id: "message_compose",
                name: "Compose iPhone Message",
                summary: "Open an unsent Messages draft on the approved iPhone with an exact recipient and body. Never sends.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "to",
                        title: "To",
                        description: "Recipient contact name or phone number.",
                        kind: .string
                    ),
                    ToolParameter(
                        name: "body",
                        title: "Body",
                        description: "Message body for the unsent draft.",
                        kind: .string
                    )
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("messages"), .literal("compose"),
                        .option("--to", "to"), .option("--body", "body"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run", "--offline"]
                ),
                capability: .write,
                annotations: openWorld
            ),
            preset(
                id: "actions",
                name: "List Iris Actions",
                summary: "List the public Iris actions the approved iPhone supports, optionally filtered by application family.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "application",
                        title: "Application",
                        description: "Application family filter, such as reminders.",
                        kind: .string,
                        required: false
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("actions"), .literal("list"),
                    .option("--application", "application"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: localManifest
            ),
            preset(
                id: "action_schema",
                name: "Iris Action Schema",
                summary: "Read the full manifest schema for one Iris action ID before running it through the Iris Flexible Command.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "action_id",
                        title: "Action ID",
                        description: "Iris action ID, such as device.battery.get.",
                        kind: .string
                    )
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("actions"), .literal("schema"), .value("action_id"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: localManifest
            ),
            preset(
                id: "doctor",
                name: "Iris Health Check",
                summary: "Run Iris's live doctor check of the app, runtime, sockets, transport, and pairing. A failing check exits nonzero.",
                executablePath: executablePath,
                parameters: [],
                invocation: ProcessInvocation(arguments: [
                    .literal("doctor"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld
            ),
            preset(
                id: "run",
                name: "Iris Flexible Command",
                summary: "Run any Iris CLI command with an exact argv array (no shell). Iris controls the approved iPhone; sensitive reads such as screen read and clipboard get, and every --confirm action, run only with per-call approval. Pairing, device authorization, and transport management stay blocked.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "args",
                        title: "Arguments",
                        description: "Exact Iris argv items. No shell syntax or expansion is available.",
                        kind: .stringArray,
                        required: false
                    )
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
        annotations: ToolAnnotationOverrides?
    ) -> DefaultToolPreset {
        DefaultToolPreset(
            id: "preset.iris.\(id)",
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            capability: capability,
            category: .iphone,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            mode: mode,
            permissionRequirements: [],
            parameters: parameters,
            processInvocation: invocation,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotations
        )
    }
}
