import Foundation

final class ToolSurfaceRuntime: ToolExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private let environment: [String: String]
    private var tools: [ToolDefinition]

    init(tools: [ToolDefinition] = [], environment: [String: String]) {
        self.tools = tools
        self.environment = environment
    }

    func update(tools: [ToolDefinition]) {
        lock.lock()
        self.tools = tools
        lock.unlock()
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
        return try await ConfiguredToolExecutor(
            tools: snapshot,
            environment: environment
        )
        .execute(toolID: toolID, parameters: parameters)
    }
}
