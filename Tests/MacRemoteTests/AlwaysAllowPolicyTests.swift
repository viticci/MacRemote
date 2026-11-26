import Foundation
import Testing
@testable import MacRemote

/// D49 — the arithmetic and the consent copy behind Always Allow. These are the
/// two things the Apps page used to get wrong: a denominator that excluded tools
/// it still counted as unallowed, and dialog text with a number typed into it.
struct AlwaysAllowPolicyTests {

    // MARK: - AppToolPolicySummary

    @Test func badgeCountsEveryToolTheAppCanSee() {
        let tools = [
            policyTool(id: "a", approvalPolicy: .standard),
            policyTool(id: "b", approvalPolicy: .standard),
            policyTool(id: "c", approvalPolicy: .everyCall)
        ]
        let summary = AppToolPolicySummary(sharedTools: tools, allowedToolIDs: ["a", "b"])

        #expect(summary.sharedCount == 3)
        #expect(summary.allowedSharedCount == 2)
        #expect(summary.riskySharedCount == 1)
        #expect(summary.asksEveryTimeCount == 1)
        #expect(!summary.allSharedToolsAllowed)
        #expect(summary.badgeText == "2/3 Always Allowed · 1 ask every time")
    }

    /// The bug this whole change exists to kill: parity was unreachable while
    /// any shared tool was every-call, so the verb never retired into its chip.
    @Test func parityIsReachableWithEveryCallToolsInTheSet() {
        let tools = [
            policyTool(id: "a", approvalPolicy: .standard),
            policyTool(id: "b", approvalPolicy: .everyCall)
        ]
        let summary = AppToolPolicySummary(sharedTools: tools, allowedToolIDs: ["a", "b"])

        #expect(summary.allSharedToolsAllowed)
        #expect(summary.asksEveryTimeCount == 0)
        #expect(summary.badgeText == "2/2 Always Allowed")
    }

    /// The count follows each tool's own policy, so it cannot drift from the
    /// catalog the way a literal "12" would.
    @Test func riskyCountIsDerivedFromPolicyNotAConstant() {
        let tools = (0..<20).map {
            policyTool(id: "t\($0)", approvalPolicy: $0 % 4 == 0 ? .everyCall : .standard)
        }
        let summary = AppToolPolicySummary(sharedTools: tools, allowedToolIDs: [])

        #expect(summary.riskySharedCount == 5)
        #expect(summary.asksEveryTimeCount == 5)
    }

    @Test func emptySurfaceIsNeverReportedAsFullyAllowed() {
        let summary = AppToolPolicySummary(sharedTools: [], allowedToolIDs: [])

        #expect(!summary.allSharedToolsAllowed)
        #expect(summary.badgeText == "0/0 Always Allowed")
    }

    /// A grant for a Not Shared tool is real but off-card; the badge speaks
    /// only about what this app can see.
    @Test func grantsForToolsOutsideTheSharedSetDoNotInflateTheBadge() {
        let summary = AppToolPolicySummary(
            sharedTools: [policyTool(id: "a", approvalPolicy: .standard)],
            allowedToolIDs: ["a", "hidden"]
        )

        #expect(summary.allowedSharedCount == 1)
        #expect(summary.badgeText == "1/1 Always Allowed")
    }

    /// D79 — a read-only tool never asks, grant or not, so it has no switch and
    /// counts as running without asking. The tooltip must not claim nothing does.
    @Test func toolsThatNeverAskCountAsRunningWithoutAsking() {
        let tools = [
            policyTool(id: "read", approvalPolicy: .standard, capability: .readOnly),
            policyTool(id: "write", approvalPolicy: .standard)
        ]
        let summary = AppToolPolicySummary(sharedTools: tools, allowedToolIDs: [])

        #expect(summary.allowedSharedCount == 1)
        #expect(summary.badgeText == "1/2 Always Allowed")
        #expect(summary.badgeHelp(clientName: "Claude") == "Claude runs 1 of 2 shared tools without asking.")
    }

    // MARK: - AlwaysAllowConsequence

    @Test func standardToolKeepsTheOrdinaryCaption() {
        let tool = policyTool(id: "notes_search", approvalPolicy: .standard)

        #expect(AlwaysAllowConsequence.text(for: tool, clientName: "Claude") == nil)
    }

    @Test func flexibleCommandConsequenceNamesTheCommandAndTheDefault() throws {
        let tool = policyTool(
            id: "musicctl_run",
            name: "MusicCTL Flexible Command",
            executablePath: "/Users/test/bin/musicctl",
            argumentPattern: ["{args}"],
            approvalPolicy: .everyCall
        )
        let text = try #require(AlwaysAllowConsequence.text(for: tool, clientName: "Claude"))

        #expect(text.contains("Claude can run any musicctl command without asking"))
        #expect(text.contains("normally asks you every time"))
        #expect(text.contains("Sign-in and credential commands stay blocked."))
        #expect(text.contains("You can undo this in Apps."))
    }

    /// The credential clause is a claim about enforcement, so it appears only
    /// where `FirstPartyFlexibleCommandPolicy` actually enforces something.
    @Test func credentialClauseIsOmittedWhenNothingBlocksIt() throws {
        let tool = policyTool(
            id: "remctl_run",
            name: "RemCTL Flexible Command",
            executablePath: "/Users/test/bin/remctl",
            argumentPattern: ["{args}"],
            approvalPolicy: .everyCall
        )
        let text = try #require(AlwaysAllowConsequence.text(for: tool, clientName: "Claude"))

        #expect(text.contains("any remctl command"))
        #expect(!text.contains("credential commands stay blocked"))
    }

    @Test func fixedEveryCallToolNamesTheToolRatherThanTheCommand() throws {
        let tool = policyTool(
            id: "remctl_delete",
            name: "Delete Reminder",
            executablePath: "/Users/test/bin/remctl",
            argumentPattern: ["delete", "{reminder_id}"],
            approvalPolicy: .everyCall
        )
        let text = try #require(AlwaysAllowConsequence.text(for: tool, clientName: "Claude"))

        #expect(text.contains("Claude can run Delete Reminder without asking"))
        #expect(!text.contains("any remctl command"))
    }

    // MARK: - The enforcement the copy points at

    @Test func credentialPolicyStillBlocksRegardlessOfAnyGrant() throws {
        let tool = policyTool(
            id: "musicctl_run",
            name: "MusicCTL Flexible Command",
            executablePath: "/Users/test/bin/musicctl",
            argumentPattern: ["{args}"],
            approvalPolicy: .everyCall
        )

        #expect(FirstPartyFlexibleCommandPolicy.blocksCredentialCommands(in: tool))
        #expect(throws: ToolValidationError.self) {
            try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: ["onboard"])
        }
        #expect(throws: ToolValidationError.self) {
            try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: ["auth", "login"])
        }
        try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: ["doctor", "--json"])
    }

    @Test func musicFlexibleCommandBlocksCredentialRoutesAcrossAliases() throws {
        for executable in ["musicctl", "mctl", "applemusic"] {
            let tool = policyTool(
                id: "\(executable)_run",
                executablePath: "/Users/test/bin/\(executable)",
                argumentPattern: ["{args}"],
                approvalPolicy: .everyCall
            )
            #expect(FirstPartyFlexibleCommandPolicy.blocksCredentialCommands(in: tool))
            for arguments in [
                ["onboard"],
                ["--profile", "default", "onboard"],
                ["--", "request", "GET", "/v1/me/recent/played/tracks"],
                ["auth", "configure"],
                ["auth", "--json", "setup"],
                ["--language=en-US", "auth", "login"],
                ["auth", "--", "logout"],
                ["config", "set", "storefront", "us"],
                ["config", "--no-color", "unset", "storefront"],
                ["search", "songs", "x", "--private-key-file", "/tmp/key.p8"],
                ["--private-key-file=/tmp/key.p8", "doctor"],
                ["auth", "test", "--private-key-stdin"],
                ["doctor", "--reference", "/tmp/profile.json"],
                ["doctor", "--reference=/tmp/profile.json"]
            ] {
                #expect(throws: ToolValidationError.self) {
                    try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: arguments)
                }
            }
            for arguments in [
                ["capabilities"],
                ["schema", "search"],
                ["endpoints"],
                ["doctor", "--json"],
                ["auth", "status"],
                ["auth", "--profile", "default", "test"],
                ["config", "show"],
                ["config", "get", "storefront"],
                ["config", "path"],
                ["search", "songs", "Midnight City"],
                ["player", "pause"],
                ["library", "songs", "--limit", "25"]
            ] {
                try FirstPartyFlexibleCommandPolicy.validate(tool: tool, arguments: arguments)
            }
        }
    }

    @Test func policyReportsNoCredentialBlockingForUnpolicedCommands() {
        let remctl = policyTool(
            id: "remctl_run",
            executablePath: "/Users/test/bin/remctl",
            argumentPattern: ["{args}"],
            approvalPolicy: .everyCall
        )
        // A Fixed Command is out of scope for the policy entirely.
        let fixed = policyTool(
            id: "frames_devices",
            executablePath: "/Users/test/bin/frames",
            argumentPattern: ["list"],
            approvalPolicy: .standard
        )

        #expect(!FirstPartyFlexibleCommandPolicy.blocksCredentialCommands(in: remctl))
        #expect(!FirstPartyFlexibleCommandPolicy.blocksCredentialCommands(in: fixed))
    }
}

private func policyTool(
    id: String,
    name: String = "Tool",
    executablePath: String = "/bin/echo",
    argumentPattern: [String] = ["run"],
    approvalPolicy: ToolApprovalPolicy,
    capability: ToolCapability = .destructive
) -> ToolDefinition {
    ToolDefinition(
        id: id,
        permissionEpoch: "epoch-1",
        name: name,
        summary: "Summary.",
        executablePath: executablePath,
        argumentPattern: argumentPattern,
        parameters: argumentPattern == ["{args}"]
            ? [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)]
            : [],
        capability: capability,
        timeoutSeconds: 10,
        outputByteLimit: 1_024,
        origin: .userDefined,
        category: .utilities,
        approvalPolicy: approvalPolicy
    )
}
