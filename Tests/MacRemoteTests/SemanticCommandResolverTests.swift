import Foundation
import Testing
@testable import MacRemote

@Suite("Semantic process invocation")
struct SemanticCommandResolverTests {
    @Test("Habit result maps an enum and carries a dry-run preflight")
    func habitResult() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.habitctl.record_result"))
        let tool = try preset.draft.makeTool(id: preset.toolID)
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

    @Test("Pocket state and queue placement cannot escape their enum maps")
    func pocketEnums() throws {
        let statePreset = try #require(DefaultToolPresetCatalog.preset(id: "preset.pocketctl.update_state"))
        let state = try statePreset.draft.makeTool(id: statePreset.toolID)
        #expect(try ToolArgumentResolver.arguments(for: state, parameters: [
            "episode_uuid": .string("episode"),
            "state": .string("unplayed")
        ]) == ["unplayed", "episode", "--json"])

        let queuePreset = try #require(DefaultToolPresetCatalog.preset(id: "preset.pocketctl.change_up_next"))
        let queue = try queuePreset.draft.makeTool(id: queuePreset.toolID)
        #expect(try ToolArgumentResolver.arguments(for: queue, parameters: [
            "episode_uuid": .string("episode"),
            "placement": .string("remove")
        ]) == ["remove-up-next", "episode", "--json"])
    }

    @Test("GoodLinks optional filters and repeated tags lower exactly")
    func goodLinksSearch() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.goodlinksctl.search"))
        let tool = try preset.draft.makeTool(id: preset.toolID)
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "query": .string("automation"),
            "tags": .stringArray(["apple", "ai"]),
            "read_state": .string("false"),
            "limit": .string("20")
        ]) == [
            "--json", "links", "list", "--search", "automation",
            "--tag", "apple", "--tag", "ai", "--read", "false",
            "--sort", "newestSaved", "--all-pages", "--max-items", "20"
        ])
    }

    @Test("GoodLinks update rejects no-op and contradictory tag changes")
    func goodLinksUpdateConstraints() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.goodlinksctl.update"))
        let tool = try preset.draft.makeTool(id: preset.toolID)
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
        ]) == ["--json", "links", "update", "1", "--read"])
    }

    @Test("GoodLinks delete preflight removes confirmation before dry-run")
    func deletePreflightRecipe() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.goodlinksctl.delete"))
        let tool = try preset.draft.makeTool(id: preset.toolID)
        #expect(tool.processInvocation?.preflightSuffix == ["--dry-run"])
        #expect(tool.processInvocation?.preflightRemovingArguments == ["--yes"])
        #expect(try ToolArgumentResolver.arguments(for: tool, parameters: [
            "link_id": .string("1")
        ]) == ["--json", "links", "delete", "1", "--yes"])
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

    @Test("Flexible credential and endpoint commands are rejected")
    func flexibleGuardrails() throws {
        let tools = [
            try #require(DefaultToolPresetCatalog.preset(id: "preset.habitctl.run")).draft.makeTool(id: "habitctl_run"),
            try #require(DefaultToolPresetCatalog.preset(id: "preset.pocketctl.run")).draft.makeTool(id: "pocketctl_run"),
            try #require(DefaultToolPresetCatalog.preset(id: "preset.goodlinksctl.run")).draft.makeTool(id: "goodlinksctl_run")
        ]
        #expect(throws: ToolValidationError.self) {
            try FirstPartyFlexibleCommandPolicy.validate(tool: tools[0], arguments: ["login"])
        }
        #expect(throws: ToolValidationError.self) {
            try FirstPartyFlexibleCommandPolicy.validate(tool: tools[1], arguments: ["--password-file", "/tmp/secret"])
        }
        #expect(throws: ToolValidationError.self) {
            try FirstPartyFlexibleCommandPolicy.validate(tool: tools[2], arguments: ["--api-url=https://example.com", "links", "list"])
        }
    }

    @Test("Recipe, enum, and approval changes alter security fingerprints")
    func fingerprints() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.habitctl.record_result"))
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
