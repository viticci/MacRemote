import XCTest
@testable import MacRemote

final class ProcessRunnerTests: XCTestCase {
    func testRunnerExecutesWithoutShell() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/echo",
            arguments: ["hello"],
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertEqual(result.arguments, ["hello"])
        XCTAssertEqual(result.executablePath, "/bin/echo")
    }

    func testRunnerAppliesExplicitEnvironment() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/usr/bin/env",
            arguments: [],
            timeoutSeconds: 2,
            outputByteLimit: 4 * 1024,
            environment: ["MACREMOTE_TEST_ENV": "present"]
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertTrue(result.stdout.contains("MACREMOTE_TEST_ENV=present"))
    }

    func testRunnerWritesStandardInput() async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executablePath: "/bin/cat",
            arguments: [],
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            standardInput: "hello stdin"
        )

        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.stdout, "hello stdin")
    }
}
