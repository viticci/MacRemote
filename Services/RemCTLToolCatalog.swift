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
        ToolDefinition(
            id: "remctl.today",
            name: "Today",
            summary: "Return due today and overdue reminders.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "today"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.upcoming",
            name: "Upcoming",
            summary: "Return reminders due in the next N days.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "upcoming", "{days}"],
            parameters: [
                ToolParameter(
                    name: "days",
                    title: "Days",
                    kind: .integer,
                    required: false,
                    defaultValue: "7",
                    integerRange: 1...31
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.overdue",
            name: "Overdue",
            summary: "Return all overdue reminders.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "overdue"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.lists",
            name: "Lists",
            summary: "Return all iCloud reminder lists.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "lists"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.sections",
            name: "Sections",
            summary: "Return sections across iCloud reminder lists.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "sections"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.stats",
            name: "Stats",
            summary: "Return reminder database statistics.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "stats"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.search",
            name: "Search",
            summary: "Search reminders by query.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "search", "{query}"],
            parameters: [
                ToolParameter(
                    name: "query",
                    title: "Query",
                    kind: .string,
                    maximumLength: 160
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.show",
            name: "Show List",
            summary: "Show reminders in a named list.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "show", "{list}"],
            parameters: [
                ToolParameter(
                    name: "list",
                    title: "List",
                    kind: .string,
                    maximumLength: 80
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        ),
        ToolDefinition(
            id: "remctl.info",
            name: "Reminder Info",
            summary: "Return detail for a numeric reminder id.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "info", "{id}"],
            parameters: [
                ToolParameter(
                    name: "id",
                    title: "Reminder ID",
                    kind: .integer,
                    integerRange: 1...999_999_999
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            category: .reminders,
            permissionRequirements: permissionRequirements
        )
        ]
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
