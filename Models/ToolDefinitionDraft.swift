import Foundation

enum ToolAdapterMode: String, CaseIterable, Identifiable {
    case cliAdapter
    case commandTemplate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cliAdapter: "CLI Adapter"
        case .commandTemplate: "Command Template"
        }
    }
}

struct ToolDefinitionDraft: Equatable {
    var mode: ToolAdapterMode = .cliAdapter
    var name: String = ""
    var summary: String = ""
    var executablePath: String = ""
    var argumentsText: String = ""
    var capability: ToolCapability = .readOnly
    var category: ToolCategory = .utilities
    var timeoutSeconds: Double = 10
    var outputLimitKB: Int = 512

    var argumentPattern: [String] {
        if mode == .cliAdapter {
            return ["{args}"]
        }

        return argumentsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func makeTool(id: String = Self.makeID()) throws -> ToolDefinition {
        let tool = ToolDefinition(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            executablePath: executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            argumentPattern: argumentPattern,
            parameters: try Self.inferredParameters(from: argumentPattern),
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: outputLimitKB * 1024,
            origin: .userDefined,
            category: category
        )
        try ToolArgumentResolver.validate(tool)
        return tool
    }

    static func inferredParameters(from argumentPattern: [String]) throws -> [ToolParameter] {
        var seen = Set<String>()
        var parameters = [ToolParameter]()
        var includesGenericArgs = false

        for argument in argumentPattern {
            guard argument.hasPrefix("{") || argument.hasSuffix("}") else {
                continue
            }
            guard argument.hasPrefix("{"), argument.hasSuffix("}") else {
                throw ToolValidationError.invalidPlaceholder(argument)
            }

            let name = String(argument.dropFirst().dropLast())
            guard ToolArgumentResolver.isValidPlaceholderName(name) else {
                throw ToolValidationError.invalidPlaceholder(argument)
            }

            if seen.insert(name).inserted {
                if name == "args" || name == "argv" {
                    includesGenericArgs = true
                    parameters.append(ToolParameter(
                        name: name,
                        title: "Arguments",
                        kind: .stringArray,
                        required: false
                    ))
                    continue
                }

                parameters.append(ToolParameter(
                    name: name,
                    title: name.replacingOccurrences(of: "_", with: " ").capitalized,
                    kind: .string,
                    maximumLength: 256
                ))
            }
        }

        if includesGenericArgs, !seen.contains("stdin") {
            parameters.append(ToolParameter(
                name: "stdin",
                title: "Standard Input",
                kind: .string,
                required: false,
                maximumLength: 1024 * 1024
            ))
        }

        return parameters
    }

    private static func makeID() -> String {
        let bytes = (0..<8).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return "custom." + bytes.map { String(format: "%02x", $0) }.joined()
    }
}
