import Foundation
import Testing
@testable import MacRemote

/// Ports the apps-surface scratch-harness cases for the AP-12 argument
/// re-rendering heuristic (`ApprovalCard.parseArguments`).
@MainActor
struct ApprovalCardArgumentParsingTests {
    @Test func parsesSimplePairs() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "list=Work priority=high")
        #expect(parsed.rows == [KeyValueRow("list", "Work"), KeyValueRow("priority", "high")])
        #expect(parsed.stdinCharacterCount == nil)
    }

    @Test func spacedValuesExtendThePreviousPair() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "args=add Test -l Work due=tomorrow")
        #expect(parsed.rows == [
            KeyValueRow("args", "add Test -l Work"),
            KeyValueRow("due", "tomorrow")
        ])
    }

    @Test func embeddedEqualsStaysInsideTheValue() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "query=status=done limit=5")
        #expect(parsed.rows == [
            KeyValueRow("query", "status=done"),
            KeyValueRow("limit", "5")
        ])
    }

    @Test func extractsStdinSizeIntoItsOwnSlot() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "path=/tmp/report.md stdin=<700 chars>")
        #expect(parsed.rows == [KeyValueRow("path", "/tmp/report.md")])
        #expect(parsed.stdinCharacterCount == 700)
    }

    @Test func stdinOnlyPreviewYieldsNoRows() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "stdin=<4200 chars>")
        #expect(parsed.rows.isEmpty)
        #expect(parsed.stdinCharacterCount == 4200)
    }

    @Test func noArgumentsSentinelParsesEmpty() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "No arguments")
        #expect(parsed == ApprovalCard.ParsedToolArguments())
    }

    @Test func emptyAndWhitespacePreviewsParseEmpty() {
        #expect(ApprovalCard.parseArguments(fromPreview: "") == ApprovalCard.ParsedToolArguments())
        #expect(ApprovalCard.parseArguments(fromPreview: "   ") == ApprovalCard.ParsedToolArguments())
    }

    @Test func unstructurablePreviewFallsBackToRawOnly() {
        // Doesn't open with a key=value pair — the card keeps only the raw string.
        let parsed = ApprovalCard.parseArguments(fromPreview: "delete everything under ~/Documents")
        #expect(parsed == ApprovalCard.ParsedToolArguments())
    }

    @Test func keysMustStartWithLetterOrUnderscore() {
        // "1x=2" is not a valid key, so the preview is unstructurable.
        #expect(ApprovalCard.parseArguments(fromPreview: "1x=2") == ApprovalCard.ParsedToolArguments())
        // "-flag=on" likewise; "_hidden=1" is valid.
        #expect(ApprovalCard.parseArguments(fromPreview: "-flag=on") == ApprovalCard.ParsedToolArguments())
        #expect(
            ApprovalCard.parseArguments(fromPreview: "_hidden=1").rows ==
            [KeyValueRow("_hidden", "1")]
        )
    }

    @Test func malformedStdinTokenStaysARegularRow() {
        let parsed = ApprovalCard.parseArguments(fromPreview: "stdin=<lots chars>")
        #expect(parsed.rows == [KeyValueRow("stdin", "<lots chars>")])
        #expect(parsed.stdinCharacterCount == nil)
    }

    @Test func stdinSummaryFormatsCharactersAndKilobytes() {
        #expect(ApprovalCard.stdinSummary(characterCount: 999) == "999 characters")
        #expect(ApprovalCard.stdinSummary(characterCount: 4200) == "4.2 KB")
    }
}
