import Foundation
import Testing
@testable import MacRemote

@Suite("Stable tool identifiers")
struct ToolIdentifierTests {
    @Test func normalizationAndValidationUseCrossHostSafeNames() throws {
        #expect(ToolIdentifier.presetToolID(from: "preset.remctl.today") == "remctl_today")
        #expect(ToolIdentifier.presetToolID(from: "preset.ytdlp.metadata") == "ytdlp_metadata")
        #expect(ToolIdentifier.customToolID(title: "Generate Report!", existingIDs: []) == "custom_generate_report")
        #expect(ToolIdentifier.isValid("openchrome_get_page_content"))
        #expect(!ToolIdentifier.isValid("custom.deadbeef"))
        #expect(!ToolIdentifier.isValid("9invalid"))
        try ToolIdentifier.validate("remctl_today")
    }

    @Test func customAndScannedCollisionsPersistFriendlyNumericSuffixes() {
        #expect(
            ToolIdentifier.customToolID(
                title: "Generate Report",
                existingIDs: ["custom_generate_report"]
            ) == "custom_generate_report_2"
        )
        #expect(
            ToolIdentifier.scannedToolID(
                source: .homebrewFormula,
                binaryName: "rg",
                existingIDs: ["scan_homebrew_formula_rg"]
            ) == "scan_homebrew_formula_rg_2"
        )
    }

    @Test func importedIdentityDependsOnlyOnConfiguredServerAndUpstreamNames() {
        let first = ToolIdentifier.importedMCPToolID(
            serverName: "x-search",
            upstreamToolName: "search_posts_all"
        )
        let second = ToolIdentifier.importedMCPToolID(
            serverName: "x-search",
            upstreamToolName: "search_posts_all"
        )
        #expect(first == "x_search_search_posts_all")
        #expect(second == first)
    }

    @Test func importedIdentityStartingWithDigitsGetsAValidStablePrefix() {
        let id = ToolIdentifier.importedMCPToolID(
            serverName: "123 Server",
            upstreamToolName: "find"
        )
        #expect(id == "tool_123_server_find")
        #expect(ToolIdentifier.isValid(id))

        let collidingID = ToolIdentifier.importedMCPToolID(
            serverName: "123 Server",
            upstreamToolName: "find",
            forceStableSuffix: true
        )
        #expect(collidingID.hasPrefix("tool_123_server_find_"))
        #expect(ToolIdentifier.isValid(collidingID))
    }

    @Test func normalizedImportedCollisionsUseOrderIndependentStableHashes() {
        let hyphenated = ToolIdentifier.importedMCPToolID(
            serverName: "Server",
            upstreamToolName: "find-item",
            forceStableSuffix: true
        )
        let underscored = ToolIdentifier.importedMCPToolID(
            serverName: "Server",
            upstreamToolName: "find_item",
            forceStableSuffix: true
        )
        #expect(hyphenated != underscored)
        #expect(ToolIdentifier.isValid(hyphenated))
        #expect(ToolIdentifier.isValid(underscored))
    }

    @Test func importedToolsHashOnlyOnAnExactCuratedIDCollision() {
        let reservedID = ToolIdentifier.presetToolID(from: "preset.remctl.today")
        let colliding = ToolIdentifier.importedMCPToolID(
            serverName: "remctl",
            upstreamToolName: "today",
            existingIDs: [reservedID]
        )
        let distinct = ToolIdentifier.importedMCPToolID(
            serverName: "remctl",
            upstreamToolName: "experimental_export",
            existingIDs: [reservedID]
        )
        #expect(colliding != "remctl_today")
        #expect(colliding.hasPrefix("remctl_today_"))
        #expect(distinct == "remctl_experimental_export")
        #expect(ToolIdentifier.isValid(colliding))
    }

    @Test func generatedIdentifiersRespectTheMaximumLength() {
        let id = ToolIdentifier.importedMCPToolID(
            serverName: String(repeating: "server", count: 20),
            upstreamToolName: String(repeating: "tool", count: 20)
        )
        #expect(id.count == ToolIdentifier.maximumLength)
        #expect(ToolIdentifier.isValid(id))
    }

    @Test func completeCatalogHasValidUniqueSemanticIDs() throws {
        let ids = DefaultToolPresetCatalog.presets.map(\.toolID) + FileTransferToolCatalog.builtInTools.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ids {
            try ToolIdentifier.validate(id)
        }
    }
}
