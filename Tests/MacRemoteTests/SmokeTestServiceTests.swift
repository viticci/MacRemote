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

    func testAnthropicCopyCommandUsesPlaceholderWithoutLiteralSecret() throws {
        let url = try XCTUnwrap(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .anthropicAPI, mcpURL: url)

        XCTAssertTrue(command.contains("ANTHROPIC_API_KEY=\"<key>\""))
        XCTAssertTrue(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
        XCTAssertFalse(command.contains("--mcp-preflight-only"))
    }

    func testCopyCommandCanTargetCustomSmokeTool() throws {
        let url = try XCTUnwrap(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .preflight, mcpURL: url, toolID: "custom.pocketctl")

        XCTAssertTrue(command.contains("MACREMOTE_SMOKE_TOOL=\"custom.pocketctl\""))
        XCTAssertTrue(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
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

    func testProofMarkersKeepOnlyRedactedStatusLines() {
        let result = CommandRunResult(
            executablePath: SmokeTestService.scriptPath,
            arguments: [],
            exitCode: 0,
            stdout: """
            oauth_status=approved
            access_token=secret
            mcp_url=https://example.trycloudflare.com/mcp/ab...
            tool_use[1] name=remctl.today server=macremote
            tool_result[1] is_error=false content_bytes=42
            smoke_test=passed
            """,
            stderr: "",
            duration: 1,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )

        XCTAssertEqual(
            SmokeTestService.proofMarkers(for: result),
            [
                "oauth_status=approved",
                "mcp_url=https://example.trycloudflare.com/mcp/ab...",
                "tool_use[1] name=remctl.today server=macremote",
                "tool_result[1] is_error=false content_bytes=42",
                "smoke_test=passed"
            ]
        )
    }

    func testProofRecordClipboardTextIsRedactedAndUseful() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z"))
        let record = SmokeProofRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            date: date,
            mode: .anthropicAPI,
            mcpURL: "https://example.trycloudflare.com/mcp/abc123",
            toolSurface: "10 tools; 9 read-only, 1 host-gated; 1 generic adapters",
            succeeded: true,
            resultSummary: "smoke_test=passed",
            exitCode: 0,
            duration: 1.25,
            markers: ["smoke_test=passed"]
        )

        let text = record.clipboardText

        XCTAssertTrue(text.contains("MacRemote Remote MCP Proof"))
        XCTAssertTrue(text.contains("Mode: Anthropic API Smoke"))
        XCTAssertTrue(text.contains("Status: Passed"))
        XCTAssertTrue(text.contains("smoke_test=passed"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("anthropic_api_key"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("access_token"))
    }
}
