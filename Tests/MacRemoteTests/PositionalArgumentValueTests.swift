import Foundation
import Testing
@testable import MacRemote

/// A value that fills a positional argv item on its own must stay an input.
/// With a leading dash the command would read it as an option instead.
@Suite("Positional argument values")
struct PositionalArgumentValueTests {
    private func fixedTool(
        argumentPattern: [String] = ["-n", "{pattern}", "{path}"],
        parameters: [ToolParameter]? = nil,
        processInvocation: ProcessInvocation? = nil
    ) -> ToolDefinition {
        ToolDefinition(
            id: "custom.positional",
            name: "Positional",
            summary: "Exercises positional values.",
            executablePath: "/usr/bin/grep",
            argumentPattern: argumentPattern,
            parameters: parameters ?? [
                ToolParameter(name: "pattern", title: "Pattern", kind: .string),
                ToolParameter(name: "path", title: "Path", kind: .string)
            ],
            processInvocation: processInvocation,
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024,
            origin: .userDefined
        )
    }

    @Test("Fixed Command placeholders reject values that start with a dash")
    func placeholderRejectsOptionLikeValue() throws {
        let tool = fixedTool()
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "pattern": .string("needle"),
            "path": .string("/tmp/file.txt")
        ]) == ["-n", "needle", "/tmp/file.txt"])

        for (name, value) in [("pattern", "--version"), ("path", "-r"), ("pattern", "-")] {
            var parameters: [String: ToolArgumentValue] = [
                "pattern": .string("needle"),
                "path": .string("/tmp/file.txt")
            ]
            parameters[name] = .string(value)
            #expect(throws: ToolValidationError.optionLikeValue(name)) {
                try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
            }
        }
    }

    @Test("Negative numbers, fixed choices, and array items follow the same rule")
    func allowedDashValues() throws {
        let tool = fixedTool(
            argumentPattern: ["{mode}", "{offset}", "{paths}"],
            parameters: [
                ToolParameter(name: "mode", title: "Mode", kind: .string, allowedValues: ["-c", "-l"]),
                ToolParameter(name: "offset", title: "Offset", kind: .string),
                ToolParameter(name: "paths", title: "Paths", kind: .stringArray)
            ]
        )
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "mode": .string("-c"),
            "offset": .string("-15.5"),
            "paths": .stringArray(["/tmp/a", "/tmp/b"])
        ]) == ["-c", "-15.5", "/tmp/a", "/tmp/b"])

        for offset in ["-1.", "-1.2.3", "-1e5", "-inf"] {
            #expect(throws: ToolValidationError.optionLikeValue("offset")) {
                try ToolArgumentResolver.arguments(for: tool, parameters: [
                    "mode": .string("-c"),
                    "offset": .string(offset),
                    "paths": .stringArray(["/tmp/a"])
                ])
            }
        }
        #expect(throws: ToolValidationError.optionLikeValue("paths")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: [
                "mode": .string("-l"),
                "offset": .string("3"),
                "paths": .stringArray(["/tmp/a", "--null"])
            ])
        }
    }

    @Test("Structured catalog recipes pass dash-leading values unchanged")
    func structuredInvocation() throws {
        let tool = fixedTool(
            argumentPattern: [],
            parameters: [
                ToolParameter(name: "episode", title: "Episode", kind: .string),
                ToolParameter(name: "query", title: "Query", kind: .string, required: false)
            ],
            processInvocation: ProcessInvocation(arguments: [
                .literal("show"),
                .value("episode"),
                .option("--search", "query")
            ])
        )
        // Each recipe is tested against its own CLI; HabitCTL IDs such as
        // "-OwFKFbgUqv0T0pR37dr" start with a dash and must reach it intact.
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "episode": .string("-OwFKFbgUqv0T0pR37dr"),
            "query": .string("-draft")
        ]) == ["show", "-OwFKFbgUqv0T0pR37dr", "--search", "-draft"])
    }

    @Test("Flexible Commands still pass options through")
    func flexibleCommandPassesOptions() throws {
        let tool = fixedTool(
            argumentPattern: ["{args}"],
            parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)]
        )
        #expect(tool.isGenericCLIAdapter)
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "args": .stringArray(["-n", "needle", "/tmp/file.txt"])
        ]) == ["-n", "needle", "/tmp/file.txt"])
    }

    @Test("The Ripgrep Flexible Command blocks options that start other programs")
    func ripgrepFlexibleCommandPolicy() throws {
        let tool = ToolDefinition(
            id: "rg_run",
            name: "Ripgrep CLI",
            summary: "Run ripgrep by passing argv directly.",
            executablePath: "/opt/homebrew/bin/rg",
            argumentPattern: ["{args}"],
            parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
            capability: .readOnly,
            timeoutSeconds: 20,
            outputByteLimit: 1024
        )
        try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: ["--json", "needle", "/tmp"])
        for arguments in [
            ["--pre", "/usr/bin/true", "needle", "/tmp"],
            ["--pre=/usr/bin/true", "needle"],
            ["--PRE=/usr/bin/true", "needle"],
            ["--hostname-bin=/usr/bin/true", "needle"]
        ] {
            #expect(throws: ToolValidationError.restrictedFlexibleCommand("rg_run")) {
                try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: arguments)
            }
        }
    }
}
