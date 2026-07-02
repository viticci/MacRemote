import SwiftUI

/// Requests — the queue and the session history (spec §5.3). Pending requests
/// render the same `ApprovalCard` the floating window uses; history keeps the
/// two kinds in separate sections, never merged.
struct RequestsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var expandAll = DetailsExpandAll()
    @State private var isConfirmingDenyAll = false

    var body: some View {
        Group {
            if appModel.approvals.isEmpty && appModel.toolCallApprovals.isEmpty {
                EmptyState(
                    "Nothing waiting",
                    systemImage: "hand.raised",
                    message: "When an app wants to connect or run a tool that needs your OK, it shows up here — and in a window you can't miss."
                )
            } else {
                requestList
            }
        }
        .pageContainerShape()
        .navigationTitle("Requests")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button("Open Approval Window", systemImage: "macwindow") {
                    appModel.presentApprovalWindow()
                }
                .disabled(appModel.pendingRequestCount == 0)
            }
        }
        // GUIDELINES §3.3: glass buttons over scrolling content, 2+ pending
        // only. Deny All Waiting is the sole batch verb — no Approve All (D2).
        .safeAreaBar(edge: .bottom) {
            if appModel.pendingRequestCount >= 2 {
                Button("Deny All Waiting") {
                    isConfirmingDenyAll = true
                }
                .buttonStyle(.glass)
                .padding(Space.s3)
            }
        }
        .confirmationDialog(
            "Deny \(appModel.pendingRequestCount) waiting request\(appModel.pendingRequestCount == 1 ? "" : "s")?",
            isPresented: $isConfirmingDenyAll,
            titleVisibility: .visible
        ) {
            Button("Deny All", role: .destructive) {
                appModel.denyAllWaitingRequests()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each app can ask again.")
        }
    }

    private var subtitle: String {
        let count = appModel.pendingRequestCount
        return count == 0 ? "Nothing waiting" : "\(count) waiting"
    }

    private var requestList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s3) {
                if appModel.shouldOfferNotificationPrompt {
                    NotificationOfferRow()
                }

                pendingSection
                historySections
            }
            .padding(Space.s5)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    // MARK: - Waiting

    @ViewBuilder
    private var pendingSection: some View {
        let pending = appModel.pendingInterrupts
        if !pending.isEmpty {
            Text("Waiting")
                .font(TypeRamp.cardTitle)

            ForEach(pending) { interrupt in
                pendingCard(interrupt)
            }

            if pendingAuthorizationCount >= OAuthCoordinator.maxPendingAuthorizations {
                queueCapNote
            }
        }
    }

    private func pendingCard(_ interrupt: PendingInterrupt) -> some View {
        ApprovalCard(
            interrupt: interrupt,
            variant: .inline,
            oauthConsequence: oauthConsequence(for: interrupt),
            unavailableReason: appModel.serverStatus.isRunning ? nil : "Start the server to respond.",
            onApprove: { approve(interrupt) },
            onDeny: { deny(interrupt) },
            onAlwaysAllow: alwaysAllowAction(for: interrupt),
            onCopyDetail: { row in
                appModel.appendLog(level: .info, "Copied \(row.label) from a request.")
            },
            expandAll: $expandAll
        )
    }

    private func oauthConsequence(for interrupt: PendingInterrupt) -> String? {
        guard case .authorization(let request) = interrupt else { return nil }
        let summary = appModel.toolExposureSummary
        return "If you approve, \(request.clientName) can run your \(summary.readOnly) read-only tools without asking. The \(summary.gatedToolCount) tools marked Asks First will still ask every time."
    }

    private func approve(_ interrupt: PendingInterrupt) {
        switch interrupt {
        case .authorization(let request):
            appModel.approveAuthorizationRequest(request.id)
        case .toolCall(let request):
            appModel.approveToolCallRequest(request.id)
        }
    }

    private func deny(_ interrupt: PendingInterrupt) {
        switch interrupt {
        case .authorization(let request):
            appModel.denyAuthorizationRequest(request.id)
        case .toolCall(let request):
            appModel.denyToolCallRequest(request.id)
        }
    }

    private func alwaysAllowAction(for interrupt: PendingInterrupt) -> (() -> Void)? {
        guard case .toolCall(let request) = interrupt, request.clientID != nil else { return nil }
        return { appModel.approveToolCallForever(request.id) }
    }

    private var pendingAuthorizationCount: Int {
        appModel.approvals.count(where: { $0.state == .pending })
    }

    /// §8.3: the 16-pending cap surfaces as a queue-footer note when hit.
    private var queueCapNote: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("The queue is full — new connection requests are turned away until you respond to one of these.")
                .font(TypeRamp.truthNote)
        }
    }

    // MARK: - This session (history — two kinds, never merged)

    @ViewBuilder
    private var historySections: some View {
        let authorizationHistory = appModel.approvals
            .filter { $0.state != .pending }
            .sorted { $0.createdAt > $1.createdAt }
        let toolRunHistory = appModel.toolCallApprovals
            .filter { $0.state != .pending }
            .sorted { $0.createdAt > $1.createdAt }

        if !authorizationHistory.isEmpty || !toolRunHistory.isEmpty {
            Text("This session — cleared when MacRemote quits")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .padding(.top, Space.s3)

            if !authorizationHistory.isEmpty {
                Text("Connection Requests")
                    .font(TypeRamp.cardTitle)
                ForEach(authorizationHistory) { request in
                    ConnectionRequestHistoryRow(request: request, expandAll: $expandAll)
                    Divider()
                }
            }

            if !toolRunHistory.isEmpty {
                Text("Tool Runs")
                    .font(TypeRamp.cardTitle)
                    .padding(.top, authorizationHistory.isEmpty ? 0 : Space.s3)
                ForEach(toolRunHistory) { request in
                    ToolRunHistoryRow(request: request, expandAll: $expandAll)
                    Divider()
                }
            }
        }
    }
}

// MARK: - History rows

/// Shared header chrome for history rows: tinted state word (AP-4), actor ·
/// action, capability chip, time. Expansion uses the standard `▸ Details`
/// disclosure so ⌥-click expand-all works page-wide.
private struct HistoryRowHeader: View {
    let stateWord: String
    let stateSymbol: String
    let tint: Color
    let title: String
    let capability: ToolCapability?
    let time: Date

    var body: some View {
        HStack(spacing: Space.s2) {
            HStack(spacing: Space.s1) {
                Image(systemName: stateSymbol)
                    .font(.caption)
                    .symbolRenderingMode(.hierarchical)
                Text(stateWord)
                    .font(TypeRamp.chip)
            }
            .foregroundStyle(tint)
            .frame(minWidth: 110, alignment: .leading)

            Text(title)
                .font(.body)
                .lineLimit(1)

            if let capability {
                StateChip(capability: capability)
            }

            Spacer()

            Text(time, style: .time)
                .font(TypeRamp.machineCaption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stateWord). \(title)")
    }
}

private struct ConnectionRequestHistoryRow: View {
    @Environment(AppModel.self) private var appModel
    let request: ApprovalRequest
    let expandAll: Binding<DetailsExpandAll>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HistoryRowHeader(
                stateWord: stateWord,
                stateSymbol: stateSymbol,
                tint: tint,
                title: "\(request.clientName) · connect to this Mac",
                capability: nil,
                time: request.createdAt
            )

            DetailsDisclosure(id: "request.\(request.id.uuidString)", expandAll: expandAll) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    if !request.requestedScopes.isEmpty {
                        HStack(spacing: Space.s2) {
                            Text("Scopes")
                                .font(TypeRamp.rowDetail)
                                .foregroundStyle(.secondary)
                            Text(request.requestedScopes.joined(separator: ", "))
                                .machineText(TypeRamp.machineCaption)
                        }
                    }
                    KeyValueGrid(rows: detailRows) { row in
                        appModel.appendLog(level: .info, "Copied \(row.label) from a connection request.")
                    }
                }
            }
            .padding(.leading, Space.s6)
        }
        .padding(.vertical, Space.s1)
    }

    private var detailRows: [KeyValueRow] {
        [
            KeyValueRow("Request ID", request.id.uuidString),
            KeyValueRow("Client ID", request.clientID),
            KeyValueRow("Trust ID", request.clientTrustID),
            KeyValueRow("Resource", request.resource),
            KeyValueRow("Issuer", request.issuer),
            KeyValueRow("Redirect", request.redirectURI)
        ]
    }

    private var stateWord: String {
        if request.state == .denied, let reason = appModel.requestDenialReasons[request.id] {
            return "Denied — \(reason)"
        }
        return request.stateTitle
    }

    private var stateSymbol: String {
        switch request.state {
        case .pending: "hourglass"
        case .approved: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .expired: "circle.dotted"
        }
    }

    private var tint: Color {
        switch request.state {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        case .expired: .secondary
        }
    }
}

private struct ToolRunHistoryRow: View {
    @Environment(AppModel.self) private var appModel
    let request: ToolCallApprovalRequest
    let expandAll: Binding<DetailsExpandAll>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HistoryRowHeader(
                stateWord: stateWord,
                stateSymbol: stateSymbol,
                tint: tint,
                title: "\(request.clientName ?? "An app") · \(request.toolName)",
                capability: request.capability,
                time: request.createdAt
            )

            DetailsDisclosure(id: "request.\(request.id.uuidString)", expandAll: expandAll) {
                expansion
            }
            .padding(.leading, Space.s6)
        }
        .padding(.vertical, Space.s1)
    }

    private var expansion: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            let parsed = ApprovalCard.parseArguments(fromPreview: request.argumentsPreview)
            if !parsed.rows.isEmpty {
                KeyValueGrid(rows: parsed.rows, onCopy: logCopy)
            }
            if let characterCount = parsed.stdinCharacterCount {
                StdinSummaryRow(characterCount: characterCount)
            }
            KeyValueGrid(rows: identityRows, onCopy: logCopy)
            RawArgumentsBlock(preview: request.argumentsPreview, onCopy: logCopy)
        }
    }

    private func logCopy(_ row: KeyValueRow) {
        appModel.appendLog(level: .info, "Copied \(row.label) from a tool run.")
    }

    private var identityRows: [KeyValueRow] {
        [
            KeyValueRow("Request ID", request.id.uuidString),
            KeyValueRow("Tool ID", request.toolID)
        ]
        + (request.clientID.map { [KeyValueRow("Client ID", $0)] } ?? [])
        + (request.clientTrustID.map { [KeyValueRow("Trust ID", $0)] } ?? [])
    }

    private var stateWord: String {
        if request.state == .denied, let reason = appModel.requestDenialReasons[request.id] {
            return "Denied — \(reason)"
        }
        return request.stateTitle
    }

    private var stateSymbol: String {
        switch request.state {
        case .pending: "hourglass"
        case .approved: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .expired: "circle.dotted"
        }
    }

    private var tint: Color {
        switch request.state {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        case .expired: .secondary
        }
    }
}
