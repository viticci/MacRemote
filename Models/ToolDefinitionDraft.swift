import Foundation

enum ToolAdapterMode: String, CaseIterable, Identifiable, Sendable {
    case cliAdapter
    case commandTemplate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cliAdapter: "Flexible Command"
        case .commandTemplate: "Fixed Command"
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
    var requiresFullDiskAccess = false
    var permissionRequirements: [ToolPermissionRequirement] = []
    /// Preserves hand-authored schemas from catalog tools while the argument
    /// pattern is unchanged. If a user edits the pattern, save-time inference
    /// takes over so stale parameters cannot survive the edit.
    var parameterOverrides: [ToolParameter]?
    var parameterOverrideArgumentPattern: [String]?
    /// Catalog-authored semantic argv lowering is preserved only while the
    /// visible argument pattern remains unchanged.
    var processInvocationOverride: ProcessInvocation?
    var processInvocationOverrideArgumentPattern: [String]?
    var approvalPolicy: ToolApprovalPolicy = .standard
    var annotationOverrides: ToolAnnotationOverrides?
    var provenance: ToolProvenance?
    /// Widget affordances (MCP Apps) carried through preset→tool and edit
    /// round-trips; the editor UI doesn't surface them yet.
    var uiActions: [ToolUIAction]?
    /// Typed MCP Apps presentation carried through catalog/edit round-trips.
    var widgetPresentation: ToolWidgetPresentation?

    var argumentPattern: [String] {
        if mode == .cliAdapter {
            return ["{args}"]
        }

        return argumentsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func makeTool(id: String, permissionEpoch: String? = nil) throws -> ToolDefinition {
        let resolvedArgumentPattern = argumentPattern
        let parameters: [ToolParameter]
        if parameterOverrideArgumentPattern == resolvedArgumentPattern,
           let parameterOverrides {
            parameters = parameterOverrides
        } else {
            parameters = try Self.inferredParameters(from: resolvedArgumentPattern)
        }

        let tool = ToolDefinition(
            id: id,
            permissionEpoch: permissionEpoch,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            executablePath: executablePath.trimmingCharacters(in: .whitespacesAndNewlines),
            argumentPattern: resolvedArgumentPattern,
            parameters: parameters,
            processInvocation: processInvocationOverrideArgumentPattern == resolvedArgumentPattern
                ? processInvocationOverride
                : nil,
            capability: capability,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: outputLimitKB * 1024,
            origin: .userDefined,
            category: category,
            permissionRequirements: ToolPermissionRequirement.normalized(
                permissionRequirements + (requiresFullDiskAccess ? [.fullDiskAccess] : [])
            ),
            approvalPolicy: approvalPolicy,
            annotationOverrides: annotationOverrides,
            provenance: provenance,
            uiActions: uiActions,
            widgetPresentation: widgetPresentation
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
                    maximumLength: maximumLength(for: name)
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

    private static func maximumLength(for placeholderName: String) -> Int {
        switch placeholderName {
        case "prompt", "instructions":
            4096
        case "input", "url":
            2048
        case "path", "root", "working_directory", "workdir", "repository":
            1024
        case "filter", "pattern", "query":
            512
        default:
            256
        }
    }

}
