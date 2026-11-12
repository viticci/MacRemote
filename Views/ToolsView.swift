import SwiftUI

// MARK: - Shared Tools-surface vocabulary

extension ToolCategory {
    var iconSystemImage: String {
        switch self {
        case .reminders: "checklist"
        case .notes: "note.text"
        case .habits: "figure.mind.and.body"
        case .podcasts: "music.microphone"
        case .music: "music.note"
        case .readLater: "bookmark"
        case .filesystem: "folder"
        case .utilities: "wrench.adjustable"
        case .imageProcessing: "photo"
        case .text: "text.alignleft"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .ai: "apple.intelligence"
        case .iphone: "iphone"
        }
    }

    var iconTint: Color {
        switch self {
        case .reminders: .blue
        case .notes: .yellow
        case .habits: .mint
        case .podcasts: .purple
        case .music: .pink
        case .readLater: .blue
        case .filesystem: .orange
        case .utilities: .green
        case .imageProcessing: .pink
        case .text: .indigo
        case .developer: .teal
        case .ai: .cyan
        case .iphone: .indigo
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
    /// Visible copy for built-in tools that run in-process (no subprocess).
    static let nativeExecutionSummary = "Runs natively in MacRemote — no command is launched."

    var isNativeExecution: Bool { backend == .native }

    var modeDisplayTitle: String {
        if isMCPBridge { return "Imported" }
        if isNativeExecution { return "Native" }
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
    let server: ServerHeaderModel?
    /// A single-server page lists its tools without a section header.
    var isFlat: Bool = false
}

/// One imported MCP server family: its tools plus the header model the
/// source column and the server page share.
private struct ServerFamily: Identifiable {
    let header: ServerHeaderModel
    let tools: [ToolDefinition]

    var id: String { header.identity }
}

private struct ServerRefreshRequest: Identifiable {
    let candidateID: String
    let serverName: String
    let toolCount: Int

    var id: String { candidateID }
}

// MARK: - ToolsView

/// The Tools page (D63): a source column on the left — command-line groups,
/// then every MCP server — and one page per source on the right, so an MCP
/// server is one click away instead of a scroll to the bottom.
struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedToolID: String?
    @AppStorage("MacRemote.tools.source") private var storedSource = ToolsSource.all.rawValue
    @AppStorage("MacRemote.tools.groupBy.v2") private var groupBy: ToolsGroupBy = .category
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
    @State private var lastImportServerIdentity: String?
    @State private var lastSignInServerID: String?
    @State private var expandAll = DetailsExpandAll()
    @State private var inspectorTabRequest: ToolInspectorTab?
    @State private var missingExecutableToolIDs: Set<String> = []

    var body: some View {
        toolsLifecycle
    }

    private var toolsChrome: some View {
        content
            .navigationTitle("Tools")
            .navigationSubtitle("\(sharedCount) shared of \(appModel.allTools.count)")
            .searchable(text: $searchText, prompt: "Search tools")
            .searchFocused($isSearchFocused)
            .toolbar { toolbarContent }
    }

    private var toolsPresentations: some View {
        @Bindable var appModel = appModel

        return toolsChrome
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
    }

    private var toolsDialogs: some View {
        toolsPresentations
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
                Text("Refreshing updates this server's \(counted(request.toolCount, "tool")). Unchanged tools keep Always Allow; changed or removed tools ask again.")
            }
    }

    private var toolsLifecycle: some View {
        toolsDialogs
            .onChange(of: appModel.pendingToolsCommand) {
                consumePendingToolsCommand()
            }
            .onChange(of: appModel.searchFocusToken) {
                isSearchFocused = true
            }
            .onChange(of: familyIdentities) {
                followImportedFamily()
            }
            .task {
                consumePendingToolsCommand()
            }
            .task(id: missingFileCheckKey) {
                await refreshMissingExecutables()
            }
            .task(id: storedSource) {
                checkOpenedServerIfNeeded()
            }
            .pageContainerShape()
    }

    // MARK: Source selection

    private var source: ToolsSource {
        get { ToolsSource(rawValue: storedSource) ?? .all }
        nonmutating set { storedSource = newValue.rawValue }
    }

    /// The stored source, or All Tools when its server or candidate is gone.
    private var effectiveSource: ToolsSource {
        switch source {
        case .all, .allMCP, .commandLine:
            return source
        case .server(let identity):
            return serverFamilies.contains { $0.id == identity } ? source : .all
        case .candidate(let id):
            return unimportedCandidates.contains { $0.id == id } ? source : .all
        }
    }

    private var sourceBinding: Binding<ToolsSource> {
        Binding(
            get: { effectiveSource },
            set: { newValue in
                source = newValue
                selectedToolID = nil
            }
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if showsPageEmptyState {
            pageEmptyState
        } else {
            // A fixed-width column and a Divider, like the Library sheet. The
            // GeometryReader keeps this page's reported minimum size at zero:
            // when the column plus a page header made the detail column's
            // minimum grow past the space left beside the inspector, AppKit's
            // split view re-entered layout during its constraint pass and the
            // app aborted (an `HSplitView` did the same).
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    sourceColumn
                        .frame(width: 232)
                    Divider()
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }

    private var sourceColumn: some View {
        ToolsSourceColumn(
            allCount: countForColumn(toolsInSelection(.all)),
            commandLineRows: commandLineRows,
            mcpCount: countForColumn(toolsInSelection(.allMCP)),
            serverRows: serverRows,
            candidateRows: candidateRows,
            isScanning: appModel.localMCPScanState.isScanning,
            selection: sourceBinding,
            scanAction: { appModel.scanLocalMCPServers() }
        )
    }

    private var detail: some View {
        VStack(spacing: 0) {
            detailHeader
            chipsBar
            if isSearchResultEmpty {
                EmptyState(searchText: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                toolsList
            }
        }
    }

    // MARK: Page headers

    @ViewBuilder
    private var detailHeader: some View {
        switch effectiveSource {
        case .all:
            ToolsPageHeader(
                systemImage: "square.grid.2x2",
                tint: .secondary,
                title: "All Tools",
                subtitle: "\(sharedCount) of \(appModel.allTools.count) shared · \(processTools.count) command-line · \(bridgeTools.count) from MCP servers"
            ) {
                EmptyView()
            } detail: {
                EmptyView()
            } actions: {
                EmptyView()
            } notes: {
                if let groupError = rowErrors["catalog"] {
                    ErrorRow(message: groupError)
                }
            }

        case .commandLine(let group):
            let tools = commandLineTools(in: group)
            ToolsPageHeader(
                systemImage: group.systemImage,
                tint: .secondary,
                title: group.title,
                subtitle: "\(tools.count(where: { appModel.isToolExposed($0) })) of \(tools.count) shared"
            ) {
                EmptyView()
            } detail: {
                EmptyView()
            } actions: {
                if group == .found {
                    Button("Scan for Command-Line Tools…", systemImage: "sparkle.magnifyingglass") { openCommandLineToolsTab() }
                }
                if group == .added {
                    Button("New Tool…", systemImage: "plus") { beginNewTool() }
                }
                Menu {
                    Button("Share All") { setShared(true, for: tools, errorKey: "group.\(group.rawValue)") }
                    Button("Share None") { setShared(false, for: tools, errorKey: "group.\(group.rawValue)") }
                } label: {
                    Text("Share")
                }
                .fixedSize()
                .help("Share or stop sharing every tool in \(group.title)")
            } notes: {
                if let groupError = rowErrors["group.\(group.rawValue)"] {
                    ErrorRow(message: groupError)
                }
            }

        case .allMCP:
            ToolsPageHeader(
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: .teal,
                title: "MCP Servers",
                subtitle: scanSummaryLine
            ) {
                EmptyView()
            } detail: {
                Text("Find the MCP servers your Mac's AI apps already use, and share their tools through MacRemote.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } actions: {
                Button(
                    appModel.localMCPScanState.isScanning ? "Scanning…" : "Scan This Mac",
                    systemImage: "sparkle.magnifyingglass"
                ) {
                    appModel.scanLocalMCPServers()
                }
                .disabled(appModel.localMCPScanState.isScanning)
                .symbolEffect(.pulse, isActive: appModel.localMCPScanState.isScanning && !reduceMotion)
            } notes: {
                EmptyView()
            }

        case .server(let identity):
            if let family = serverFamilies.first(where: { $0.id == identity }) {
                ImportedServerHeader(
                    server: family.header,
                    status: status(for: family.header),
                    error: rowErrors["server.\(identity)"]
                        ?? importError(for: family.header.candidate?.id)
                        ?? signInError(for: family.header.candidate?.id),
                    shareAllBinding: Binding(
                        get: { family.header.sharedCount > 0 },
                        set: { enabled in
                            rowErrors["server.\(identity)"] = appModel.setLocalMCPBridgeServerEnabled(
                                bridgeIdentity: identity,
                                enabled: enabled
                            )
                        }
                    ),
                    signInAction: {
                        if let candidate = family.header.candidate {
                            signIn(candidateID: candidate.id)
                        }
                    },
                    refreshAction: {
                        if let candidate = family.header.candidate {
                            serverPendingRefresh = ServerRefreshRequest(
                                candidateID: candidate.id,
                                serverName: family.header.name,
                                toolCount: family.header.totalCount
                            )
                        }
                    }
                )
            }

        case .candidate(let id):
            if let candidate = unimportedCandidates.first(where: { $0.id == id }) {
                CandidateServerHeader(
                    candidate: candidate,
                    status: status(for: candidate),
                    importError: importError(for: candidate.id) ?? signInError(for: candidate.id),
                    signInAction: { signIn(candidateID: candidate.id) },
                    importAction: { importServer(candidate) }
                )
            }
        }
    }

    // MARK: Server status

    private func status(for server: ServerHeaderModel) -> MCPServerStatus {
        let candidate = server.candidate
        if let candidate, appModel.mcpSignInServerID == candidate.id {
            return MCPServerStatus(kind: .signingIn, detail: nil)
        }
        if appModel.isImportingLocalMCPServer(candidateID: candidate?.id) {
            return MCPServerStatus(kind: .importing, detail: nil)
        }
        if let candidate, appModel.localMCPCheckingServerID == candidate.id {
            return MCPServerStatus(kind: .checking, detail: nil)
        }
        let signedIn = appModel.isMCPServerSignedIn(serverURL: server.serverURL)
        if candidate?.needsSignIn == true || (server.usesUpstreamOAuth && !signedIn) {
            return MCPServerStatus(kind: .needsSignIn, detail: Self.signInDetail(serverName: server.name))
        }
        if let error = candidate?.probeError {
            return MCPServerStatus(kind: .checkFailed, detail: "Check failed: \(error)")
        }
        if signedIn {
            return MCPServerStatus(kind: .signedIn, detail: nil)
        }
        return MCPServerStatus(kind: .unknown, detail: nil)
    }

    private func status(for candidate: LocalMCPServerCandidate) -> MCPServerStatus {
        if appModel.mcpSignInServerID == candidate.id {
            return MCPServerStatus(kind: .signingIn, detail: nil)
        }
        if appModel.isImportingLocalMCPServer(candidateID: candidate.id) {
            return MCPServerStatus(kind: .importing, detail: nil)
        }
        if appModel.localMCPCheckingServerID == candidate.id {
            return MCPServerStatus(kind: .checking, detail: nil)
        }
        if candidate.needsSignIn {
            return MCPServerStatus(kind: .needsSignIn, detail: Self.signInDetail(serverName: candidate.displayName))
        }
        if let error = candidate.probeError {
            return MCPServerStatus(kind: .checkFailed, detail: "Check failed: \(error)")
        }
        if !candidate.bridgeable {
            return MCPServerStatus(kind: .viewOnly, detail: candidate.reason)
        }
        return MCPServerStatus(kind: .ready, detail: nil)
    }

    private static func signInDetail(serverName: String) -> String {
        "Sign in to use this server's tools. Your browser opens \(serverName)'s approval page, and MacRemote keeps the sign-in in your Keychain."
    }

    // MARK: Source column rows

    private var commandLineRows: [ToolsSourceRow] {
        ToolsSource.CommandLineGroup.allCases.compactMap { group in
            let tools = commandLineTools(in: group)
            guard !tools.isEmpty else { return nil }
            return ToolsSourceRow(
                source: .commandLine(group),
                title: group.title,
                systemImage: group.systemImage,
                tint: .secondary,
                trailing: .count(countForColumn(tools))
            )
        }
    }

    private var serverRows: [ToolsSourceRow] {
        serverFamilies.map { family in
            ToolsSourceRow(
                source: .server(family.id),
                title: family.header.name,
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: .teal,
                trailing: .count(countForColumn(family.tools)),
                attention: status(for: family.header).kind
            )
        }
    }

    private var candidateRows: [ToolsSourceRow] {
        unimportedCandidates.map { candidate in
            ToolsSourceRow(
                source: .candidate(candidate.id),
                title: candidate.displayName,
                systemImage: candidate.bridgeable ? "tray.and.arrow.down" : "eye",
                tint: .secondary,
                trailing: candidate.isNewSinceLastScan ? .new : .none,
                attention: status(for: candidate).kind
            )
        }
    }

    /// Column counts follow the search and filter, so a query shows where its
    /// matches live before you click.
    private func countForColumn(_ tools: [ToolDefinition]) -> Int {
        tools.count(where: { matchesFilter($0) && matchesSearch($0) })
    }

    private var toolsList: some View {
        List(selection: $selectedToolID) {
            ForEach(sections) { section in
                if section.isFlat {
                    ForEach(section.tools) { tool in
                        toolRow(for: tool)
                            .tag(tool.id)
                    }
                } else {
                    Section {
                        if !collapsedSectionIDs.contains(section.id) {
                            sectionRows(for: section)
                        }
                    } header: {
                        sectionHeader(for: section)
                    }
                }
            }

            if case .candidate(let id) = effectiveSource,
               let candidate = unimportedCandidates.first(where: { $0.id == id }) {
                CandidateToolRows(candidate: candidate, searchText: searchText)
            }

            if case .allMCP = effectiveSource {
                scanStatusSection
            }
        }
        // Rows the list has not drawn yet are estimated at this height; it
        // must match the drawn tool row, or the list jumps (ListMetrics).
        .environment(\.defaultMinListRowHeight, ListMetrics.toolRowHeight)
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
            // Wraps: beside an open inspector this column is too narrow for
            // five chips and a menu on one line.
            FlowLayout {
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
            Button("Update from Catalog", systemImage: "arrow.trianglehead.2.clockwise.rotate.90") {
                rowErrors["catalog"] = appModel.updateUserToolsFromCatalog()
            }
            .disabled(appModel.wholeCatalogUpdateCount == 0)
            .help("Refresh represented tools, adopt matching scanned tools, add missing definitions, and retire obsolete provider IDs")

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

    // MARK: Tool pools

    private var processTools: [ToolDefinition] {
        appModel.allTools.filter { !$0.isMCPBridge }
    }

    private var bridgeTools: [ToolDefinition] {
        appModel.tools.filter(\.isMCPBridge)
    }

    /// CLI-26/DV-5: provenance is the source key — scan-added tools group
    /// under Found on This Mac, hand-added ones under Added by You.
    private func commandLineTools(in group: ToolsSource.CommandLineGroup) -> [ToolDefinition] {
        processTools.filter { tool in
            switch group {
            case .builtIn:
                return !tool.isUserDefined
            case .federico:
                return DefaultToolPresetCatalog.preset(toolID: tool.id)?.publisher == .federicoViticci
            case .otherCatalog:
                return DefaultToolPresetCatalog.preset(toolID: tool.id)?.publisher == .other
            case .added:
                return tool.isUserDefined && tool.provenance == nil && DefaultToolPresetCatalog.preset(toolID: tool.id) == nil
            case .found:
                return tool.isUserDefined && tool.provenance != nil && DefaultToolPresetCatalog.preset(toolID: tool.id) == nil
            }
        }
    }

    private var serverFamilies: [ServerFamily] {
        let grouped = Dictionary(grouping: bridgeTools, by: Self.familyIdentity(of:))
        let candidatesByIdentity = appModel.localMCPScanState.candidates.reduce(
            into: [String: LocalMCPServerCandidate]()
        ) { result, candidate in
            result[candidate.persistedServerIdentity] = result[candidate.persistedServerIdentity] ?? candidate
            if let bridgeIdentity = candidate.bridgeIdentity {
                result[bridgeIdentity] = result[bridgeIdentity] ?? candidate
            }
        }

        return grouped
            .map { identity, tools -> ServerFamily in
                let sorted = tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                let header = ServerHeaderModel(
                    identity: identity,
                    name: tools.first?.mcpBridgeServerName ?? "Local MCP Server",
                    totalCount: tools.count,
                    sharedCount: tools.count(where: { appModel.isToolExposed($0) }),
                    candidate: candidatesByIdentity[identity]
                        ?? tools.first?.mcpBridgeIdentity.flatMap { candidatesByIdentity[$0] },
                    serverURL: tools.first?.mcpBridge?.serverURL,
                    usesUpstreamOAuth: tools.contains { tool in
                        tool.mcpBridge?.headers.contains(where: \.isUpstreamOAuth) == true
                    }
                )
                return ServerFamily(header: header, tools: sorted)
            }
            .sorted { $0.header.name.localizedCaseInsensitiveCompare($1.header.name) == .orderedAscending }
    }

    private static func familyIdentity(of tool: ToolDefinition) -> String {
        tool.mcpBridgeServerIdentity ?? tool.mcpBridgeIdentity ?? tool.id
    }

    /// The imported families, for `onChange`. It runs on every render, so it
    /// skips the headers, candidates, and sorting that `serverFamilies` builds.
    private var familyIdentities: [String] {
        Set(bridgeTools.map(Self.familyIdentity(of:))).sorted()
    }

    private var importedIdentities: Set<String> {
        Set(appModel.tools.compactMap { tool in
            tool.mcpBridgeServerIdentity ?? tool.mcpBridgeIdentity
        })
    }

    private var unimportedCandidates: [LocalMCPServerCandidate] {
        // Built once: reading `importedIdentities` inside the filter rebuilt
        // the set from every tool, twice per candidate, on every render.
        let imported = importedIdentities
        return appModel.localMCPScanState.candidates
            .filter { candidate in
                if imported.contains(candidate.persistedServerIdentity) {
                    return false
                }
                if let bridgeIdentity = candidate.bridgeIdentity,
                   imported.contains(bridgeIdentity) {
                    return false
                }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.isNewSinceLastScan != rhs.isNewSinceLastScan {
                    return lhs.isNewSinceLastScan
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }

    private func toolsInSelection(_ source: ToolsSource) -> [ToolDefinition] {
        switch source {
        case .all: appModel.allTools
        case .commandLine(let group): commandLineTools(in: group)
        case .allMCP: bridgeTools
        case .server(let identity): serverFamilies.first { $0.id == identity }?.tools ?? []
        case .candidate: []
        }
    }

    private var visibleTools: [ToolDefinition] {
        toolsInSelection(effectiveSource).filter { matchesFilter($0) && matchesSearch($0) }
    }

    // MARK: Section building

    private var sections: [ToolsSection] {
        let visible = visibleTools
        switch effectiveSource {
        case .all:
            let process = visible.filter { !$0.isMCPBridge }
            switch groupBy {
            case .category: return categorySections(process) + serverSections(visible)
            case .source: return sourceSections(process) + serverSections(visible)
            case .capability: return capabilitySections(visible)
            }
        case .commandLine(let group):
            switch groupBy {
            case .category: return categorySections(visible)
            case .capability: return capabilitySections(visible)
            case .source: return [makeSection(id: "source.\(group.rawValue)", title: group.title, tools: visible)]
            }
        case .allMCP:
            return serverSections(visible)
        case .server(let identity):
            if groupBy == .capability {
                return capabilitySections(visible)
            }
            var flat = makeSection(id: "server.\(identity)", title: "", tools: visible)
            flat.isFlat = true
            return [flat]
        case .candidate:
            return []
        }
    }

    private func categorySections(_ tools: [ToolDefinition]) -> [ToolsSection] {
        let grouped = Dictionary(grouping: tools, by: \.category)
        return grouped.keys
            .sorted { $0.title < $1.title }
            .compactMap { category in
                guard let tools = grouped[category], !tools.isEmpty else { return nil }
                return makeSection(id: "category.\(category.rawValue)", title: category.title, tools: tools)
            }
    }

    private func sourceSections(_ tools: [ToolDefinition]) -> [ToolsSection] {
        let ids = Set(tools.map(\.id))
        return ToolsSource.CommandLineGroup.allCases.compactMap { group in
            let groupTools = commandLineTools(in: group).filter { ids.contains($0.id) }
            guard !groupTools.isEmpty else { return nil }
            return makeSection(id: "source.\(group.rawValue)", title: group.title, tools: groupTools)
        }
    }

    private func capabilitySections(_ tools: [ToolDefinition]) -> [ToolsSection] {
        let order: [ToolCapability] = [.readOnly, .write, .destructive]
        let grouped = Dictionary(grouping: tools, by: \.capability)
        return order.compactMap { capability in
            guard let tools = grouped[capability], !tools.isEmpty else { return nil }
            return makeSection(id: "capability.\(capability.rawValue)", title: capability.title, tools: tools)
        }
    }

    private func serverSections(_ visible: [ToolDefinition]) -> [ToolsSection] {
        let visibleIDs = Set(visible.map(\.id))
        return serverFamilies.compactMap { family in
            let tools = family.tools.filter { visibleIDs.contains($0.id) }
            guard !tools.isEmpty || searchText.isEmpty else { return nil }
            return ToolsSection(
                id: "server.\(family.id)",
                title: family.header.name,
                tools: tools,
                sharedCount: tools.count(where: { appModel.isToolExposed($0) }),
                server: family.header
            )
        }
    }

    private func makeSection(id: String, title: String, tools: [ToolDefinition]) -> ToolsSection {
        let sorted = tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ToolsSection(
            id: id,
            title: title,
            tools: sorted,
            sharedCount: sorted.count(where: { appModel.isToolExposed($0) }),
            server: nil
        )
    }

    // MARK: Section headers and rows

    /// The section's name comes first: beside an open inspector the header
    /// drops its shared count before it shortens the name.
    private func sectionHeader(for section: ToolsSection) -> some View {
        ViewThatFits(in: .horizontal) {
            sectionHeader(for: section, showsCounts: true)
            sectionHeader(for: section, showsCounts: false)
        }
    }

    private func sectionHeader(for section: ToolsSection, showsCounts: Bool) -> some View {
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
                        .lineLimit(1)
                        // Unshrinkable with the counts, so a header that
                        // would shorten the name gives way to the plain one.
                        .fixedSize(horizontal: showsCounts, vertical: false)
                    Text("(\(section.tools.count))")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .countText()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(section.title), \(counted(section.tools.count, "tool"))")
            .accessibilityValue(collapsedSectionIDs.contains(section.id) ? "Collapsed" : "Expanded")

            if let server = section.server {
                if let glyph = status(for: server).kind.columnGlyph {
                    Image(systemName: glyph.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(glyph.tint)
                        .symbolRenderingMode(.hierarchical)
                        .help(glyph.help)
                        .accessibilityLabel(glyph.help)
                }
            }

            Spacer(minLength: 0)

            if let server = section.server {
                if showsCounts {
                    if server.sharedCount > 0 && server.sharedCount < server.totalCount {
                        StateChip("Partially Shared", tint: .orange)
                    }
                    Text("\(server.sharedCount)/\(server.totalCount) shared")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .countText()
                        .lineLimit(1)
                        .fixedSize()
                }
                Button("Open", systemImage: "chevron.right") {
                    sourceBinding.wrappedValue = .server(server.identity)
                }
                .labelStyle(.titleAndIcon)
                .controlSize(.small)
                .help("Open \(server.name): status, sign-in, refresh, and sharing")
            } else {
                if showsCounts {
                    Text("\(section.sharedCount) shared")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .countText()
                        .lineLimit(1)
                        .fixedSize()
                }

                Menu {
                    Button("Share All") { setShared(true, for: section.tools, errorKey: section.id) }
                    Button("Share None") { setShared(false, for: section.tools, errorKey: section.id) }
                } label: {
                    Text("Share")
                }
                .fixedSize()
                // Small, like the server sections' Open button: a regular
                // menu drew the header 4 pt taller than the height the list
                // estimates for headers it has not drawn, so it jumped.
                .controlSize(.small)
                .help("Share or stop sharing every tool in \(section.title)")
            }
        }
    }

    @ViewBuilder
    private func sectionRows(for section: ToolsSection) -> some View {
        if let groupError = rowErrors[section.id] {
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

            if appModel.isCatalogUpdateAvailable(for: tool) {
                catalogUpdateRow(for: tool)
            }
        }
        .contextMenu {
            Button(appModel.isToolExposed(tool) ? "Stop Sharing" : "Share") { toggleShare(tool) }
            Button("Test Tool…") { testingTool = tool }
            if appModel.isCatalogUpdateAvailable(for: tool) {
                Button("Update from Catalog") {
                    rowErrors[tool.id] = appModel.updateUserToolFromCatalog(id: tool.id)
                }
            }
            if !tool.isMCPBridge {
                Button("Duplicate") { duplicate(tool) }
            }
            if tool.isUserDefined {
                Divider()
                Button("Remove…", role: .destructive) { toolPendingRemoval = tool }
            }
        }
    }

    private func catalogUpdateRow(for tool: ToolDefinition) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Label(
                "A newer command definition is available. Sharing stays the same; changed permissions ask again.",
                systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
            )
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.orange)

            Spacer()

            Button("Update from Catalog") {
                rowErrors[tool.id] = appModel.updateUserToolFromCatalog(id: tool.id)
            }
            .controlSize(.small)
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

    // MARK: Scan status section (All MCP Servers page)

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
            }

            if !unimportedCandidates.isEmpty {
                Text("\(unimportedCandidates.count) \(unimportedCandidates.count == 1 ? "server is" : "servers are") not imported yet — pick one in the column on the left to review its tools.")
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
        }
    }

    private var showsScanEmptyState: Bool {
        !appModel.localMCPScanState.isScanning &&
            unimportedCandidates.isEmpty &&
            importedIdentities.isEmpty &&
            !isScanFailed
    }

    /// LM-3 — the old overview pills survive as one status line.
    private var scanSummaryLine: String {
        let candidates = appModel.localMCPScanState.candidates
        guard !candidates.isEmpty || !importedIdentities.isEmpty else {
            return "None found yet"
        }
        let readyCount = candidates.count(where: \.bridgeable)
        let newCount = candidates.count(where: \.isNewSinceLastScan)
        var parts = ["\(candidates.count) detected"]
        if newCount > 0 {
            parts.append("\(newCount) new")
        }
        parts.append("\(readyCount) ready to import")
        parts.append("\(serverFamilies.count) imported")
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
        guard !searchText.isEmpty, visibleTools.isEmpty else { return false }
        if case .candidate(let id) = effectiveSource,
           let candidate = unimportedCandidates.first(where: { $0.id == id }) {
            return !(candidate.probe?.tools ?? []).contains { CandidateToolRows.matches($0, searchText) }
        }
        return true
    }

    // MARK: Counts and filtering

    private var sharedCount: Int {
        appModel.allTools.count(where: { appModel.isToolExposed($0) })
    }

    private func count(for filter: ToolsFilter) -> Int {
        toolsInSelection(effectiveSource).count(where: { matches($0, filter: filter) })
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
            appModel.isToolExposed(tool) && tool.asksBeforeRunning
        case .readOnly:
            appModel.isToolExposed(tool) && !tool.asksBeforeRunning
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

    private func setShared(_ shared: Bool, for tools: [ToolDefinition], errorKey: String) {
        rowErrors[errorKey] = nil
        for tool in tools {
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

    /// Importing a detected server turns its column row into a server row;
    /// remember the identity so the page follows it there.
    private func importServer(_ candidate: LocalMCPServerCandidate) {
        lastImportServerID = candidate.id
        lastImportServerIdentity = candidate.persistedServerIdentity
        appModel.importLocalMCPServer(candidateID: candidate.id)
    }

    private func followImportedFamily() {
        guard case .candidate = source,
              let identity = lastImportServerIdentity,
              familyIdentities.contains(identity) else {
            return
        }
        lastImportServerIdentity = nil
        source = .server(identity)
    }

    /// Opening an HTTP server's page checks it once, so the page reports a
    /// live state instead of waiting for Refresh. Never repeats for a server
    /// already checked, and never touches stdio servers.
    private func checkOpenedServerIfNeeded() {
        let candidate: LocalMCPServerCandidate?
        switch effectiveSource {
        case .server(let identity):
            candidate = serverFamilies.first { $0.id == identity }?.header.candidate
        case .candidate(let id):
            candidate = unimportedCandidates.first { $0.id == id }
        case .all, .allMCP, .commandLine:
            candidate = nil
        }
        guard let candidate,
              candidate.transport == .http,
              candidate.probe == nil,
              candidate.probeError == nil,
              !candidate.needsSignIn else {
            return
        }
        appModel.checkMCPServer(candidateID: candidate.id)
    }

    private func signIn(candidateID: String) {
        lastSignInServerID = candidateID
        appModel.signInToMCPServer(candidateID: candidateID)
    }

    private func importError(for candidateID: String?) -> String? {
        guard let candidateID, candidateID == lastImportServerID else { return nil }
        return appModel.localMCPErrorMessage
    }

    private func signInError(for candidateID: String?) -> String? {
        guard let candidateID, candidateID == lastSignInServerID else { return nil }
        return appModel.mcpSignInErrorMessage
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

    static func sourceTitle(_ source: String) -> String {
        switch source {
        case FirstPartyMCPProviderCatalog.discoverySource: "Federico Viticci"
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
            // The name matters most. As the column narrows the row first drops
            // the chips that repeat what the switch and the inspector say,
            // then shows the capability as its symbol, and only then shortens
            // the name.
            ViewThatFits(in: .horizontal) {
                line(chips: .all, fullName: true)
                line(chips: .capability, fullName: true)
                line(chips: .symbol, fullName: true)
                line(chips: .symbol, fullName: false)
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

    /// How much a row's chips say; see `body`.
    private enum ChipDetail {
        case all, capability, symbol
    }

    private func line(chips detail: ChipDetail, fullName: Bool) -> some View {
        HStack(spacing: Space.s3) {
            iconView

            Text(tool.name)
                .lineLimit(1)
                // At its full width the name cannot be squeezed, so a line
                // that would shorten it does not fit and the next one is tried.
                .fixedSize(horizontal: fullName, vertical: false)

            Spacer(minLength: 0)

            chips(detail)

            Toggle("Share", isOn: shareBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityLabel("Share \(tool.name)")
        }
    }

    private func chips(_ detail: ChipDetail) -> some View {
        HStack(spacing: Space.s1) {
            if detail == .all {
                if !isShared {
                    StateChip("Not Shared", role: .off)
                }
                if tool.isGenericCLIAdapter {
                    StateChip("Flexible Command", role: .off)
                }
            }
            if detail == .symbol {
                capabilityChip.symbolOnly()
            } else {
                capabilityChip
            }
            permissionDots
        }
    }

    private var capabilityChip: StateChip {
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

// MARK: - Detected (unimported) server tool preview

/// The upstream tool list of a server that is not imported yet: read-only
/// rows, so you can see what Import would bring in.
private struct CandidateToolRows: View {
    let candidate: LocalMCPServerCandidate
    let searchText: String

    var body: some View {
        if let tools = candidate.probe?.tools, !tools.isEmpty {
            let visible = tools.filter { Self.matches($0, searchText) }
            Section {
                ForEach(visible) { tool in
                    CandidateToolInfoRow(tool: tool)
                        .selectionDisabled()
                }
            } header: {
                Text("\(visible.count) of \(counted(tools.count, "tool"))")
                    .font(TypeRamp.cardTitle)
                    .countText()
            }
        } else {
            Text("No tool list is available — check this server again.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .selectionDisabled()
        }
    }

    static func matches(_ tool: LocalMCPToolSummary, _ searchText: String) -> Bool {
        guard !searchText.isEmpty else { return true }
        return [tool.displayTitle, tool.name, tool.description ?? ""].contains {
            $0.localizedCaseInsensitiveContains(searchText)
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
