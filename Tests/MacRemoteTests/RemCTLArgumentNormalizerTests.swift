import XCTest
@testable import MacRemote

final class RemCTLArgumentNormalizerTests: XCTestCase {
    func testResolvesReminderDeepLinkUUIDToNumericID() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: [
                "edit",
                "x-apple-reminderkit://REMCDReminder/4A0782C7-06B0-494A-B0BA-F399A270BCD4",
                "-d",
                "2026-06-24T18:30:00",
                "--json"
            ]
        ) { uuid in
            XCTAssertEqual(uuid, "4A0782C7-06B0-494A-B0BA-F399A270BCD4")
            return 23829
        }

        XCTAssertEqual(
            normalized,
            ["edit", "23829", "-d", "2026-06-24T18:30:00", "--json"]
        )
    }

    func testResolvesBareReminderUUIDToNumericID() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: [
                "edit",
                "4A0782C7-06B0-494A-B0BA-F399A270BCD4",
                "-d",
                "2026-06-24T18:30:00",
                "--json"
            ]
        ) { _ in 23829 }

        XCTAssertEqual(
            normalized,
            ["edit", "23829", "-d", "2026-06-24T18:30:00", "--json"]
        )
    }

    func testStripsPrivateForNormalDueAndAlarmEdits() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: [
                "edit",
                "23829",
                "--private",
                "-d",
                "2026-06-24T18:30:00",
                "--alarm",
                "2026-06-24T18:30:00",
                "--json"
            ]
        ) { _ in nil }

        XCTAssertEqual(
            normalized,
            [
                "edit",
                "23829",
                "-d",
                "2026-06-24T18:30:00",
                "--alarm",
                "2026-06-24T18:30:00",
                "--json"
            ]
        )
    }

    func testKeepsPrivateForPrivateMetadataEdits() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["edit", "23829", "--private", "--section", "NPC", "--json"]
        ) { _ in nil }

        XCTAssertEqual(normalized, ["edit", "23829", "--private", "--section", "NPC", "--json"])
    }

    func testKeepsPrivateForRichURLAttachmentEdits() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["edit", "23829", "--private", "--url", "https://example.com", "--json"]
        ) { _ in nil }

        XCTAssertEqual(normalized, ["edit", "23829", "--private", "--url", "https://example.com", "--json"])
    }

    func testKeepsPrivateForRichURLAttachmentAdds() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["add", "Research", "-l", "Projects", "--private", "--url=https://example.com", "--json"]
        ) { _ in nil }

        XCTAssertEqual(normalized, ["add", "Research", "-l", "Projects", "--private", "--url=https://example.com", "--json"])
    }

    func testLeavesOtherGenericCLIsUntouched() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: codexAdapter(),
            arguments: ["exec", "4A0782C7-06B0-494A-B0BA-F399A270BCD4"]
        ) { _ in
            XCTFail("Non-RemCTL tools should not resolve Reminders UUIDs.")
            return nil
        }

        XCTAssertEqual(normalized, ["exec", "4A0782C7-06B0-494A-B0BA-F399A270BCD4"])
    }

    private func remCTLAdapter() -> ToolDefinition {
        ToolDefinition(
            id: "custom.remctl",
            name: "Run RemCTL",
            summary: "Run RemCTL by passing argv directly.",
            executablePath: "/usr/local/bin/remctl",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)
            ],
            capability: .destructive,
            timeoutSeconds: 30,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .reminders
        )
    }

    private func codexAdapter() -> ToolDefinition {
        ToolDefinition(
            id: "custom.codex",
            name: "Codex CLI",
            summary: "Run Codex by passing argv directly.",
            executablePath: "/usr/local/bin/codex",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)
            ],
            capability: .destructive,
            timeoutSeconds: 60,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer
        )
    }
}
