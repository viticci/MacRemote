import Foundation

enum ToolArgumentResolver {
    private static let maximumArgumentCount = 64
    static let defaultStringArrayItemMaximumLength = 4096
    static let maximumExecutionInputBytes = 96 * 1024
    private static let maximumArgumentLength = defaultStringArrayItemMaximumLength
    static let maximumTimeoutSeconds: TimeInterval = 24 * 60 * 60
    static let maximumOutputByteLimit = 64 * 1024 * 1024
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

        guard tool.timeoutSeconds >= 1, tool.timeoutSeconds <= maximumTimeoutSeconds else {
            throw ToolValidationError.invalidTimeout
        }

        guard tool.outputByteLimit >= 1024, tool.outputByteLimit <= maximumOutputByteLimit else {
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
        guard parameterNames.count == tool.parameters.count else {
            throw ToolValidationError.invalidArgument("duplicate parameter name")
        }
        for parameter in tool.parameters {
            guard isValidPlaceholderName(parameter.name) else {
                throw ToolValidationError.invalidArgument(parameter.name)
            }
            if let allowedValues = parameter.allowedValues {
                guard parameter.kind == .string,
                      !allowedValues.isEmpty,
                      Set(allowedValues).count == allowedValues.count,
                      allowedValues.allSatisfy({ !$0.isEmpty && !$0.contains("\0") }) else {
                    throw ToolValidationError.invalidArgument(parameter.name)
                }
            }
            if parameter.kind == .json,
               let schema = parameter.jsonSchema,
               schema.objectValue == nil {
                throw ToolValidationError.invalidArgument(parameter.name)
            }
        }

        if let invocation = tool.processInvocation {
            try validate(invocation, parameterNames: parameterNames)
        }
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
        if tool.backend == .native {
            try validateDeclaredParameters(for: tool, parameters: parameters)
            try validateNativeConstraints(for: tool, parameters: parameters)
            return []
        }
        guard tool.backend == .process else { return [] }

        let declaredParameterNames = Set(tool.parameters.map(\.name))
        for name in parameters.keys where !declaredParameterNames.contains(name) {
            throw ToolValidationError.invalidArgument(name)
        }

        if let invocation = tool.processInvocation {
            let resolved = try resolve(
                invocation,
                for: tool,
                parameters: parameters
            )
            try validateExecutionInputBytes(
                resolved,
                executablePath: tool.executablePath,
                standardInput: parameters["stdin"]?.stringValue
            )
            return resolved
        }

        let placeholderNames = Set(tool.argumentPattern.compactMap { argument -> String? in
            guard argument.hasPrefix("{"), argument.hasSuffix("}") else { return nil }
            return String(argument.dropFirst().dropLast())
        })
        // Some process inputs, notably stdin, are deliberately not argv
        // placeholders. They still must satisfy their declared schema before
        // ConfiguredToolExecutor consumes them directly.
        for schema in tool.parameters
        where !placeholderNames.contains(schema.name)
            && (schema.required || parameters[schema.name] != nil)
        {
            _ = try validatedValues(
                named: schema.name,
                for: tool,
                parameters: parameters
            )
        }

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
            // A Flexible Command passes options on purpose; every other
            // placeholder is one input, never an option.
            if !tool.isGenericCLIAdapter {
                try rejectOptionLikeValues(values, named: parameterName, for: tool)
            }
            resolved.append(contentsOf: values)
        }
        try validateExecutionInputBytes(
            resolved,
            executablePath: tool.executablePath,
            standardInput: parameters["stdin"]?.stringValue
        )
        return resolved
    }

    /// Native tools consume values directly instead of lowering them to argv.
    /// Validate their declared schema here so both pre-execution checks and the
    /// native dispatch path enforce the same contract as process tools. The one
    /// compatibility exception is `filesystem_read_file.length`: it must be an
    /// integer, but D35 requires the native operation to clamp its range.
    static func validateNativeArguments(
        for tool: ToolDefinition,
        parameters: [String: ToolArgumentValue]
    ) throws {
        try validate(tool)
        guard tool.backend == .native else {
            throw ToolValidationError.invalidNativeTool("tool does not use the native backend")
        }
        try validateDeclaredParameters(for: tool, parameters: parameters)
        try validateNativeConstraints(for: tool, parameters: parameters)
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
        parameters: [String: ToolArgumentValue],
        enforceIntegerRange: Bool = true
    ) throws -> [String] {
        guard let schema = tool.parameters.first(where: { $0.name == name }) else {
            throw ToolValidationError.missingParameter(name)
        }

        let explicitValue = parameters[name]
        let rawValue = explicitValue ?? schema.defaultValue.map { .string($0) }
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
            if let allowedValues = schema.allowedValues,
               !allowedValues.contains(rawValue) {
                throw ToolValidationError.valueNotAllowed(name)
            }
            if schema.stringFormat == "uri" {
                guard let components = URLComponents(string: rawValue),
                      ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                      components.host?.isEmpty == false else {
                    throw ToolValidationError.invalidFormat(name)
                }
            } else if schema.stringFormat == "absolute-path" {
                guard rawValue.hasPrefix("/") else {
                    throw ToolValidationError.invalidFormat(name)
                }
            }
            if rawValue.isEmpty {
                if schema.required {
                    throw ToolValidationError.missingParameter(name)
                }
                return []
            }
            return [rawValue]
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
            if enforceIntegerRange,
               let range = schema.integerRange,
               !range.contains(integer) {
                throw ToolValidationError.integerOutOfRange(name)
            }
            return [String(integer)]
        case .stringArray:
            let values: [String]
            switch rawValue {
            case .string(let value):
                // Schema defaults are stored as plain strings; remote JSON must send an array.
                guard explicitValue == nil else {
                    throw ToolValidationError.invalidArgument(name)
                }
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
            if values.isEmpty, schema.required {
                throw ToolValidationError.missingParameter(name)
            }
            let maximumLength = schema.maximumLength ?? defaultStringArrayItemMaximumLength
            for value in values {
                if value.contains("\0") {
                    throw ToolValidationError.nulByte(name)
                }
                if value.count > maximumLength {
                    throw ToolValidationError.stringTooLong(name)
                }
                if schema.stringFormat == "absolute-path", !value.hasPrefix("/") {
                    throw ToolValidationError.invalidFormat(name)
                }
            }
            return values
        case .boolean:
            let value: Bool
            if let boolean = rawValue.booleanValue {
                value = boolean
            } else if explicitValue == nil,
                      let string = rawValue.stringValue,
                      let boolean = Bool(string) {
                value = boolean
            } else {
                throw ToolValidationError.invalidBoolean(name)
            }
            return [value ? "true" : "false"]
        case .number:
            guard let value = rawValue.numberValue else {
                throw ToolValidationError.invalidNumber(name)
            }
            if let range = schema.numberRange, !range.contains(value) {
                throw ToolValidationError.numberOutOfRange(name)
            }
            return [canonicalNumber(value)]
        case .json:
            guard case .json(let value) = rawValue else {
                throw ToolValidationError.invalidJSON(name)
            }
            try validateJSON(value, schema: schema.jsonSchema, parameter: name)
            let encoded = try canonicalJSON(value, parameter: name)
            if let maximumLength = schema.maximumLength,
               encoded.utf8.count > maximumLength {
                throw ToolValidationError.stringTooLong(name)
            }
            return [encoded]
        }
    }

    private static func validateDeclaredParameters(
        for tool: ToolDefinition,
        parameters: [String: ToolArgumentValue]
    ) throws {
        let declaredParameterNames = Set(tool.parameters.map(\.name))
        for name in parameters.keys where !declaredParameterNames.contains(name) {
            throw ToolValidationError.invalidArgument(name)
        }
        for schema in tool.parameters {
            let enforceIntegerRange = !(
                tool.nativeToolID == .fsReadFile && schema.name == "length"
            )
            _ = try validatedValues(
                named: schema.name,
                for: tool,
                parameters: parameters,
                enforceIntegerRange: enforceIntegerRange
            )
        }
    }

    private static func validateNativeConstraints(
        for tool: ToolDefinition,
        parameters: [String: ToolArgumentValue]
    ) throws {
        guard tool.nativeToolID == .fsDownloadZip else { return }

        let hasPath = parameters["path"]?.stringValue?.isEmpty == false
        let hasBase = parameters["base"]?.stringValue?.isEmpty == false
        let hasPaths = parameters["paths"]?.stringArrayValue?.isEmpty == false
        if hasPath {
            guard !hasBase, !hasPaths else {
                throw ToolValidationError.constraintViolation(
                    "Use either path or base with paths, not both."
                )
            }
            return
        }
        guard hasBase, hasPaths else {
            throw ToolValidationError.constraintViolation(
                "Provide path, or provide both base and paths."
            )
        }
    }

    private static func validate(
        _ invocation: ProcessInvocation,
        parameterNames: Set<String>
    ) throws {
        guard !invocation.arguments.isEmpty,
              invocation.arguments.count <= maximumArgumentCount else {
            throw ToolValidationError.tooManyArguments
        }
        for rule in invocation.arguments {
            if let literal = rule.literal {
                guard !literal.isEmpty,
                      !literal.contains("\0"),
                      literal.count <= maximumArgumentLength else {
                    throw ToolValidationError.invalidArgument(literal)
                }
            }
            if let option = rule.option {
                guard option.hasPrefix("-"),
                      !option.contains("\0"),
                      option.count <= maximumArgumentLength else {
                    throw ToolValidationError.invalidArgument(option)
                }
            }
            if let parameter = rule.parameter,
               !parameterNames.contains(parameter) {
                throw ToolValidationError.undefinedPlaceholder(parameter)
            }
            switch rule.kind {
            case .literal:
                guard rule.literal != nil, rule.parameter == nil,
                      rule.option == nil, rule.choices == nil else {
                    throw ToolValidationError.invalidArgument("process invocation literal")
                }
            case .value, .json:
                guard rule.parameter != nil, rule.literal == nil,
                      rule.option == nil, rule.choices == nil else {
                    throw ToolValidationError.invalidArgument("process invocation value")
                }
            case .option, .flag, .repeatedOption:
                guard rule.parameter != nil, rule.option != nil,
                      rule.literal == nil, rule.choices == nil else {
                    throw ToolValidationError.invalidArgument("process invocation option")
                }
            case .choice:
                guard rule.parameter != nil, rule.literal == nil, rule.option == nil,
                      let choices = rule.choices, !choices.isEmpty,
                      choices.values.flatMap({ $0 }).allSatisfy({
                          !$0.isEmpty && !$0.contains("\0") && $0.count <= maximumArgumentLength
                      }) else {
                    throw ToolValidationError.invalidArgument("process invocation choice")
                }
            }
        }
        for constraint in invocation.constraints {
            guard constraint.parameters.count >= 2,
                  Set(constraint.parameters).count == constraint.parameters.count,
                  constraint.parameters.allSatisfy(parameterNames.contains) else {
                throw ToolValidationError.invalidArgument("process invocation constraint")
            }
        }
        if let suffix = invocation.preflightSuffix {
            guard !suffix.isEmpty,
                  suffix.allSatisfy({
                      !$0.isEmpty && !$0.contains("\0") && $0.count <= maximumArgumentLength
                  }) else {
                throw ToolValidationError.invalidArgument("process invocation preflight")
            }
        }
        if let removed = invocation.preflightRemovingArguments {
            guard invocation.preflightSuffix != nil,
                  !removed.isEmpty,
                  removed.allSatisfy({
                      !$0.isEmpty && !$0.contains("\0") && $0.count <= maximumArgumentLength
                  }) else {
                throw ToolValidationError.invalidArgument("process invocation preflight removal")
            }
        }
    }

    private static func resolve(
        _ invocation: ProcessInvocation,
        for tool: ToolDefinition,
        parameters: [String: ToolArgumentValue]
    ) throws -> [String] {
        var values = [String: [String]]()
        for schema in tool.parameters {
            let resolved = try validatedValues(
                named: schema.name,
                for: tool,
                parameters: parameters
            )
            values[schema.name] = resolved
        }

        func isPresent(_ name: String) -> Bool {
            guard parameters[name] != nil else { return false }
            if tool.parameters.first(where: { $0.name == name })?.kind == .boolean {
                return parameters[name]?.booleanValue == true
            }
            guard let value = values[name] else { return false }
            if let choice = invocation.arguments.first(where: {
                $0.kind == .choice && $0.parameter == name
            }),
               let selected = value.first,
               choice.choices?[selected]?.isEmpty == true {
                return false
            }
            return !value.isEmpty
        }
        for constraint in invocation.constraints {
            let count = constraint.parameters.count(where: isPresent)
            switch constraint.kind {
            case .atLeastOne where count == 0:
                throw ToolValidationError.constraintViolation(
                    "At least one of \(constraint.parameters.joined(separator: ", ")) is required."
                )
            case .exactlyOne where count != 1:
                throw ToolValidationError.constraintViolation(
                    "Exactly one of \(constraint.parameters.joined(separator: ", ")) is required."
                )
            case .mutuallyExclusive where count > 1:
                throw ToolValidationError.constraintViolation(
                    "\(constraint.parameters.joined(separator: ", ")) cannot be combined."
                )
            default:
                break
            }
        }

        var arguments = [String]()
        for rule in invocation.arguments {
            switch rule.kind {
            case .literal:
                arguments.append(rule.literal!)
            case .value:
                arguments.append(contentsOf: values[rule.parameter!] ?? [])
            case .option:
                let resolved = values[rule.parameter!] ?? []
                if let value = resolved.first {
                    arguments.append(rule.option!)
                    arguments.append(value)
                }
            case .flag:
                guard parameters[rule.parameter!]?.booleanValue == true else { continue }
                arguments.append(rule.option!)
            case .repeatedOption:
                for value in values[rule.parameter!] ?? [] {
                    arguments.append(rule.option!)
                    arguments.append(value)
                }
            case .choice:
                guard let value = values[rule.parameter!]?.first else { continue }
                guard let mapped = rule.choices?[value] else {
                    throw ToolValidationError.valueNotAllowed(rule.parameter!)
                }
                arguments.append(contentsOf: mapped)
            case .json:
                guard let raw = parameters[rule.parameter!] else { continue }
                guard case .json(let json) = raw else {
                    throw ToolValidationError.invalidJSON(rule.parameter!)
                }
                arguments.append(try canonicalJSON(json, parameter: rule.parameter!))
            }
            guard arguments.count <= maximumArgumentCount else {
                throw ToolValidationError.tooManyArguments
            }
        }
        return arguments
    }

    /// A value that fills a Fixed Command placeholder on its own must not
    /// start with a dash, or the command reads it as an option rather than
    /// the input the tool declares. Negative numbers and values picked from a
    /// fixed list stay allowed. Structured catalog recipes (`processInvocation`)
    /// are not checked: each is written and tested against its own CLI, and
    /// some take IDs that start with a dash (HabitCTL habit IDs).
    private static func rejectOptionLikeValues(
        _ values: [String],
        named name: String,
        for tool: ToolDefinition
    ) throws {
        guard let schema = tool.parameters.first(where: { $0.name == name }),
              schema.kind == .string || schema.kind == .stringArray,
              schema.allowedValues == nil else {
            return
        }
        // Compared as a byte, the way the command will see it. "-" followed by
        // a combining mark is one character to Swift, so `hasPrefix("-")` is
        // false for a value whose first byte is still a dash.
        for value in values where value.utf8.first == UInt8(ascii: "-") && !isNegativeNumber(value) {
            throw ToolValidationError.optionLikeValue(name)
        }
    }

    private static func isNegativeNumber(_ value: String) -> Bool {
        let digits = value.dropFirst()
        guard let first = digits.first, first.isASCII, first.isNumber else { return false }
        var sawPoint = false
        for character in digits {
            if character == "." {
                guard !sawPoint else { return false }
                sawPoint = true
            } else if !(character.isASCII && character.isNumber) {
                return false
            }
        }
        return digits.last != "."
    }

    private static func canonicalNumber(_ value: Double) -> String {
        if let integer = Int(exactly: value) {
            return String(integer)
        }
        return String(value)
    }

    private static func canonicalJSON(_ value: JSONValue, parameter: String) throws -> String {
        guard JSONSerialization.isValidJSONObject(value.anyValue),
              let data = try? JSONSerialization.checkedData(
                withJSONObject: value.anyValue,
                options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let result = String(data: data, encoding: .utf8) else {
            throw ToolValidationError.invalidJSON(parameter)
        }
        guard !result.contains("\0") else {
            throw ToolValidationError.nulByte(parameter)
        }
        return result
    }

    private static func validateJSON(
        _ value: JSONValue,
        schema: JSONValue?,
        parameter: String
    ) throws {
        guard let object = schema?.objectValue else { return }
        let type: String?
        if case .string(let schemaType) = object["type"] {
            type = schemaType
        } else {
            type = nil
        }
        switch type {
        case "array":
            guard case .array(let values) = value else {
                throw ToolValidationError.invalidJSON(parameter)
            }
            if case .number(let minimum)? = object["minItems"],
               values.count < Int(minimum) {
                throw ToolValidationError.invalidJSON(parameter)
            }
            if case .number(let maximum)? = object["maxItems"],
               values.count > Int(maximum) {
                throw ToolValidationError.invalidJSON(parameter)
            }
            let itemType: String?
            if case .string(let type)? = object["items"]?.objectValue?["type"] {
                itemType = type
            } else {
                itemType = nil
            }
            if itemType == "object",
               values.contains(where: { $0.objectValue == nil }) {
                throw ToolValidationError.invalidJSON(parameter)
            }
        case "object":
            guard value.objectValue != nil else {
                throw ToolValidationError.invalidJSON(parameter)
            }
        default:
            break
        }
    }

    /// Keep process argv plus standard input well below both MacRemote's
    /// 128 KiB MCP request boundary and macOS ARG_MAX, leaving substantial
    /// room for JSON framing and the process environment.
    private static func validateExecutionInputBytes(
        _ arguments: [String],
        executablePath: String,
        standardInput: String?
    ) throws {
        var byteCount = executablePath.utf8.count + 1
        for argument in arguments {
            let argumentBytes = argument.utf8.count + 1
            guard argumentBytes <= maximumExecutionInputBytes,
                  byteCount <= maximumExecutionInputBytes - argumentBytes else {
                throw ToolValidationError.argumentsTooLarge
            }
            byteCount += argumentBytes
        }
        if let standardInput {
            let standardInputBytes = standardInput.utf8.count
            guard standardInputBytes <= maximumExecutionInputBytes,
                  byteCount <= maximumExecutionInputBytes - standardInputBytes else {
                throw ToolValidationError.argumentsTooLarge
            }
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
        if let inputSchema = bridge.inputSchema,
           !MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(inputSchema) {
            throw ToolValidationError.invalidMCPBridge(
                "inputSchema violates modern MCP mirrored-header bounds or annotations"
            )
        }

        if let annotations = bridge.annotations,
           annotations.objectValue == nil {
            throw ToolValidationError.invalidMCPBridge("annotations must be a JSON object")
        }

        var seenHeaderNames = Set<String>()
        for header in bridge.headers {
            let name = header.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name == header.name,
                  !name.isEmpty,
                  name.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-").inverted) == nil else {
                throw ToolValidationError.invalidMCPBridge("header names must use HTTP token syntax")
            }
            guard seenHeaderNames.insert(name.lowercased()).inserted else {
                throw ToolValidationError.invalidMCPBridge("duplicate header name \(name)")
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
                case .oauth:
                    guard name.caseInsensitiveCompare("Authorization") == .orderedSame else {
                        throw ToolValidationError.invalidMCPBridge("an oauth header source only supplies Authorization")
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
        if let inputSchema = bridge.inputSchema,
           !MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(inputSchema) {
            throw ToolValidationError.invalidMCPBridge(
                "inputSchema violates modern MCP mirrored-header bounds or annotations"
            )
        }

        if let annotations = bridge.annotations,
           annotations.objectValue == nil {
            throw ToolValidationError.invalidMCPBridge("annotations must be a JSON object")
        }

        var seenEnvironmentNames = Set<String>()
        for variable in bridge.environment {
            guard isValidEnvironmentName(variable.name) else {
                throw ToolValidationError.invalidMCPBridge("environment variable names must use POSIX name syntax")
            }
            guard seenEnvironmentNames.insert(variable.name).inserted else {
                throw ToolValidationError.invalidMCPBridge("duplicate environment variable \(variable.name)")
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
                case .oauth:
                    throw ToolValidationError.invalidMCPBridge("environment variables never carry MacRemote's own sign-in")
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
