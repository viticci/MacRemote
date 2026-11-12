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

    var providerSourcePath: String { serveArguments.joined(separator: " ") }
}

enum FirstPartyMCPProviderCatalog {
    /// Discovery source recorded on candidates and bridged tools that MacRemote
    /// synthesized from an installed first-party executable.
    static let discoverySource = "first_party"

    static let providers: [FirstPartyMCPProvider] = [remCTL, notesCTL]

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

    /// Recognizes a configured MCP server that launches a provider's own
    /// server: `remctl mcp`, `python3 /path/to/remctl mcp`, or
    /// `notesctl mcp serve --client codex`. Symlinks resolve to the same file.
    static func provider(
        launchedBy command: String,
        args: [String],
        detectedExecutablePaths: [String: String]
    ) -> FirstPartyMCPProvider? {
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
                  let serveVerb = provider.serveArguments.first,
                  serveArgs.first == serveVerb else { continue }
            return provider
        }
        return nil
    }

    /// Applies category, approval, and widget policy to freshly bridged tools.
    /// Everything else on the tool stays exactly what the upstream server said.
    static func applyPolicy(
        _ provider: FirstPartyMCPProvider,
        to tools: [ToolDefinition]
    ) -> [ToolDefinition] {
        // Imported names may be disambiguated when an older process adapter
        // already owns the semantic ID. Bind actions to this imported family,
        // never to the unrelated tool occupying the original name.
        let actionTargets = Dictionary(uniqueKeysWithValues: tools.compactMap { tool -> (String, String)? in
            guard let name = tool.mcpStdioBridge?.toolName else { return nil }
            let canonical = name.hasPrefix(provider.serverName + "_") ? name : provider.serverName + "_" + name
            return (canonical, tool.id)
        })
        return tools.map { tool in
            guard let bridge = tool.mcpStdioBridge else { return tool }
            let policy = provider.toolPolicies[bridge.toolName] ?? FirstPartyMCPProvider.ToolPolicy()
            return ToolDefinition(
                id: tool.id,
                permissionEpoch: tool.permissionEpoch,
                name: bridge.toolTitle ?? tool.name,
                summary: tool.summary,
                executablePath: tool.executablePath,
                argumentPattern: tool.argumentPattern,
                parameters: tool.parameters,
                processInvocation: tool.processInvocation,
                capability: tool.capability,
                timeoutSeconds: tool.timeoutSeconds,
                outputByteLimit: tool.outputByteLimit,
                origin: tool.origin,
                category: provider.category,
                permissionRequirements: tool.permissionRequirements,
                backend: tool.backend,
                mcpBridge: tool.mcpBridge,
                mcpStdioBridge: tool.mcpStdioBridge,
                nativeToolID: tool.nativeToolID,
                approvalPolicy: policy.approvalPolicy,
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
            toolPolicies: policies
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
            toolPolicies: policies
        )
    }()
}
