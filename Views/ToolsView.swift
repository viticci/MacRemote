import SwiftUI

// MARK: - Shared Tools-surface vocabulary

extension ToolCategory {
    var iconSystemImage: String {
        switch self {
        case .reminders: "checklist"
        case .habits: "figure.mind.and.body"
        case .podcasts: "music.microphone"
        case .filesystem: "folder"
        case .utilities: "wrench.adjustable"
        case .imageProcessing: "photo"
        case .text: "text.alignleft"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .ai: "apple.intelligence"
        }
    }

    var iconTint: Color {
        switch self {
        case .reminders: .blue
        case .habits: .mint
        case .podcasts: .purple
        case .filesystem: .orange
        case .utilities: .green
        case .imageProcessing: .pink
        case .text: .indigo
        case .developer: .teal
        case .ai: .cyan
        }
    }
}

extension ToolAdapterMode {
    /// D7 — the model's raw titles ("CLI Adapter"/"Command Template") are banned as visible copy.
    var displayTitle: String {
        switch self {
        case .cliAdapter: "Flexible Command"
        case .commandTemplate: "Fixed Command"
        }
    }
}

extension ToolDefinition {
    var modeDisplayTitle: String {
        if isMCPBridge { return "Imported" }
        return isGenericCLIAdapter ? ToolAdapterMode.cliAdapter.displayTitle : ToolAdapterMode.commandTemplate.displayTitle
    }
}

// MARK: - Grouping and filtering

private enum ToolsGroupBy: String, CaseIterable, Identifiable {
    case category
    case source
    case capability

    var id: String { rawValue }

    var title: String {
        switch self {
        case .category: "Category"
        case .source: "Source"
        case .capability: "Capability"
        }
    }
}

private enum ToolsFilter: String, CaseIterable, Identifiable {
    case all
    case shared
    case asksFirst
    case readOnly
    case needsAccess
    case notShared
    case flexibleCommand

    var id: String { rawValue }

    /// The five click-to-filter chips; the long tail lives in the Filter menu.
    static let chipCases: [ToolsFilter] = [.all, .shared, .asksFirst, .readOnly, .needsAccess]

    var title: String {
        switch self {
        case .all: "All"
        case .shared: "Shared"
        case .asksFirst: "Asks First"
        case .readOnly: "Read-only"
        case .needsAccess: "Needs Access"
        case .notShared: "Not Shared"
        case .flexibleCommand: "Flexible Command"
        }
    }
}

// MARK: - List model

private struct ToolsSection: Identifiable {
    let id: String
    let title: String
    let tools: [ToolDefinition]
    let sharedCount: Int
    let isRemindersCategory: Bool
    let server: ServerHeaderModel?
}

private struct ServerHeaderModel {
    let identity: String
    let name: String
    let totalCount: Int
    let sharedCount: Int
    let candidate: LocalMCPServerCandidate?
}

private struct ServerRefreshRequest: Identifiable {
    let candidateID: String
    let serverName: String
    let toolCount: Int

    var id: String { candidateID }
}

// MARK: - ToolsView

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedToolID: String?
    @State private var groupBy: ToolsGroupBy = .category
    @State private var filter: ToolsFilter = .all
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var rowErrors: [String: String] = [:]
    @State private var isLibraryPresented = false
    @State private var libraryInitialTab: ToolLibraryTab = .bundles
    @State private var isCreatingNewTool = false
    @State private var testingTool: ToolDefinition?
    @State private var toolPendingRemoval: ToolDefinition?
    @State private var serverPendingRefresh: ServerRefreshRequest?
    @State private var lastImportServerID: String?
    @State private var expandAll = DetailsExpandAll()
    @State private var inspectorTabRequest: ToolInspectorTab?
    @State private var missingExecutableToolIDs: Set<String> = []

    var body: some View {
        @Bindable var appModel = appModel

        content
            .navigationTitle("Tools")
            .navigationSubtitle("\(sharedCount) shared of \(appModel.allTools.count)")
            .searchable(text: $searchText, prompt: "Search tools")
            .searchFocused($isSearchFocused)
            .toolbar { toolbarContent }
            .inspector(isPresented: $appModel.isToolInspectorPresented) {
                ToolInspector(
                    tool: selectedTool,
                    isCreatingNewTool: $isCreatingNewTool,
                    onCreated: { newToolID in selectedToolID = newToolID },
                    onTest: { testingTool = $0 },
                    onDuplicate: { duplicate($0) },
                    onRemove: { toolPendingRemoval = $0 },
                    requestedTab: $inspectorTabRequest
                )
                .inspectorColumnWidth(min: 300, ideal: 340, max: 480)
            }
            .sheet(isPresented: $isLibraryPresented) {
                ToolLibrarySheet(initialTab: libraryInitialTab)
            }
            .sheet(item: $testingTool) { tool in
                ToolTestSheet(tool: tool)
            }
            .confirmationDialog(
                "Remove “\(toolPendingRemoval?.name ?? "")”?",
                isPresented: removalDialogPresented,
                titleVisibility: .visible,
                presenting: toolPendingRemoval
            ) { tool in
                Button("Remove Tool", role: .destructive) { performRemoval(of: tool) }
            } message: { _ in
                Text("Apps lose access immediately; its Always Allow settings are cleared.")
            }
            .confirmationDialog(
                "Refresh “\(serverPendingRefresh?.serverName ?? "")”?",
                isPresented: refreshDialogPresented,
                titleVisibility: .visible,
                presenting: serverPendingRefresh
            ) { request in
                Button("Refresh Tools") { performRefresh(request) }
            } message: { request in
                Text("Refreshing replaces this server's \(request.toolCount) tools and clears their Always Allow settings.")
            }
            .onChange(of: appModel.pendingToolsCommand) {
                consumePendingToolsCommand()
            }
            .onChange(of: appModel.searchFocusToken) {
                isSearchFocused = true
            }
            .task {
                consumePendingToolsCommand()
            }
            .task(id: missingFileCheckKey) {
                await refreshMissingExecutables()
            }
            .pageContainerShape()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if showsPageEmptyState {
            pageEmptyState
        } else if isSearchResultEmpty {
            VStack(spacing: 0) {
                chipsBar
                EmptyState(searchText: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                chipsBar
                toolsList
            }
        }
    }

    private var toolsList: some View {
        List(selection: $selectedToolID) {
            ForEach(sections) { section in
                Section {
                    if !collapsedSectionIDs.contains(section.id) {
                        sectionRows(for: section)
                    }
                } header: {
                    sectionHeader(for: section)
                }
            }

            if showsLocalMCPArea {
                ForEach(unimportedCandidates) { candidate in
                    Section {
                        if !collapsedSectionIDs.contains("candidate.\(candidate.id)") {
                            CandidateServerRows(
                                candidate: candidate,
                                isImporting: appModel.localMCPWorkingServerID == candidate.id,
                                importError: importError(for: candidate.id),
                                importAction: { importServer(candidateID: candidate.id) }
                            )
                        }
                    } header: {
                        candidateHeader(for: candidate)
                    }
                }

                scanStatusSection
            } else if let hint = mcpSearchHintLine {
                Section {
                    Text(hint)
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onDeleteCommand {
            if let tool = selectedTool, tool.isUserDefined {
                toolPendingRemoval = tool
            }
        }
        .onKeyPress(phases: .down) { press in
            handleKeyPress(press)
        }
    }

    // MARK: Chips row

    private var chipsBar: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                ForEach(ToolsFilter.chipCases) { chipFilter in
                    StatChip(
                        count: count(for: chipFilter),
                        label: chipFilter.title,
                        isSelected: filter == chipFilter,
                        action: { filter = chipFilter }
                    )
                }

                Menu {
                    Toggle("Not Shared", isOn: longTailBinding(for: .notShared))
                    Toggle("Flexible Command", isOn: longTailBinding(for: .flexibleCommand))
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .help("More filters")

                Spacer()
            }

            if sharedCount == 0 && !appModel.allTools.isEmpty {
                Label("Share at least one tool before starting the local server.", systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
    }

    private func longTailBinding(for target: ToolsFilter) -> Binding<Bool> {
        Binding(
            get: { filter == target },
            set: { filter = $0 ? target : .all }
        )
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Menu {
                Picker("Group By", selection: $groupBy) {
                    ForEach(ToolsGroupBy.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Group By", systemImage: "rectangle.3.group")
            }
            .help("Group tools by category, source, or capability")

            // CLI-1: two scan objects, one kept-verbatim menu label. The
            // command-line item only navigates — it never starts a scan (DL-4).
            Menu {
                Button("Scan for MCP Servers") { appModel.scanLocalMCPServers() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(appModel.localMCPScanState.isScanning)
                Button("Scan for Command-Line Tools…") { openCommandLineToolsTab() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(appModel.cliScanState.isScanning)
            } label: {
                Label(
                    isAnyScanRunning ? "Scanning…" : "Scan This Mac",
                    systemImage: "sparkle.magnifyingglass"
                )
                .symbolEffect(.pulse, isActive: isAnyScanRunning && !reduceMotion)
            }
            .help("Scan this Mac for MCP servers or command-line tools")
        }

        ToolbarSpacer(.fixed)

        ToolbarItemGroup {
            Menu {
                Button("New Tool…") { beginNewTool() }
                Button("Add from Library…") { openLibrary(at: .bundles) }
                Divider()
                Button("Scan for MCP Servers") { appModel.scanLocalMCPServers() }
                Button("Scan for Command-Line Tools…") { openCommandLineToolsTab() }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .help("Add a tool")
        }
    }

    private var isAnyScanRunning: Bool {
        appModel.localMCPScanState.isScanning || appModel.cliScanState.isScanning
    }

    /// DL-4: entry points navigate to Library ▸ Found on This Mac (cached
    /// results or the invitation) — only the in-tab button starts a scan.
    private func openCommandLineToolsTab() {
        openLibrary(at: .found)
    }

    private func openLibrary(at tab: ToolLibraryTab) {
        libraryInitialTab = tab
        isLibraryPresented = true
    }

    // MARK: Section building

    private var sections: [ToolsSection] {
        switch groupBy {
        case .category: categorySections + importedServerSections
        case .source: sourceSections + importedServerSections
        case .capability: capabilitySections
        }
    }

    private var visibleTools: [ToolDefinition] {
        appModel.allTools.filter { matchesFilter($0) && matchesSearch($0) }
    }

    private var categorySections: [ToolsSection] {
        let process = visibleTools.filter { !$0.isMCPBridge }
        let grouped = Dictionary(grouping: process, by: \.category)
        return grouped.keys
            .sorted { $0.title < $1.title }
            .compactMap { category in
                guard let tools = grouped[category], !tools.isEmpty else { return nil }
                return makeSection(
                    id: "category.\(category.rawValue)",
                    title: category.title,
                    tools: tools,
                    isRemindersCategory: category == .reminders
                )
            }
    }

    private var sourceSections: [ToolsSection] {
        let process = visibleTools.filter { !$0.isMCPBridge }
        let builtIn = process.filter { !$0.isUserDefined }
        // CLI-26/DV-5: provenance is the source key — scan-added tools group
        // under Found on This Mac, hand-added ones under Added by You.
        let added = process.filter { $0.isUserDefined && $0.provenance == nil }
        let found = process.filter { $0.isUserDefined && $0.provenance != nil }
        var result: [ToolsSection] = []
        if !builtIn.isEmpty {
            result.append(makeSection(id: "source.builtIn", title: "Built-in", tools: builtIn, isRemindersCategory: false))
        }
        if !added.isEmpty {
            result.append(makeSection(id: "source.added", title: "Added by You", tools: added, isRemindersCategory: false))
        }
        if !found.isEmpty {
            result.append(makeSection(id: "source.found", title: "Found on This Mac", tools: found, isRemindersCategory: false))
        }
        return result
    }

    private var capabilitySections: [ToolsSection] {
        let order: [ToolCapability] = [.readOnly, .write, .destructive]
        let grouped = Dictionary(grouping: visibleTools, by: \.capability)
        return order.compactMap { capability in
            guard let tools = grouped[capability], !tools.isEmpty else { return nil }
            return makeSection(
                id: "capability.\(capability.rawValue)",
                title: capability.title,
                tools: tools,
                isRemindersCategory: false
            )
        }
    }

    private func makeSection(id: String, title: String, tools: [ToolDefinition], isRemindersCategory: Bool) -> ToolsSection {
        let sorted = tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ToolsSection(
            id: id,
            title: title,
            tools: sorted,
            sharedCount: sorted.count(where: { appModel.isToolExposed($0) }),
            isRemindersCategory: isRemindersCategory,
            server: nil
        )
    }

    private var importedServerSections: [ToolsSection] {
        let bridgeTools = appModel.tools.filter(\.isMCPBridge)
        let grouped = Dictionary(grouping: bridgeTools) { $0.mcpBridgeIdentity ?? $0.id }
        let candidatesByIdentity = Dictionary(
            appModel.localMCPScanState.candidates.compactMap { candidate in
                candidate.bridgeIdentity.map { ($0, candidate) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        return grouped
            .map { identity, tools -> ToolsSection in
                let visible = tools
                    .filter { matchesFilter($0) && matchesSearch($0) }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let header = ServerHeaderModel(
                    identity: identity,
                    name: tools.first?.mcpBridgeServerName ?? "Local MCP Server",
                    totalCount: tools.count,
                    sharedCount: tools.count(where: { appModel.isToolExposed($0) }),
                    candidate: candidatesByIdentity[identity]
                )
                return ToolsSection(
                    id: "server.\(identity)",
                    title: header.name,
                    tools: visible,
                    sharedCount: visible.count(where: { appModel.isToolExposed($0) }),
                    isRemindersCategory: false,
                    server: header
                )
            }
            .filter { !$0.tools.isEmpty || searchText.isEmpty }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private var importedIdentities: Set<String> {
        Set(appModel.tools.compactMap(\.mcpBridgeIdentity))
    }

    private var unimportedCandidates: [LocalMCPServerCandidate] {
        appModel.localMCPScanState.candidates.filter { candidate in
            guard let identity = candidate.bridgeIdentity else { return true }
            return !importedIdentities.contains(identity)
        }
    }

    /// Scan results and status stay visible while filter chips are active; text
    /// search hides the list but a truthNote preserves the count.
    private var showsLocalMCPArea: Bool {
        searchText.isEmpty
    }

    private var mcpSearchHintLine: String? {
        guard !searchText.isEmpty else { return nil }
        let count = appModel.localMCPScanState.candidates.count
        guard count > 0 else { return nil }
        return "\(count) MCP servers found — clear search to view them."
    }

    // MARK: Section headers and rows

    private func sectionHeader(for section: ToolsSection) -> some View {
        HStack(spacing: Space.s2) {
            Button {
                toggleCollapsed(section.id)
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedSectionIDs.contains(section.id) ? -90 : 0))
                    if section.server != nil {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(.teal)
                            .accessibilityHidden(true)
                    }
                    Text(section.title)
                        .font(TypeRamp.cardTitle)
                    Text("(\(section.tools.count))")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .countText()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(section.tools.count) tools")
            .accessibilityValue(collapsedSectionIDs.contains(section.id) ? "Collapsed" : "Expanded")

            if let server = section.server, let candidate = server.candidate {
                StateChip(Self.sourceTitle(candidate.source), systemImage: "app.connected.to.app.below.fill", tint: .secondary)
            }

            Spacer()

            if let server = section.server {
                if server.sharedCount > 0 && server.sharedCount < server.totalCount {
                    StateChip("Partially Shared", tint: .orange)
                }
                Text("\(server.sharedCount)/\(server.totalCount) shared")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .countText()
            } else {
                Text("\(section.sharedCount) shared")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .countText()

                Menu {
                    Button("Share All") { setSection(section, shared: true) }
                    Button("Share None") { setSection(section, shared: false) }
                } label: {
                    Text("Share")
                }
                .fixedSize()
                .help("Share or stop sharing every tool in \(section.title)")
            }
        }
    }

    @ViewBuilder
    private func sectionRows(for section: ToolsSection) -> some View {
        if let server = section.server {
            ImportedServerRow(
                server: server,
                isImporting: appModel.isImportingLocalMCPServer(candidateID: server.candidate?.id),
                error: rowErrors[section.id] ?? importError(for: server.candidate?.id),
                expandAll: $expandAll,
                shareAllBinding: Binding(
                    get: { server.sharedCount > 0 },
                    set: { enabled in
                        rowErrors[section.id] = appModel.setLocalMCPBridgeServerEnabled(
                            bridgeIdentity: server.identity,
                            enabled: enabled
                        )
                    }
                ),
                refreshAction: {
                    if let candidate = server.candidate {
                        serverPendingRefresh = ServerRefreshRequest(
                            candidateID: candidate.id,
                            serverName: server.name,
                            toolCount: server.totalCount
                        )
                    }
                },
                onCopyEndpoint: { appModel.appendLog(level: .info, "Copied MCP server address for \(server.name).") }
            )
        } else if let groupError = rowErrors[section.id] {
            ErrorRow(message: groupError)
        }

        ForEach(section.tools) { tool in
            toolRow(for: tool)
                .tag(tool.id)
        }
    }

    private func toolRow(for tool: ToolDefinition) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            ToolRowView(
                tool: tool,
                isShared: appModel.isToolExposed(tool),
                error: rowErrors[tool.id],
                shareBinding: shareBinding(for: tool)
            )

            if missingExecutableToolIDs.contains(tool.id) {
                missingExecutableRow(for: tool)
            }

            if appModel.provenanceIdentityChangedToolIDs.contains(tool.id) {
                identityChangedRow(for: tool)
            }
        }
        .contextMenu {
            Button(appModel.isToolExposed(tool) ? "Stop Sharing" : "Share") { toggleShare(tool) }
            Button("Test Tool…") { testingTool = tool }
            if !tool.isMCPBridge {
                Button("Duplicate") { duplicate(tool) }
            }
            if tool.isUserDefined {
                Divider()
                Button("Remove…", role: .destructive) { toolPendingRemoval = tool }
            }
        }
    }

    /// CLI-27 — never auto-removed, never auto-unshared for a missing file.
    private func missingExecutableRow(for tool: ToolDefinition) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Label(
                "This tool's file is missing — it was at \(tool.executablePath). Edit the tool to point at a new file, or remove it.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.red)
            .textSelection(.enabled)

            Spacer()

            Button("Edit") { openInspector(for: tool, at: .definition) }
                .controlSize(.small)
            Button("Remove…", role: .destructive) { toolPendingRemoval = tool }
                .controlSize(.small)
        }
    }

    /// CLI-30 (R16) — identity change already flipped sharing off in the model;
    /// this row says so and routes to the provenance record.
    private func identityChangedRow(for tool: ToolDefinition) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Label(
                "\(tool.name) changed publisher since you added it — review before sharing again.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.orange)
            .textSelection(.enabled)

            Spacer()

            Button("Review…") { openInspector(for: tool, at: .overview) }
                .controlSize(.small)
        }
    }

    private func openInspector(for tool: ToolDefinition, at tab: ToolInspectorTab) {
        selectedToolID = tool.id
        inspectorTabRequest = tab
        appModel.isToolInspectorPresented = true
    }

    private func candidateHeader(for candidate: LocalMCPServerCandidate) -> some View {
        HStack(spacing: Space.s2) {
            Button {
                toggleCollapsed("candidate.\(candidate.id)")
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(collapsedSectionIDs.contains("candidate.\(candidate.id)") ? -90 : 0))
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(candidate.displayName)
                        .font(TypeRamp.cardTitle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            StateChip(Self.sourceTitle(candidate.source), systemImage: "app.connected.to.app.below.fill", tint: .secondary)
            if candidate.isNewSinceLastScan {
                StateChip("New", role: .working)
            }
            if candidate.bridgeable {
                StateChip("Ready to Import", systemImage: "tray.and.arrow.down", role: .ready)
            } else {
                StateChip("View Only", systemImage: "eye", role: .off)
            }

            Spacer()
        }
    }

    // MARK: Scan status section

    private var scanStatusSection: some View {
        Section {
            if appModel.localMCPScanState.isScanning {
                HStack(spacing: Space.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning this Mac for MCP servers…")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                }
                .selectionDisabled()
            }

            if case .failed(let message) = appModel.localMCPScanState {
                HStack(spacing: Space.s2) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                    Button("Retry") { appModel.scanLocalMCPServers() }
                }
                .selectionDisabled()
            }

            if let message = appModel.localMCPErrorMessage, lastImportServerID == nil {
                ErrorRow(message: message)
                    .selectionDisabled()
            }

            if showsScanEmptyState {
                EmptyState(
                    "No MCP servers yet",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    message: "Scan this Mac to find MCP servers from Claude, Codex, Cursor, VS Code, Zed, Gemini, and other AI apps' configs.",
                    actionTitle: "Scan This Mac",
                    action: { appModel.scanLocalMCPServers() }
                )
                .selectionDisabled()
            } else if showsScanHint {
                Text("Scan This Mac to look for new MCP servers.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }

            if !appModel.localMCPScanState.candidates.isEmpty {
                Text(scanSummaryLine)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .countText()
                    .selectionDisabled()
            }

            if case .stale(let lastScan, _) = appModel.localMCPFreshness {
                HStack(spacing: Space.s2) {
                    Text("Scan results may be out of date — MCP configs changed since \(lastScan.formatted(date: .omitted, time: .shortened)).")
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                    Button("Scan This Mac") { appModel.scanLocalMCPServers() }
                        .font(TypeRamp.truthNote)
                }
                .selectionDisabled()
            } else if let lastScanDate = appModel.localMCPScanState.lastScanDate {
                Text("Last scan: \(lastScanDate.formatted(date: .omitted, time: .shortened))")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        } header: {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Local MCP Servers")
                    .font(TypeRamp.cardTitle)
                Text("Find the MCP servers your Mac's AI apps already use, and share their tools through MacRemote.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var showsScanEmptyState: Bool {
        !appModel.localMCPScanState.isScanning &&
            unimportedCandidates.isEmpty &&
            importedIdentities.isEmpty &&
            !isScanFailed
    }

    private var showsScanHint: Bool {
        !appModel.localMCPScanState.isScanning &&
            unimportedCandidates.isEmpty &&
            appModel.localMCPScanState.candidates.isEmpty &&
            !isScanFailed
    }

    /// LM-3 — the old overview pills survive as one status line.
    private var scanSummaryLine: String {
        let candidates = appModel.localMCPScanState.candidates
        let readyCount = candidates.count(where: \.bridgeable)
        let newCount = candidates.count(where: \.isNewSinceLastScan)
        var parts = ["\(candidates.count) detected"]
        if newCount > 0 {
            parts.append("\(newCount) new")
        }
        parts.append("\(readyCount) ready to import")
        parts.append("\(importedIdentities.count) imported")
        return parts.joined(separator: " · ")
    }

    private var isScanFailed: Bool {
        if case .failed = appModel.localMCPScanState { return true }
        return false
    }

    // MARK: Empty states

    private var showsPageEmptyState: Bool {
        appModel.allTools.isEmpty &&
            appModel.localMCPScanState.candidates.isEmpty &&
            !appModel.localMCPScanState.isScanning &&
            searchText.isEmpty
    }

    private var pageEmptyState: some View {
        ContentUnavailableView {
            Label("No tools yet", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("Add tools from the library or create your own. Scan this Mac to find MCP servers from Claude, Codex, Cursor, VS Code, Zed, Gemini, and other AI apps' configs. Or scan this Mac for command-line tools installed with Homebrew, npm, or on your PATH.")
        } actions: {
            Button("Add from Library…") { openLibrary(at: .bundles) }
            Button("New Tool…") { beginNewTool() }
            Button("Scan This Mac") { appModel.scanLocalMCPServers() }
        }
    }

    private var isSearchResultEmpty: Bool {
        !searchText.isEmpty && visibleTools.isEmpty
    }

    // MARK: Counts and filtering

    private var sharedCount: Int {
        appModel.allTools.count(where: { appModel.isToolExposed($0) })
    }

    private func count(for filter: ToolsFilter) -> Int {
        appModel.allTools.count(where: { matches($0, filter: filter) })
    }

    private func matchesFilter(_ tool: ToolDefinition) -> Bool {
        matches(tool, filter: filter)
    }

    private func matches(_ tool: ToolDefinition, filter: ToolsFilter) -> Bool {
        switch filter {
        case .all:
            true
        case .shared:
            appModel.isToolExposed(tool)
        case .asksFirst:
            appModel.isToolExposed(tool) && tool.capability != .readOnly
        case .readOnly:
            appModel.isToolExposed(tool) && tool.capability == .readOnly
        case .needsAccess:
            appModel.isToolExposed(tool) && tool.permissionRequirements.contains(.fullDiskAccess)
        case .notShared:
            !appModel.isToolExposed(tool)
        case .flexibleCommand:
            tool.isGenericCLIAdapter
        }
    }

    private func matchesSearch(_ tool: ToolDefinition) -> Bool {
        guard !searchText.isEmpty else { return true }
        let haystacks = [
            tool.name,
            tool.summary,
            tool.id,
            tool.executablePath,
            tool.mcpBridgeServerName ?? "",
            tool.mcpBridgeToolName ?? ""
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(searchText) }
    }

    // MARK: Actions

    private var selectedTool: ToolDefinition? {
        guard let selectedToolID else { return nil }
        return appModel.allTools.first { $0.id == selectedToolID }
    }

    private func shareBinding(for tool: ToolDefinition) -> Binding<Bool> {
        Binding(
            get: { appModel.isToolExposed(tool) },
            set: { enabled in
                rowErrors[tool.id] = appModel.setToolEnabled(id: tool.id, enabled: enabled)
            }
        )
    }

    private func toggleShare(_ tool: ToolDefinition) {
        rowErrors[tool.id] = appModel.setToolEnabled(id: tool.id, enabled: !appModel.isToolExposed(tool))
    }

    private func setSection(_ section: ToolsSection, shared: Bool) {
        rowErrors[section.id] = nil
        if section.isRemindersCategory {
            // MO-2: the Reminders header menu is the UI home of the RemCTL profile switch.
            rowErrors[section.id] = appModel.setRemCTLProfileEnabled(shared)
            return
        }
        for tool in section.tools {
            if let error = appModel.setToolEnabled(id: tool.id, enabled: shared) {
                rowErrors[tool.id] = error
            }
        }
    }

    private func duplicate(_ tool: ToolDefinition) {
        guard !tool.isMCPBridge else {
            rowErrors[tool.id] = "Imported tools can't be duplicated. Refresh their MCP server instead."
            return
        }
        var draft = ToolDefinitionDraft(tool: tool)
        draft.name += " Copy"
        if let error = appModel.addUserTool(from: draft) {
            rowErrors[tool.id] = error
        } else if let newTool = appModel.tools.last(where: \.isUserDefined) {
            selectedToolID = newTool.id
            appModel.isToolInspectorPresented = true
        }
    }

    private func performRemoval(of tool: ToolDefinition) {
        rowErrors[tool.id] = appModel.deleteUserTool(id: tool.id)
        if rowErrors[tool.id] == nil, selectedToolID == tool.id {
            selectedToolID = nil
        }
    }

    private func performRefresh(_ request: ServerRefreshRequest) {
        lastImportServerID = request.candidateID
        appModel.importLocalMCPServer(candidateID: request.candidateID)
    }

    private func importServer(candidateID: String) {
        lastImportServerID = candidateID
        appModel.importLocalMCPServer(candidateID: candidateID)
    }

    private func importError(for candidateID: String?) -> String? {
        guard let candidateID, candidateID == lastImportServerID else { return nil }
        return appModel.localMCPErrorMessage
    }

    private func beginNewTool() {
        appModel.isToolInspectorPresented = true
        isCreatingNewTool = true
    }

    private func consumePendingToolsCommand() {
        guard let command = appModel.pendingToolsCommand else { return }
        switch command {
        case .newTool:
            beginNewTool()
        case .addFromLibrary:
            openLibrary(at: .bundles)
        case .scanCommandLineTools:
            openCommandLineToolsTab()
        }
        appModel.clearPendingToolsCommand()
    }

    // MARK: Missing-executable check (§5.6 — cheap stat, refreshed on tool
    // changes and after each CLI scan; missing files are flagged, never acted on)

    private struct MissingFileCheckKey: Equatable {
        let paths: [String]
        let lastCLIScanDate: Date?
    }

    private var missingFileCheckKey: MissingFileCheckKey {
        MissingFileCheckKey(
            paths: appModel.tools.filter { $0.isUserDefined && !$0.isMCPBridge }.map(\.executablePath),
            lastCLIScanDate: appModel.cliScanState.lastScanDate
        )
    }

    private func refreshMissingExecutables() async {
        let checkable = appModel.tools
            .filter { $0.isUserDefined && !$0.isMCPBridge }
            .map { (id: $0.id, path: $0.executablePath) }
        let missing = await Task.detached(priority: .utility) {
            Set(checkable.filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.id))
        }.value
        missingExecutableToolIDs = missing
    }

    private func toggleCollapsed(_ id: String) {
        withAnimation(.snappy) {
            if collapsedSectionIDs.contains(id) {
                collapsedSectionIDs.remove(id)
            } else {
                collapsedSectionIDs.insert(id)
            }
        }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.command), let tool = selectedTool else { return .ignored }
        if press.key == KeyEquivalent("s"), press.modifiers.contains(.control) {
            toggleShare(tool)
            return .handled
        }
        if press.key == KeyEquivalent("d") {
            duplicate(tool)
            return .handled
        }
        if press.key == .return {
            // D4: while a request pends, ⌘⏎ belongs to Requests ▸ Approve —
            // never let a misdirected Return open anything else, let alone approve.
            guard appModel.frontmostPendingInterrupt == nil else { return .ignored }
            testingTool = tool
            return .handled
        }
        return .ignored
    }

    // MARK: Dialog bindings

    private var removalDialogPresented: Binding<Bool> {
        Binding(
            get: { toolPendingRemoval != nil },
            set: { if !$0 { toolPendingRemoval = nil } }
        )
    }

    private var refreshDialogPresented: Binding<Bool> {
        Binding(
            get: { serverPendingRefresh != nil },
            set: { if !$0 { serverPendingRefresh = nil } }
        )
    }

    fileprivate static func sourceTitle(_ source: String) -> String {
        switch source {
        case "claude_extension": "Claude Extension"
        case "claude_runtime": "Claude Runtime"
        case "claude_desktop": "Claude Desktop"
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "grok": "Grok"
        case "opencode": "OpenCode"
        case "cursor": "Cursor"
        case "lmstudio": "LM Studio"
        case "xcode_coding_assistant": "Xcode"
        case "vscode": "VS Code"
        case "windsurf": "Windsurf"
        case "zed": "Zed"
        case "gemini": "Gemini CLI"
        case "antigravity": "Antigravity"
        case "copilot_cli": "Copilot CLI"
        case "cline": "Cline"
        default: source
        }
    }
}

// MARK: - Tool row

private struct ToolRowView: View {
    let tool: ToolDefinition
    let isShared: Bool
    let error: String?
    let shareBinding: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s3) {
                iconView

                Text(tool.name)
                    .lineLimit(1)

                Spacer()

                chips

                Toggle("Share", isOn: shareBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .accessibilityLabel("Share \(tool.name)")
            }
            .opacity(isShared ? 1 : 0.62)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .help(tool.summary)
    }

    private var iconView: some View {
        Image(systemName: tool.isMCPBridge ? "point.3.connected.trianglepath.dotted" : tool.category.iconSystemImage)
            .font(.callout)
            .foregroundStyle(iconTint)
            .frame(width: 24, height: 24)
            .background(iconTint.opacity(0.13), in: AppShape.mono)
            .accessibilityHidden(true)
    }

    private var iconTint: Color {
        tool.isMCPBridge ? .teal : tool.category.iconTint
    }

    @ViewBuilder
    private var chips: some View {
        // Row chips carry only what differs between neighbors: shared state,
        // capability, and permission dots. The mode chip (Flexible/Fixed
        // Command) repeats across whole groups — it lives in the inspector.
        HStack(spacing: Space.s1) {
            if !isShared {
                StateChip("Not Shared", role: .off)
            }
            capabilityChip
            permissionDots
        }
    }

    @ViewBuilder
    private var capabilityChip: some View {
        switch tool.capability {
        case .readOnly:
            StateChip(capability: .readOnly)
        case .write:
            StateChip.asksFirst
        case .destructive:
            StateChip(capability: .destructive)
        }
    }

    @ViewBuilder
    private var permissionDots: some View {
        if !tool.permissionRequirements.isEmpty {
            HStack(spacing: Space.s1) {
                ForEach(tool.permissionRequirements, id: \.self) { requirement in
                    Image(systemName: requirement.systemImage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(requirement.title)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Needs \(tool.permissionRequirements.map(\.title).joined(separator: ", "))")
        }
    }
}

// MARK: - Imported MCP server management row

private struct ImportedServerRow: View {
    @Environment(AppModel.self) private var appModel

    let server: ServerHeaderModel
    let isImporting: Bool
    let error: String?
    let expandAll: Binding<DetailsExpandAll>
    let shareAllBinding: Binding<Bool>
    let refreshAction: () -> Void
    let onCopyEndpoint: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                if let candidate = server.candidate {
                    MonoValue(candidate.displayEndpoint, font: TypeRamp.machineCaption, onCopy: onCopyEndpoint)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if server.candidate != nil {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refreshAction)
                        .disabled(appModel.localMCPWorkingServerID != nil)
                        .help("Fetch this server's tools again")
                }

                Toggle("Share All", isOn: shareAllBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            if let description = server.candidate?.probe?.serverInfo.description, !description.isEmpty {
                Text(description)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if server.candidate == nil {
                Label("Original config no longer found — tools still work", systemImage: "info.circle")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                DetailsDisclosure(id: "tools.server.\(server.identity)", expandAll: expandAll) {
                    MonoValue(server.identity, font: TypeRamp.machineCaption, onCopy: {
                        appModel.appendLog(level: .info, "Copied MCP server identity for \(server.name).")
                    })
                    .foregroundStyle(.secondary)
                }
            }

            if isImporting {
                HStack(spacing: Space.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing tools…")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }

            if let probeError = server.candidate?.probeError {
                Label("Check failed: \(probeError)", systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .selectionDisabled()
    }
}

// MARK: - Detected (unimported) server rows

private struct CandidateServerRows: View {
    @Environment(AppModel.self) private var appModel

    let candidate: LocalMCPServerCandidate
    let isImporting: Bool
    let importError: String?
    let importAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s3) {
                MonoValue(candidate.displayEndpoint, font: TypeRamp.machineCaption, onCopy: {
                    appModel.appendLog(level: .info, "Copied MCP server address for \(candidate.displayName).")
                })
                .foregroundStyle(.secondary)

                Spacer()

                if candidate.bridgeable {
                    Button("Import", systemImage: "tray.and.arrow.down", action: importAction)
                        .disabled(appModel.localMCPWorkingServerID != nil)
                }
            }

            if let description = candidate.probe?.serverInfo.description, !description.isEmpty {
                Text(description)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !candidate.bridgeable, let reason = candidate.reason {
                Label(reason, systemImage: "info.circle")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }

            if isImporting {
                HStack(spacing: Space.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing tools…")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }

            if let probeError = candidate.probeError {
                Label("Check failed: \(probeError)", systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .selectionDisabled()

        if let tools = candidate.probe?.tools, !tools.isEmpty {
            ForEach(tools) { tool in
                CandidateToolInfoRow(tool: tool)
                    .selectionDisabled()
            }
        } else {
            Text("No tool list is available — scan again to check this server.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }
}

private struct CandidateToolInfoRow: View {
    let tool: LocalMCPToolSummary

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: tool.capability.chipSymbolName)
                .font(.callout)
                .foregroundStyle(tool.capability.chipTint)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s2) {
                    Text(tool.displayTitle)
                        .lineLimit(1)
                    Text(tool.name)
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let description = tool.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            StateChip(capability: tool.capability)
        }
    }
}

// MARK: - Shared error row

private struct ErrorRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.red)
            .textSelection(.enabled)
    }
}
