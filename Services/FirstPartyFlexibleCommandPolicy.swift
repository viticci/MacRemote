import Foundation

/// Remote Flexible Commands are intentionally broad, but they never expose
/// credential enrollment, secret-file ingestion, or endpoint redirection.
/// Those workflows remain local operator actions.
enum FirstPartyFlexibleCommandPolicy {
    /// The blocked argument list per command, keyed by executable name. Kept as
    /// data so the consent copy can ask whether a claim is true for a given tool
    /// rather than repeating the list in a string somewhere else.
    private static let blockedArguments: [String: [String]] = [
        "goodlinksctl": ["--api-url", "--token-stdin", "auth", "setup"],
        "habitctl": ["login", "logout", "onboard", "--key"],
        "pocketctl": [
            "login", "--password-file", "--password-env",
            "--api-key-file", "--api-key-env"
        ],
        "pctl": [
            "login", "--password-file", "--password-env",
            "--api-key-file", "--api-key-env"
        ],
        "pocketcasts": [
            "login", "--password-file", "--password-env",
            "--api-key-file", "--api-key-env"
        ],
        "overctl": ["--show-secrets", "--force"],
        "octl": ["--show-secrets", "--force"]
    ]

    /// Ripgrep options that start another program. The Ripgrep Flexible
    /// Command is read-only, so it runs without asking; these would let it
    /// run more than ripgrep.
    private static let ripgrepBlockedOptions = ["--pre", "--hostname-bin"]

    private static let alexandriaBlockedRootCommands: Set<String> = [
        "deploy", "check", "privileged"
    ]

    private static let alexandriaBlockedConnectionOptions: Set<String> = [
        "--host", "--port"
    ]

    private static let alexandriaRootFlagOptions: Set<String> = [
        "--help", "--json", "--no-color", "--version"
    ]

    private static let alexandriaRootValueOptions: Set<String> = [
        "--host", "--port", "--timeout"
    ]

    private static let overCTLBlockedRootCommands: Set<String> = [
        "audio-url", "export", "export-opml", "login", "logout", "upload"
    ]

    private static let overCTLBlockedCommandPaths: Set<[String]> = [
        ["cache", "export"],
        ["protocol", "decode"],
        ["receipts", "clear"]
    ]

    private static let overCTLGlobalFlagOptions: Set<String> = [
        "--json", "--no-color", "--offline", "--verbose", "--version",
        "--install-completion", "--show-completion", "--help", "-h"
    ]

    private static let overCTLGlobalValueOptions: Set<String> = [
        "--output-format", "--source"
    ]

    private static let pocketCTLExecutableNames: Set<String> = [
        "pocketctl", "pocketcasts", "pctl"
    ]

    private static let pocketCTLGlobalFlagOptions: Set<String> = [
        "--help", "--install-completion", "--show-completion", "--verbose",
        "--version", "-v"
    ]

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

    private static let irisExecutableNames: Set<String> = [
        "iris", "iphone"
    ]

    private static let irisBlockedRootCommands: Set<String> = [
        "migrate"
    ]

    private static let irisBlockedCommandPaths: Set<[String]> = [
        ["devices", "pair"],
        ["devices", "authorize"],
        ["devices", "revoke"],
        ["devices", "use"],
        ["transport", "configure"]
    ]

    private static let irisGlobalFlagOptions: Set<String> = [
        "--json", "--dry-run", "-n", "--offline", "--wait", "--no-wait",
        "--version", "--help", "-h"
    ]

    private static let irisGlobalValueOptions: Set<String> = [
        "--confirm", "--timeout", "--device"
    ]

    /// Whether this tool's argument list is policed at all — the honesty check
    /// behind "Sign-in and credential commands stay blocked" in consent copy.
    static func blocksCredentialCommands(in tool: ToolDefinition) -> Bool {
        guard tool.isGenericCLIAdapter else { return false }
        let executable = executableName(of: tool)
        return blockedArguments[executable] != nil
            || musicCTLExecutableNames.contains(executable)
            || irisExecutableNames.contains(executable)
    }

    static func validate(tool: ToolDefinition, arguments: [String]) throws {
        guard tool.isGenericCLIAdapter else { return }
        let executable = executableName(of: tool)
        let lowered = arguments.map { $0.lowercased() }

        if let blocked = blockedArguments[executable] {
            try reject(arguments: lowered, exact: blocked, tool: tool)
        }
        if executable == "rg" {
            try reject(arguments: lowered, exact: ripgrepBlockedOptions, tool: tool)
        }
        if executable == "alexandria" {
            if lowered.contains(where: alexandriaRedirectsEndpoint) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
            if let command = alexandriaRootCommand(in: lowered),
               alexandriaBlockedRootCommands.contains(command) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
        }
        if pocketCTLExecutableNames.contains(executable),
           pocketCTLCommandPath(in: lowered) == ["gemini", "key"] {
            throw ToolValidationError.restrictedFlexibleCommand(tool.id)
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
        if executable == "overctl" || executable == "octl" {
            let path = overCTLCommandPath(in: lowered)
            if let root = path.first,
               overCTLBlockedRootCommands.contains(root) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
            if overCTLBlockedCommandPaths.contains(path) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
        }
        if irisExecutableNames.contains(executable) {
            let path = irisCommandPath(in: lowered)
            if let root = path.first,
               irisBlockedRootCommands.contains(root) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
            if irisBlockedCommandPaths.contains(path) {
                throw ToolValidationError.restrictedFlexibleCommand(tool.id)
            }
        }
    }

    /// Return Alexandria's root command without mistaking a later positional
    /// value such as a note search for an operator command.
    private static func alexandriaRootCommand(in arguments: [String]) -> String? {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if argument == "--" {
                index += 1
            } else if argument == "-h" || matchesAlexandriaOption(option, in: alexandriaRootFlagOptions) {
                index += 1
            } else if matchesAlexandriaOption(option, in: alexandriaRootValueOptions) {
                index += argument.contains("=") ? 1 : 2
            } else {
                return argument
            }
        }
        return nil
    }

    /// Python argparse accepts unambiguous long-option prefixes by default.
    /// Match that behavior so abbreviations cannot bypass the endpoint boundary.
    private static func alexandriaRedirectsEndpoint(_ argument: String) -> Bool {
        let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
        return matchesAlexandriaOption(option, in: alexandriaBlockedConnectionOptions)
    }

    private static func matchesAlexandriaOption(_ candidate: String, in options: Set<String>) -> Bool {
        guard candidate.hasPrefix("--"), candidate.count > 2 else { return false }
        return options.contains(where: { $0.hasPrefix(candidate) })
    }

    /// Extract at most the root and nested command while accepting OverCTL's
    /// documented global options before, between, or after command words.
    private static func overCTLCommandPath(in arguments: [String]) -> [String] {
        var path = [String]()
        var index = 0
        while index < arguments.count, path.count < 2 {
            let argument = arguments[index]
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if argument == "--" || overCTLGlobalFlagOptions.contains(option) {
                index += 1
                continue
            }
            if overCTLGlobalValueOptions.contains(option) {
                index += argument.contains("=") ? 1 : 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            path.append(argument)
            index += 1
            if path.count == 1,
               !["cache", "protocol", "receipts"].contains(path[0]) {
                break
            }
        }
        return path
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

    /// Extract at most the root and nested Iris command while accepting its
    /// documented global options before, between, or after command words.
    private static func irisCommandPath(in arguments: [String]) -> [String] {
        var path = [String]()
        var index = 0
        while index < arguments.count, path.count < 2 {
            let argument = arguments[index]
            let option = argument.split(separator: "=", maxSplits: 1).first.map(String.init) ?? argument
            if argument == "--" || irisGlobalFlagOptions.contains(option) {
                index += 1
                continue
            }
            if irisGlobalValueOptions.contains(option) {
                index += argument.contains("=") ? 1 : 2
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            path.append(argument)
            index += 1
            if path.count == 1,
               !["devices", "transport"].contains(path[0]) {
                break
            }
        }
        return path
    }

    private static func pocketCTLCommandPath(in arguments: [String]) -> [String] {
        var path = [String]()
        var index = 0
        while index < arguments.count, path.count < 2 {
            let argument = arguments[index]
            if argument == "--" || pocketCTLGlobalFlagOptions.contains(argument) {
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                index += 1
                continue
            }
            path.append(argument)
            index += 1
            if path.first != "gemini" {
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
