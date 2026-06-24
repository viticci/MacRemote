import XCTest
@testable import MacRemote

final class MacOSPrivacyAccessServiceTests: XCTestCase {
    func testAutomaticallyCheckedRequirementsOnlyIncludeSupportedServices() {
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

        XCTAssertEqual(
            MacOSPrivacyAccessService.automaticallyCheckedRequirements(in: [tool]),
            [.reminders]
        )
    }

    func testReportIsReadyWhenRequiredServicesAreReady() {
        let report = MacOSPrivacyAccessService.report(
            requirements: [.reminders],
            statuses: [.reminders: .ready]
        )

        XCTAssertEqual(report.state, .ready)
        XCTAssertTrue(report.isReady)
        XCTAssertEqual(report.checkedRequirements, [.reminders])
    }

    func testReportBlocksWhenRequiredServiceIsDenied() {
        let report = MacOSPrivacyAccessService.report(
            requirements: [.reminders],
            statuses: [.reminders: .denied]
        )

        XCTAssertEqual(report.state, .required([.reminders]))
        XCTAssertFalse(report.isReady)
        XCTAssertTrue(report.detail.contains("Grant Reminders access"))
    }
}
