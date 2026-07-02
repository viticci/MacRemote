import Foundation
import Testing
@testable import MacRemote

struct RemCTLArgumentNormalizerTests {
    @Test func resolvesReminderDeepLinkUUIDToNumericID() async throws {
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
            #expect(uuid == "4A0782C7-06B0-494A-B0BA-F399A270BCD4")
            return 23829
        }

        #expect(
            normalized ==
            ["edit", "23829", "-d", "2026-06-24T18:30:00", "--json"]
        )
    }

    @Test func resolvesBareReminderUUIDToNumericID() async throws {
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

        #expect(
            normalized ==
            ["edit", "23829", "-d", "2026-06-24T18:30:00", "--json"]
        )
    }

    @Test func stripsPrivateForNormalDueAndAlarmEdits() async throws {
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

        #expect(
            normalized ==
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

    @Test func stripsPrivateForNormalAddFields() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: [
                "add",
                "Draft column",
                "--private",
                "-l",
                "Work",
                "-d",
                "2026-06-30 10:00",
                "--alarm",
                "15m",
                "--json"
            ]
        ) { _ in nil }

        #expect(
            normalized ==
            [
                "add",
                "Draft column",
                "-l",
                "Work",
                "-d",
                "2026-06-30 10:00",
                "--alarm",
                "15m",
                "--json"
            ]
        )
    }

    @Test func keepsPrivateForRemCTLPrivateMetadataArguments() async throws {
        let cases = [
            ["add", "Tagged", "--private", "-t", "work", "--json"],
            ["add", "Tagged", "--private", "--tags=work", "--json"],
            ["add", "Linked", "--private", "--url=https://example.com", "--json"],
            ["add", "Groceries", "--private", "--grocery", "--json"],
            ["add", "Sectioned", "--private", "--section", "Research", "--json"],
            ["add", "Sectioned", "--private", "--section-id=DCD255E2-7CF5-4B45-9566-3F9A5D84AFA8", "--json"],
            ["add", "Sectioned", "--private", "--new-section", "Research", "--json"],
            ["add", "Parent", "--private", "--subtask", "Child", "--json"],
            ["add", "Image", "--private", "--image", "/tmp/example.png", "--json"],
            ["add", "Flagged", "--private", "-f", "--json"],
            ["add", "Flagged", "--private", "--flag", "--json"],
            ["add", "Urgent", "--private", "--urgent", "--json"],
            ["add", "Not urgent", "--private", "--no-urgent", "--json"],
            ["add", "Early", "--private", "--early-reminder", "15m", "--json"],
            ["add", "Assigned", "--private", "--assign", "me", "--json"],
            ["add", "Unassigned", "--private", "--unassign", "--json"],
            ["edit", "23829", "--private", "--flagged", "--json"],
            ["edit", "23829", "--private", "--no-flagged", "--json"],
            ["edit", "23829", "--private", "--set-tags", "work,home", "--json"],
            ["edit", "23829", "--private", "--clear-tags", "--json"],
            ["edit", "23829", "--private", "--remove-tag=stale", "--json"],
            ["edit", "23829", "--private", "--location-title", "Apple Park", "--json"],
            ["edit", "23829", "--private", "--latitude", "37.3349", "--json"],
            ["edit", "23829", "--private", "--longitude=-122.0090", "--json"],
            ["edit", "23829", "--private", "--radius", "200", "--json"],
            ["edit", "23829", "--private", "--proximity=leaving", "--json"]
        ]

        for arguments in cases {
            let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
                for: remCTLAdapter(),
                arguments: arguments
            ) { _ in nil }

            #expect(normalized == arguments, "Failed to preserve --private for \(arguments)")
        }
    }

    @Test func keepsPrivateForPrivateMetadataEdits() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["edit", "23829", "--private", "--section", "NPC", "--json"]
        ) { _ in nil }

        #expect(normalized == ["edit", "23829", "--private", "--section", "NPC", "--json"])
    }

    @Test func keepsPrivateForRichURLAttachmentEdits() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["edit", "23829", "--private", "--url", "https://example.com", "--json"]
        ) { _ in nil }

        #expect(normalized == ["edit", "23829", "--private", "--url", "https://example.com", "--json"])
    }

    @Test func keepsPrivateForRichURLAttachmentAdds() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["add", "Research", "-l", "Projects", "--private", "--url=https://example.com", "--json"]
        ) { _ in nil }

        #expect(normalized == ["add", "Research", "-l", "Projects", "--private", "--url=https://example.com", "--json"])
    }

    @Test func keepsPrivateForRealFlagAdds() async throws {
        let normalizedShortFlag = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["add", "Flag me", "-l", "Projects", "--private", "-f", "--json"]
        ) { _ in nil }

        #expect(normalizedShortFlag == ["add", "Flag me", "-l", "Projects", "--private", "-f", "--json"])

        let normalizedLongFlag = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: remCTLAdapter(),
            arguments: ["add", "Flag me", "-l", "Projects", "--private", "--flag", "--json"]
        ) { _ in nil }

        #expect(normalizedLongFlag == ["add", "Flag me", "-l", "Projects", "--private", "--flag", "--json"])
    }

    @Test func keepsPrivateForKnownPrivateMetadataFlagTokens() async throws {
        let flags = [
            "-f",
            "-t",
            "--assign",
            "--early-reminder",
            "--flag",
            "--flagged",
            "--grocery",
            "--image",
            "--latitude",
            "--location-title",
            "--longitude",
            "--new-section",
            "--no-flagged",
            "--no-urgent",
            "--proximity",
            "--radius",
            "--clear-tags",
            "--remove-tag",
            "--section",
            "--section-id",
            "--set-tags",
            "--subtask",
            "--tags",
            "--unassign",
            "--url",
            "--urgent"
        ]

        // Command-specific validity belongs to RemCTL. This test keeps the
        // normalizer's token-level preservation list from regressing silently.
        for flag in flags {
            let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
                for: remCTLAdapter(),
                arguments: ["add", "Research", "--private", flag, "--json"]
            ) { _ in nil }

            #expect(
                normalized.contains("--private"),
                "`--private` should be preserved for \(flag)"
            )
        }
    }

    @Test func keepsPrivateForRemCTL13CommandsWhoseValuesLookLikeOldCommandNames() async throws {
        let cases = [
            ["list-create", "add", "--private", "--symbol", "education3", "--json"],
            ["template-create", "edit", "--from-list", "Projects", "--private", "--json"],
            ["group-create", "show", "--private", "--add-list", "Projects", "--json"],
            ["smart-list-create", "today", "--private", "--flagged", "--json"],
            ["section-create", "search", "-l", "Projects", "--private", "--json"]
        ]

        for arguments in cases {
            let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
                for: remCTLAdapter(),
                arguments: arguments
            ) { _ in nil }

            #expect(normalized == arguments, "Failed to preserve --private for \(arguments)")
        }
    }

    @Test func leavesOtherGenericCLIsUntouched() async throws {
        let normalized = try await RemCTLArgumentNormalizer.normalizedArguments(
            for: codexAdapter(),
            arguments: ["exec", "4A0782C7-06B0-494A-B0BA-F399A270BCD4"]
        ) { _ in
            Issue.record("Non-RemCTL tools should not resolve Reminders UUIDs.")
            return nil
        }

        #expect(normalized == ["exec", "4A0782C7-06B0-494A-B0BA-F399A270BCD4"])
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
