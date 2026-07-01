import Foundation

enum RemCTLArgumentNormalizer {
    private static let numericIDCommands: Set<String> = [
        "delete",
        "done",
        "edit",
        "flag",
        "info",
        "link",
        "open",
        "subtasks",
        "undone",
        "unflag"
    ]

    private static let commandNames: Set<String> = numericIDCommands.union([
        "add",
        "export",
        "flagged",
        "group-create",
        "group-delete",
        "group-edit",
        "group-info",
        "groups",
        "import",
        "list-create",
        "list-delete",
        "list-edit",
        "list-pin",
        "list-rename",
        "list-symbols",
        "list-unpin",
        "lists",
        "overdue",
        "search",
        "section-create",
        "section-delete",
        "section-rename",
        "sections",
        "sharees",
        "show",
        "smart-list-create",
        "smart-list-delete",
        "smart-list-edit",
        "smart-lists",
        "stats",
        "tags",
        "template-apply",
        "template-create",
        "template-delete",
        "template-info",
        "templates",
        "today",
        "urgent",
        "upcoming"
    ])

    private static let privateMetadataFlags: Set<String> = [
        "-f",
        "-t",
        "--assign",
        "--early-reminder",
        "--flagged",
        "--flag",
        "--grocery",
        "--image",
        "--latitude",
        "--location-title",
        "--longitude",
        "--new-section",
        "--no-flagged",
        "--no-urgent",
        "--proximity",
        "--radius",
        "--clear-tags",
        "--remove-tag",
        "--section",
        "--section-id",
        "--set-tags",
        "--subtask",
        "--tags",
        "--unassign",
        "--url",
        "--urgent"
    ]

    private static let uuidLookupCommands: [[String]] = [
        ["--format", "json", "today"],
        ["--format", "json", "upcoming", "31"],
        ["--format", "json", "upcoming", "3650"],
        ["--format", "json", "overdue"],
        ["--format", "json", "flagged"]
    ]

    static func normalizedArguments(
        for tool: ToolDefinition,
        arguments: [String],
        runner: ProcessRunner,
        environment: [String: String]
    ) async throws -> [String] {
        try await normalizedArguments(for: tool, arguments: arguments) { uuid in
            try await resolveNumericID(
                forReminderUUID: uuid,
                executablePath: tool.executablePath,
                runner: runner,
                environment: environment
            )
        }
    }

    static func normalizedArguments(
        for tool: ToolDefinition,
        arguments: [String],
        uuidResolver: @Sendable (String) async throws -> Int?
    ) async throws -> [String] {
        guard applies(to: tool), let commandIndex = firstCommandIndex(in: arguments) else {
            return arguments
        }

        var normalized = arguments
        let command = normalized[commandIndex]
        if numericIDCommands.contains(command) {
            let idIndex = commandIndex + 1
            if normalized.indices.contains(idIndex),
               let uuid = reminderUUID(from: normalized[idIndex]) {
                guard let numericID = try await uuidResolver(uuid) else {
                    throw ToolValidationError.invalidArgument(
                        "RemCTL needs the numeric reminder `id`, not the UUID in `deepLink`: \(uuid)"
                    )
                }
                normalized[idIndex] = String(numericID)
            }
        }

        if shouldStripPrivateFlag(arguments: normalized, commandIndex: commandIndex) {
            normalized.removeAll { $0 == "--private" }
        }

        return normalized
    }

    static func applies(to tool: ToolDefinition) -> Bool {
        tool.isGenericCLIAdapter
            && URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased() == "remctl"
    }

    private static func firstCommandIndex(in arguments: [String]) -> Int? {
        arguments.firstIndex { commandNames.contains($0) }
    }

    private static func shouldStripPrivateFlag(arguments: [String], commandIndex: Int) -> Bool {
        guard arguments.contains("--private"),
              arguments.indices.contains(commandIndex) else {
            return false
        }

        let command = arguments[commandIndex]
        guard command == "edit" || command == "add" else {
            return false
        }

        return !arguments[(commandIndex + 1)...].contains { isPrivateMetadataArgument($0) }
    }

    private static func isPrivateMetadataArgument(_ argument: String) -> Bool {
        if privateMetadataFlags.contains(argument) {
            return true
        }

        return privateMetadataFlags.contains { flag in
            argument.hasPrefix("\(flag)=")
        }
    }

    private static func reminderUUID(from argument: String) -> String? {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String

        if let range = trimmed.range(of: "REMCDReminder/", options: [.caseInsensitive]) {
            candidate = String(trimmed[range.upperBound...])
                .split(whereSeparator: { $0 == "?" || $0 == "#" || $0 == "/" })
                .first
                .map(String.init) ?? ""
        } else {
            candidate = trimmed
        }

        let uppercased = candidate.uppercased()
        return isUUIDString(uppercased) ? uppercased : nil
    }

    private static func isUUIDString(_ value: String) -> Bool {
        guard value.count == 36 else { return false }
        for (index, character) in value.enumerated() {
            if [8, 13, 18, 23].contains(index) {
                guard character == "-" else { return false }
            } else {
                guard character.isHexDigit else { return false }
            }
        }
        return true
    }

    private static func resolveNumericID(
        forReminderUUID uuid: String,
        executablePath: String,
        runner: ProcessRunner,
        environment: [String: String]
    ) async throws -> Int? {
        for arguments in uuidLookupCommands {
            let result = try await runner.run(
                executablePath: executablePath,
                arguments: arguments,
                timeoutSeconds: 10,
                outputByteLimit: 1024 * 1024,
                environment: environment
            )
            guard result.succeeded,
                  let data = result.stdout.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else {
                continue
            }

            if let id = numericID(in: object, matchingReminderUUID: uuid) {
                return id
            }
        }
        return nil
    }

    private static func numericID(in object: Any, matchingReminderUUID uuid: String) -> Int? {
        if let array = object as? [Any] {
            for item in array {
                if let id = numericID(in: item, matchingReminderUUID: uuid) {
                    return id
                }
            }
            return nil
        }

        guard let dictionary = object as? [String: Any] else {
            return nil
        }

        if dictionaryMatchesReminderUUID(dictionary, uuid: uuid),
           let id = integerValue(dictionary["id"]) {
            return id
        }

        for value in dictionary.values {
            if let id = numericID(in: value, matchingReminderUUID: uuid) {
                return id
            }
        }
        return nil
    }

    private static func dictionaryMatchesReminderUUID(_ dictionary: [String: Any], uuid: String) -> Bool {
        let uppercasedUUID = uuid.uppercased()
        for key in ["deepLink", "url", "uuid", "user_uuid", "externalID", "externalId"] {
            guard let value = dictionary[key] as? String else { continue }
            if value.uppercased().contains(uppercasedUUID) {
                return true
            }
        }
        return false
    }

    private static func integerValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
