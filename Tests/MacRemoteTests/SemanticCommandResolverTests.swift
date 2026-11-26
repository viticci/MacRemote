import Foundation
import Testing
@testable import MacRemote

@Suite("Semantic process invocation")
struct SemanticCommandResolverTests {
    // The recipes below are saved tools' recipes, not catalog presets: a
    // tool keeps its recipe in tools.json after its catalog is gone (SPEC
    // D88), so the resolver must keep honoring each shape.

    @Test("A choice maps an enum and carries a dry-run preflight")
    func choiceWithPreflight() throws {
        let tool = recipeTool(
            parameters: [
                ToolParameter(name: "habit", title: "Habit", kind: .string, maximumLength: 256),
                ToolParameter(name: "result", title: "Result", kind: .string, allowedValues: ["completed", "failed"]),
                ToolParameter(name: "date", title: "Date", kind: .string, required: false, defaultValue: "today", maximumLength: 64)
            ],
            invocation: ProcessInvocation(
                arguments: [
                    .choice("result", ["completed": ["check"], "failed": ["fail"]]),
                    .value("habit"), .option("--date", "date"), .literal("--json")
                ],
                preflightSuffix: ["--dry-run"]
            )
        )
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "habit": .string("reading"),
            "result": .string("failed")
        ]) == ["fail", "reading", "--date", "today", "--json"])
        #expect(tool.processInvocation?.preflightSuffix == ["--dry-run"])
        #expect(throws: ToolValidationError.self) {
            try ToolArgumentResolver.arguments(for: tool, parameters: [
                "habit": .string("reading"),
                "result": .string("delete")
            ])
        }
    }

    @Test("Optional filters and repeated options lower exactly")
    func repeatedOptions() throws {
        let tool = recipeTool(
            parameters: [
                ToolParameter(name: "query", title: "Query", kind: .string, required: false, maximumLength: 1024),
                ToolParameter(name: "tags", title: "Tags", kind: .stringArray, required: false, maximumLength: 128),
                ToolParameter(name: "read_state", title: "Read State", kind: .string, required: false, defaultValue: "any", allowedValues: ["any", "true", "false"]),
                ToolParameter(name: "limit", title: "Limit", kind: .integer, required: false, defaultValue: "100", integerRange: 1...1000)
            ],
            invocation: ProcessInvocation(arguments: [
                .literal("--json"), .literal("list"),
                .option("--search", "query"),
                .repeatedOption("--tag", "tags"),
                .choice("read_state", ["any": [], "true": ["--read", "true"], "false": ["--read", "false"]]),
                .option("--max-items", "limit")
            ])
        )
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "query": .string("automation"),
            "tags": .stringArray(["apple", "ai"]),
            "read_state": .string("false"),
            "limit": .string("20")
        ]) == [
            "--json", "list", "--search", "automation",
            "--tag", "apple", "--tag", "ai", "--read", "false", "--max-items", "20"
        ])
    }

    @Test("Constraints reject no-op and contradictory changes")
    func updateConstraints() throws {
        let tool = recipeTool(
            parameters: [
                ToolParameter(name: "link_id", title: "Link", kind: .string, maximumLength: 64),
                ToolParameter(name: "read_state", title: "Read State", kind: .string, required: false, defaultValue: "unchanged", allowedValues: ["unchanged", "read", "unread"]),
                ToolParameter(name: "add_tags", title: "Add Tags", kind: .stringArray, required: false, maximumLength: 128),
                ToolParameter(name: "clear_tags", title: "Clear Tags", kind: .boolean, required: false, defaultValue: "false")
            ],
            invocation: ProcessInvocation(
                arguments: [
                    .literal("update"), .value("link_id"),
                    .choice("read_state", ["unchanged": [], "read": ["--read"], "unread": ["--unread"]]),
                    .repeatedOption("--add-tag", "add_tags"),
                    .flag("--clear-tags", "clear_tags")
                ],
                constraints: [
                    .atLeastOne(["read_state", "add_tags", "clear_tags"]),
                    .mutuallyExclusive(["clear_tags", "add_tags"])
                ]
            )
        )
        #expect(throws: ToolValidationError.self) {
            try ToolArgumentResolver.arguments(for: tool, parameters: [
                "link_id": .string("1")
            ])
        }
        #expect(throws: ToolValidationError.self) {
            try ToolArgumentResolver.arguments(for: tool, parameters: [
                "link_id": .string("1"),
                "read_state": .string("unchanged")
            ])
        }
        #expect(throws: ToolValidationError.self) {
            try ToolArgumentResolver.arguments(for: tool, parameters: [
                "link_id": .string("1"),
                "clear_tags": .json(.bool(true)),
                "add_tags": .stringArray(["apple"])
            ])
        }
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "link_id": .string("1"),
            "read_state": .string("read")
        ]) == ["update", "1", "--read"])
    }

    @Test("A delete preflight removes the confirmation before its dry run")
    func deletePreflightRecipe() throws {
        let tool = recipeTool(
            parameters: [ToolParameter(name: "link_id", title: "Link", kind: .string, maximumLength: 64)],
            invocation: ProcessInvocation(
                arguments: [.literal("delete"), .value("link_id"), .literal("--yes")],
                preflightSuffix: ["--dry-run"],
                preflightRemovingArguments: ["--yes"]
            )
        )
        #expect(tool.processInvocation?.preflightSuffix == ["--dry-run"])
        #expect(tool.processInvocation?.preflightRemovingArguments == ["--yes"])
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "link_id": .string("1")
        ]) == ["delete", "1", "--yes"])
    }

    @Test("Frames requires absolute paths and maps layouts")
    func frames() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.frames.frame_video"))
        let tool = try preset.draft.makeTool(id: preset.toolID)
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "paths": .stringArray(["/tmp/a.mov", "/tmp/b.mov"]),
            "output": .string("/tmp/out.mov"),
            "layout": .string("sequential")
        ]) == [
            "--json", "video", "--output", "/tmp/out.mov",
            "--preset", "best", "--rotate", "none",
            "--merge", "--playback-offset", "/tmp/a.mov", "/tmp/b.mov"
        ])
        #expect(throws: ToolValidationError.self) {
            try ToolArgumentResolver.arguments(for: tool, parameters: [
                "paths": .stringArray(["relative.mov"]),
                "output": .string("/tmp/out.mov")
            ])
        }
    }

    @Test("Recipe, enum, and approval changes alter security fingerprints")
    func fingerprints() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.frames.info"))
        let original = try preset.draft.makeTool(id: preset.toolID, permissionEpoch: "epoch")
        var draft = preset.draft
        draft.approvalPolicy = .everyCall
        let everyCall = try draft.makeTool(id: preset.toolID, permissionEpoch: "epoch")
        #expect(original.securityFingerprint != everyCall.securityFingerprint)
    }

    @Test("Failed CLI preflight aborts before mutation")
    func failedPreflightAbortsMutation() async throws {
        let runner = SemanticSequenceProcessRunner(results: [
            semanticRunResult(exitCode: 2, stderr: "dry-run rejected")
        ])
        let tool = semanticPreflightTool()
        let outcome = try await ConfiguredToolExecutor(
            tools: [tool],
            environment: [:],
            runner: runner
        ).execute(toolID: tool.id)

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("Preflight failed"))
        #expect(await runner.arguments() == [["mutate", "--dry-run"]])
    }

    @Test("Successful CLI preflight runs the mutation exactly once")
    func successfulPreflightRunsMutation() async throws {
        let runner = SemanticSequenceProcessRunner(results: [
            semanticRunResult(exitCode: 0, stdout: "preview"),
            semanticRunResult(exitCode: 0, stdout: "applied")
        ])
        let tool = semanticPreflightTool()
        let outcome = try await ConfiguredToolExecutor(
            tools: [tool],
            environment: [:],
            runner: runner
        ).execute(toolID: tool.id)

        #expect(outcome.succeeded)
        #expect(outcome.stdout == "applied")
        #expect(await runner.arguments() == [
            ["mutate", "--dry-run"],
            ["mutate"]
        ])
    }
}

private actor SemanticSequenceProcessRunner: ProcessRunning {
    struct Call: Sendable {
        let arguments: [String]
    }

    private var results: [CommandRunResult]
    private var calls: [Call] = []

    init(results: [CommandRunResult]) {
        self.results = results
    }

    func run(
        executablePath _: String,
        arguments: [String],
        timeoutSeconds _: TimeInterval,
        outputByteLimit _: Int,
        environment _: [String: String],
        standardInput _: String?
    ) async throws -> CommandRunResult {
        calls.append(Call(arguments: arguments))
        return results.removeFirst()
    }

    func arguments() -> [[String]] {
        calls.map(\.arguments)
    }
}

private func recipeTool(parameters: [ToolParameter], invocation: ProcessInvocation) -> ToolDefinition {
    ToolDefinition(
        id: "saved_recipe",
        name: "Saved Recipe",
        summary: "A saved tool's recipe.",
        executablePath: "/bin/echo",
        argumentPattern: [],
        parameters: parameters,
        processInvocation: invocation,
        capability: .write,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined
    )
}

private func semanticPreflightTool() -> ToolDefinition {
    ToolDefinition(
        id: "semantic_preflight",
        name: "Semantic Preflight",
        summary: "Test preflight.",
        executablePath: "/bin/echo",
        argumentPattern: [],
        parameters: [],
        processInvocation: ProcessInvocation(
            arguments: [.literal("mutate")],
            preflightSuffix: ["--dry-run"]
        ),
        capability: .write,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined
    )
}

private func semanticRunResult(
    exitCode: Int32,
    stdout: String = "",
    stderr: String = ""
) -> CommandRunResult {
    CommandRunResult(
        executablePath: "/bin/echo",
        arguments: [],
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        duration: 0.01,
        timedOut: false,
        truncatedStdout: false,
        truncatedStderr: false
    )
}
