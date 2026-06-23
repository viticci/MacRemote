import Foundation

enum RemCTLToolCatalog {
    static let executablePath = "/Users/viticci/bin/remctl"

    static let readOnlyTools: [ToolDefinition] = [
        ToolDefinition(
            id: "remctl.today",
            name: "Today",
            summary: "Return due today and overdue reminders.",
            executablePath: executablePath,
            argumentPattern: ["--format", "json", "today"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024
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
            outputByteLimit: 1024 * 1024
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
            outputByteLimit: 512 * 1024
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
            outputByteLimit: 512 * 1024
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
            outputByteLimit: 512 * 1024
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
            outputByteLimit: 512 * 1024
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
            outputByteLimit: 1024 * 1024
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
            outputByteLimit: 1024 * 1024
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
            outputByteLimit: 512 * 1024
        )
    ]

    static func tool(id: String) -> ToolDefinition? {
        readOnlyTools.first { $0.id == id }
    }

    static func arguments(for toolID: String, parameters: [String: String] = [:]) throws -> [String] {
        guard let tool = tool(id: toolID) else {
            throw ToolValidationError.unknownTool(toolID)
        }

        guard tool.capability == .readOnly else {
            throw ToolValidationError.writeToolDisabled(toolID)
        }

        var resolved = [String]()
        for argument in tool.argumentPattern {
            guard argument.hasPrefix("{"), argument.hasSuffix("}") else {
                resolved.append(argument)
                continue
            }

            let parameterName = String(argument.dropFirst().dropLast())
            let value = try validatedValue(
                named: parameterName,
                for: tool,
                parameters: parameters
            )
            resolved.append(value)
        }
        return resolved
    }

    private static func validatedValue(
        named name: String,
        for tool: ToolDefinition,
        parameters: [String: String]
    ) throws -> String {
        guard let schema = tool.parameters.first(where: { $0.name == name }) else {
            throw ToolValidationError.missingParameter(name)
        }

        guard let rawValue = parameters[name] ?? schema.defaultValue else {
            if schema.required {
                throw ToolValidationError.missingParameter(name)
            }
            return ""
        }

        if rawValue.contains("\0") {
            throw ToolValidationError.nulByte(name)
        }

        switch schema.kind {
        case .string:
            if let maximumLength = schema.maximumLength, rawValue.count > maximumLength {
                throw ToolValidationError.stringTooLong(name)
            }
            return rawValue
        case .integer:
            guard let integer = Int(rawValue) else {
                throw ToolValidationError.invalidInteger(name)
            }
            if let range = schema.integerRange, !range.contains(integer) {
                throw ToolValidationError.integerOutOfRange(name)
            }
            return String(integer)
        }
    }
}
