import Foundation

final class ToolSurfaceRuntime: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let environment: [String: String]
    private let artifactStore: ArtifactStore
    private let mcpBridgeClient = MCPHTTPBridgeClient()
    private let mcpStdioBridgeClient: MCPStdioBridgeClient
    private var tools: [ToolDefinition]
    private var preExecutionCheck: (@Sendable (ToolDefinition) async throws -> Void)?

    init(
        tools: [ToolDefinition] = [],
        environment: [String: String],
        artifactStore: ArtifactStore = ArtifactStore()
    ) {
        self.tools = tools
        self.environment = environment
        self.artifactStore = artifactStore
        self.mcpStdioBridgeClient = MCPStdioBridgeClient(environment: environment)
    }

    func update(tools: [ToolDefinition]) {
        lock.lock()
        self.tools = tools
        lock.unlock()
    }

    /// R16 pre-execution revalidation point for remote MCP calls: the owner
    /// installs a check that throws before a tool whose binary identity
    /// changed since add can run.
    func setPreExecutionCheck(_ check: (@Sendable (ToolDefinition) async throws -> Void)?) {
        lock.lock()
        preExecutionCheck = check
        lock.unlock()
    }

    private func preExecutionCheckSnapshot() -> (@Sendable (ToolDefinition) async throws -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return preExecutionCheck
    }

    func toolsSnapshot() -> [ToolDefinition] {
        lock.lock()
        defer { lock.unlock() }
        return tools
    }

    func tool(id: String) -> ToolDefinition? {
        lock.lock()
        defer { lock.unlock() }
        return tools.first { $0.id == id }
    }

    func execute(toolID: String, parameters: [String: ToolArgumentValue] = [:]) async throws -> ToolExecutionOutcome {
        let snapshot = toolsSnapshot()
        guard let tool = snapshot.first(where: { $0.id == toolID }) else {
            throw ToolValidationError.unknownTool(toolID)
        }
        if let check = preExecutionCheckSnapshot() {
            try await check(tool)
        }
        if tool.backend == .mcpHTTPBridge {
            return try await mcpBridgeClient.call(tool: tool, parameters: parameters)
        }
        if tool.backend == .mcpStdioBridge {
            return try await mcpStdioBridgeClient.call(tool: tool, parameters: parameters)
        }
        return try await ConfiguredToolExecutor(
            tools: snapshot,
            environment: environment,
            artifactStore: artifactStore
        )
            .execute(toolID: toolID, parameters: parameters)
    }
}
