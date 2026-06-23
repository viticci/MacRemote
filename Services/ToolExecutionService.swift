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
    func execute(toolID: String, parameters: [String: String]) async throws -> ToolExecutionOutcome
}

struct RemCTLToolExecutor: ToolExecuting {
    let environment: [String: String]
    private let runner = ProcessRunner()

    func execute(toolID: String, parameters: [String: String] = [:]) async throws -> ToolExecutionOutcome {
        guard let tool = RemCTLToolCatalog.tool(id: toolID) else {
            throw ToolValidationError.unknownTool(toolID)
        }

        let arguments = try RemCTLToolCatalog.arguments(for: toolID, parameters: parameters)
        let result = try await runner.run(
            executablePath: tool.executablePath,
            arguments: arguments,
            timeoutSeconds: tool.timeoutSeconds,
            outputByteLimit: tool.outputByteLimit,
            environment: environment
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
