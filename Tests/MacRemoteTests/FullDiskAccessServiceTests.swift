import Foundation
import Testing
@testable import MacRemote

struct FullDiskAccessServiceTests {
    @Test func remCTLRuntimeFailuresAreNotClassifiedAsFullDiskAccessFailures() {
        let json: [String: Any] = [
            "ok": false,
            "checks": [
                ["name": "python", "status": "fail", "detail": "3.9.6"]
            ]
        ]

        let failedChecks = FullDiskAccessService.failedCheckNames(from: json)

        #expect(failedChecks == ["python"])
        #expect(FullDiskAccessService.failedChecksRequireFullDiskAccess(failedChecks) == false)
    }

    @Test func remCTLProtectedDataFailuresAreClassifiedAsFullDiskAccessFailures() {
        #expect(FullDiskAccessService.failedChecksRequireFullDiskAccess(["database"]))
        #expect(FullDiskAccessService.failedChecksRequireFullDiskAccess(["store_dir"]))
    }

    @Test func genericFDARequiredToolRequiresManualConfirmationWithoutRemCTL() async {
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

        #expect(report.state == .confirmationRequired)
        #expect(report.requiresManualConfirmation)
        #expect(report.automaticChecksPassed)
        #expect(report.confirmationSignature != nil)
        #expect(report.targets.contains { target in
            target.path == "/bin/echo" && target.role == .toolExecutable
        })
        #expect((report.targets.contains { target in
            target.role == .helperReported
        }) == false)
    }

    @Test func layeredTargetsIncludeExecutableForFDARequiredTools() throws {
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

        #expect(targets.contains { target in
            target.path == "/bin/echo" && target.role == .toolExecutable
        })
    }

    @Test func layeredTargetsIncludeInterpreterForScriptTools() throws {
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

        #expect(targets.contains { target in
            target.path == scriptURL.path && target.role == .toolExecutable
        })
        #expect(targets.contains { target in
            target.role == .toolInterpreter && URL(fileURLWithPath: target.path).lastPathComponent.hasPrefix("python")
        })
    }

    @Test func layeredTargetsIncludeResolvedExecutableForSymlinkedTools() throws {
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

        #expect(targets.contains { target in
            target.path == symlinkURL.path && target.role == .toolExecutable
        })
        #expect(targets.contains { target in
            target.path == realScriptURL.path && target.role == .toolExecutable
        })
    }

    @Test func sharedExecutableTargetsUseExecutableNameInsteadOfArbitraryToolName() throws {
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
        let executableTarget = try #require(targets.first { $0.path == "/bin/echo" })

        #expect(executableTarget.title == "echo executable")
        #expect(executableTarget.title.contains("First Action") == false)
        #expect(executableTarget.title.contains("Second Action") == false)
    }

    @Test func envShebangSkipsAssignmentsAndOptionsBeforeInterpreter() throws {
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

        let interpreterPath = try #require(FullDiskAccessService.scriptInterpreterPath(forExecutableAt: scriptURL.path))

        #expect(URL(fileURLWithPath: interpreterPath).lastPathComponent.hasPrefix("python"))
    }

    @Test func mergedTargetsKeepSemanticRoleForDuplicateHelperPaths() {
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

        #expect(targets.count == 1)
        #expect(targets.first?.title == "Tool Python")
        #expect(targets.first?.role == .toolInterpreter)
    }

    @Test func confirmationSignatureTracksToolAndTargetSurface() {
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

        #expect(firstSignature != secondSignature)
    }

    @Test func interpreterProbeInvocationsCoverKnownInterpreters() {
        let sentinel = "/probe/sentinel"

        let python = FullDiskAccessService.probeInvocationArguments(
            forInterpreterAt: "/opt/homebrew/Cellar/python@3.14/3.14.6/bin/python3.14",
            sentinel: sentinel
        )
        #expect(python?.first == "-c")
        #expect(python?.last?.contains(sentinel) == true)

        let node = FullDiskAccessService.probeInvocationArguments(forInterpreterAt: "/usr/local/bin/node", sentinel: sentinel)
        #expect(node?.first == "-e")
        #expect(node?.last?.contains(sentinel) == true)

        let shell = FullDiskAccessService.probeInvocationArguments(forInterpreterAt: "/bin/zsh", sentinel: sentinel)
        #expect(shell?.first == "-c")
        #expect(shell?.last?.contains(sentinel) == true)

        // Unknown interpreters have no safe one-liner: probed at run time.
        #expect(FullDiskAccessService.probeInvocationArguments(forInterpreterAt: "/usr/bin/ruby", sentinel: sentinel) == nil)
        #expect(FullDiskAccessService.probeInvocationArguments(forInterpreterAt: "/usr/local/bin/codex", sentinel: sentinel) == nil)
    }

    @Test func protectedSentinelIsAFullDiskAccessGatedLocation() {
        #expect(FullDiskAccessService.protectedSentinelPath.hasSuffix("/Library/Application Support/com.apple.TCC"))
    }
}
