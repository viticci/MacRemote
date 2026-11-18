import SwiftUI

/// Apps — one card per connected app (spec §5.2). Absorbs the old Clients
/// surface: identity, token liveness, the Details grid, bulk verbs, and the
/// per-tool Always Allow policy list grouped by category.
struct AppsView: View {
    /// Live token state changes without any UI event, so an open window
    /// re-reads it on a slow beat rather than letting the Active chip go stale.
    private static let livenessInterval: Duration = .seconds(30)

    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""
    @State private var expandAll = DetailsExpandAll()
    @State private var signOutSummary: String?
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
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, prompt: "Search apps")
        .searchFocused($isSearchFocused)
        .onChange(of: appModel.searchFocusToken) {
            isSearchFocused = true
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.livenessInterval)
                guard !Task.isCancelled else { return }
                appModel.refreshConnectedClients()
            }
        }
    }

    private var subtitle: String {
        let all = appModel.connectedClients.count
        let active = appModel.connectedClients.count { $0.sessionState == .active }
        return active == all
            ? "\(all) connected"
            : "\(all) connected · \(active) signed in"
    }

    private var matchingClients: [ConnectedClient] {
        guard !searchText.isEmpty else { return appModel.connectedClients }
        return appModel.connectedClients.filter { Self.matches($0, query: searchText) }
    }

    /// What the user typed, matched loosely on purpose — this is a filter over
    /// a list already on screen, not brand inference, which stays exact (see
    /// `Models/ConnectedAppIdentity.swift`). IDs match by prefix so a copied
    /// prefix finds its app without a partial hash matching by accident.
    static func matches(_ client: ConnectedClient, query: String) -> Bool {
        let normalizedQuery = ConnectedAppIdentity.normalize(query)
        let rawQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty || !rawQuery.isEmpty else { return true }

        let identity = ConnectedAppIdentity.resolve(
            name: client.name,
            redirectURIs: client.redirectURIs
        )
        if !normalizedQuery.isEmpty {
            if ConnectedAppIdentity.normalize(client.name).contains(normalizedQuery)
                || ConnectedAppIdentity.normalize(identity.displayName).contains(normalizedQuery) {
                return true
            }
        }
        guard !rawQuery.isEmpty else { return false }
        return client.id.lowercased().hasPrefix(rawQuery)
            || client.trustID.lowercased().hasPrefix(rawQuery)
    }

    @ViewBuilder
    private var appList: some View {
        let clients = matchingClients
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s6) {
                if let signOutSummary {
                    InlineSummaryRow(text: signOutSummary) {
                        self.signOutSummary = nil
                    }
                }
                if clients.isEmpty {
                    Text("No apps match \u{201C}\(searchText)\u{201D}.")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, Space.s6)
                }
                // Order comes from the coordinator's snapshot (signed in, then
                // mid-sign-in, then lapsed); the view never re-sorts.
                ForEach(clients) { client in
                    AppCard(
                        client: client,
                        expandAll: $expandAll,
                        onSignedOut: { signOutSummary = $0 }
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
    /// Below this a card's tool list is short enough to scan; above it the
    /// per-card filter earns its space (spec §5.2 progressive disclosure).
    private static let toolFilterThreshold = 8

    @Environment(AppModel.self) private var appModel
    let client: ConnectedClient
    let expandAll: Binding<DetailsExpandAll>
    let onSignedOut: (String) -> Void

    @State private var isConfirmingAllowAll = false
    @State private var isConfirmingSignOut = false
    @State private var expandedCategories: Set<ToolCategory> = []
    @State private var actionSummary: String?
    @State private var toolFilter = ""

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
        .opacity(client.sessionState == .expired ? 0.85 : 1)
    }

    // MARK: Identity

    /// A card stays listed while the app holds an approved sign-in. Which of
    /// the three real states it is in comes from the coordinator, not from a
    /// token count the view interprets on its own.
    @ViewBuilder
    private var sessionChip: some View {
        switch client.sessionState {
        case .active:
            StateChip("Active", systemImage: "checkmark.circle", role: .ready)
        case .awaitingSignIn:
            StateChip("Waiting to finish signing in", systemImage: "hourglass", role: .attention)
        case .expired:
            StateChip("Sign-in expired", systemImage: "clock.badge.xmark", tint: .secondary)
        }
    }

    private var header: some View {
        HStack(spacing: Space.s3) {
            ConnectedAppIconView(
                clientName: client.name,
                redirectURIs: client.redirectURIs,
                clientSuppliedIcons: appModel.clientSuppliedIcons(forClientID: client.id),
                size: .card,
                isDimmed: client.sessionState != .active
            )

            Text(client.name)
                .font(TypeRamp.cardTitle)

            sessionChip

            StateChip(
                client.authenticationMethod.isConfidential
                    ? "Signs in with client secret"
                    : "Registered itself",
                systemImage: client.authenticationMethod.isConfidential ? "key" : "person.badge.key",
                tint: .secondary
            )

            Spacer()

            StateChip(
                policySummary.badgeText,
                systemImage: "checkmark.shield",
                tint: policySummary.allowedSharedCount == 0 ? .secondary : .green
            )
            .help(policySummary.badgeHelp(clientName: client.name))
        }
    }

    private var firstConnected: String {
        client.createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var lastConnected: String {
        client.lastAuthorizedAt.formatted(date: .abbreviated, time: .shortened)
    }

    @ViewBuilder
    private var metaLine: some View {
        switch client.sessionState {
        case .active:
            Text("^[\(client.activeAccessTokens) access token](inflect: true) · ^[\(client.activeRefreshTokens) refresh token](inflect: true) · First connected \(firstConnected) · Last connected \(lastConnected)")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .countText()
        case .awaitingSignIn:
            Text("Approved — waiting for the app to finish signing in.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            Text("First connected \(firstConnected) · Last connected \(lastConnected)")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
        case .expired:
            Text("Sign-in expired — reappears when it reconnects.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            Text("First connected \(firstConnected) · Last connected \(lastConnected)")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
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
        if !client.redirectURIs.isEmpty {
            rows.append(KeyValueRow("Redirect URIs", client.redirectURIs.joined(separator: ", ")))
        }
        rows.append(KeyValueRow("Scopes", client.scopes.joined(separator: ", ")))
        rows.append(KeyValueRow("First connected", firstConnected))
        rows.append(KeyValueRow("Last connected", lastConnected))
        rows.append(KeyValueRow("Access Tokens", String(client.activeAccessTokens)))
        rows.append(KeyValueRow("Refresh Tokens", String(client.activeRefreshTokens)))
        return rows
    }

    // MARK: Bulk verbs

    /// Every currently shared tool already has an Always Allow rule. The verb
    /// would be a no-op, so state stands in its place — clicking "Allow All"
    /// again because the grant was easy to forget is exactly what this avoids.
    private var allCurrentToolsAllowed: Bool {
        policySummary.allSharedToolsAllowed
    }

    private var verbRow: some View {
        HStack(spacing: Space.s2) {
            if allCurrentToolsAllowed {
                StateChip(policySummary.sharedCount == 1 ? "The 1 shared tool is already allowed" : "All \(policySummary.sharedCount) shared tools already allowed", systemImage: "checkmark.seal.fill", role: .ready)
                    .help("\(client.name) runs every currently shared tool without asking. Sharing a new tool brings the Allow All verb back.")
            } else {
                Button("Allow All Current Tools", systemImage: "checkmark.shield") {
                    isConfirmingAllowAll = true
                }
                .disabled(appModel.tools.isEmpty)
            }

            Button("Revoke All Always-Allows", systemImage: "xmark.shield") {
                revokeAllAllowances()
            }
            .disabled(allowedToolIDs.isEmpty)

            Button("Sign Out…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                isConfirmingSignOut = true
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
            Text(allowAllConsequence)
        }
        .confirmationDialog(
            "Sign out \u{201C}\(client.name)\u{201D}?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive) {
                signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(client.name)'s sign-in, tokens, waiting requests, and Always Allow settings are removed. It can ask to connect again anytime.")
        }
    }

    /// The dialog quotes the two numbers that decide whether this is a routine
    /// grant or a loaded one, and never rounds the loaded ones away.
    private var allowAllConsequence: String {
        let summary = policySummary
        let gated = appModel.toolExposureSummary.gatedToolCount
        var text = "\(client.name) will run \(Self.everySharedTool(summary.sharedCount)) without asking — including \(gated) that normally \(gated == 1 ? "asks" : "ask") first"
        if summary.riskySharedCount > 0 {
            text += " and \(summary.riskySharedCount) that \(summary.riskySharedCount == 1 ? "asks" : "ask") every time by default, like the Flexible Commands"
        }
        return text + ". You can undo this in Apps."
    }

    /// "all 12 shared tools", or "the 1 shared tool" when there is only one.
    private static func everySharedTool(_ count: Int) -> String {
        count == 1 ? "the 1 shared tool" : "all \(count) shared tools"
    }

    private func allowAllCurrentTools() {
        appModel.allowAllCurrentTools(for: client.id)
        actionSummary = "\(client.name) now runs \(Self.everySharedTool(policySummary.sharedCount)) without asking."
    }

    private func revokeAllAllowances() {
        appModel.clearToolAllowances(for: client.id)
        actionSummary = "Removed every Always Allow rule for \(client.name)."
    }

    /// The summary comes from the revocation itself. The old version counted
    /// tokens from this card's already-stale copy of the client.
    private func signOut() {
        switch appModel.signOutApp(id: client.id) {
        case .success(let result):
            onSignedOut(result.summary)
        case .failure(let error):
            onSignedOut(error.localizedDescription)
        }
    }

    // MARK: Policy list

    private var sortedTools: [ToolDefinition] {
        appModel.allTools.sorted { lhs, rhs in
            if lhs.category.title != rhs.category.title {
                return lhs.category.title < rhs.category.title
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var allowedToolIDs: Set<String> {
        appModel.alwaysAllowedToolIDs(for: client.id)
    }

    /// Every count this card shows comes from here, so the badge, the bulk
    /// verb, and the confirmation copy can never disagree.
    private var policySummary: AppToolPolicySummary {
        appModel.toolPolicySummary(for: client.id)
    }

    @ViewBuilder
    private var policyList: some View {
        let sortedTools = self.sortedTools
        if sortedTools.isEmpty {
            Text("No tools yet — anything you add in Tools shows up here.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        } else {
            policyListHeader(toolCount: sortedTools.count)
            let filteredTools = toolFilter.isEmpty ? sortedTools : sortedTools.filter {
                $0.name.localizedCaseInsensitiveContains(toolFilter)
                    || $0.id.localizedCaseInsensitiveContains(toolFilter)
            }
            if filteredTools.isEmpty {
                Text("No tools match \u{201C}\(toolFilter)\u{201D}.")
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
                        isExpanded: !toolFilter.isEmpty || expandedCategories.contains(category),
                        onToggle: { toggleCategory(category) },
                        onSummary: { actionSummary = $0 }
                    )
                }
            }
        }
    }

    /// Page search now finds apps, so the tool filter lives here — visible on
    /// the card it belongs to, and only once the list is long enough to need it.
    @ViewBuilder
    private func policyListHeader(toolCount: Int) -> some View {
        HStack(spacing: Space.s2) {
            Text("Tool permissions")
                .font(TypeRamp.cardTitle)
            Text("(\(toolCount))")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .countText()
            Spacer()
            if toolCount > Self.toolFilterThreshold {
                TextField("Filter tools", text: $toolFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .frame(maxWidth: 200)
                    .accessibilityLabel("Filter \(client.name)'s tools")
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
        let staleIDs = allowedToolIDs.subtracting(Set(appModel.allTools.map(\.id)))
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

    @State private var isConfirmingAllowAll = false

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
                    Button(riskyCount == 0 ? "Allow All in \(category.title)" : "Allow All in \(category.title)…") {
                        if riskyCount == 0 {
                            setCategoryAllowed(true)
                        } else {
                            isConfirmingAllowAll = true
                        }
                    }
                    Button("Revoke All in \(category.title)") {
                        setCategoryAllowed(false)
                    }
                    .disabled(!holdsGrantInCategory)
                }
                .fixedSize()
                .controlSize(.small)
            }
            .confirmationDialog(
                "Allow all \(category.title) tools?",
                isPresented: $isConfirmingAllowAll,
                titleVisibility: .visible
            ) {
                Button("Allow All") {
                    setCategoryAllowed(true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(client.name) will run \(categoryTools.count == 1 ? "the 1 \(category.title) tool" : "all \(categoryTools.count) \(category.title) tools") without asking — including \(riskyCount) that \(riskyCount == 1 ? "asks" : "ask") every time by default. You can undo this in Apps.")
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

    /// Tools in this category the app runs without asking: read-only ones
    /// never ask (D79), the others once granted.
    private var allowedCount: Int {
        categoryTools.count {
            !$0.asksBeforeRunning || appModel.isToolAlwaysAllowed(toolID: $0.id, clientID: client.id)
        }
    }

    private var holdsGrantInCategory: Bool {
        categoryTools.contains { appModel.isToolAlwaysAllowed(toolID: $0.id, clientID: client.id) }
    }

    /// Tools in this category that ask every time by default. A bulk verb that
    /// would sweep one of them up says so before it runs.
    private var riskyCount: Int {
        categoryTools.count { $0.asksBeforeRunning && $0.approvalPolicy == .everyCall }
    }

    private func setCategoryAllowed(_ isAllowed: Bool) {
        let risky = riskyCount
        for tool in categoryTools
        where appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: client.id) != isAllowed {
            appModel.setToolAlwaysAllowed(isAllowed, toolID: tool.id, clientID: client.id, clientTrustID: client.trustID)
        }
        guard isAllowed else {
            onSummary("Removed every Always Allow rule in \(category.title) for \(client.name).")
            return
        }
        onSummary(
            risky == 0
                ? "\(client.name) now runs every \(category.title) tool without asking."
                : "\(client.name) now runs every \(category.title) tool without asking, including \(risky) that ask every time by default."
        )
    }
}

// MARK: - Tool row

private struct ToolPolicyRow: View {
    @Environment(AppModel.self) private var appModel
    let client: ConnectedClient
    let tool: ToolDefinition

    @State private var isConfirmingAlwaysAllow = false
    /// Holds the switch in its new position while the consent dialog is up, so
    /// the control never snaps back under the user's hand.
    @State private var isGrantPending = false

    var body: some View {
        HStack(spacing: Space.s3) {
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s2) {
                    Text(tool.name)
                        .font(.body)
                    StateChip(capability: tool.capability)
                    // The chip states what happens now, not what the catalog
                    // once decided: granting this tool retires it.
                    if tool.asksBeforeRunning, tool.approvalPolicy == .everyCall, !isAllowed {
                        StateChip("Asks Every Time", systemImage: "hand.raised.fill", role: .attention)
                    }
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

            if tool.asksBeforeRunning {
                Toggle(
                    "Always Allow",
                    isOn: Binding(
                        get: { isGrantPending || isAllowed },
                        set: { shouldAllow in
                            guard shouldAllow else {
                                setAllowed(false)
                                return
                            }
                            guard consequence != nil else {
                                setAllowed(true)
                                return
                            }
                            isGrantPending = true
                            isConfirmingAlwaysAllow = true
                        }
                    )
                )
                .toggleStyle(.switch)
                .help(consequence ?? "Turn this on and \(client.name) runs \(tool.name) without asking.")
            } else {
                // D79: a read-only tool never asks, so a switch would change nothing.
                Text("Runs without asking")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .help("Read-only tools never ask, so \(client.name) runs \(tool.name) without asking.")
            }
        }
        .padding(.vertical, Space.s2)
        .confirmationDialog(
            "Always allow \u{201C}\(tool.name)\u{201D} for \(client.name)?",
            isPresented: $isConfirmingAlwaysAllow,
            titleVisibility: .visible
        ) {
            Button("Always Allow") {
                setAllowed(true)
                isGrantPending = false
            }
            Button("Cancel", role: .cancel) {
                isGrantPending = false
            }
        } message: {
            Text(consequence ?? "")
        }
    }

    private var isAllowed: Bool {
        appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: client.id)
    }

    /// `nil` for ordinary tools — those grant straight from the switch.
    private var consequence: String? {
        AlwaysAllowConsequence.text(for: tool, clientName: client.name)
    }

    private func setAllowed(_ isAllowed: Bool) {
        appModel.setToolAlwaysAllowed(
            isAllowed,
            toolID: tool.id,
            clientID: client.id,
            clientTrustID: client.trustID
        )
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
