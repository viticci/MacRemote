import Foundation

struct ToolExecutionOutcome: Sendable, Equatable {
    let toolID: String
    let toolName: String
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let duration: TimeInterval
    let timedOut: Bool
    let truncatedStdout: Bool
    let truncatedStderr: Bool
    let stdoutSpool: ProcessOutputSpool?
    let stdoutBytesAreValidUTF8: Bool
    let stdoutPreservationError: String?
    let upstreamMCPResult: MCPBridgeUpstreamResultContext?
    /// Set when a signal killed the tool; see `CommandRunResult`.
    let terminationSignal: Int32?

    init(
        toolID: String,
        toolName: String,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        duration: TimeInterval,
        timedOut: Bool,
        truncatedStdout: Bool,
        truncatedStderr: Bool,
        stdoutSpool: ProcessOutputSpool? = nil,
        stdoutBytesAreValidUTF8: Bool = true,
        stdoutPreservationError: String? = nil,
        upstreamMCPResult: MCPBridgeUpstreamResultContext? = nil,
        terminationSignal: Int32? = nil
    ) {
        self.toolID = toolID
        self.toolName = toolName
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.duration = duration
        self.timedOut = timedOut
        self.truncatedStdout = truncatedStdout
        self.truncatedStderr = truncatedStderr
        self.stdoutSpool = stdoutSpool
        self.stdoutBytesAreValidUTF8 = stdoutBytesAreValidUTF8
        self.stdoutPreservationError = stdoutPreservationError
        self.upstreamMCPResult = upstreamMCPResult
        self.terminationSignal = terminationSignal
    }

    var succeeded: Bool {
        exitCode == 0 && !timedOut
    }

    var outputByteCount: Int {
        stdoutSpool?.sizeBytes ?? stdout.utf8.count
    }
}

protocol ToolExecuting: Sendable {
    /// Checks a call the way `execute` will, without running anything. The
    /// server calls this before asking the owner to approve, so the owner is
    /// never prompted for a call that cannot run.
    func validate(toolID: String, parameters: [String: ToolArgumentValue]) throws
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome
    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue],
        expectedSecurityFingerprint: String?
    ) async throws -> ToolExecutionOutcome
    /// Where an Upload File call would save its file: the real path its
    /// `path` resolves to now (SPEC D83). The upload keeps it, so the call's
    /// second half saves there or nowhere. Nil for every other call.
    func uploadDestination(toolID: String, parameters: [String: ToolArgumentValue]) -> String?
}

extension ToolExecuting {
    /// Executors with nothing to check in advance accept every call.
    func validate(toolID _: String, parameters _: [String: ToolArgumentValue]) throws {}

    /// Executors without native tools save no uploads.
    func uploadDestination(toolID _: String, parameters _: [String: ToolArgumentValue]) -> String? { nil }

    /// Test/dedicated executors that do not own a mutable catalog may use the
    /// original execution requirement. Production catalog runtimes override
    /// this witness and enforce the expected fingerprint atomically.
    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue],
        expectedSecurityFingerprint _: String?
    ) async throws -> ToolExecutionOutcome {
        try await execute(toolID: toolID, parameters: parameters)
    }
}

struct ConfiguredToolExecutor: ToolExecuting {
    let toolsByID: [String: ToolDefinition]
    private let ambiguousToolIDs: Set<String>
    let environment: [String: String]
    private let runner: any ProcessRunning
    private let mcpBridgeClient = MCPHTTPBridgeClient()
    private let mcpStdioBridgeClient: MCPStdioBridgeClient
    private let nativeToolExecutor: NativeToolExecutor
    private let fileTransferPolicy: FileTransferPathPolicy

    init(
        tools: [ToolDefinition],
        environment: [String: String],
        artifactStore: ArtifactStore = ArtifactStore(),
        runner: any ProcessRunning = ProcessRunner(),
        fileTransferPolicy: FileTransferPathPolicy = FileTransferPathPolicy()
    ) {
        let groupedTools = Dictionary(grouping: tools, by: \.id)
        toolsByID = groupedTools.compactMapValues { matchingTools in
            matchingTools.count == 1 ? matchingTools[0] : nil
        }
        ambiguousToolIDs = Set(groupedTools.compactMap { id, matchingTools in
            matchingTools.count > 1 ? id : nil
        })
        self.environment = environment
        self.runner = runner
        self.mcpStdioBridgeClient = MCPStdioBridgeClient(environment: environment)
        self.nativeToolExecutor = NativeToolExecutor(pathPolicy: fileTransferPolicy, artifactStore: artifactStore)
        self.fileTransferPolicy = fileTransferPolicy
    }

    /// A tool that runs without asking may only be pointed at files inside the
    /// folders the owner allowed. Tools that ask are not checked here: the
    /// owner sees the path on the approval card and decides.
    private func requireReachablePaths(for tool: ToolDefinition, parameters: [String: ToolArgumentValue]) throws {
        guard !tool.asksBeforeRunning else { return }
        for (name, value) in parameters where name != "stdin" {
            let texts: [String]
            switch value {
            case .string(let text): texts = [text]
            case .stringArray(let items): texts = items
            case .json: texts = value.stringArrayValue ?? value.stringValue.map { [$0] } ?? []
            }
            for text in texts {
                do {
                    try fileTransferPolicy.requireReachable(pathLikeValue: text)
                } catch {
                    throw ToolValidationError.constraintViolation(
                        "\(tool.name) runs without asking, so \"\(name)\" can only name files in the folders the owner allowed: "
                            + "\(fileTransferPolicy.allowedFoldersDescription). Paths with \"..\" are not accepted. "
                            + "The owner can add folders in MacRemote Settings."
                    )
                }
            }
        }
    }

    func validate(toolID: String, parameters: [String: ToolArgumentValue]) throws {
        // Unknown and duplicate IDs are reported by `execute`.
        guard let tool = toolsByID[toolID] else { return }
        switch tool.backend {
        case .mcpHTTPBridge, .mcpStdioBridge:
            // The upstream server owns its own argument rules.
            return
        case .native:
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: parameters)
            try nativeToolExecutor.validatePaths(in: parameters)
            try nativeToolExecutor.validateEdit(of: tool, parameters: parameters)
            try nativeToolExecutor.validateUpload(of: tool, parameters: parameters)
        case .process:
            let arguments = try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
            try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: arguments)
            try requireReachablePaths(for: tool, parameters: parameters)
        }
    }

    func uploadDestination(toolID: String, parameters: [String: ToolArgumentValue]) -> String? {
        guard toolsByID[toolID]?.nativeToolID == .fsUploadFile else { return nil }
        return nativeToolExecutor.uploadDestination(parameters)
    }

    func execute(toolID: String, parameters: [String: ToolArgumentValue] = [:]) async throws -> ToolExecutionOutcome {
        if ambiguousToolIDs.contains(toolID) {
            throw ToolIdentifierError.duplicate(toolID)
        }
        guard let tool = toolsByID[toolID] else {
            throw ToolValidationError.unknownTool(toolID)
        }

        if tool.backend == .mcpHTTPBridge {
            return try await mcpBridgeClient.call(tool: tool, parameters: parameters)
        }
        if tool.backend == .mcpStdioBridge {
            return try await mcpStdioBridgeClient.call(tool: tool, parameters: parameters)
        }
        if tool.backend == .native {
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: parameters)
            return try await nativeToolExecutor.execute(
                tool: tool,
                parameters: parameters,
                timeoutSeconds: tool.timeoutSeconds
            )
        }

        do {
            let arguments = try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
            try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: arguments)
            try requireReachablePaths(for: tool, parameters: parameters)
            let standardInput = parameters["stdin"]?.stringValue
            if let suffix = tool.processInvocation?.preflightSuffix {
                let removed = Set(tool.processInvocation?.preflightRemovingArguments ?? [])
                let preflightArguments = arguments.filter { !removed.contains($0) } + suffix
                let preflight = try await runner.run(
                    executablePath: tool.executablePath,
                    arguments: preflightArguments,
                    timeoutSeconds: tool.timeoutSeconds,
                    outputByteLimit: tool.outputByteLimit,
                    environment: environment,
                    standardInput: standardInput
                )
                if preflight.exitCode != 0 || preflight.timedOut {
                    return ToolExecutionOutcome(
                        toolID: toolID,
                        toolName: tool.name,
                        exitCode: preflight.exitCode,
                        stdout: preflight.stdout,
                        stderr: "Preflight failed; the requested change was not applied.\n\(preflight.stderr)",
                        duration: preflight.duration,
                        timedOut: preflight.timedOut,
                        truncatedStdout: preflight.truncatedStdout,
                        truncatedStderr: preflight.truncatedStderr,
                        stdoutSpool: preflight.stdoutSpool,
                        stdoutBytesAreValidUTF8: preflight.stdoutBytesAreValidUTF8,
                        stdoutPreservationError: preflight.stdoutPreservationError,
                        terminationSignal: preflight.terminationSignal
                    )
                }
            }
            let result = try await runner.run(
                executablePath: tool.executablePath,
                arguments: arguments,
                timeoutSeconds: tool.timeoutSeconds,
                outputByteLimit: tool.outputByteLimit,
                environment: environment,
                standardInput: standardInput
            )

            return ToolExecutionOutcome(
                toolID: toolID,
                toolName: tool.name,
                exitCode: result.exitCode,
                stdout: result.stdout,
                stderr: result.stderr,
                duration: result.duration,
                timedOut: result.timedOut,
                truncatedStdout: result.truncatedStdout,
                truncatedStderr: result.truncatedStderr,
                stdoutSpool: result.stdoutSpool,
                stdoutBytesAreValidUTF8: result.stdoutBytesAreValidUTF8,
                stdoutPreservationError: result.stdoutPreservationError,
                terminationSignal: result.terminationSignal
            )
        } catch ProcessRunnerError.executableUnavailable {
            // Preserve the path internally for registry recovery while the MCP
            // error formatter emits a path-free, user-facing message.
            throw ToolValidationError.executableUnavailable(tool.executablePath)
        }
    }

    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue],
        expectedSecurityFingerprint: String?
    ) async throws -> ToolExecutionOutcome {
        if ambiguousToolIDs.contains(toolID) {
            throw ToolIdentifierError.duplicate(toolID)
        }
        guard let tool = toolsByID[toolID] else {
            throw ToolValidationError.unknownTool(toolID)
        }
        if let expectedSecurityFingerprint,
           tool.securityFingerprint != expectedSecurityFingerprint {
            throw ToolSecurityFingerprintError.changed
        }
        return try await execute(toolID: toolID, parameters: parameters)
    }
}
