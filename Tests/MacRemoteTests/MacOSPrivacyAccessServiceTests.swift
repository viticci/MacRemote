import Foundation
import Testing
@testable import MacRemote

struct MacOSPrivacyAccessServiceTests {
    @Test func automaticallyCheckedRequirementsOnlyIncludeSupportedServices() {
        let tool = ToolDefinition(
            id: "custom.reminders",
            name: "Reminders Tool",
            summary: "Uses Reminders and Screen Recording.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .write,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            permissionRequirements: [.screenRecording, .reminders, .fullDiskAccess]
        )

        #expect(
            MacOSPrivacyAccessService.automaticallyCheckedRequirements(in: [tool]) ==
            [.reminders]
        )
    }

    @Test func reportIsReadyWhenRequiredServicesAreReady() {
        let report = MacOSPrivacyAccessService.report(
            requirements: [.reminders],
            statuses: [.reminders: .ready]
        )

        #expect(report.state == .ready)
        #expect(report.isReady)
        #expect(report.checkedRequirements == [.reminders])
    }

    @Test func reportBlocksWhenRequiredServiceIsDenied() {
        let report = MacOSPrivacyAccessService.report(
            requirements: [.reminders],
            statuses: [.reminders: .denied]
        )

        #expect(report.state == .required([.reminders]))
        #expect(report.isReady == false)
        #expect(report.detail.contains("Grant Reminders access"))
    }
}
