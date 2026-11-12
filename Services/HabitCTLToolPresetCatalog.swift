import Foundation

enum HabitCTLToolPresetCatalog {
    static var presets: [DefaultToolPreset] {
        presets(executablePath: ExecutableLocator.executablePath(named: "habitctl"))
    }

    static func presets(executablePath: String?) -> [DefaultToolPreset] {
        guard let executablePath else {
            return []
        }

        let openWorld = ToolAnnotationOverrides(openWorldHint: true)
        let habit = ToolParameter(
            name: "habit",
            title: "Habit",
            description: "Exact Habitify habit id or an unambiguous name.",
            kind: .string,
            maximumLength: 256
        )
        let date = ToolParameter(
            name: "date",
            title: "Date",
            description: "Habitify journal date accepted by HabitCTL.",
            kind: .string,
            required: false,
            defaultValue: "today",
            maximumLength: 64
        )

        return [
            preset(
                id: "today",
                name: "Get Today’s Habits",
                summary: "Return the Habitify journal for one date as JSON.",
                executablePath: executablePath,
                parameters: [date],
                invocation: ProcessInvocation(arguments: [
                    .literal("today"), .option("--date", "date"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld,
                uiActions: habitRowUIActions
            ),
            preset(
                id: "search",
                name: "Find Habits",
                summary: "Search Habitify habits and return bounded JSON matches.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(name: "query", title: "Query", description: "Habit name text to find.", kind: .string, maximumLength: 512),
                    ToolParameter(name: "limit", title: "Limit", description: "Maximum matches.", kind: .integer, required: false, defaultValue: "50", integerRange: 1...250)
                ],
                invocation: ProcessInvocation(arguments: [
                    .literal("search"), .value("query"),
                    .option("--limit", "limit"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld,
                uiActions: habitRowUIActions
            ),
            preset(
                id: "show",
                name: "Get Habit",
                summary: "Return one Habitify habit by exact id or unambiguous name.",
                executablePath: executablePath,
                parameters: [habit],
                invocation: ProcessInvocation(arguments: [
                    .literal("show"), .value("habit"), .literal("--json")
                ]),
                capability: .readOnly,
                annotations: openWorld,
                uiActions: habitRowUIActions
            ),
            preset(
                id: "record_result",
                name: "Record Habit Result",
                summary: "Set a Habitify journal result. MacRemote runs HabitCTL’s dry-run first, then applies only after a successful preflight.",
                executablePath: executablePath,
                parameters: [
                    habit,
                    ToolParameter(
                        name: "result",
                        title: "Result",
                        description: "Desired journal state.",
                        kind: .string,
                        allowedValues: ["completed", "failed", "skipped", "in_progress"]
                    ),
                    date
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .choice("result", [
                            "completed": ["check"],
                            "failed": ["fail"],
                            "skipped": ["skip"],
                            "in_progress": ["undo"]
                        ]),
                        .value("habit"),
                        .option("--date", "date"),
                        .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                annotations: ToolAnnotationOverrides(idempotentHint: true, openWorldHint: true)
            ),
            preset(
                id: "log_value",
                name: "Log Habit Value",
                summary: "Log one finite numeric Habitify value and exact unit. MacRemote runs HabitCTL’s dry-run before applying it.",
                executablePath: executablePath,
                parameters: [
                    habit,
                    ToolParameter(
                        name: "value",
                        title: "Value",
                        description: "Finite numeric value to log.",
                        kind: .number,
                        numberRange: -1_000_000_000...1_000_000_000
                    ),
                    ToolParameter(
                        name: "unit",
                        title: "Unit",
                        description: "Exact unit configured for this habit.",
                        kind: .string,
                        maximumLength: 128
                    ),
                    date
                ],
                invocation: ProcessInvocation(
                    arguments: [
                        .literal("log"), .value("habit"), .value("value"), .value("unit"),
                        .option("--date", "date"), .literal("--json")
                    ],
                    preflightSuffix: ["--dry-run"]
                ),
                capability: .write,
                annotations: openWorld
            ),
            preset(
                id: "run",
                name: "HabitCTL Flexible Command",
                summary: "Advanced fallback; prefer the dedicated HabitCTL tools. Pass exact argv items with no shell for habit definitions, areas, notes, exports, diagnostics, and uncommon workflows. Login, logout, onboarding, and secret-key arguments are blocked remotely. This tool asks for every call.",
                executablePath: executablePath,
                parameters: [
                    ToolParameter(
                        name: "args",
                        title: "Arguments",
                        description: "Exact HabitCTL argv items. No shell syntax or expansion is available.",
                        kind: .stringArray,
                        required: false
                    )
                ],
                argumentPattern: ["{args}"],
                capability: .destructive,
                timeoutSeconds: 120,
                outputLimitKB: 4096,
                mode: .cliAdapter,
                approvalPolicy: .everyCall,
                annotations: openWorld
            )
        ]
    }

    /// Widget affordance for habit-shaped results: one leading check circle
    /// that records today's completion through the dedicated write tool, so
    /// the call still passes the normal approval gate and HabitCTL's own
    /// dry-run preflight. `date` is left to the tool's default (`today`).
    ///
    /// Journal rows (`habitctl today`) carry `status`, which drives the
    /// filled state; habit *definition* rows (`search`/`show`) have an `id`
    /// but no `status`, so the circle reads empty there and the action still
    /// checks the habit off for today — the useful behaviour on a search hit.
    static var habitRowUIActions: [ToolUIAction] {
        [
            ToolUIAction(
                id: "check_off",
                title: "Check Off",
                kind: .checkOff,
                toolID: "habitctl_record_result",
                arguments: .object([
                    "habit": .string("{id}"),
                    "result": .string("completed")
                ]),
                requiredRowFields: ["id"],
                completedWhenField: "status",
                completedWhenEquals: "completed"
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
        timeoutSeconds: Double = 30,
        outputLimitKB: Int = 2048,
        mode: ToolAdapterMode = .commandTemplate,
        approvalPolicy: ToolApprovalPolicy = .standard,
        annotations: ToolAnnotationOverrides?,
        uiActions: [ToolUIAction]? = nil
    ) -> DefaultToolPreset {
        DefaultToolPreset(
            id: "preset.habitctl.\(id)",
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            capability: capability,
            category: .habits,
            timeoutSeconds: timeoutSeconds,
            outputLimitKB: outputLimitKB,
            mode: mode,
            parameters: parameters,
            processInvocation: invocation,
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotations,
            uiActions: uiActions
        )
    }
}
