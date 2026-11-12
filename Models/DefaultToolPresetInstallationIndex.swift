import Foundation

enum DefaultToolPresetInstallationState: Equatable, Sendable {
    case notInstalled
    case current
    case updateAvailable
    case equivalentTool

    var isInstalled: Bool {
        self != .notInstalled
    }
}

struct DefaultToolPresetScanAdoption: Equatable, Sendable {
    let preset: DefaultToolPreset
    let scannedTool: ToolDefinition
}

/// One source of truth for whether a curated preset is already represented in
/// the registry. Stable preset identity is primary; an exact execution
/// signature remains the fallback for custom or legacy tools created before
/// semantic preset IDs existed.
struct DefaultToolPresetInstallationIndex: Equatable, Sendable {
    private let toolIDs: Set<String>
    private let executionSignatures: Set<String>
    private let toolsByID: [String: ToolDefinition]
    private let toolsByExecutionSignature: [String: [ToolDefinition]]

    init(tools: [ToolDefinition]) {
        toolIDs = Set(tools.map(\.id))
        toolsByID = Dictionary(tools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        toolsByExecutionSignature = Dictionary(grouping: tools) {
            Self.executionSignature(
                executablePath: $0.executablePath,
                argumentPattern: $0.argumentPattern,
                processInvocation: $0.processInvocation
            )
        }
        executionSignatures = Set(toolsByExecutionSignature.keys)
    }

    func isInstalled(_ preset: DefaultToolPreset) -> Bool {
        state(for: preset).isInstalled
    }

    func state(for preset: DefaultToolPreset) -> DefaultToolPresetInstallationState {
        if let tool = toolsByID[preset.toolID] {
            return Self.matchesCatalogDefinition(tool, preset: preset)
                ? .current
                : .updateAvailable
        }
        if executionSignatures.contains(Self.executionSignature(for: preset)) {
            return .equivalentTool
        }
        return .notInstalled
    }

    func updateAvailable(_ preset: DefaultToolPreset) -> Bool {
        state(for: preset) == .updateAvailable
    }

    func updateablePresets(in presets: [DefaultToolPreset]) -> [DefaultToolPreset] {
        presets.filter(updateAvailable)
    }

    /// A complete first-party catalog refresh may adopt one scanner-created
    /// equivalent into the catalog's stable semantic identity. Signature
    /// equality alone is not provenance: a hand-authored tool, more than one
    /// matching saved row, or more than one matching preset remains untouched.
    func adoptableScannedTools(in presets: [DefaultToolPreset]) -> [DefaultToolPresetScanAdoption] {
        let presetsBySignature = Dictionary(grouping: presets, by: Self.executionSignature(for:))

        return presets.compactMap { preset in
            guard toolsByID[preset.toolID] == nil else { return nil }
            let signature = Self.executionSignature(for: preset)
            guard presetsBySignature[signature]?.count == 1,
                  let matches = toolsByExecutionSignature[signature],
                  matches.count == 1,
                  let scannedTool = matches.first,
                  scannedTool.origin == .userDefined,
                  scannedTool.backend == .process,
                  scannedTool.provenance != nil else {
                return nil
            }
            return DefaultToolPresetScanAdoption(
                preset: preset,
                scannedTool: scannedTool
            )
        }
    }

    /// Raw scan hits have no curated stable ID, so their existing contract
    /// intentionally remains exact execution-signature matching.
    func containsExecutionSignature(_ signature: String) -> Bool {
        executionSignatures.contains(signature)
    }

    func installedCount(in presets: [DefaultToolPreset]) -> Int {
        presets.count(where: isInstalled)
    }

    /// Returns only presets that can be inserted without replacing an existing
    /// tool. The rolling sets also make repeated IDs or signatures inside one
    /// incoming batch harmless.
    func installablePresets(in presets: [DefaultToolPreset]) -> [DefaultToolPreset] {
        var reservedIDs = toolIDs
        var reservedSignatures = executionSignatures
        var result: [DefaultToolPreset] = []
        result.reserveCapacity(presets.count)

        for preset in presets {
            let signature = Self.executionSignature(for: preset)
            guard !reservedIDs.contains(preset.toolID),
                  !reservedSignatures.contains(signature) else {
                continue
            }

            result.append(preset)
            reservedIDs.insert(preset.toolID)
            reservedSignatures.insert(signature)
        }

        return result
    }

    static func executionSignature(for preset: DefaultToolPreset) -> String {
        executionSignature(
            executablePath: preset.executablePath,
            argumentPattern: preset.argumentPattern,
            processInvocation: preset.processInvocation
        )
    }

    static func executionSignature(
        executablePath: String,
        argumentPattern: [String],
        processInvocation: ProcessInvocation? = nil
    ) -> String {
        guard let processInvocation else {
            return ([executablePath] + argumentPattern).joined(separator: "\u{1f}")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let invocation = Optional(processInvocation)
            .flatMap { try? encoder.encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? ""
        return ([executablePath] + argumentPattern + [invocation]).joined(separator: "\u{1f}")
    }

    private static func matchesCatalogDefinition(
        _ tool: ToolDefinition,
        preset: DefaultToolPreset
    ) -> Bool {
        guard let catalogTool = try? preset.draft.makeTool(
            id: tool.id,
            permissionEpoch: tool.permissionEpoch
        ) else {
            return false
        }
        return catalogTool == tool
    }
}
