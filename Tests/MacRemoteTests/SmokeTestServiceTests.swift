import Foundation
import Testing
@testable import MacRemote

struct SmokeTestServiceTests {
    @Test func preflightArgumentsUseDirectScriptFlag() {
        #expect(SmokeTestService.arguments(for: .preflight) == ["--mcp-preflight-only"])
    }

    @Test func anthropicArgumentsDoNotRequireShellExpansion() {
        #expect(SmokeTestService.arguments(for: .anthropicAPI) == [])
    }

    @Test func preflightCopyCommandUsesMCPURLOnly() throws {
        let url = try #require(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .preflight, mcpURL: url)

        #expect(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
        #expect(command.contains("--mcp-preflight-only"))
        #expect(command.contains("ANTHROPIC_API_KEY") == false)
    }

    @Test func anthropicCopyCommandUsesPlaceholderWithoutLiteralSecret() throws {
        let url = try #require(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .anthropicAPI, mcpURL: url)

        #expect(command.contains("ANTHROPIC_API_KEY=\"<key>\""))
        #expect(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
        #expect(command.contains("--mcp-preflight-only") == false)
    }

    @Test func copyCommandCanTargetCustomSmokeTool() throws {
        let url = try #require(URL(string: "https://example.trycloudflare.com/mcp/abc123"))
        let command = SmokeTestService.copyCommand(for: .preflight, mcpURL: url, toolID: "custom.pocketctl")

        #expect(command.contains("MACREMOTE_SMOKE_TOOL=\"custom.pocketctl\""))
        #expect(command.contains("MACREMOTE_MCP_URL=\"https://example.trycloudflare.com/mcp/abc123\""))
    }

    @Test func summaryPrefersSuccessMarker() {
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

        #expect(SmokeTestService.summary(for: result, mode: .anthropicAPI) == "smoke_test=passed")
    }

    @Test func summaryDoesNotUseStdoutWhenStderrExplainsFailure() {
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

        #expect(
            SmokeTestService.summary(for: result, mode: .preflight) ==
            "Missing --mcp-url or MACREMOTE_MCP_URL."
        )
    }

    @Test func proofMarkersKeepOnlyRedactedStatusLines() {
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

        #expect(
            SmokeTestService.proofMarkers(for: result) ==
            [
                "oauth_status=approved",
                "mcp_url=https://example.trycloudflare.com/mcp/ab...",
                "tool_use[1] name=remctl.today server=macremote",
                "tool_result[1] is_error=false content_bytes=42",
                "smoke_test=passed"
            ]
        )
    }

    @Test func proofRecordClipboardTextIsRedactedAndUseful() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-06-24T00:00:00Z"))
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

        #expect(text.contains("MacRemote Remote MCP Proof"))
        #expect(text.contains("Mode: Anthropic API Smoke"))
        #expect(text.contains("Status: Passed"))
        #expect(text.contains("smoke_test=passed"))
        #expect(text.localizedCaseInsensitiveContains("anthropic_api_key") == false)
        #expect(text.localizedCaseInsensitiveContains("access_token") == false)
    }
}
