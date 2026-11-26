import CryptoKit
import Foundation

/// A first-party CLI that ships its own MCP server.
///
/// MacRemote launches the server over stdio and bridges its tools. The CLI
/// owns tool names, input schemas, descriptions, and result shapes. MacRemote
/// owns transport, sign-in, Mac-side approval, output caps, the widget, and
/// the small amount of product policy declared here.
struct FirstPartyMCPProvider: Identifiable, Hashable, Sendable {
    /// Per-tool policy keyed by the upstream tool name.
    struct ToolPolicy: Hashable, Sendable {
        var approvalPolicy: ToolApprovalPolicy = .standard
        /// Overrides the provider default. `.some(nil)` is not expressible
        /// here on purpose: a tool either refines the presentation or inherits it.
        var widgetPresentation: ToolWidgetPresentation? = nil
        var uiActions: [ToolUIAction]? = nil
        /// Replaces the bridge's 60-second default for a call the CLI itself
        /// lets run long, such as MusicCTL's whole-library New Releases scan.
        var timeoutSeconds: TimeInterval? = nil
    }

    /// Stable provider id, also the Library group id (`provider.remctl`).
    let id: String
    /// Display name (`RemCTL`).
    let name: String
    /// Server name used for bridged tool ids: `remctl` gives `remctl_today`.
    let serverName: String
    let category: ToolCategory
    /// Executable basenames MacRemote looks for, most specific first.
    let executableNames: [String]
    /// Arguments that start the MCP server when appended to the executable.
    let serveArguments: [String]
    /// Presentation every bridged tool inherits unless its policy refines it.
    let widgetPresentation: ToolWidgetPresentation?
    let toolPolicies: [String: ToolPolicy]
    /// Bumped by hand whenever this provider's policy changes, so every
    /// family already added is imported once more and gets the new policy
    /// (SPEC D86). It is saved with the executable's stat line.
    let policyRevision: Int
    /// Process tools an earlier MacRemote installed from a hand-written
    /// catalog for this CLI: tool id → `invocationFingerprint(of:)` of the
    /// command that catalog gave it. Importing the server carries each one
    /// the owner has not edited over to the bridged tool of the same id
    /// (SPEC D86, D87), and removes one no bridged tool takes if the owner
    /// never shared it. RemCTL, NotesCTL, and MusicCTL have one; MailCTL
    /// and PhotoCTL never had such a catalog.
    var legacyInvocationFingerprints: [String: String] = [:]
    /// Executable basenames the retired catalog ran, from any folder.
    var legacyExecutableNames: Set<String> = []

    var legacyProcessToolIDs: Set<String> { Set(legacyInvocationFingerprints.keys) }

    var providerSourcePath: String { serveArguments.joined(separator: " ") }
}

enum FirstPartyMCPProviderCatalog {
    /// Discovery source recorded on candidates and bridged tools that MacRemote
    /// synthesized from an installed first-party executable.
    static let discoverySource = "first_party"

    static let providers: [FirstPartyMCPProvider] = [remCTL, notesCTL, mailCTL, photoCTL, musicCTL]

    static func provider(id: String) -> FirstPartyMCPProvider? {
        providers.first { $0.id == id }
    }

    static func provider(serverName: String) -> FirstPartyMCPProvider? {
        providers.first { $0.serverName == serverName }
    }

    static func provider(forCandidateSource source: String, name: String) -> FirstPartyMCPProvider? {
        guard source == discoverySource else { return nil }
        return provider(serverName: name)
    }

    static func detectedExecutablePath(
        for provider: FirstPartyMCPProvider,
        using locate: (String) -> String? = { ExecutableLocator.executablePath(named: $0) }
    ) -> String? {
        for name in provider.executableNames {
            if let path = locate(name) {
                return path
            }
        }
        return nil
    }

    static func detectedProviders(
        using locate: (String) -> String? = { ExecutableLocator.executablePath(named: $0) }
    ) -> [(provider: FirstPartyMCPProvider, executablePath: String)] {
        providers.compactMap { provider in
            detectedExecutablePath(for: provider, using: locate).map { (provider, $0) }
        }
    }

    static func isFirstPartyExecutableName(_ basename: String) -> Bool {
        let lowered = basename.lowercased()
        return providers.contains { $0.executableNames.contains(lowered) }
    }

    /// Process tools left from a provider's retired hand-written catalog,
    /// whether or not the CLI is installed right now.
    static func legacyProcessTools(
        of provider: FirstPartyMCPProvider,
        in tools: [ToolDefinition]
    ) -> [ToolDefinition] {
        guard !provider.legacyProcessToolIDs.isEmpty else { return [] }
        return tools.filter { $0.backend == .process && provider.legacyProcessToolIDs.contains($0.id) }
    }

    /// True for a process tool installed from a retired first-party catalog,
    /// so the Tools page keeps it with the rest of Federico's tools until
    /// the carry-over replaces it.
    static func isLegacyProcessTool(_ tool: ToolDefinition) -> Bool {
        tool.backend == .process && providers.contains { $0.legacyProcessToolIDs.contains(tool.id) }
    }

    /// True for a legacy process tool still as the retired catalog installed
    /// it: one of the CLI's own executables, in any folder, running the same
    /// arguments and constraints for its id. Only such a row is carried over
    /// (D86). A row the owner pointed at another executable or whose command
    /// they edited is theirs: it stays, with its sharing and its id. Name,
    /// summary, category, and other presentation edits do not count.
    ///
    /// `installedExecutable` is the CLI MacRemote detected. When the row's
    /// executable still exists, it must be that same file (symlinks
    /// followed): a wrapper the owner saved under the CLI's own name is
    /// theirs too (D87). A row whose old path is gone, as after the CLI moved,
    /// still counts as stock.
    static func isUneditedLegacyProcessTool(
        _ tool: ToolDefinition,
        of provider: FirstPartyMCPProvider,
        installedExecutable: String?
    ) -> Bool {
        guard tool.backend == .process,
              let installed = provider.legacyInvocationFingerprints[tool.id] else { return false }
        let executable = URL(fileURLWithPath: tool.executablePath).lastPathComponent
        guard provider.legacyExecutableNames.contains(executable),
              invocationFingerprint(of: tool) == installed else { return false }
        guard FileManager.default.fileExists(atPath: tool.executablePath) else { return true }
        guard let installedExecutable else { return false }
        return URL(fileURLWithPath: tool.executablePath).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: installedExecutable).resolvingSymlinksInPath().path
    }

    /// A short digest of a tool's invocation arguments and constraints. A
    /// tool without a typed invocation runs its plain argument pattern, so
    /// that pattern is the fingerprint (`pattern:{args}`): a Flexible
    /// Command the owner turned into a fixed command no longer matches.
    static func invocationFingerprint(of tool: ToolDefinition) -> String {
        struct Material: Encodable {
            let arguments: [ProcessArgumentRule]
            let constraints: [ProcessInvocationConstraint]
        }
        guard let invocation = tool.processInvocation else {
            return "pattern:" + tool.argumentPattern.joined(separator: " ")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(Material(arguments: invocation.arguments, constraints: invocation.constraints)) else {
            return "unencodable"
        }
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Recognizes a configured MCP server that launches a provider's own
    /// server: `remctl mcp`, `python3 /path/to/remctl mcp`, or
    /// `notesctl mcp serve --client codex`. Symlinks resolve to the same file.
    /// Only the same launch counts: no environment variables, which can point
    /// the server at other data, and the provider's serve arguments, give or
    /// take one `--client <label>` pair. Any other argument may change what
    /// the server does, so that launch stays a server of its own (SPEC D86).
    /// The scanner folds config rows with this rule, and an import adopts a
    /// stored plain family only if its saved launch passes it too.
    static func provider(
        launchedBy command: String,
        args: [String],
        environment: [MCPStdioEnvironmentVariable],
        detectedExecutablePaths: [String: String]
    ) -> FirstPartyMCPProvider? {
        guard environment.isEmpty else { return nil }
        let commandBasename = URL(fileURLWithPath: command).lastPathComponent.lowercased()
        let entrypoint: String
        let serveArgs: [String]
        if Self.interpreterBasenames.contains(where: commandBasename.hasPrefix), let first = args.first {
            entrypoint = first
            serveArgs = Array(args.dropFirst())
        } else {
            entrypoint = command
            serveArgs = args
        }
        let resolvedEntrypoint = URL(fileURLWithPath: entrypoint).resolvingSymlinksInPath().path
        for provider in providers {
            guard let detected = detectedExecutablePaths[provider.id] else { continue }
            let resolvedDetected = URL(fileURLWithPath: detected).resolvingSymlinksInPath().path
            guard resolvedDetected == resolvedEntrypoint,
                  withoutClientLabel(serveArgs) == withoutClientLabel(provider.serveArguments) else { continue }
            return provider
        }
        return nil
    }

    /// Arguments without their first `--client <label>` pair, which only
    /// names the app that launched the server.
    private static func withoutClientLabel(_ args: [String]) -> [String] {
        guard let index = args.firstIndex(of: "--client"), index + 1 < args.count else { return args }
        var args = args
        args.removeSubrange(index...(index + 1))
        return args
    }

    /// The ownership identity of the candidate MacRemote synthesizes for an
    /// installed provider. It is keyed by provider, not by executable path,
    /// so a CLI that moves (`~/bin/remctl` to `~/.local/bin/remctl`) keeps its
    /// imported tools until the next import points them at the new path. The
    /// exact executable stays in the runtime identity and in the approval
    /// fingerprint, so that import still drops Always Allow.
    static func ownerIdentity(for provider: FirstPartyMCPProvider) -> String {
        "\(discoverySource).\(provider.id)"
    }

    /// The key ownership matching compares for one config owner. Tools
    /// imported before owners were keyed by provider carry
    /// `first_party.<serverName>.<path hash>`; both forms map to the
    /// provider's identity. Every other owner is its own key. Only MacRemote
    /// writes the `first_party` source, so no config file can claim it.
    static func ownershipKey(of owner: MCPDiscoveryOwner) -> String {
        guard owner.source == discoverySource else { return owner.serverIdentity }
        let provider = providers.first {
            owner.serverIdentity == ownerIdentity(for: $0)
                || owner.serverIdentity.hasPrefix("\(discoverySource).\($0.serverName).")
        }
        return provider.map(ownerIdentity(for:)) ?? owner.serverIdentity
    }

    /// Applies category, approval, timeout, and widget policy to freshly
    /// bridged tools. Everything else on the tool stays exactly what the
    /// upstream server said, with two exceptions. A tool the server marks
    /// destructive asks on every call, whatever the named policy says, so a
    /// destructive tool a new CLI version adds is guarded the day it appears.
    /// And a tool that asks on every call is never left read-only, because a
    /// read-only tool runs without asking (`asksBeforeRunning`). PhotoCTL
    /// marks its flexible `photoctl_run` read-only; it still asks every time.
    static func applyPolicy(
        _ provider: FirstPartyMCPProvider,
        to tools: [ToolDefinition]
    ) -> [ToolDefinition] {
        // Imported names may be disambiguated when an older process adapter
        // already owns the semantic ID. Bind actions to this imported family,
        // never to the unrelated tool occupying the original name. When two
        // upstream names share one canonical name (`search` and
        // `musicctl_search`), the exact name is the target.
        let actionTargets = Dictionary(
            tools.compactMap { tool -> (String, String, Bool)? in
                guard let name = tool.mcpStdioBridge?.toolName else { return nil }
                let isExact = name.hasPrefix(provider.serverName + "_")
                return (isExact ? name : provider.serverName + "_" + name, tool.id, isExact)
            }
            .sorted { $0.2 && !$1.2 }
            .map { ($0.0, $0.1) },
            uniquingKeysWith: { first, _ in first }
        )
        return tools.map { tool in
            guard let bridge = tool.mcpStdioBridge else { return tool }
            let policy = provider.toolPolicies[bridge.toolName] ?? FirstPartyMCPProvider.ToolPolicy()
            let approvalPolicy = tool.capability == .destructive ? .everyCall : policy.approvalPolicy
            let capability = approvalPolicy == .everyCall && tool.capability == .readOnly
                ? ToolCapability.write
                : tool.capability
            return ToolDefinition(
                id: tool.id,
                permissionEpoch: tool.permissionEpoch,
                name: bridge.toolTitle ?? tool.name,
                summary: tool.summary,
                executablePath: tool.executablePath,
                argumentPattern: tool.argumentPattern,
                parameters: tool.parameters,
                processInvocation: tool.processInvocation,
                capability: capability,
                timeoutSeconds: policy.timeoutSeconds ?? tool.timeoutSeconds,
                outputByteLimit: tool.outputByteLimit,
                origin: tool.origin,
                category: provider.category,
                permissionRequirements: tool.permissionRequirements,
                backend: tool.backend,
                mcpBridge: tool.mcpBridge,
                mcpStdioBridge: tool.mcpStdioBridge,
                nativeToolID: tool.nativeToolID,
                approvalPolicy: approvalPolicy,
                annotationOverrides: tool.annotationOverrides,
                provenance: tool.provenance,
                uiActions: policy.uiActions?.compactMap { action in
                    guard let declaredID = action.toolID, let targetID = actionTargets[declaredID] else { return nil }
                    return ToolUIAction(
                        id: action.id, title: action.title, kind: action.kind,
                        toolID: targetID, arguments: action.arguments,
                        requiredRowFields: action.requiredRowFields,
                        completedWhenField: action.completedWhenField,
                        completedWhenEquals: action.completedWhenEquals,
                        style: action.style, inputs: action.inputs
                    )
                },
                widgetPresentation: policy.widgetPresentation ?? provider.widgetPresentation
            )
        }
    }

    private static let interpreterBasenames = ["python", "node", "bun", "deno", "uv", "ruby", "perl"]

    // MARK: - RemCTL

    private static let remCTLRowActions: [ToolUIAction] = [
        ToolUIAction(
            id: "complete",
            title: "Mark Done",
            kind: .checkOff,
            toolID: "remctl_set_completion",
            arguments: .object([
                "reminder_id": .string("{id}"),
                "completed": .bool(true)
            ]),
            requiredRowFields: ["id"],
            completedWhenField: "completed"
        ),
        ToolUIAction(
            id: "reschedule",
            title: "Reschedule",
            kind: .rowButton,
            toolID: "remctl_update_reminder",
            arguments: .object([
                "reminder_id": .string("{id}"),
                "due": .string("{input.due}")
            ]),
            requiredRowFields: ["id"],
            inputs: [ToolUIActionInput(name: "due", title: "New due", placeholder: "2026-08-01 · 2026-08-01 09:30 · clear")]
        ),
        ToolUIAction(
            id: "rename",
            title: "Edit Title",
            kind: .rowButton,
            toolID: "remctl_update_reminder",
            arguments: .object([
                "reminder_id": .string("{id}"),
                "title": .string("{input.title}")
            ]),
            requiredRowFields: ["id"],
            inputs: [ToolUIActionInput(name: "title", title: "Title", prefillField: "title")]
        ),
        ToolUIAction(
            id: "delete",
            title: "Delete",
            kind: .rowButton,
            toolID: "remctl_delete_reminder",
            arguments: .object(["reminder_id": .string("{id}")]),
            requiredRowFields: ["id"],
            style: .destructive
        )
    ]

    static let remCTL: FirstPartyMCPProvider = {
        let rows = ToolWidgetPresentation(profile: .reminderRows, accent: "#8b5cf6")
        let plain = ToolWidgetPresentation(profile: .semanticResult, accent: "#8b5cf6", automatic: false)
        var policies: [String: FirstPartyMCPProvider.ToolPolicy] = [:]
        for read in ["today", "upcoming", "overdue", "flagged", "search", "show_list", "get_reminder"] {
            policies[read] = .init(uiActions: remCTLRowActions)
        }
        for helper in ["lists", "get_list", "resolve_location", "doctor"] {
            policies[helper] = .init(widgetPresentation: plain)
        }
        policies["delete_reminder"] = .init(approvalPolicy: .everyCall)
        policies["run"] = .init(approvalPolicy: .everyCall, widgetPresentation: plain)
        return FirstPartyMCPProvider(
            id: "provider.remctl",
            name: "RemCTL",
            serverName: "remctl",
            category: .reminders,
            executableNames: ["remctl", "rctl", "reminders"],
            serveArguments: ["mcp"],
            widgetPresentation: rows,
            toolPolicies: policies,
            // 2 (D87): a family imported beside the retired process tools
            // is imported once more, so those tools carry over.
            policyRevision: 2,
            // The nine tools the retired RemCTL process catalog installed
            // (`git show 08e9bf4^:Services/RemCTLToolCatalog.swift`). Five
            // have a server tool of the same id; `remctl_info`,
            // `remctl_create`, `remctl_update`, and `remctl_delete` do not.
            legacyInvocationFingerprints: [
                "remctl_today": "f06f22ee1b530459",
                "remctl_search": "90503fac79688861",
                "remctl_info": "cafdb3bad396599c",
                "remctl_create": "32eb9240a9bde8ec",
                "remctl_update": "25f96f4e53e50be9",
                "remctl_set_completion": "0659f19832020713",
                "remctl_set_flagged": "846873225871a89d",
                "remctl_delete": "96a094dff25c97e1",
                "remctl_run": "pattern:{args}"
            ],
            legacyExecutableNames: ["remctl", "rctl", "reminders"]
        )
    }()

    // MARK: - NotesCTL

    private static let notesCTLRowActions: [ToolUIAction] = [
        ToolUIAction(
            id: "view_note",
            title: "View Note",
            kind: .rowButton,
            toolID: "notesctl_show",
            arguments: .object(["note_id": .string("{identifier}")]),
            requiredRowFields: ["identifier"]
        )
    ]

    static let notesCTL: FirstPartyMCPProvider = {
        let accent = "light-dark(#7a5900, #ffd60a)"
        let rows = ToolWidgetPresentation(profile: .noteRows, accent: accent, rootPath: "result")
        let plain = ToolWidgetPresentation(profile: .semanticResult, accent: accent)
        var policies: [String: FirstPartyMCPProvider.ToolPolicy] = [:]
        for tool in [
            "notesctl_doctor", "notesctl_capabilities", "notesctl_accounts", "notesctl_folders",
            "notesctl_tags", "notesctl_links", "notesctl_attachments", "notesctl_table",
            "notesctl_open_link", "notesctl_mkfolder", "notesctl_move", "notesctl_pin",
            "notesctl_unpin", "notesctl_check", "notesctl_uncheck", "notesctl_checklist_add",
            "notesctl_import_markdown", "notesctl_add_tags"
        ] {
            policies[tool] = .init(widgetPresentation: plain)
        }
        for read in ["notesctl_search", "notesctl_recent"] {
            policies[read] = .init(uiActions: notesCTLRowActions)
        }
        for guarded in ["notesctl_add_content", "notesctl_apply_edit", "notesctl_trash"] {
            policies[guarded] = .init(approvalPolicy: .everyCall)
        }
        policies["notesctl_remove_tags"] = .init(approvalPolicy: .everyCall, widgetPresentation: plain)
        policies["notesctl_run"] = .init(approvalPolicy: .everyCall, widgetPresentation: plain)
        return FirstPartyMCPProvider(
            id: "provider.notesctl",
            name: "NotesCTL",
            serverName: "notesctl",
            category: .notes,
            executableNames: ["notesctl"],
            serveArguments: ["mcp", "serve", "--client", "macremote"],
            widgetPresentation: rows,
            toolPolicies: policies,
            policyRevision: 2,
            // The 19 tools the retired NotesCTL process catalog installed
            // (`git show 08e9bf4^:Services/NotesCTLToolCatalog.swift`). All 19
            // exist on the server under the same ids.
            legacyInvocationFingerprints: [
                "notesctl_doctor": "b514335bf55979c9",
                "notesctl_capabilities": "813d36d01924afc9",
                "notesctl_accounts": "baf5199d0ca1183e",
                "notesctl_folders": "ff6299e81535b4cf",
                "notesctl_tags": "22a6b22c26259545",
                "notesctl_search": "0fb6d43a6630ed79",
                "notesctl_show": "ba9ef41dfada6092",
                "notesctl_recent": "72fe13ed1b557a74",
                "notesctl_create": "2f3f488a97f7d23a",
                "notesctl_preview_add_content": "7b261e27fcb202f8",
                "notesctl_add_content": "4b4f725a53f21d12",
                "notesctl_preview_edit": "4e51f94becec47cf",
                "notesctl_apply_edit": "4460e5e58593f7ca",
                "notesctl_transcribe": "2ba96586528d7f41",
                "notesctl_add_tags": "c2d7255015de019a",
                "notesctl_remove_tags": "f718e4de442324c0",
                "notesctl_preview_trash": "ee3837d0c807feee",
                "notesctl_trash": "c7305c4d850fb041",
                "notesctl_run": "pattern:{args}"
            ],
            legacyExecutableNames: ["notesctl"]
        )
    }()

    // MARK: - MailCTL

    /// Apple Mail through MailCTL's own server. Reads run freely and the
    /// writes ask first, as their annotations say. Archive and move take up to
    /// 100 messages, and a Mail rule acts on every message that arrives, so
    /// those ask every time, like the flexible `mailctl_run`. No MailCTL tool
    /// sends mail. The widget has no mail-row shape, so results use the
    /// semantic card and carry no row actions. Only `mailctl` is looked for:
    /// MailCTL's `mail` alias is also `/usr/bin/mail`, and `mctl` is a name
    /// both MailCTL and MusicCTL install.
    static let mailCTL: FirstPartyMCPProvider = {
        let accent = "light-dark(#0064d1, #0a84ff)"
        let card = ToolWidgetPresentation(profile: .semanticResult, accent: accent)
        let lookup = ToolWidgetPresentation(profile: .semanticResult, accent: accent, automatic: false)
        var policies: [String: FirstPartyMCPProvider.ToolPolicy] = [:]
        for helper in ["mailctl_doctor", "mailctl_capabilities", "mailctl_accounts", "mailctl_mailboxes"] {
            policies[helper] = .init(widgetPresentation: lookup)
        }
        for broad in ["mailctl_archive", "mailctl_move", "mailctl_rule_set_enabled"] {
            policies[broad] = .init(approvalPolicy: .everyCall)
        }
        policies["mailctl_run"] = .init(approvalPolicy: .everyCall, widgetPresentation: lookup)
        return FirstPartyMCPProvider(
            id: "provider.mailctl",
            name: "MailCTL",
            serverName: "mailctl",
            category: .mail,
            executableNames: ["mailctl"],
            serveArguments: ["mcp", "serve"],
            widgetPresentation: card,
            toolPolicies: policies,
            policyRevision: 1
        )
    }()

    // MARK: - PhotoCTL

    /// Apple Photos through PhotoCTL's own server. Every tool reads, except
    /// `photoctl_export`, which copies files into a folder and asks first as
    /// its annotations say. The flexible `photoctl_run` asks every time. The
    /// widget has no photo-row shape, so results use the semantic card.
    static let photoCTL: FirstPartyMCPProvider = {
        let accent = "light-dark(#b8326b, #ff6fa8)"
        let card = ToolWidgetPresentation(profile: .semanticResult, accent: accent)
        let lookup = ToolWidgetPresentation(profile: .semanticResult, accent: accent, automatic: false)
        var policies: [String: FirstPartyMCPProvider.ToolPolicy] = [:]
        for helper in ["photoctl_doctor", "photoctl_capabilities"] {
            policies[helper] = .init(widgetPresentation: lookup)
        }
        policies["photoctl_run"] = .init(approvalPolicy: .everyCall, widgetPresentation: lookup)
        return FirstPartyMCPProvider(
            id: "provider.photoctl",
            name: "PhotoCTL",
            serverName: "photoctl",
            category: .imageProcessing,
            executableNames: ["photoctl"],
            serveArguments: ["mcp", "serve"],
            widgetPresentation: card,
            toolPolicies: policies,
            policyRevision: 1
        )
    }()

    // MARK: - MusicCTL

    /// Apple Music through MusicCTL's own server. Reads run freely and the
    /// writes ask first, as their annotations say. The flexible `musicctl_run`
    /// and the destructive `musicctl_rating_clear` ask every time. New
    /// Releases scans the whole cloud library, so it keeps the hour the old
    /// process tool had. Results use the semantic card: the retired process
    /// catalog had no row presentation to keep. Only `musicctl` is looked
    /// for: MailCTL installs an `mctl` alias too, so that name does not say
    /// which CLI answers.
    ///
    /// `legacyInvocationFingerprints` are the 16 tools the retired MusicCTL
    /// process catalog installed, each with the command it ran. All 16 exist
    /// on the server under the same ids.
    static let musicCTL: FirstPartyMCPProvider = {
        let accent = "light-dark(#c4002b, #ff375f)"
        let card = ToolWidgetPresentation(profile: .semanticResult, accent: accent)
        let lookup = ToolWidgetPresentation(profile: .semanticResult, accent: accent, automatic: false)
        var policies: [String: FirstPartyMCPProvider.ToolPolicy] = [:]
        for helper in ["musicctl_doctor", "musicctl_capabilities"] {
            policies[helper] = .init(widgetPresentation: lookup)
        }
        policies["musicctl_rating_clear"] = .init(approvalPolicy: .everyCall)
        policies["musicctl_run"] = .init(approvalPolicy: .everyCall, widgetPresentation: lookup)
        policies["musicctl_new_releases"] = .init(timeoutSeconds: 3_600)
        return FirstPartyMCPProvider(
            id: "provider.musicctl",
            name: "MusicCTL",
            serverName: "musicctl",
            category: .music,
            executableNames: ["musicctl"],
            serveArguments: ["mcp", "serve"],
            widgetPresentation: card,
            toolPolicies: policies,
            policyRevision: 1,
            // Computed from `git show 226a2d0:Services/MusicCTLToolCatalog.swift`.
            legacyInvocationFingerprints: [
                "musicctl_doctor": "394ca20857f85a25",
                "musicctl_search": "a7e3bddae68d3873",
                "musicctl_list_library": "a5a3bf35f5cebc37",
                "musicctl_new_releases": "eafb2edcb5960bee",
                "musicctl_list_playlists": "426e61b8190c99f9",
                "musicctl_playlist_tracks": "c39ffbb86b3514d5",
                "musicctl_listening_history": "ae61bcca83073647",
                "musicctl_player_status": "bc15932c138d6045",
                "musicctl_list_output_routes": "911244b2f4abb8e8",
                "musicctl_player_control": "67494f12fc041e14",
                "musicctl_seek": "7245bfe35af1ca77",
                "musicctl_set_volume": "8c870ce31bfc6a19",
                "musicctl_set_shuffle": "b91884549edf06cc",
                "musicctl_set_repeat": "f07e010deb2153b0",
                "musicctl_select_output_routes": "5aa8e40d41658358",
                "musicctl_run": "pattern:{args}"
            ],
            legacyExecutableNames: ["musicctl", "mctl"]
        )
    }()
}

extension MCPDiscoveryOwner {
    /// What ownership matching compares for this owner: the provider's
    /// identity for a first-party owner, the owner's own identity otherwise.
    var ownershipKey: String { FirstPartyMCPProviderCatalog.ownershipKey(of: self) }
}
