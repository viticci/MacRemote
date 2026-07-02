import Foundation

enum RemCTLToolCatalog {
    private static let permissionRequirements: [ToolPermissionRequirement] = [.fullDiskAccess, .reminders]

    static var detectedExecutablePath: String? {
        ExecutableLocator.executablePath(named: "remctl")
    }

    static var executablePath: String {
        detectedExecutablePath ?? "\(ExecutableLocator.homeDirectory)/bin/remctl"
    }

    static var fullCLITool: ToolDefinition {
        ToolDefinition(
        id: "remctl.run",
        name: "Run RemCTL",
        summary: "Run the Reminders CLI by passing argv directly. Requires Full Disk Access because the command reads protected Reminders data.",
        executablePath: executablePath,
        argumentPattern: ["{args}"],
        parameters: [
            ToolParameter(
                name: "args",
                title: "Arguments",
                kind: .stringArray,
                required: false
            ),
            ToolParameter(
                name: "stdin",
                title: "Standard Input",
                kind: .string,
                required: false,
                maximumLength: 1024 * 1024
            )
        ],
        capability: .destructive,
        timeoutSeconds: 30,
        outputByteLimit: 2 * 1024 * 1024,
        category: .reminders,
        permissionRequirements: permissionRequirements
        )
    }

    static var readOnlyTools: [ToolDefinition] {
        [
            readOnlyTool(
                id: "remctl.today",
                name: "Today",
                summary: "Return due today and overdue reminders.",
                argumentPattern: ["--format", "json", "today"],
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.upcoming",
                name: "Upcoming",
                summary: "Return reminders due in the next N days.",
                argumentPattern: ["--format", "json", "upcoming", "{days}"],
                parameters: [
                    ToolParameter(
                        name: "days",
                        title: "Days",
                        kind: .integer,
                        required: false,
                        defaultValue: "7",
                        integerRange: 1...3650
                    )
                ],
                outputByteLimit: 1024 * 1024,
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.overdue",
                name: "Overdue",
                summary: "Return all overdue reminders.",
                argumentPattern: ["--format", "json", "overdue"],
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.flagged",
                name: "Flagged",
                summary: "Return flagged reminders.",
                argumentPattern: ["--format", "json", "flagged"],
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.urgent",
                name: "Urgent",
                summary: "Return urgent reminders.",
                argumentPattern: ["--format", "json", "urgent"],
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.lists",
                name: "Lists",
                summary: "Return all iCloud reminder lists.",
                argumentPattern: ["--format", "json", "lists"]
            ),
            readOnlyTool(
                id: "remctl.groups",
                name: "Groups",
                summary: "Return Reminders list groups and child-list counts.",
                argumentPattern: ["--format", "json", "groups"],
                outputByteLimit: 1024 * 1024
            ),
            readOnlyTool(
                id: "remctl.smart_lists",
                name: "Smart Lists",
                summary: "Return Reminders smart lists and decoded filter metadata.",
                argumentPattern: ["--format", "json", "smart-lists"],
                outputByteLimit: 1024 * 1024
            ),
            readOnlyTool(
                id: "remctl.templates",
                name: "Templates",
                summary: "Return saved Reminders templates.",
                argumentPattern: ["--format", "json", "templates"],
                outputByteLimit: 1024 * 1024
            ),
            readOnlyTool(
                id: "remctl.sections",
                name: "Sections",
                summary: "Return sections across iCloud reminder lists.",
                argumentPattern: ["--format", "json", "sections"]
            ),
            readOnlyTool(
                id: "remctl.tags",
                name: "Tags",
                summary: "Return synced Reminders hashtag labels.",
                argumentPattern: ["--format", "json", "tags"]
            ),
            readOnlyTool(
                id: "remctl.list_symbols",
                name: "List Symbols",
                summary: "Return official Reminders list badge symbol names.",
                argumentPattern: ["--format", "json", "list-symbols"]
            ),
            readOnlyTool(
                id: "remctl.stats",
                name: "Stats",
                summary: "Return reminder database statistics.",
                argumentPattern: ["--format", "json", "stats"]
            ),
            readOnlyTool(
                id: "remctl.search",
                name: "Search",
                summary: "Search reminders by query.",
                argumentPattern: ["--format", "json", "search", "{query}"],
                parameters: [
                    ToolParameter(
                        name: "query",
                        title: "Query",
                        kind: .string,
                        maximumLength: 160
                    )
                ],
                outputByteLimit: 1024 * 1024,
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.show",
                name: "Show List",
                summary: "Show reminders in a named list or group.",
                argumentPattern: ["--format", "json", "show", "{list}"],
                parameters: [
                    ToolParameter(
                        name: "list",
                        title: "List",
                        kind: .string,
                        maximumLength: 80
                    )
                ],
                outputByteLimit: 1024 * 1024,
                uiActions: reminderRowUIActions
            ),
            readOnlyTool(
                id: "remctl.group_info",
                name: "Group Info",
                summary: "Return details for one Reminders list group.",
                argumentPattern: ["--format", "json", "group-info", "{group}"],
                parameters: [
                    ToolParameter(
                        name: "group",
                        title: "Group",
                        kind: .string,
                        maximumLength: 120
                    )
                ],
                outputByteLimit: 1024 * 1024
            ),
            readOnlyTool(
                id: "remctl.template_info",
                name: "Template Info",
                summary: "Return saved reminders and metadata for one Reminders template.",
                argumentPattern: ["--format", "json", "template-info", "{template}"],
                parameters: [
                    ToolParameter(
                        name: "template",
                        title: "Template",
                        kind: .string,
                        maximumLength: 160
                    )
                ],
                outputByteLimit: 1024 * 1024
            ),
            readOnlyTool(
                id: "remctl.sharees",
                name: "Sharees",
                summary: "Return people available for assignment in a shared list.",
                argumentPattern: ["--format", "json", "sharees", "{list}"],
                parameters: [
                    ToolParameter(
                        name: "list",
                        title: "List",
                        kind: .string,
                        maximumLength: 80
                    )
                ]
            ),
            readOnlyTool(
                id: "remctl.subtasks",
                name: "Subtasks",
                summary: "Return subtasks for a numeric reminder id.",
                argumentPattern: ["--format", "json", "subtasks", "{id}"],
                parameters: [
                    ToolParameter(
                        name: "id",
                        title: "Reminder ID",
                        kind: .integer,
                        integerRange: 1...999_999_999
                    )
                ],
                outputByteLimit: 1024 * 1024
            ),
            readOnlyTool(
                id: "remctl.info",
                name: "Reminder Info",
                summary: "Return detail for a numeric reminder id.",
                argumentPattern: ["--format", "json", "info", "{id}"],
                parameters: [
                    ToolParameter(
                        name: "id",
                        title: "Reminder ID",
                        kind: .integer,
                        integerRange: 1...999_999_999
                    )
                ]
            )
        ]
    }

    /// Widget affordance for reminder-list results (MCP Apps): a Reminders-style
    /// check-off circle per row, wired to `remctl done <id>` through the full
    /// CLI tool. Data only — the call still passes capability gating and the
    /// host approval flow ("if allowed" is enforced by the server, not the UI).
    static var reminderRowUIActions: [ToolUIAction] {
        [
            ToolUIAction(
                id: "complete",
                title: "Mark Done",
                kind: .checkOff,
                toolID: fullCLITool.id,
                arguments: .object(["args": .array([.string("--json"), .string("done"), .string("{id}")])]),
                requiredRowFields: ["id"],
                completedWhenField: "completed"
            )
        ]
    }

    private static func readOnlyTool(
        id: String,
        name: String,
        summary: String,
        argumentPattern: [String],
        parameters: [ToolParameter] = [],
        timeoutSeconds: Double = 10,
        outputByteLimit: Int = 512 * 1024,
        uiActions: [ToolUIAction]? = nil
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: summary,
            executablePath: executablePath,
            argumentPattern: argumentPattern,
            parameters: parameters,
            capability: .readOnly,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: outputByteLimit,
            category: .reminders,
            permissionRequirements: permissionRequirements,
            uiActions: uiActions
        )
    }

    static var builtInTools: [ToolDefinition] { [fullCLITool] + readOnlyTools }

    static func tool(id: String) -> ToolDefinition? {
        builtInTools.first { $0.id == id }
    }

    static func arguments(for toolID: String, parameters: [String: String] = [:]) throws -> [String] {
        guard let tool = tool(id: toolID) else {
            throw ToolValidationError.unknownTool(toolID)
        }
        return try ToolArgumentResolver.arguments(for: tool, stringParameters: parameters)
    }

    static func arguments(for toolID: String, parameters: [String: ToolArgumentValue]) throws -> [String] {
        guard let tool = tool(id: toolID) else {
            throw ToolValidationError.unknownTool(toolID)
        }
        return try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
    }
}
