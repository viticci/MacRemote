import Foundation
import Testing
@testable import MacRemote

struct ToolExecutionAvailabilityTests {
    @Test func launchRaceMapsToPathFreeUnavailableContract() async throws {
        let secretArgument = "--private-terminal-argument"
        let tool = ToolDefinition(
            id: "test_launch_race",
            name: "Launch Race",
            summary: "Exercise a command that disappears immediately before launch.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let executor = ConfiguredToolExecutor(
            tools: [tool],
            environment: ExecutableLocator.toolEnvironment,
            runner: UnavailableAtLaunchProcessRunner()
        )

        do {
            _ = try await executor.execute(
                toolID: tool.id,
                parameters: ["args": .stringArray([secretArgument])]
            )
            Issue.record("A command that disappears at launch must not execute.")
        } catch let error as ToolValidationError {
            #expect(error == .executableUnavailable(tool.executablePath))
            #expect(error.callToolReason == "unavailable")
            let message = error.callToolMessage(
                tool: tool,
                arguments: ["args": .stringArray([secretArgument])]
            )
            #expect(message.contains("not installed or is no longer available"))
            #expect(message.contains(tool.executablePath) == false)
            #expect(message.contains(secretArgument) == false)
            #expect(error.localizedDescription.contains(tool.executablePath) == false)
        }
    }
}

private struct UnavailableAtLaunchProcessRunner: ProcessRunning {
    func run(
        executablePath _: String,
        arguments _: [String],
        timeoutSeconds _: TimeInterval,
        outputByteLimit _: Int,
        environment _: [String: String],
        standardInput _: String?
    ) async throws -> CommandRunResult {
        throw ProcessRunnerError.executableUnavailable
    }
}
