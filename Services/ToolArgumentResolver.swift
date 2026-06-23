import Foundation

enum ToolArgumentResolver {
    private static let maximumArgumentCount = 64
    private static let maximumArgumentLength = 4096
    private static let blockedExecutableNames: Set<String> = [
        "bash",
        "csh",
        "env",
        "fish",
        "sh",
        "tcsh",
        "zsh"
    ]

    static func validate(_ tool: ToolDefinition) throws {
        guard !tool.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolValidationError.emptyName
        }

        guard tool.timeoutSeconds >= 1, tool.timeoutSeconds <= 60 else {
            throw ToolValidationError.invalidTimeout
        }

        guard tool.outputByteLimit >= 1024, tool.outputByteLimit <= 5 * 1024 * 1024 else {
            throw ToolValidationError.invalidOutputLimit
        }

        guard tool.argumentPattern.count <= maximumArgumentCount else {
            throw ToolValidationError.tooManyArguments
        }

        guard tool.executablePath.hasPrefix("/") else {
            throw ToolValidationError.executableNotAbsolute
        }

        let executableName = URL(fileURLWithPath: tool.executablePath).lastPathComponent.lowercased()
        if blockedExecutableNames.contains(executableName) {
            throw ToolValidationError.blockedExecutable(tool.executablePath)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: tool.executablePath, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: tool.executablePath) else {
            throw ToolValidationError.executableUnavailable(tool.executablePath)
        }

        let parameterNames = Set(tool.parameters.map(\.name))
        for argument in tool.argumentPattern {
            guard !argument.contains("\0"),
                  argument.count <= maximumArgumentLength else {
                throw ToolValidationError.invalidArgument(argument)
            }

            guard argument.hasPrefix("{") || argument.hasSuffix("}") else {
                continue
            }

            guard argument.hasPrefix("{"), argument.hasSuffix("}") else {
                throw ToolValidationError.invalidPlaceholder(argument)
            }

            let placeholder = String(argument.dropFirst().dropLast())
            guard isValidPlaceholderName(placeholder) else {
                throw ToolValidationError.invalidPlaceholder(argument)
            }
            guard parameterNames.contains(placeholder) else {
                throw ToolValidationError.undefinedPlaceholder(placeholder)
            }
        }
    }

    static func arguments(for tool: ToolDefinition, parameters: [String: ToolArgumentValue] = [:]) throws -> [String] {
        try validate(tool)

        var resolved = [String]()
        for argument in tool.argumentPattern {
            guard argument.hasPrefix("{"), argument.hasSuffix("}") else {
                resolved.append(argument)
                continue
            }

            let parameterName = String(argument.dropFirst().dropLast())
            let values = try validatedValues(
                named: parameterName,
                for: tool,
                parameters: parameters
            )
            resolved.append(contentsOf: values)
        }
        return resolved
    }

    static func arguments(for tool: ToolDefinition, stringParameters: [String: String]) throws -> [String] {
        try arguments(
            for: tool,
            parameters: stringParameters.mapValues { .string($0) }
        )
    }

    static func isValidPlaceholderName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 32 else {
            return false
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")
        guard name.rangeOfCharacter(from: allowed.inverted) == nil else {
            return false
        }

        guard let first = name.unicodeScalars.first else {
            return false
        }
        return CharacterSet.letters.contains(first) || first.value == 95
    }

    private static func validatedValues(
        named name: String,
        for tool: ToolDefinition,
        parameters: [String: ToolArgumentValue]
    ) throws -> [String] {
        guard let schema = tool.parameters.first(where: { $0.name == name }) else {
            throw ToolValidationError.missingParameter(name)
        }

        let rawValue = parameters[name] ?? schema.defaultValue.map { .string($0) }
        guard let rawValue else {
            if schema.required {
                throw ToolValidationError.missingParameter(name)
            }
            return []
        }

        switch schema.kind {
        case .string:
            guard let rawValue = rawValue.stringValue else {
                throw ToolValidationError.invalidArgument(name)
            }
            if rawValue.contains("\0") {
                throw ToolValidationError.nulByte(name)
            }
            if let maximumLength = schema.maximumLength, rawValue.count > maximumLength {
                throw ToolValidationError.stringTooLong(name)
            }
            return rawValue.isEmpty ? [] : [rawValue]
        case .integer:
            guard let rawValue = rawValue.stringValue else {
                throw ToolValidationError.invalidInteger(name)
            }
            if rawValue.contains("\0") {
                throw ToolValidationError.nulByte(name)
            }
            guard let integer = Int(rawValue) else {
                throw ToolValidationError.invalidInteger(name)
            }
            if let range = schema.integerRange, !range.contains(integer) {
                throw ToolValidationError.integerOutOfRange(name)
            }
            return [String(integer)]
        case .stringArray:
            let values: [String]
            switch rawValue {
            case .string(let value):
                values = value.isEmpty ? [] : [value]
            case .stringArray(let array):
                values = array
            }

            guard values.count <= maximumArgumentCount else {
                throw ToolValidationError.tooManyArguments
            }
            for value in values {
                if value.contains("\0") {
                    throw ToolValidationError.nulByte(name)
                }
                if value.count > maximumArgumentLength {
                    throw ToolValidationError.stringTooLong(name)
                }
            }
            return values
        }
    }
}
