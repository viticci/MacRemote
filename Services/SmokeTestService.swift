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
            "Could not read Anthropic API key from 1Password."
        case .anthropicAPIKeyLookupFailed(let message):
            "Anthropic API key lookup failed: \(message)"
        }
    }
}

struct SmokeTestService: Sendable {
    static let repositoryRoot = "/Users/viticci/Projects/MacRemote"
    static let scriptPath = "\(repositoryRoot)/script/anthropic_mcp_smoke.py"
    static let opGetPath = "/Users/viticci/bin/op-get"

    private let runner = ProcessRunner()

    func run(
        mode: SmokeTestMode,
        mcpURL: URL,
        environment: [String: String]
    ) async throws -> SmokeTestRunResult {
        var smokeEnvironment = environment
        smokeEnvironment["MACREMOTE_MCP_URL"] = mcpURL.absoluteString

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

    static func arguments(for mode: SmokeTestMode) -> [String] {
        switch mode {
        case .preflight:
            ["--mcp-preflight-only"]
        case .anthropicAPI:
            []
        }
    }

    static func copyCommand(for mode: SmokeTestMode, mcpURL: URL) -> String {
        switch mode {
        case .preflight:
            """
            MACREMOTE_MCP_URL="\(mcpURL.absoluteString)" \\
            ./script/anthropic_mcp_smoke.py --mcp-preflight-only
            """
        case .anthropicAPI:
            """
            ANTHROPIC_API_KEY="$(/Users/viticci/bin/op-get "Anthropic API Key")" \\
            MACREMOTE_MCP_URL="\(mcpURL.absoluteString)" \\
            ./script/anthropic_mcp_smoke.py
            """
        }
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

    private func loadAnthropicAPIKey(environment: [String: String]) async throws -> String {
        let result = try await runner.run(
            executablePath: Self.opGetPath,
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
