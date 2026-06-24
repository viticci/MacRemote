import Foundation

struct SmokeTestRunResult: Sendable, Equatable {
    let mode: SmokeTestMode
    let processResult: CommandRunResult

    var succeeded: Bool {
        processResult.succeeded
    }

    var duration: TimeInterval {
        processResult.duration
    }

    var summary: String {
        SmokeTestService.summary(for: processResult, mode: mode)
    }
}

enum SmokeTestServiceError: LocalizedError, Equatable {
    case missingAnthropicAPIKey
    case anthropicAPIKeyLookupFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAnthropicAPIKey:
            "Set ANTHROPIC_API_KEY or install op-get with an Anthropic API Key item."
        case .anthropicAPIKeyLookupFailed(let message):
            "Anthropic API key lookup failed: \(message)"
        }
    }
}

struct SmokeTestService: Sendable {
    static var repositoryRoot: String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
    }

    static var scriptPath: String {
        URL(fileURLWithPath: repositoryRoot)
            .appendingPathComponent("script/anthropic_mcp_smoke.py")
            .path
    }

    static var opGetPath: String? {
        ExecutableLocator.executablePath(named: "op-get") ??
            ExecutableLocator.executablePath(candidates: ["\(ExecutableLocator.homeDirectory)/bin/op-get"])
    }

    private let runner = ProcessRunner()

    func run(
        mode: SmokeTestMode,
        mcpURL: URL,
        toolID: String?,
        environment: [String: String]
    ) async throws -> SmokeTestRunResult {
        var smokeEnvironment = environment
        smokeEnvironment["MACREMOTE_MCP_URL"] = mcpURL.absoluteString
        if let toolID {
            smokeEnvironment["MACREMOTE_SMOKE_TOOL"] = toolID
        }

        if mode == .anthropicAPI {
            smokeEnvironment["ANTHROPIC_API_KEY"] = try await loadAnthropicAPIKey(environment: environment)
        }

        let result = try await runner.run(
            executablePath: Self.scriptPath,
            arguments: Self.arguments(for: mode),
            timeoutSeconds: Self.timeoutSeconds(for: mode),
            outputByteLimit: 32 * 1024,
            environment: smokeEnvironment
        )

        return SmokeTestRunResult(mode: mode, processResult: result)
    }

    func checkAnthropicAPIKey(environment: [String: String]) async -> AnthropicCredentialState {
        do {
            _ = try await loadAnthropicAPIKey(environment: environment)
            return .ready
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func arguments(for mode: SmokeTestMode) -> [String] {
        switch mode {
        case .preflight:
            ["--mcp-preflight-only"]
        case .anthropicAPI:
            []
        }
    }

    static func copyCommand(for mode: SmokeTestMode, mcpURL: URL, toolID: String? = nil) -> String {
        var lines: [String] = []
        switch mode {
        case .preflight:
            if let toolID {
                lines.append("MACREMOTE_SMOKE_TOOL=\"\(toolID)\"")
            }
            lines.append("MACREMOTE_MCP_URL=\"\(mcpURL.absoluteString)\"")
            lines.append("./script/anthropic_mcp_smoke.py --mcp-preflight-only")
        case .anthropicAPI:
            lines.append("ANTHROPIC_API_KEY=\"<key>\"")
            if let toolID {
                lines.append("MACREMOTE_SMOKE_TOOL=\"\(toolID)\"")
            }
            lines.append("MACREMOTE_MCP_URL=\"\(mcpURL.absoluteString)\"")
            lines.append("./script/anthropic_mcp_smoke.py")
        }
        return lines.enumerated().map { index, line in
            index == lines.count - 1 ? line : "\(line) \\"
        }
        .joined(separator: "\n")
    }

    static func summary(for result: CommandRunResult, mode: SmokeTestMode) -> String {
        if result.succeeded {
            if let marker = firstMatchingLine(in: result.stdout, prefixes: successPrefixes(for: mode)) {
                return marker
            }
            return "\(mode.title) completed successfully."
        }

        if result.timedOut {
            return "\(mode.title) timed out after \(result.duration.formattedDuration)."
        }

        if let stderr = firstMeaningfulLine(in: result.stderr) {
            return stderr
        }

        if let stdout = firstMeaningfulLine(in: result.stdout) {
            return stdout
        }

        return "\(mode.title) exited \(result.exitCode)."
    }

    static func proofMarkers(for result: CommandRunResult) -> [String] {
        var markers = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter(isProofLine)

        if !result.succeeded,
           let failure = firstMeaningfulLine(in: result.stderr) {
            markers.append("stderr=\(failure)")
        }

        return markers
    }

    private static func timeoutSeconds(for mode: SmokeTestMode) -> TimeInterval {
        switch mode {
        case .preflight: 240
        case .anthropicAPI: 300
        }
    }

    private static func successPrefixes(for mode: SmokeTestMode) -> [String] {
        switch mode {
        case .preflight:
            ["mcp_preflight=passed", "anthropic_call=skipped"]
        case .anthropicAPI:
            ["smoke_test=passed", "mcp_tool_result_count=", "mcp_preflight=passed"]
        }
    }

    private static func firstMatchingLine(in output: String, prefixes: [String]) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                prefixes.contains { line.hasPrefix($0) }
            }
    }

    private static func firstMeaningfulLine(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
            .map { String($0.prefix(220)) }
    }

    private static func isProofLine(_ line: String) -> Bool {
        let exactPrefixes = [
            "model=",
            "mcp_url=",
            "tool=",
            "oauth_status=",
            "mcp_preflight=",
            "mcp_protocol_version=",
            "mcp_tool_count=",
            "mcp_tool_use_count=",
            "mcp_tool_result_count=",
            "anthropic_call=",
            "smoke_test="
        ]

        if exactPrefixes.contains(where: line.hasPrefix) {
            return true
        }

        return line.hasPrefix("tool_use[") || line.hasPrefix("tool_result[")
    }

    private func loadAnthropicAPIKey(environment: [String: String]) async throws -> String {
        if let key = environment["ANTHROPIC_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }

        guard let opGetPath = Self.opGetPath else {
            throw SmokeTestServiceError.missingAnthropicAPIKey
        }

        let result = try await runner.run(
            executablePath: opGetPath,
            arguments: ["Anthropic API Key"],
            timeoutSeconds: 15,
            outputByteLimit: 4 * 1024,
            environment: environment
        )

        guard result.succeeded else {
            let message = Self.firstMeaningfulLine(in: result.stderr)
                ?? Self.firstMeaningfulLine(in: result.stdout)
                ?? "op-get exited \(result.exitCode)"
            throw SmokeTestServiceError.anthropicAPIKeyLookupFailed(message)
        }

        let key = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw SmokeTestServiceError.missingAnthropicAPIKey
        }

        return key
    }
}
