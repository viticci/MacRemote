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

    var succeeded: Bool {
        exitCode == 0 && !timedOut
    }

    var outputByteCount: Int {
        stdout.utf8.count
    }
}

protocol ToolExecuting: Sendable {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome
}

struct ConfiguredToolExecutor: ToolExecuting {
    let toolsByID: [String: ToolDefinition]
    let environment: [String: String]
    private let runner = ProcessRunner()
    private let mcpBridgeClient = MCPHTTPBridgeClient()
    private let mcpStdioBridgeClient: MCPStdioBridgeClient
    private let nativeToolExecutor: NativeToolExecutor

    init(
        tools: [ToolDefinition],
        environment: [String: String],
        artifactStore: ArtifactStore = ArtifactStore()
    ) {
        toolsByID = Dictionary(uniqueKeysWithValues: tools.map { ($0.id, $0) })
        self.environment = environment
        self.mcpStdioBridgeClient = MCPStdioBridgeClient(environment: environment)
        self.nativeToolExecutor = NativeToolExecutor(artifactStore: artifactStore)
    }

    func execute(toolID: String, parameters: [String: ToolArgumentValue] = [:]) async throws -> ToolExecutionOutcome {
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
            return try await nativeToolExecutor.execute(
                tool: tool,
                parameters: parameters,
                timeoutSeconds: tool.timeoutSeconds
            )
        }

        var arguments = try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
        arguments = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: tool,
            arguments: arguments,
            runner: runner,
            environment: environment
        )
        let standardInput = parameters["stdin"]?.stringValue
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
            truncatedStderr: result.truncatedStderr
        )
    }
}

struct RemCTLToolExecutor: ToolExecuting {
    let environment: [String: String]

    func execute(toolID: String, parameters: [String: ToolArgumentValue] = [:]) async throws -> ToolExecutionOutcome {
        try await ConfiguredToolExecutor(
            tools: RemCTLToolCatalog.builtInTools,
            environment: environment
        )
        .execute(toolID: toolID, parameters: parameters)
    }
}
