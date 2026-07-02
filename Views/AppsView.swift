import SwiftUI

/// Apps — one card per connected app (spec §5.2). Absorbs the old Clients
/// surface: identity, token liveness, the Details grid, bulk verbs, and the
/// per-tool Always Allow policy list grouped by category.
struct AppsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var expandAll = DetailsExpandAll()
    @State private var deletionSummary: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        Group {
            if appModel.connectedClients.isEmpty {
                EmptyState(
                    "No apps yet",
                    systemImage: "app.badge.checkmark",
                    message: "Go public, paste your link into an app like Claude, then approve its request here.",
                    actionTitle: "Copy Public URL",
                    action: { appModel.copyPublicURL() }
                )
            } else {
                appList
            }
        }
        .pageContainerShape()
        .navigationTitle("Apps")
        .navigationSubtitle("\(appModel.connectedClients.count) connected")
        .searchable(text: $searchText, prompt: "Search allowed tools")
        .searchFocused($isSearchFocused)
        .onChange(of: appModel.searchFocusToken) {
            isSearchFocused = true
        }
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s6) {
                if let deletionSummary {
                    InlineSummaryRow(text: deletionSummary) {
                        self.deletionSummary = nil
                    }
                }
                ForEach(appModel.connectedClients) { client in
                    AppCard(
                        client: client,
                        searchText: searchText,
                        expandAll: $expandAll,
                        onDeleted: { deletionSummary = $0 }
                    )
                }
            }
            .padding(Space.s5)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: - AppCard

private struct AppCard: View {
    @Environment(AppModel.self) private var appModel
    let client: ConnectedClient
    let searchText: String
    let expandAll: Binding<DetailsExpandAll>
    let onDeleted: (String) -> Void

    @State private var isConfirmingAllowAll = false
    @State private var isConfirmingDelete = false
    @State private var expandedCategories: Set<ToolCategory> = []
    @State private var actionSummary: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Space.s3) {
                header
                metaLine

                DetailsDisclosure(id: "apps.details.\(client.id)", expandAll: expandAll) {
                    KeyValueGrid(rows: detailRows) { row in
                        appModel.appendLog(level: .info, "Copied \(row.label) for \(client.name).")
                    }
                }

                verbRow

                if let actionSummary {
                    InlineSummaryRow(text: actionSummary) {
                        self.actionSummary = nil
                    }
                }

                Divider()

                policyList
                staleAllowancesFooter
            }
        }
        .opacity(isExpired ? 0.85 : 1)
    }

    // MARK: Identity

    /// A client stays listed while it holds an approved sign-in; with zero
    /// live tokens its session has lapsed — the old UI let it vanish silently.
    private var isExpired: Bool {
        client.activeAccessTokens == 0 && client.activeRefreshTokens == 0
    }

    /// Confidential (static-credential) clients carry the coordinator's
    /// "macremote-confidential-" trust prefix; everything else self-registered.
    private var isStaticClient: Bool {
        client.trustID.hasPrefix("macremote-confidential-")
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.6))
                Image(systemName: ConnectorProviderProfile.inferred(fromClientName: client.name).systemImage)
                    .font(.caption)
                    .foregroundStyle(isExpired ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
            .frame(width: 28, height: 28)

            Text(client.name)
                .font(TypeRamp.cardTitle)

            if !isExpired {
                StateChip("Active", systemImage: "checkmark.circle", role: .ready)
            }

            StateChip(
                isStaticClient ? "Signs in with client secret" : "Registered itself",
                systemImage: isStaticClient ? "key" : "person.badge.key",
                tint: .secondary
            )

            Spacer()

            StateChip(
                "\(allowedSharedCount)/\(sharedToolIDs.count) Always Allowed",
                systemImage: "checkmark.shield",
                tint: allowedSharedCount == 0 ? .secondary : .green
            )
        }
    }

    @ViewBuilder
    private var metaLine: some View {
        if isExpired {
            Text("Sign-in expired — reappears when it reconnects")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            Text("Last connected \(client.lastAuthorizedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
        } else {
            Text("^[\(client.activeAccessTokens) access token](inflect: true) · ^[\(client.activeRefreshTokens) refresh token](inflect: true) · Last connected \(client.lastAuthorizedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .countText()
        }
    }

    private var detailRows: [KeyValueRow] {
        var rows = [
            KeyValueRow("Client ID", client.id),
            KeyValueRow("Trust ID", client.trustID)
        ]
        if let issuer = client.issuer {
            rows.append(KeyValueRow("Issuer", issuer))
        }
        if let resource = client.resource {
            rows.append(KeyValueRow("Resource", resource))
        }
        rows.append(KeyValueRow("Scopes", client.scopes.joined(separator: ", ")))
        rows.append(KeyValueRow("Last Auth", client.lastAuthorizedAt.formatted(date: .abbreviated, time: .shortened)))
        rows.append(KeyValueRow("Access Tokens", String(client.activeAccessTokens)))
        rows.append(KeyValueRow("Refresh Tokens", String(client.activeRefreshTokens)))
        return rows
    }

    // MARK: Bulk verbs

    private var verbRow: some View {
        HStack(spacing: Space.s2) {
            Button("Allow All Current Tools", systemImage: "checkmark.shield") {
                isConfirmingAllowAll = true
            }
            .disabled(appModel.tools.isEmpty)

            Button("Revoke All Always-Allows", systemImage: "xmark.shield") {
                revokeAllAllowances()
            }
            .disabled(allowedToolIDs.isEmpty)

            Button("Delete App…", systemImage: "trash", role: .destructive) {
                isConfirmingDelete = true
            }
        }
        .confirmationDialog(
            "Allow all current tools?",
            isPresented: $isConfirmingAllowAll,
            titleVisibility: .visible
        ) {
            Button("Allow All") {
                allowAllCurrentTools()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(client.name) will run all \(appModel.toolExposureSummary.total) shared tools without asking — including \(appModel.toolExposureSummary.gatedToolCount) that normally ask first.")
        }
        .confirmationDialog(
            "Delete \u{201C}\(client.name)\u{201D}?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete App", role: .destructive) {
                deleteApp()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(client.name) is signed out; its tokens, pending requests, and Always Allow settings are removed. It can ask to connect again anytime.")
        }
    }

    private func allowAllCurrentTools() {
        appModel.allowAllCurrentTools(for: client.id)
        actionSummary = "\(client.name) now runs all \(appModel.toolExposureSummary.total) shared tools without asking."
    }

    private func revokeAllAllowances() {
        appModel.clearToolAllowances(for: client.id)
        actionSummary = "Removed every Always Allow rule for \(client.name)."
    }

    private func deleteApp() {
        let name = client.name
        let tokenCount = client.activeAccessTokens + client.activeRefreshTokens
        if let error = appModel.deleteOAuthClient(id: client.id) {
            onDeleted(error)
        } else {
            onDeleted("Signed out \(name) — removed 1 registration, \(tokenCount) token\(tokenCount == 1 ? "" : "s").")
        }
    }

    // MARK: Policy list

    private var sortedTools: [ToolDefinition] {
        appModel.tools.sorted { lhs, rhs in
            if lhs.category.title != rhs.category.title {
                return lhs.category.title < rhs.category.title
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var filteredTools: [ToolDefinition] {
        guard !searchText.isEmpty else { return sortedTools }
        return sortedTools.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var sharedToolIDs: Set<String> {
        Set(appModel.tools.filter { appModel.isToolExposed($0) }.map(\.id))
    }

    private var allowedToolIDs: Set<String> {
        appModel.alwaysAllowedToolIDs(for: client.id)
    }

    private var allowedSharedCount: Int {
        allowedToolIDs.intersection(sharedToolIDs).count
    }

    @ViewBuilder
    private var policyList: some View {
        if sortedTools.isEmpty {
            Text("No tools yet — anything you add in Tools shows up here.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        } else if filteredTools.isEmpty {
            Text("No tools match \u{201C}\(searchText)\u{201D}.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        } else {
            let visibleCategories = orderedCategories(of: filteredTools)
            ForEach(visibleCategories) { category in
                CategoryPolicySection(
                    client: client,
                    category: category,
                    categoryTools: sortedTools.filter { $0.category == category },
                    visibleTools: filteredTools.filter { $0.category == category },
                    isExpanded: !searchText.isEmpty || expandedCategories.contains(category),
                    onToggle: { toggleCategory(category) },
                    onSummary: { actionSummary = $0 }
                )
            }
        }
    }

    private func orderedCategories(of tools: [ToolDefinition]) -> [ToolCategory] {
        var seen = Set<ToolCategory>()
        var ordered: [ToolCategory] = []
        for tool in tools where !seen.contains(tool.category) {
            seen.insert(tool.category)
            ordered.append(tool.category)
        }
        return ordered
    }

    private func toggleCategory(_ category: ToolCategory) {
        withAnimation(.snappy) {
            if expandedCategories.contains(category) {
                expandedCategories.remove(category)
            } else {
                expandedCategories.insert(category)
            }
        }
    }

    // MARK: Stale allowances (rules for tools that no longer exist)

    @ViewBuilder
    private var staleAllowancesFooter: some View {
        let staleIDs = allowedToolIDs.subtracting(Set(appModel.tools.map(\.id)))
        if !staleIDs.isEmpty {
            HStack(spacing: Space.s2) {
                Text("\(staleIDs.count) rule\(staleIDs.count == 1 ? "" : "s") reference\(staleIDs.count == 1 ? "s" : "") removed tools")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                Button("Clean Up") {
                    cleanUpStaleAllowances(staleIDs)
                }
                .controlSize(.small)
            }
        }
    }

    private func cleanUpStaleAllowances(_ staleIDs: Set<String>) {
        for toolID in staleIDs {
            appModel.setToolAlwaysAllowed(false, toolID: toolID, clientID: client.id, clientTrustID: client.trustID)
        }
        actionSummary = "Removed \(staleIDs.count) rule\(staleIDs.count == 1 ? "" : "s") for tools that no longer exist."
    }
}

// MARK: - Category section

private struct CategoryPolicySection: View {
    @Environment(AppModel.self) private var appModel
    let client: ConnectedClient
    let category: ToolCategory
    /// The full category — bulk verbs act on this set even while a search
    /// narrows the visible rows.
    let categoryTools: [ToolDefinition]
    let visibleTools: [ToolDefinition]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSummary: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Button(action: onToggle) {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(category.title)
                            .font(TypeRamp.cardTitle)
                        Text("(\(allowedCount) of \(categoryTools.count) allowed)")
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.secondary)
                            .countText()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(category.title), \(allowedCount) of \(categoryTools.count) allowed")
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

                Spacer()

                Menu("Allow") {
                    Button("Allow All in \(category.title)") {
                        setCategoryAllowed(true)
                    }
                    Button("Revoke All in \(category.title)") {
                        setCategoryAllowed(false)
                    }
                    .disabled(allowedCount == 0)
                }
                .fixedSize()
                .controlSize(.small)
            }

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(visibleTools) { tool in
                        ToolPolicyRow(client: client, tool: tool)
                        if tool.id != visibleTools.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var allowedCount: Int {
        categoryTools.count { appModel.isToolAlwaysAllowed(toolID: $0.id, clientID: client.id) }
    }

    private func setCategoryAllowed(_ isAllowed: Bool) {
        for tool in categoryTools
        where appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: client.id) != isAllowed {
            appModel.setToolAlwaysAllowed(isAllowed, toolID: tool.id, clientID: client.id, clientTrustID: client.trustID)
        }
        onSummary(
            isAllowed
                ? "\(client.name) now runs every \(category.title) tool without asking."
                : "Removed every Always Allow rule in \(category.title) for \(client.name)."
        )
    }
}

// MARK: - Tool row

private struct ToolPolicyRow: View {
    @Environment(AppModel.self) private var appModel
    let client: ConnectedClient
    let tool: ToolDefinition

    var body: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s2) {
                    Text(tool.name)
                        .font(.body)
                    StateChip(capability: tool.capability)
                    if !appModel.isToolExposed(tool) {
                        StateChip("Not Shared", systemImage: "pause.circle", tint: .secondary)
                    }
                }
                MonoValue(tool.id, font: TypeRamp.machineCaption) {
                    appModel.appendLog(level: .info, "Copied tool ID \(tool.id).")
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle(
                "Always Allow",
                isOn: Binding(
                    get: {
                        appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: client.id)
                    },
                    set: { isAllowed in
                        appModel.setToolAlwaysAllowed(
                            isAllowed,
                            toolID: tool.id,
                            clientID: client.id,
                            clientTrustID: client.trustID
                        )
                    }
                )
            )
            .toggleStyle(.switch)
        }
        .padding(.vertical, Space.s2)
    }
}

// MARK: - Post-action feedback (spec §5.2 — inline, not logs-only)

private struct InlineSummaryRow: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(text)
                .font(TypeRamp.rowDetail)
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Space.s2)
        .background(.quaternary.opacity(0.4), in: AppShape.mono)
    }
}
