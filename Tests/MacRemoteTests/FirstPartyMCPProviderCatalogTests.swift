import Foundation
import Testing
@testable import MacRemote

@Suite("First-party MCP providers")
struct FirstPartyMCPProviderCatalogTests {
    @Test("RemCTL and NotesCTL are the two providers with native MCP servers")
    func providers() {
        let ids = FirstPartyMCPProviderCatalog.providers.map(\.id)
        #expect(ids == ["provider.remctl", "provider.notesctl"])
        #expect(FirstPartyMCPProviderCatalog.remCTL.serveArguments == ["mcp"])
        #expect(FirstPartyMCPProviderCatalog.notesCTL.serveArguments == ["mcp", "serve", "--client", "macremote"])
        #expect(FirstPartyMCPProviderCatalog.isFirstPartyExecutableName("rctl"))
        #expect(!FirstPartyMCPProviderCatalog.isFirstPartyExecutableName("musicctl"))
    }

    @Test("Detection follows the executable, so a missing CLI yields no provider")
    func detection() {
        #expect(FirstPartyMCPProviderCatalog.detectedProviders(using: { _ in nil }).isEmpty)
        let detected = FirstPartyMCPProviderCatalog.detectedProviders(using: { name in
            name == "notesctl" ? "/fake/bin/notesctl" : nil
        })
        #expect(detected.map(\.provider.id) == ["provider.notesctl"])
        #expect(detected.first?.executablePath == "/fake/bin/notesctl")
    }

    @Test("A configured launch of the CLI's own server is attributed to the provider")
    func launchMatching() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let real = directory.appendingPathComponent("remctl")
        try Data("#!/bin/sh\n".utf8).write(to: real)
        let link = directory.appendingPathComponent("rctl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let detected = ["provider.remctl": real.path]

        // Direct launch.
        #expect(FirstPartyMCPProviderCatalog.provider(
            launchedBy: real.path, args: ["mcp"], detectedExecutablePaths: detected
        )?.id == "provider.remctl")
        // Interpreter launch, as Claude Code writes it.
        #expect(FirstPartyMCPProviderCatalog.provider(
            launchedBy: "/usr/bin/python3.13", args: [real.path, "mcp"], detectedExecutablePaths: detected
        )?.id == "provider.remctl")
        // Symlinked alias.
        #expect(FirstPartyMCPProviderCatalog.provider(
            launchedBy: link.path, args: ["mcp", "serve"], detectedExecutablePaths: detected
        )?.id == "provider.remctl")
        // Same binary, but not its MCP server.
        #expect(FirstPartyMCPProviderCatalog.provider(
            launchedBy: real.path, args: ["today", "--json"], detectedExecutablePaths: detected
        ) == nil)
        // Different binary.
        #expect(FirstPartyMCPProviderCatalog.provider(
            launchedBy: "/opt/homebrew/bin/node", args: ["/srv/other.js", "mcp"], detectedExecutablePaths: detected
        ) == nil)
    }

    @Test("Policy sets category, approval, and widget hints; the CLI keeps everything else")
    func policy() throws {
        let provider = FirstPartyMCPProviderCatalog.remCTL
        func bridged(_ name: String, title: String, capability: ToolCapability) -> ToolDefinition {
            ToolDefinition(
                id: "remctl_\(name)",
                name: "RemCTL: \(title)",
                summary: "Upstream description for \(name).",
                executablePath: "",
                argumentPattern: [],
                parameters: [],
                capability: capability,
                timeoutSeconds: 60,
                outputByteLimit: 1024,
                origin: .userDefined,
                category: .developer,
                backend: .mcpStdioBridge,
                mcpStdioBridge: MCPStdioBridgeConfiguration(
                    serverName: "RemCTL",
                    command: "/fake/bin/remctl",
                    args: ["mcp"],
                    toolName: name,
                    toolTitle: title,
                    toolDescription: "Upstream description for \(name)."
                )
            )
        }
        let tools = FirstPartyMCPProviderCatalog.applyPolicy(provider, to: [
            bridged("today", title: "Today's Reminders", capability: .readOnly),
            bridged("lists", title: "Reminder Lists", capability: .readOnly),
            bridged("set_completion", title: "Complete Reminder", capability: .write),
            bridged("update_reminder", title: "Update Reminder", capability: .write),
            bridged("delete_reminder", title: "Delete Reminder", capability: .destructive),
            bridged("run", title: "Run RemCTL Command", capability: .destructive)
        ])
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.mcpStdioBridge!.toolName, $0) })

        let today = try #require(byName["today"])
        #expect(today.name == "Today's Reminders")
        #expect(today.summary == "Upstream description for today.")
        #expect(today.category == .reminders)
        #expect(today.approvalPolicy == .standard)
        #expect(today.widgetPresentation?.profile == .reminderRows)
        #expect(today.uiActions?.map(\.toolID) == [
            "remctl_set_completion", "remctl_update_reminder", "remctl_update_reminder", "remctl_delete_reminder"
        ])

        #expect(byName["lists"]?.widgetPresentation?.profile == .semanticResult)
        #expect(byName["lists"]?.uiActions == nil)
        #expect(!LocalMCPServer.widgetEligible(tool: try #require(byName["lists"])))
        #expect(!LocalMCPServer.widgetEligible(tool: try #require(byName["run"])))
        #expect(LocalMCPServer.widgetEligible(tool: today))
        for helper in ["lists", "get_list", "doctor", "resolve_location", "run"] {
            #expect(provider.toolPolicies[helper]?.widgetPresentation?.automatic == false)
        }
        let oldPresentation = try JSONDecoder().decode(ToolWidgetPresentation.self, from: Data(#"{"profile":"reminderRows"}"#.utf8))
        #expect(oldPresentation.automatic == nil)
        #expect(try JSONDecoder().decode(ToolWidgetPresentation.self, from: JSONEncoder().encode(byName["lists"]!.widgetPresentation!)).automatic == false)
        #expect(byName["delete_reminder"]?.approvalPolicy == .everyCall)
        #expect(byName["delete_reminder"]?.capability == .destructive)
        #expect(byName["run"]?.approvalPolicy == .everyCall)
        #expect(byName["run"]?.widgetPresentation?.profile == .semanticResult)
        let isolated = FirstPartyMCPProviderCatalog.applyPolicy(provider, to: [bridged("today", title: "Today", capability: .readOnly)])
        #expect(isolated.first?.uiActions?.isEmpty == true)
        // A prior adapter reserves the canonical name; row actions must use
        // the imported sibling's actual public ID.
        let completion = ToolDefinition(
            id: "remctl_set_completion_collision", name: "Complete", summary: "Complete",
            executablePath: "", argumentPattern: [], parameters: [], capability: .write,
            timeoutSeconds: 60, outputByteLimit: 1024,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(serverName: "remctl", command: "/fake/bin/remctl", args: ["mcp"], toolName: "set_completion")
        )
        let collisionFamily = FirstPartyMCPProviderCatalog.applyPolicy(provider, to: [bridged("today", title: "Today", capability: .readOnly), completion])
        #expect(collisionFamily.first?.uiActions?.map(\.toolID) == ["remctl_set_completion_collision"])
        // Permissions stay with the CLI's signed helper, never with MacRemote.
        #expect(tools.allSatisfy { $0.permissionRequirements.isEmpty })
    }

    @Test("NotesCTL guarded writes ask every time and read rows carry View Note")
    func notesPolicy() {
        let provider = FirstPartyMCPProviderCatalog.notesCTL
        for guarded in ["notesctl_add_content", "notesctl_apply_edit", "notesctl_trash", "notesctl_remove_tags", "notesctl_run"] {
            #expect(provider.toolPolicies[guarded]?.approvalPolicy == .everyCall, "\(guarded)")
        }
        #expect(provider.toolPolicies["notesctl_search"]?.uiActions?.first?.toolID == "notesctl_show")
        #expect(provider.widgetPresentation?.profile == .noteRows)
        #expect(provider.widgetPresentation?.rootPath == "result")
        #expect(provider.toolPolicies["notesctl_folders"]?.widgetPresentation?.profile == .semanticResult)
    }

    @Test("A server that prefixes its own tool names does not get the prefix twice")
    func identifierPrefix() {
        #expect(ToolIdentifier.importedMCPToolID(serverName: "NotesCTL", upstreamToolName: "notesctl_search") == "notesctl_search")
        #expect(ToolIdentifier.importedMCPToolID(serverName: "RemCTL", upstreamToolName: "today") == "remctl_today")
        #expect(ToolIdentifier.importedMCPToolID(serverName: "x-search", upstreamToolName: "search_news") == "x_search_search_news")
    }
}
