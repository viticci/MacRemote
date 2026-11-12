import Foundation
import Testing
@testable import MacRemote

struct FullDiskAccessServiceTests {
    private func protectedTool(executablePath: String = "/bin/echo") -> ToolDefinition {
        ToolDefinition(
            id: "custom_echo",
            name: "Echo",
            summary: "Echo test.",
            executablePath: executablePath,
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.fullDiskAccess]
        )
    }

    @Test func nothingToCheckWhenNoSharedToolNeedsAccess() async {
        let report = await FullDiskAccessService().check(environment: [:], tools: [])
        #expect(report.state == .ready)
        #expect(report.targets.isEmpty)
    }

    /// Tests do not run from an app bundle, so there is nothing to test access
    /// against. The report must say so and ask, never claim a check passed.
    @Test func whenAccessCannotBeTestedTheOwnerIsAskedAndNothingIsClaimed() async {
        let report = await FullDiskAccessService().check(environment: [:], tools: [protectedTool()])

        #expect(report.state == .confirmationRequired)
        #expect(report.requiresManualConfirmation)
        #expect(!report.automaticChecksPassed)
        #expect(report.confirmationSignature != nil)
    }

    /// MacRemote.app is the only thing the owner is ever asked to add: never a
    /// tool's own executable, and never an interpreter such as Python.
    @Test func noToolOrInterpreterIsEverListedAsATarget() {
        let targets = FullDiskAccessService.layeredTargets(for: [protectedTool(executablePath: "/usr/bin/python3")])
        #expect(!targets.contains { $0.path.contains("python") })
        #expect(targets.allSatisfy { $0.path.hasSuffix(".app") })
    }

    @Test func confirmationSignatureTracksToolAndTargetSurface() {
        let firstTool = protectedTool()
        let secondTool = protectedTool(executablePath: "/usr/bin/true")
        let firstTargets = FullDiskAccessService.layeredTargets(for: [firstTool])
        let secondTargets = FullDiskAccessService.layeredTargets(for: [secondTool])

        let firstSignature = FullDiskAccessService.confirmationSignature(for: [firstTool], targets: firstTargets)
        let secondSignature = FullDiskAccessService.confirmationSignature(for: [secondTool], targets: secondTargets)

        #expect(firstSignature != secondSignature)
    }

    @Test func protectedSentinelPrefersRemindersStoreAndOnlyResolvesExistingPaths() {
        // The first candidate is the Reminders store — the same directory the
        // remctl doctor check reads, so chips and Status can never disagree.
        #expect(FullDiskAccessService.protectedSentinelCandidates.first?.hasSuffix("group.com.apple.reminders/Container_v1/Stores") == true)

        // A resolved sentinel must exist: probing a missing path misreads
        // "no such directory" as "no access" (the macOS 27 TCC-dir bug).
        if let sentinel = FullDiskAccessService.resolvedProtectedSentinelPath() {
            #expect(FileManager.default.fileExists(atPath: sentinel))
        }
    }
}
