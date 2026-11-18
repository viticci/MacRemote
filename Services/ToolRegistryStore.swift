import Foundation

enum ToolRegistryLoadProblem: Equatable, Sendable {
    case validation(ToolValidationError)
    case decoding(row: Int, reason: String)
    case unexpectedValidation(reason: String)
}

struct ToolRegistryLoadIssue: Equatable, Sendable {
    let toolID: String?
    let toolName: String
    let problem: ToolRegistryLoadProblem
    let requiresQuarantine: Bool
    let blocksWrites: Bool
}

struct ToolRegistryLoadReport: Equatable, Sendable {
    let tools: [ToolDefinition]
    let issues: [ToolRegistryLoadIssue]

    var writesAllowed: Bool {
        !issues.contains(where: \.blocksWrites)
    }
}

enum ToolRegistryStoreError: LocalizedError, Equatable, Sendable {
    case invalidTopLevel
    case unreadableTool(row: Int, name: String, reason: String)
    case unexpectedValidation(toolName: String, reason: String)
    case writesBlocked(String)

    var errorDescription: String? {
        switch self {
        case .invalidTopLevel:
            "Saved tools must be a JSON array."
        case .unreadableTool(let row, let name, let reason):
            "Saved tool \(name) at row \(row) could not be read: \(reason)"
        case .unexpectedValidation(let toolName, let reason):
            "Saved tool \(toolName) could not be validated: \(reason)"
        case .writesBlocked(let reason):
            "Tool catalog changes are blocked to preserve tools.json: \(reason)"
        }
    }
}

struct ToolRegistryStore: Sendable {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
            return
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.fileURL = base
            .appendingPathComponent("MacRemote", isDirectory: true)
            .appendingPathComponent("tools.json")
    }

    func loadUserDefinedTools() throws -> [ToolDefinition] {
        let report = try loadUserDefinedToolsReport()
        if let issue = report.issues.first {
            switch issue.problem {
            case .validation(let error):
                throw error
            case .decoding(let row, let reason):
                throw ToolRegistryStoreError.unreadableTool(
                    row: row,
                    name: issue.toolName,
                    reason: reason
                )
            case .unexpectedValidation(let reason):
                throw ToolRegistryStoreError.unexpectedValidation(
                    toolName: issue.toolName,
                    reason: reason
                )
            }
        }
        return report.tools
    }

    /// Startup must not discard the whole catalog when one previously valid
    /// executable has moved or been uninstalled. Keep every decoded tool so the
    /// user can see and repair it, and report each validation issue separately.
    func loadUserDefinedToolsReport() throws -> ToolRegistryLoadReport {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return ToolRegistryLoadReport(tools: [], issues: [])
        }

        let data = try Data(contentsOf: fileURL)
        let root = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let rows = root as? [Any] else {
            throw ToolRegistryStoreError.invalidTopLevel
        }

        var tools = [ToolDefinition]()
        var issues = [ToolRegistryLoadIssue]()
        for (zeroBasedIndex, row) in rows.enumerated() {
            let rowNumber = zeroBasedIndex + 1
            let fallbackIdentity = Self.fallbackIdentity(for: row, rowNumber: rowNumber)
            let tool: ToolDefinition
            do {
                let rowData = try JSONSerialization.checkedData(withJSONObject: row, options: [.fragmentsAllowed])
                tool = try JSONDecoder().decode(ToolDefinition.self, from: rowData)
            } catch {
                issues.append(
                    ToolRegistryLoadIssue(
                        toolID: fallbackIdentity.id,
                        toolName: fallbackIdentity.name,
                        problem: .decoding(row: rowNumber, reason: Self.decodingReason(error)),
                        requiresQuarantine: false,
                        blocksWrites: true
                    )
                )
                continue
            }

            guard tool.isUserDefined else { continue }
            tools.append(tool)
            do {
                try ToolArgumentResolver.validate(tool)
            } catch let error as ToolValidationError {
                let trimmedName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
                issues.append(
                    ToolRegistryLoadIssue(
                        toolID: tool.id,
                        toolName: trimmedName.isEmpty ? tool.id : trimmedName,
                        problem: .validation(error),
                        requiresQuarantine: Self.requiresQuarantine(for: error),
                        blocksWrites: false
                    )
                )
            } catch {
                let trimmedName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
                issues.append(
                    ToolRegistryLoadIssue(
                        toolID: tool.id,
                        toolName: trimmedName.isEmpty ? tool.id : trimmedName,
                        problem: .unexpectedValidation(reason: error.localizedDescription),
                        requiresQuarantine: true,
                        blocksWrites: false
                    )
                )
            }
        }
        return ToolRegistryLoadReport(tools: tools, issues: issues)
    }

    private static func fallbackIdentity(for row: Any, rowNumber: Int) -> (id: String?, name: String) {
        guard let object = row as? [String: Any] else {
            return (nil, "row \(rowNumber)")
        }
        let id = object["id"] as? String
        let rawName = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.flatMap { $0.isEmpty ? nil : $0 } ?? id ?? "row \(rowNumber)"
        return (id, name)
    }

    private static func decodingReason(_ error: Error) -> String {
        guard let error = error as? DecodingError else {
            return error.localizedDescription
        }
        switch error {
        case .keyNotFound(let key, _):
            return "missing required field '\(key.stringValue)'"
        case .typeMismatch(_, let context):
            return context.debugDescription
        case .valueNotFound(_, let context):
            return context.debugDescription
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func requiresQuarantine(for error: ToolValidationError) -> Bool {
        guard case .executableUnavailable(let path) = error else {
            return true
        }
        return FileManager.default.fileExists(atPath: path)
    }

    func saveUserDefinedTools(
        _ tools: [ToolDefinition],
        preservingInvalidToolIDs: Set<String> = []
    ) throws {
        let userTools = try tools.filter(\.isUserDefined).map { tool in
            do {
                try ToolArgumentResolver.validate(tool)
            } catch let error as ToolValidationError {
                // Only rows the caller names may bypass validation: those
                // found invalid at startup and those this save leaves
                // unchanged. New and edited tools still use the strict path,
                // while an unrelated save cannot erase an unavailable tool.
                guard preservingInvalidToolIDs.contains(tool.id) else {
                    throw error
                }
            } catch {
                throw error
            }
            return tool
        }

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.sortedPrettyPrinted.encode(userTools)
        try data.write(to: fileURL, options: [.atomic])
        // The registry can hold a bridged server's credentials, so only the
        // owner may read it. An atomic write makes a new file each time.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

private extension JSONEncoder {
    static var sortedPrettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
