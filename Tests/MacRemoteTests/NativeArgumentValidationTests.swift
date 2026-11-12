import Foundation
import Testing
@testable import MacRemote

@Suite("Native argument validation")
struct NativeArgumentValidationTests {
    @Test("Malformed write input is rejected before touching the destination")
    func malformedWriteDoesNotTouchDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-native-validation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let destination = directory.appendingPathComponent("untouched.txt")
        let tool = FileTransferToolCatalog.writeFileTool
        let executor = ConfiguredToolExecutor(tools: [tool], environment: [:])

        await #expect(throws: ToolValidationError.valueNotAllowed("mode")) {
            _ = try await executor.execute(toolID: tool.id, parameters: [
                "path": .string(destination.path),
                "data": .string("contents"),
                "encoding": .string("utf8"),
                "mode": .string("replace")
            ])
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Wrong optional native types are not silently defaulted")
    func wrongOptionalTypeIsRejected() throws {
        let tool = FileTransferToolCatalog.listTreeTool

        #expect(throws: ToolValidationError.invalidInteger("depth")) {
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: [
                "path": .string(FileManager.default.temporaryDirectory.path),
                "depth": .json(.bool(true))
            ])
        }
        #expect(throws: ToolValidationError.invalidBoolean("include_sizes")) {
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: [
                "path": .string(FileManager.default.temporaryDirectory.path),
                "include_sizes": .string("yes")
            ])
        }
    }

    @Test("Native bounds, enums, unknown inputs, and payload size are enforced")
    func declaredNativeSchemaIsEnforced() throws {
        #expect(throws: ToolValidationError.integerOutOfRange("depth")) {
            try ToolArgumentResolver.validateNativeArguments(
                for: FileTransferToolCatalog.listTreeTool,
                parameters: ["path": .string("/tmp"), "depth": .json(.number(6))]
            )
        }
        #expect(throws: Never.self) {
            try ToolArgumentResolver.validateNativeArguments(
                for: FileTransferToolCatalog.readFileTool,
                parameters: ["path": .string("/tmp/file"), "length": .json(.number(0))]
            )
        }
        #expect(throws: ToolValidationError.invalidInteger("length")) {
            try ToolArgumentResolver.validateNativeArguments(
                for: FileTransferToolCatalog.readFileTool,
                parameters: ["path": .string("/tmp/file"), "length": .json(.bool(false))]
            )
        }
        #expect(throws: ToolValidationError.valueNotAllowed("encoding")) {
            try ToolArgumentResolver.validateNativeArguments(
                for: FileTransferToolCatalog.writeFileTool,
                parameters: ["path": .string("/tmp/file"), "data": .string("x"), "encoding": .string("hex")]
            )
        }
        #expect(throws: ToolValidationError.invalidArgument("surprise")) {
            try ToolArgumentResolver.validateNativeArguments(
                for: FileTransferToolCatalog.statTool,
                parameters: ["path": .string("/tmp"), "surprise": .string("value")]
            )
        }

        let maximum = try #require(
            FileTransferToolCatalog.writeFileTool.parameters.first { $0.name == "data" }?.maximumLength
        )
        #expect(throws: ToolValidationError.stringTooLong("data")) {
            try ToolArgumentResolver.validateNativeArguments(
                for: FileTransferToolCatalog.writeFileTool,
                parameters: ["path": .string("/tmp/file"), "data": .string(String(repeating: "x", count: maximum + 1))]
            )
        }
    }

    @Test("Zip input requires exactly one complete input form")
    func zipInputFormsAreExclusiveAndComplete() throws {
        let tool = FileTransferToolCatalog.downloadZipTool
        #expect(throws: ToolValidationError.constraintViolation("Provide path, or provide both base and paths.")) {
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: [:])
        }
        #expect(throws: ToolValidationError.constraintViolation("Provide path, or provide both base and paths.")) {
            try ToolArgumentResolver.validateNativeArguments(
                for: tool,
                parameters: ["base": .string("/tmp")]
            )
        }
        #expect(throws: ToolValidationError.constraintViolation("Use either path or base with paths, not both.")) {
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: [
                "path": .string("/tmp/file"),
                "base": .string("/tmp"),
                "paths": .stringArray(["file"])
            ])
        }
        #expect(throws: Never.self) {
            try ToolArgumentResolver.validateNativeArguments(
                for: tool,
                parameters: ["path": .string("/tmp/file")]
            )
        }
        #expect(throws: Never.self) {
            try ToolArgumentResolver.validateNativeArguments(for: tool, parameters: [
                "base": .string("/tmp"),
                "paths": .stringArray(["file"])
            ])
        }
    }
}
