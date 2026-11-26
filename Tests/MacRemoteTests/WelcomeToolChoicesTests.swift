import Testing
@testable import MacRemote

@Suite("Welcome tool choices")
struct WelcomeToolChoicesTests {
    @Test("Clean Mac can explicitly add Current Date")
    func cleanMacCurrentDatePath() throws {
        let currentDate = try #require(
            DefaultToolPresetCatalog.preset(id: WelcomeToolChoices.currentDatePresetID)
        )
        let detected = DefaultToolPresetSet(
            id: "set.detected_clis",
            name: "Installed Command-Line Tools",
            summary: "Tools already installed on this Mac.",
            presets: []
        )

        let choices = WelcomeToolChoices.bundles(
            catalogBundles: [detected],
            currentDatePreset: currentDate
        )
        let starter = try #require(
            choices.first { $0.id == WelcomeToolChoices.currentDateBundleID }
        )

        #expect(starter.name == "Current Date")
        #expect(starter.presets.count == 1)
        #expect(starter.presets[0].capability == .readOnly)
        #expect(starter.presets[0].executablePath == "/bin/date")
        #expect(WelcomeToolChoices.initialSelection(in: choices) == ["set.detected_clis"])
        #expect(WelcomeToolChoices.addButtonTitle(selectedCount: 0, newCount: 0) == "Add Tools")

        let selected = WelcomeToolChoices.selectedPresets(
            in: choices,
            selectedBundleIDs: [WelcomeToolChoices.currentDateBundleID]
        )
        #expect(selected == [currentDate])
        #expect(WelcomeToolChoices.addButtonTitle(selectedCount: selected.count, newCount: 1) == "Add 1 Tool")
        #expect(WelcomeToolChoices.canStartConnection(sharedToolCount: selected.count))

        let tool = try selected[0].draft.makeTool(id: selected[0].toolID)
        #expect(tool.name == "Current Date")
        #expect(tool.capability == .readOnly)
    }

    @Test("Current Date stays an explicit choice beside existing bundles")
    func currentDateStaysExplicit() throws {
        let currentDate = try #require(
            DefaultToolPresetCatalog.preset(id: WelcomeToolChoices.currentDatePresetID)
        )
        let existing = DefaultToolPresetSet(
            id: "set.utilities",
            name: "Utilities",
            summary: "Utilities",
            presets: [currentDate]
        )

        let choices = WelcomeToolChoices.bundles(
            catalogBundles: [existing],
            currentDatePreset: currentDate
        )

        #expect(choices.count == 2)
        #expect(choices[0] == existing)
        #expect(choices[1].id == WelcomeToolChoices.currentDateBundleID)
        #expect(choices[1].presets == [currentDate])
    }
}
