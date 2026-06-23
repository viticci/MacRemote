import XCTest
@testable import MacRemote

final class SmokeTestServiceTests: XCTestCase {
    func testPreflightArgumentsUseDirectScriptFlag() {
        XCTAssertEqual(SmokeTestService.arguments(for: .preflight), ["--mcp-preflight-only"])
    }

    func testAnthropicArgumentsDoNotRequireShellExpansion() {
        XCTAssertEqual(SmokeTestService.arguments(for: .anthropicAPI), [])
    }

    func testPreflightCopyCommandUsesMCPURLOnly() throws {
        let url = try XCTUnwrap(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .preflight, mcpURL: url)

        XCTAssertTrue(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
        XCTAssertTrue(command.contains("--mcp-preflight-only"))
        XCTAssertFalse(command.contains("ANTHROPIC_API_KEY"))
    }

    func testAnthropicCopyCommandRetrievesKeyFromOnePasswordWithoutLiteralSecret() throws {
        let url = try XCTUnwrap(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .anthropicAPI, mcpURL: url)

        XCTAssertTrue(command.contains("ANTHROPIC_API_KEY=\"$(/Users/viticci/bin/op-get \"Anthropic API Key\")\""))
        XCTAssertTrue(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
        XCTAssertFalse(command.contains("--mcp-preflight-only"))
    }

    func testSummaryPrefersSuccessMarker() {
        let result = CommandRunResult(
            executablePath: SmokeTestService.scriptPath,
            arguments: [],
            exitCode: 0,
            stdout: "oauth_status=approved\nsmoke_test=passed\n",
            stderr: "",
            duration: 1,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )

        XCTAssertEqual(SmokeTestService.summary(for: result, mode: .anthropicAPI), "smoke_test=passed")
    }

    func testSummaryDoesNotUseStdoutWhenStderrExplainsFailure() {
        let result = CommandRunResult(
            executablePath: SmokeTestService.scriptPath,
            arguments: [],
            exitCode: 1,
            stdout: "oauth_status=waiting_for_host_approval\n",
            stderr: "Missing --mcp-url or MACREMOTE_MCP_URL.\n",
            duration: 1,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )

        XCTAssertEqual(
            SmokeTestService.summary(for: result, mode: .preflight),
            "Missing --mcp-url or MACREMOTE_MCP_URL."
        )
    }
}
