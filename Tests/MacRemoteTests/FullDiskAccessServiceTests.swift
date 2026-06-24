import XCTest
@testable import MacRemote

final class FullDiskAccessServiceTests: XCTestCase {
    func testRemCTLRuntimeFailuresAreNotClassifiedAsFullDiskAccessFailures() {
        let json: [String: Any] = [
            "ok": false,
            "checks": [
                ["name": "python", "status": "fail", "detail": "3.9.6"]
            ]
        ]

        let failedChecks = FullDiskAccessService.failedCheckNames(from: json)

        XCTAssertEqual(failedChecks, ["python"])
        XCTAssertFalse(FullDiskAccessService.failedChecksRequireFullDiskAccess(failedChecks))
    }

    func testRemCTLProtectedDataFailuresAreClassifiedAsFullDiskAccessFailures() {
        XCTAssertTrue(FullDiskAccessService.failedChecksRequireFullDiskAccess(["database"]))
        XCTAssertTrue(FullDiskAccessService.failedChecksRequireFullDiskAccess(["store_dir"]))
    }

    func testGenericFDARequiredToolRequiresManualConfirmationWithoutRemCTL() async {
        let tool = ToolDefinition(
            id: "custom.echo",
            name: "Echo",
            summary: "Echo test.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )

        let report = await FullDiskAccessService().check(environment: [:], tools: [tool])

        XCTAssertEqual(report.state, .confirmationRequired)
        XCTAssertTrue(report.requiresManualConfirmation)
        XCTAssertTrue(report.automaticChecksPassed)
        XCTAssertNotNil(report.confirmationSignature)
        XCTAssertTrue(report.targets.contains { target in
            target.path == "/bin/echo" && target.role == .toolExecutable
        })
        XCTAssertFalse(report.targets.contains { target in
            target.role == .helperReported
        })
    }

    func testLayeredTargetsIncludeExecutableForFDARequiredTools() throws {
        let tool = ToolDefinition(
            id: "custom.echo",
            name: "Echo",
            summary: "Echo test.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )

        let targets = FullDiskAccessService.layeredTargets(for: [tool])

        XCTAssertTrue(targets.contains { target in
            target.path == "/bin/echo" && target.role == .toolExecutable
        })
    }

    func testLayeredTargetsIncludeInterpreterForScriptTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scriptURL = temporaryDirectory.appendingPathComponent("example-tool")
        try """
        #!/usr/bin/env python3
        print("hello")
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let tool = ToolDefinition(
            id: "custom.script",
            name: "Script Tool",
            summary: "Script test.",
            executablePath: scriptURL.path,
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )

        let targets = FullDiskAccessService.layeredTargets(for: [tool])

        XCTAssertTrue(targets.contains { target in
            target.path == scriptURL.path && target.role == .toolExecutable
        })
        XCTAssertTrue(targets.contains { target in
            target.role == .toolInterpreter && URL(fileURLWithPath: target.path).lastPathComponent.hasPrefix("python")
        })
    }

    func testLayeredTargetsIncludeResolvedExecutableForSymlinkedTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let realScriptURL = temporaryDirectory.appendingPathComponent("real-tool")
        try """
        #!/bin/sh
        echo hello
        """.write(to: realScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: realScriptURL.path)

        let symlinkURL = temporaryDirectory.appendingPathComponent("linked-tool")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: realScriptURL)

        let tool = ToolDefinition(
            id: "custom.linked",
            name: "Linked Tool",
            summary: "Symlink test.",
            executablePath: symlinkURL.path,
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )

        let targets = FullDiskAccessService.layeredTargets(for: [tool])

        XCTAssertTrue(targets.contains { target in
            target.path == symlinkURL.path && target.role == .toolExecutable
        })
        XCTAssertTrue(targets.contains { target in
            target.path == realScriptURL.path && target.role == .toolExecutable
        })
    }

    func testSharedExecutableTargetsUseExecutableNameInsteadOfArbitraryToolName() throws {
        let firstTool = ToolDefinition(
            id: "custom.first",
            name: "First Action",
            summary: "First shared executable test.",
            executablePath: "/bin/echo",
            argumentPattern: ["first"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )
        let secondTool = ToolDefinition(
            id: "custom.second",
            name: "Second Action",
            summary: "Second shared executable test.",
            executablePath: "/bin/echo",
            argumentPattern: ["second"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )

        let targets = FullDiskAccessService.layeredTargets(for: [firstTool, secondTool])
        let executableTarget = try XCTUnwrap(targets.first { $0.path == "/bin/echo" })

        XCTAssertEqual(executableTarget.title, "echo executable")
        XCTAssertFalse(executableTarget.title.contains("First Action"))
        XCTAssertFalse(executableTarget.title.contains("Second Action"))
    }

    func testEnvShebangSkipsAssignmentsAndOptionsBeforeInterpreter() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let scriptURL = temporaryDirectory.appendingPathComponent("env-tool")
        try """
        #!/usr/bin/env FOO=bar -S python3 -I
        print("hello")
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let interpreterPath = try XCTUnwrap(FullDiskAccessService.scriptInterpreterPath(forExecutableAt: scriptURL.path))

        XCTAssertTrue(URL(fileURLWithPath: interpreterPath).lastPathComponent.hasPrefix("python"))
    }

    func testMergedTargetsKeepSemanticRoleForDuplicateHelperPaths() {
        let toolTarget = FullDiskAccessTarget(
            title: "Tool Python",
            path: "/usr/bin/python3",
            subtitle: "Generic.",
            role: .toolInterpreter
        )
        let helperTarget = FullDiskAccessTarget(
            title: "Current Python interpreter",
            path: "/usr/bin/python3",
            subtitle: "Helper-specific.",
            role: .helperReported
        )

        let targets = FullDiskAccessService.mergedTargets([toolTarget, helperTarget])

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.title, "Tool Python")
        XCTAssertEqual(targets.first?.role, .toolInterpreter)
    }

    func testConfirmationSignatureTracksToolAndTargetSurface() {
        let firstTool = ToolDefinition(
            id: "custom.echo",
            name: "Echo",
            summary: "Echo test.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )
        let secondTool = ToolDefinition(
            id: "custom.echo",
            name: "Echo",
            summary: "Echo test.",
            executablePath: "/usr/bin/true",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )
        let firstTargets = FullDiskAccessService.layeredTargets(for: [firstTool])
        let secondTargets = FullDiskAccessService.layeredTargets(for: [secondTool])

        let firstSignature = FullDiskAccessService.confirmationSignature(for: [firstTool], targets: firstTargets)
        let secondSignature = FullDiskAccessService.confirmationSignature(for: [secondTool], targets: secondTargets)

        XCTAssertNotEqual(firstSignature, secondSignature)
    }
}
