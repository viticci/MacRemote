import Foundation

enum ToolArgumentResolver {
    private static let maximumArgumentCount = 64
    private static let maximumArgumentLength = 4096
    private static let blockedExecutableNames: Set<String> = [
        "bash",
        "csh",
        "dash",
        "env",
        "fish",
        "ksh",
        "sh",
        "tcsh",
        "zsh"
    ]

    // R6 hardening: any login shell the system knows about is Ring 0 even when
    // it hides behind an innocent name, so keep both the raw /etc/shells entries
    // and their symlink-resolved forms.
    private static let registeredLoginShellPaths: Set<String> = {
        guard let contents = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else {
            return []
        }
        var paths = Set<String>()
        for line in contents.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard entry.hasPrefix("/") else { continue }
            paths.insert(entry.lowercased())
            paths.insert(URL(fileURLWithPath: entry).resolvingSymlinksInPath().path.lowercased())
        }
        return paths
    }()

    /// Ring 0 (R6/G1/G2): block shells by literal basename, by symlink-resolved
    /// basename (`~/bin/notes → /bin/zsh` must not validate), and by resolved
    /// membership in `/etc/shells`.
    private static func ensureExecutableIsNotShell(_ path: String) throws {
        let literalName = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if blockedExecutableNames.contains(literalName) {
            throw ToolValidationError.blockedExecutable(path)
        }

        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if blockedExecutableNames.contains(resolved.lastPathComponent.lowercased()) {
            throw ToolValidationError.blockedExecutable(path)
        }
        if registeredLoginShellPaths.contains(resolved.path.lowercased()) {
            throw ToolValidationError.blockedExecutable(path)
        }
    }

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

        if tool.backend == .mcpHTTPBridge {
            try validateMCPHTTPBridge(tool)
            return
        }

        if tool.backend == .mcpStdioBridge {
            try validateMCPStdioBridge(tool)
            return
        }

        if tool.backend == .native {
            try validateNativeTool(tool)
            return
        }

        guard tool.executablePath.hasPrefix("/") else {
            throw ToolValidationError.executableNotAbsolute
        }

        try ensureExecutableIsNotShell(tool.executablePath)

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
        guard tool.backend == .process else { return [] }

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
            case .json:
                guard let array = rawValue.stringArrayValue else {
                    throw ToolValidationError.invalidArgument(name)
                }
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

    private static func validateMCPHTTPBridge(_ tool: ToolDefinition) throws {
        guard let bridge = tool.mcpBridge else {
            throw ToolValidationError.invalidMCPBridge("missing bridge configuration")
        }

        guard let components = URLComponents(string: bridge.serverURL),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty,
              components.fragment == nil else {
            throw ToolValidationError.invalidMCPBridge("serverURL must be an HTTP(S) URL")
        }

        guard !bridge.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolValidationError.invalidMCPBridge("toolName is required")
        }

        guard !bridge.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolValidationError.invalidMCPBridge("serverName is required")
        }

        guard !bridge.protocolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bridge.protocolVersion.contains("\0") else {
            throw ToolValidationError.invalidMCPBridge("protocolVersion is invalid")
        }

        if let inputSchema = bridge.inputSchema,
           inputSchema.objectValue == nil {
            throw ToolValidationError.invalidMCPBridge("inputSchema must be a JSON object")
        }

        if let annotations = bridge.annotations,
           annotations.objectValue == nil {
            throw ToolValidationError.invalidMCPBridge("annotations must be a JSON object")
        }

        for header in bridge.headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-").inverted) == nil else {
                throw ToolValidationError.invalidMCPBridge("header names must use HTTP token syntax")
            }
            guard header.value != nil || header.valueSource != nil else {
                throw ToolValidationError.invalidMCPBridge("header \(name) needs a value or value source")
            }
            if let value = header.value, value.contains("\0") {
                throw ToolValidationError.invalidMCPBridge("header \(name) contains a NUL byte")
            }
            if let source = header.valueSource {
                switch source.kind {
                case .environment:
                    guard let key = source.environmentKey, !key.isEmpty else {
                        throw ToolValidationError.invalidMCPBridge("environment header source needs an environmentKey")
                    }
                case .jsonFile:
                    guard let path = source.filePath, path.hasPrefix("/"),
                          let keyPath = source.keyPath, !keyPath.isEmpty else {
                        throw ToolValidationError.invalidMCPBridge("jsonFile header source needs an absolute filePath and keyPath")
                    }
                case .tomlFile:
                    guard let path = source.filePath, path.hasPrefix("/"),
                          let keyPath = source.keyPath, !keyPath.isEmpty else {
                        throw ToolValidationError.invalidMCPBridge("tomlFile header source needs an absolute filePath and keyPath")
                    }
                }
            }
        }
    }

    private static func validateNativeTool(_ tool: ToolDefinition) throws {
        guard tool.nativeToolID != nil else {
            throw ToolValidationError.invalidNativeTool("missing nativeToolID")
        }
        guard tool.argumentPattern.isEmpty else {
            throw ToolValidationError.invalidNativeTool("native tools must not use argumentPattern")
        }
        for parameter in tool.parameters {
            guard isValidPlaceholderName(parameter.name) else {
                throw ToolValidationError.invalidNativeTool("invalid parameter name \(parameter.name)")
            }
        }
    }

    private static func validateMCPStdioBridge(_ tool: ToolDefinition) throws {
        guard let bridge = tool.mcpStdioBridge else {
            throw ToolValidationError.invalidMCPBridge("missing stdio bridge configuration")
        }

        guard bridge.command.hasPrefix("/") else {
            throw ToolValidationError.invalidMCPBridge("stdio command must be an absolute path")
        }

        try ensureExecutableIsNotShell(bridge.command)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bridge.command, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isExecutableFile(atPath: bridge.command) else {
            throw ToolValidationError.executableUnavailable(bridge.command)
        }

        guard !bridge.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolValidationError.invalidMCPBridge("toolName is required")
        }

        guard !bridge.serverName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolValidationError.invalidMCPBridge("serverName is required")
        }

        guard !bridge.protocolVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !bridge.protocolVersion.contains("\0") else {
            throw ToolValidationError.invalidMCPBridge("protocolVersion is invalid")
        }

        if let startupTimeoutSeconds = bridge.startupTimeoutSeconds,
           !(1...300).contains(startupTimeoutSeconds) {
            throw ToolValidationError.invalidMCPBridge("startupTimeoutSeconds must be between 1 and 300 seconds")
        }

        guard bridge.args.count <= maximumArgumentCount else {
            throw ToolValidationError.tooManyArguments
        }
        for argument in bridge.args {
            guard !argument.contains("\0"),
                  argument.count <= maximumArgumentLength else {
                throw ToolValidationError.invalidArgument(argument)
            }
        }

        if let inputSchema = bridge.inputSchema,
           inputSchema.objectValue == nil {
            throw ToolValidationError.invalidMCPBridge("inputSchema must be a JSON object")
        }

        if let annotations = bridge.annotations,
           annotations.objectValue == nil {
            throw ToolValidationError.invalidMCPBridge("annotations must be a JSON object")
        }

        for variable in bridge.environment {
            guard isValidEnvironmentName(variable.name) else {
                throw ToolValidationError.invalidMCPBridge("environment variable names must use POSIX name syntax")
            }
            guard variable.value != nil || variable.valueSource != nil else {
                throw ToolValidationError.invalidMCPBridge("environment variable \(variable.name) needs a value or value source")
            }
            if let value = variable.value, value.contains("\0") {
                throw ToolValidationError.invalidMCPBridge("environment variable \(variable.name) contains a NUL byte")
            }
            if let source = variable.valueSource {
                switch source.kind {
                case .environment:
                    guard let key = source.environmentKey, !key.isEmpty else {
                        throw ToolValidationError.invalidMCPBridge("environment source needs an environmentKey")
                    }
                case .jsonFile:
                    guard let path = source.filePath, path.hasPrefix("/"),
                          let keyPath = source.keyPath, !keyPath.isEmpty else {
                        throw ToolValidationError.invalidMCPBridge("jsonFile environment source needs an absolute filePath and keyPath")
                    }
                case .tomlFile:
                    guard let path = source.filePath, path.hasPrefix("/"),
                          let keyPath = source.keyPath, !keyPath.isEmpty else {
                        throw ToolValidationError.invalidMCPBridge("tomlFile environment source needs an absolute filePath and keyPath")
                    }
                }
            }
        }
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else {
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
}
