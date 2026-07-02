import Foundation

/// One command-line tool found by `LocalCLIScanner` (spec §3.1). Inert data:
/// the scanner never turns this into a `ToolDefinition` — promotion happens in
/// the review UI through `makeDraft()` and the ordinary add pipeline.
struct DiscoveredCLICandidate: Identifiable, Hashable, Codable, Sendable {
    enum Source: String, Codable, Hashable, CaseIterable, Sendable {
        case homebrewFormula
        case homebrewTap
        case homebrewCask
        case npmGlobal
        case uvTool
        case pipx
        case pipUser
        case cargo
        case goBinary
        case application
        case looseBinary

        /// Ledger bucket for scan progress and grouping.
        var scanSource: CLIScanSource {
            switch self {
            case .homebrewFormula, .homebrewTap, .homebrewCask: .homebrew
            case .npmGlobal: .npm
            case .uvTool, .pipx, .pipUser: .python
            case .cargo: .cargo
            case .goBinary: .go
            case .application, .looseBinary: .pathFolders
            }
        }

        var displayName: String {
            switch self {
            case .homebrewFormula, .homebrewCask: "Homebrew"
            case .homebrewTap: "a Homebrew tap"
            case .npmGlobal: "npm"
            case .uvTool: "uv"
            case .pipx: "pipx"
            case .pipUser: "pip"
            case .cargo: "Cargo"
            case .goBinary: "Go"
            case .application: "an app on this Mac"
            case .looseBinary: "a folder on your PATH"
            }
        }

        /// Richer metadata wins when two locations resolve to one binary.
        var metadataRichnessRank: Int {
            switch self {
            case .homebrewFormula: 100
            case .homebrewCask: 90
            case .homebrewTap: 85
            case .npmGlobal: 80
            case .uvTool: 70
            case .pipx: 65
            case .pipUser: 60
            case .cargo: 55
            case .goBinary: 50
            case .application: 40
            case .looseBinary: 10
            }
        }
    }

    enum FileKind: Hashable, Codable, Sendable {
        case machO(architectures: [String])
        case universal
        case script(interpreter: String, interpreterMissing: Bool)
    }

    enum SignatureTrust: Hashable, Codable, Sendable {
        case developerID(team: String, name: String?)
        case adhoc
        case unsigned
        case invalid
        case unchecked
    }

    let id: String                    // "scan.<source>.<slug>" — product-minted, never harvested
    let source: Source
    let binaryName: String            // verbatim command name ("rg")
    let stablePath: String            // enumerated bin-dir path (DL-18) → ToolDefinition.executablePath
    let resolvedPath: String          // realpath — dedupe key, classification target, seen-set key
    let resolutionChain: [String]     // for the disclosure's "→" display
    let aliases: [String]             // other in-scope locations of the same realpath
    let packageName: String?
    let version: String?              // sanitized, ≤32; nil ⇒ UI shows "—"
    let summary: String?              // sanitized harvested text, ≤160; nil ⇒ generated fallback at draft time
    let summaryOrigin: String?        // "Homebrew", "npm", "PyPI metadata", "man page", "Homebrew catalog", app name
    let homepage: String?             // display-only; never a tappable link in the row
    let siblingExecutables: [String]  // other bins of the same package
    let installedOnRequest: Bool?     // brew receipts; nil elsewhere
    let installDate: Date?
    let fileKind: FileKind
    let signature: SignatureTrust
    let isQuarantined: Bool
    let originDomain: String?         // kMDItemWhereFroms, Details row only
    let isInterpreter: Bool           // Ring 2
    let isDependencyOnly: Bool        // brew installed_as_dependency — behind the filter
    let suggestedCategory: ToolCategory
    let isNewSinceLastScan: Bool
    // Capability is deliberately NOT a field: it is a constant (.destructive) at draft time — DL-1.

    /// Prefilled review draft (spec §3.3). Capability is hardcoded `.destructive`
    /// (DL-1) and the defaults match `GenericCLIAdapterDescriptor` (DL-9).
    /// Harvested text can never set or lower capability (R5).
    func makeDraft() -> ToolDefinitionDraft {
        var draft = ToolDefinitionDraft()
        draft.mode = .cliAdapter
        draft.name = binaryName
        draft.summary = summary
            ?? "Runs \(binaryName) (found via \(source.displayName)) by passing argv directly."
        draft.executablePath = stablePath
        draft.argumentsText = "{args}"
        draft.capability = .destructive
        draft.category = suggestedCategory
        draft.timeoutSeconds = 60
        draft.outputLimitKB = 2048
        draft.permissionRequirements = []
        return draft
    }

    /// Matches the app's existing "Added ✓" dedupe scheme: a scanned adapter for
    /// a path collides exactly with a preset or hand-added `{args}` adapter.
    var addedSignature: String {
        ([stablePath] + ["{args}"]).joined(separator: "\u{1f}")
    }
}
