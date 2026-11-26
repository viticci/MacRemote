import Foundation
import Testing
@testable import MacRemote

struct DefaultToolPresetInstallationIndexTests {
    @Test func oneExactScanProvenanceMatchIsAdoptable() throws {
        let preset = try currentDatePreset()
        let scanned = try scannedEquivalent(of: preset, id: "scan_loose_binary_date")
        let index = DefaultToolPresetInstallationIndex(tools: [scanned])

        #expect(index.state(for: preset) == .equivalentTool)
        #expect(index.adoptableScannedTools(in: [preset]) == [
            DefaultToolPresetScanAdoption(preset: preset, scannedTool: scanned)
        ])
    }

    @Test func handAuthoredEquivalentIsNeverAdoptable() throws {
        let preset = try currentDatePreset()
        let custom = try preset.draft.makeTool(id: "custom_equivalent_date")
        let index = DefaultToolPresetInstallationIndex(tools: [custom])

        #expect(index.state(for: preset) == .equivalentTool)
        #expect(index.adoptableScannedTools(in: [preset]).isEmpty)
    }

    @Test func ambiguousEquivalentRowsAreNeverAdoptable() throws {
        let preset = try currentDatePreset()
        let first = try scannedEquivalent(of: preset, id: "scan_loose_binary_date")
        let second = try scannedEquivalent(of: preset, id: "scan_homebrew_date")
        let index = DefaultToolPresetInstallationIndex(tools: [first, second])

        #expect(index.state(for: preset) == .equivalentTool)
        #expect(index.adoptableScannedTools(in: [preset]).isEmpty)
    }

    @Test func ambiguousPresetContractsAreNeverAdoptable() throws {
        let preset = try currentDatePreset()
        let duplicate = DefaultToolPreset(
            id: "preset.utilities.current_date_duplicate",
            name: "Current Date Duplicate",
            summary: preset.summary,
            executablePath: preset.executablePath,
            argumentPattern: preset.argumentPattern,
            capability: preset.capability,
            category: preset.category,
            timeoutSeconds: preset.timeoutSeconds,
            outputLimitKB: preset.outputLimitKB,
            mode: preset.mode,
            permissionRequirements: preset.permissionRequirements,
            parameters: preset.parameters,
            processInvocation: preset.processInvocation,
            approvalPolicy: preset.approvalPolicy,
            annotationOverrides: preset.annotationOverrides,
            uiActions: preset.uiActions,
            widgetPresentation: preset.widgetPresentation
        )
        let scanned = try scannedEquivalent(of: preset, id: "scan_loose_binary_date")
        let index = DefaultToolPresetInstallationIndex(tools: [scanned])

        #expect(index.adoptableScannedTools(in: [preset, duplicate]).isEmpty)
    }

    private func currentDatePreset() throws -> DefaultToolPreset {
        try #require(
            DefaultToolPresetCatalog.preset(id: "preset.utilities.current_date")
        )
    }

    private func scannedEquivalent(
        of preset: DefaultToolPreset,
        id: String
    ) throws -> ToolDefinition {
        var draft = preset.draft
        draft.provenance = ToolProvenance(
            sourceKind: .looseBinary,
            packageName: nil,
            packageVersion: nil,
            addedDate: Date(timeIntervalSince1970: 1),
            resolvedPathAtAdd: preset.executablePath,
            signingIdentityAtAdd: "unsigned",
            contentSHA256AtAdd: "fixture",
            wasQuarantinedAtAdd: false,
            summaryIsHarvested: false,
            summaryOrigin: nil
        )
        return try draft.makeTool(id: id)
    }
}
