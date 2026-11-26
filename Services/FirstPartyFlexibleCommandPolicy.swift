import Foundation

/// Remote Flexible Commands are intentionally broad, but they never expose
/// credential enrollment, secret-file ingestion, or endpoint redirection.
/// Those workflows remain local operator actions.
enum FirstPartyFlexibleCommandPolicy {
    /// Ripgrep options that start another program. The Ripgrep Flexible
    /// Command is read-only, so it runs without asking; these would let it
    /// run more than ripgrep.
    private static let ripgrepBlockedOptions = ["--pre", "--hostname-bin"]

    /// MusicCTL's process catalog is retired (SPEC D86): its tools now come
    /// from MusicCTL's own MCP server. These rules stay because a legacy
    /// `musicctl_run` process tool keeps working, and keeps this guard, until
    /// the carry-over replaces it with the bridged tool.
    private static let musicCTLExecutableNames: Set<String> = [
        "musicctl", "mctl", "applemusic"
    ]

    private static let musicCTLBlockedRootCommands: Set<String> = [
        "onboard", "request"
    ]

    private static let musicCTLBlockedCommandPaths: Set<[String]> = [
        ["auth", "configure"],
        ["auth", "setup"],
        ["auth", "login"],
        ["auth", "logout"],
        ["config", "set"],
        ["config", "unset"]
    ]

    private static let musicCTLBlockedOptions = [
        "--private-key-file", "--private-key-stdin", "--reference"
    ]

    private static let musicCTLGlobalFlagOptions: Set<String> = [
        "--json", "--no-color", "--version", "--help", "-h"
    ]

    private static let musicCTLGlobalValueOptions: Set<String> = [
        "--profile", "--storefront", "--language"
    ]

    private static let musicCTLNestedRootCommands: Set<String> = [
        "auth", "config"
    ]

    /// Whether this tool's argument list is policed at all — the honesty check
    /// behind "Sign-in and credential commands stay blocked" in consent copy.
    static func blocksCredentialCommands(in tool: ToolDefinition) -> Bool {
        guard tool.isGenericCLIAdapter else { return false }
        return musicCTLExecutableNames.contains(executableName(of: tool))
    }

    static func validate(tool: ToolDefinition, arguments: [String]) throws {
        guard tool.isGenericCLIAdapter else { return }
        let executable = executableName(of: tool)
        let lowered = arguments.map { $0.lowercased() }

        if executable == "rg" {
            try reject(arguments: lowered, exact: ripgrepBlockedOptions, tool: tool)
        }
        if musicCTLExecutableNames.contains(executable) {
            try reject(arguments: lowered, exact: musicCTLBlockedOptions, tool: tool)
            let path = musicCTLCommandPath(in: lowered)
            if let root = path.first,
               musicCTLBlockedRootCommands.contains(root) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
            if musicCTLBlockedCommandPaths.contains(path) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
        }
    }

    /// Extract MusicCTL's root and nested command while accepting documented
    /// global options before, between, or after command words.
    private static func musicCTLCommandPath(in arguments: [String]) -> [String] {
        commandPath(
            in: arguments,
            nestedRoots: musicCTLNestedRootCommands,
            globalFlagOptions: musicCTLGlobalFlagOptions,
            globalValueOptions: musicCTLGlobalValueOptions
        )
    }

    private static func commandPath(
        in arguments: [String],
        nestedRoots: Set<String>,
        globalFlagOptions: Set<String>,
        globalValueOptions: Set<String>
    ) -> [String] {
        var path = [String]()
        var index = 0
        while index < arguments.count, path.count < 2 {
            let argument = arguments[index]
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if argument == "--" || globalFlagOptions.contains(option) {
                index += 1
                continue
            }
            if globalValueOptions.contains(option) {
                index += argument.contains("=") ? 1 : 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            path.append(argument)
            index += 1
            if path.count == 1, !nestedRoots.contains(path[0]) {
                break
            }
        }
        return path
    }

    private static func executableName(of tool: ToolDefinition) -> String {
        URL(fileURLWithPath: tool.executablePath)
            .lastPathComponent
            .lowercased()
    }

    private static func reject(
        arguments: [String],
        exact blockedValues: [String],
        tool: ToolDefinition
    ) throws {
        let blocked = Set(blockedValues)
        if !blocked.isDisjoint(with: arguments) {
            throw ToolValidationError.restrictedFlexibleCommand(tool.id)
        }
        if arguments.contains(where: { argument in
            blocked.contains(where: { argument.hasPrefix("\($0)=") })
        }) {
            throw ToolValidationError.restrictedFlexibleCommand(tool.id)
        }
    }
}
