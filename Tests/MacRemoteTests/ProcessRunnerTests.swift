import Foundation
import Testing
@testable import MacRemote

struct ProcessRunnerTests {
    @Test func runnerExecutesWithoutShell() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/echo",
            arguments: ["hello"],
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )

        #expect(result.succeeded)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(result.arguments == ["hello"])
        #expect(result.executablePath == "/bin/echo")
    }

    @Test func runnerAppliesExplicitEnvironment() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/env",
            arguments: [],
            timeoutSeconds: 2,
            outputByteLimit: 4 * 1024,
            environment: ["MACREMOTE_TEST_ENV": "present"]
        )

        #expect(result.succeeded)
        #expect(result.stdout.contains("MACREMOTE_TEST_ENV=present"))
        #expect(result.stdout.contains("PATH=") == false)
        #expect(result.stdout.contains("ANTHROPIC_API_KEY=") == false)
    }

    @Test func runnerWritesStandardInput() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            standardInput: "hello stdin"
        )

        #expect(result.succeeded)
        #expect(result.stdout == "hello stdin")
    }
}
