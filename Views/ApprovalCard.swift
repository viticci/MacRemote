import Accessibility
import Foundation
import SwiftUI

/// The approval anatomy (spec §5.4): clear actor → clear capability → clear
/// scope → calm urgency. Pure view — hosts (Requests, the Approval window,
/// onboarding's demo) supply data and verbs. Material discipline per
/// GUIDELINES §3: the body is content-layer; glass appears only through the
/// system `.glass`/`.glassProminent` button styles in the window verb row.
struct ApprovalCard: View {
    enum Variant {
        /// The floating Approval window: 64 pt countdown ring, glass verb row.
        case window
        /// The Requests queue row: compact header with inline verbs.
        case inline
    }

    /// Verb-row lifecycle. Hosts drive `minted`/`resolved`: the model resolves
    /// immediately; the card lingers on the minted rule for 1.2 s (spec §5.4).
    enum Phase: Equatable {
        case pending
        case minted(String)
        case resolved(word: String, role: StatusRole)
    }

    // The real fuses (spec §5.4): ToolCallApprovalCoordinator's 120 s default
    // and OAuthCoordinator's 300 s pending-authorization expiry.
    static let toolCallFuse: TimeInterval = 120
    static let authorizationFuse: TimeInterval = 300

    let interrupt: PendingInterrupt
    var variant: Variant
    var phase: Phase = .pending
    var pagingLabel: String? = nil
    var oauthConsequence: String? = nil
    /// D18: non-nil renders the reason and disables every verb — no silent no-ops.
    var unavailableReason: String? = nil
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}
    /// nil hides Always Allow (OAuth requests, tool calls without a client ID).
    var onAlwaysAllow: (() -> Void)? = nil
    /// Audit hook — hosts write the log line for every copy (parity CC-2).
    var onCopyDetail: ((KeyValueRow) -> Void)? = nil
    var expandAll: Binding<DetailsExpandAll>? = nil

    var body: some View {
        switch variant {
        case .window:
            windowLayout
                .animation(.default, value: phase)
        case .inline:
            Card {
                inlineLayout
            }
            .animation(.default, value: phase)
        }
    }

    // MARK: - Window layout

    private var windowLayout: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .top) {
                countdownIcon(iconSize: 64)
                Spacer()
                if let pagingLabel, phase == .pending {
                    Text(pagingLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .countText()
                }
            }

            switch interrupt {
            case .toolCall(let request):
                Text("\u{201C}\(clientDisplayName)\u{201D} wants to run")
                    .font(TypeRamp.cardTitle)
                Text(request.toolName)
                    .font(TypeRamp.heroStatus)
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)
                capabilitySentenceText(request.capability)
                argumentSection(for: request)
            case .authorization:
                Text("\u{201C}\(clientDisplayName)\u{201D} wants to connect to this Mac")
                    .font(TypeRamp.heroStatus)
                consequenceSection
            }

            detailsSection

            if let caption = undoCaption {
                Text(caption)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            }

            footerRow(deny: { $0.buttonStyle(.glass) }, approve: { $0.buttonStyle(.glassProminent) })
        }
    }

    // MARK: - Inline layout

    private var inlineLayout: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                countdownIcon(iconSize: 24)
                if phase == .pending {
                    remainingTimeText
                }
                Text(inlineSentence)
                    .font(TypeRamp.cardTitle)
                    .foregroundStyle(isDestructive ? Color.red : Color.primary)
                Spacer()
                footerRow(deny: { $0.buttonStyle(.bordered) }, approve: { $0.buttonStyle(.borderedProminent) })
            }

            switch interrupt {
            case .toolCall(let request):
                capabilitySentenceText(request.capability)
                argumentSection(for: request)
            case .authorization:
                consequenceSection
            }

            detailsSection

            if let caption = undoCaption {
                Text(caption)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inlineSentence: String {
        switch interrupt {
        case .toolCall(let request):
            "\(clientDisplayName) wants to run \(request.toolName)"
        case .authorization:
            "\(clientDisplayName) wants to connect to this Mac"
        }
    }

    // MARK: - Shared pieces

    private func countdownIcon(iconSize: CGFloat) -> some View {
        CountdownRing(
            endDate: Self.endDate(for: interrupt),
            duration: Self.fuse(for: interrupt),
            iconSize: iconSize
        ) {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.6))
                Image(systemName: ConnectorProviderProfile.inferred(fromClientName: interrupt.clientName).systemImage)
                    .font(iconSize >= 48 ? .title2 : .caption)
                    .foregroundStyle(.tint)
            }
        }
        // §5 A11y: the owner posts the 60 s / 15 s countdown announcements.
        .task(id: announcementTaskID) {
            guard variant == .window, phase == .pending else { return }
            for threshold: TimeInterval in [60, 15] {
                let delay = Self.endDate(for: interrupt).timeIntervalSinceNow - threshold
                guard delay > 0 else { continue }
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                AccessibilityNotification.Announcement(
                    "Expires in \(CountdownRing<AnyView>.remainingDescription(threshold))"
                ).post()
            }
        }
    }

    private var announcementTaskID: String {
        "\(interrupt.id.uuidString)-\(phase == .pending)-\(variant == .window)"
    }

    private var remainingTimeText: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Self.endDate(for: interrupt).timeIntervalSince(context.date))
            Text(Duration.seconds(remaining).formatted(.time(pattern: .minuteSecond)))
                .font(TypeRamp.machineCaption)
                .monospacedDigit()
                .foregroundStyle(remaining <= 30 ? Color.orange : Color.secondary)
        }
    }

    private func capabilitySentenceText(_ capability: ToolCapability) -> some View {
        Text(Self.capabilitySentence(capability))
            .font(TypeRamp.rowDetail)
            .foregroundStyle(capability.chipTint)
    }

    @ViewBuilder
    private func argumentSection(for request: ToolCallApprovalRequest) -> some View {
        let parsed = Self.parseArguments(fromPreview: request.argumentsPreview)
        if !parsed.rows.isEmpty {
            KeyValueGrid(rows: parsed.rows, onCopy: onCopyDetail)
        }
        if let characterCount = parsed.stdinCharacterCount {
            StdinSummaryRow(characterCount: characterCount)
        }
    }

    @ViewBuilder
    private var consequenceSection: some View {
        if case .authorization(let request) = interrupt {
            if let oauthConsequence {
                Text(oauthConsequence)
                    .font(TypeRamp.rowDetail.weight(.medium))
            }
            if !request.requestedScopes.isEmpty {
                HStack(spacing: Space.s2) {
                    Text("Scopes")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                    Text(request.requestedScopes.joined(separator: ", "))
                        .machineText(TypeRamp.machineCaption)
                }
            }
        }
    }

    private var detailsSection: some View {
        DetailsDisclosure(id: "request.\(interrupt.id.uuidString)", expandAll: expandAll) {
            VStack(alignment: .leading, spacing: Space.s2) {
                KeyValueGrid(rows: identityRows, onCopy: onCopyDetail)
                if case .toolCall(let request) = interrupt {
                    RawArgumentsBlock(preview: request.argumentsPreview, onCopy: onCopyDetail)
                }
            }
        }
    }

    private var identityRows: [KeyValueRow] {
        switch interrupt {
        case .authorization(let request):
            [
                KeyValueRow("Request ID", request.id.uuidString),
                KeyValueRow("Client ID", request.clientID),
                KeyValueRow("Trust ID", request.clientTrustID),
                KeyValueRow("Resource", request.resource),
                KeyValueRow("Issuer", request.issuer),
                KeyValueRow("Redirect", request.redirectURI)
            ]
        case .toolCall(let request):
            [
                KeyValueRow("Request ID", request.id.uuidString),
                KeyValueRow("Tool ID", request.toolID)
            ]
            + (request.clientID.map { [KeyValueRow("Client ID", $0)] } ?? [])
            + (request.clientTrustID.map { [KeyValueRow("Trust ID", $0)] } ?? [])
        }
    }

    private var undoCaption: String? {
        guard phase == .pending, case .toolCall = interrupt else { return nil }
        if onAlwaysAllow != nil {
            return "Allowing once runs it now. \u{201C}Always Allow\u{201D} lets \(clientDisplayName) run this tool without asking again — you can undo it in Apps."
        }
        return "Allowing once runs it now."
    }

    // MARK: - Verb row / phase footer

    @ViewBuilder
    private func footerRow(
        deny: (Button<Text>) -> some View,
        approve: (Button<Text>) -> some View
    ) -> some View {
        switch phase {
        case .pending:
            VStack(alignment: .trailing, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    if variant == .window {
                        deny(Button("Deny", action: onDeny))
                        Spacer()
                        alwaysAllowMenu
                        approve(Button(approveTitle, action: onApprove))
                    } else {
                        deny(Button("Deny", action: onDeny))
                        approve(Button(approveTitle, action: onApprove))
                        inlineOverflowMenu
                    }
                }
                .disabled(unavailableReason != nil)

                if let unavailableReason {
                    HStack(spacing: Space.s1) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(unavailableReason)
                    }
                    .font(TypeRamp.truthNote)
                }
            }
        case .minted(let line):
            HStack(spacing: Space.s2) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                Text(line)
                    .font(TypeRamp.cardTitle)
            }
            .transition(.opacity)
        case .resolved(let word, let role):
            StateChip(word, systemImage: role.symbolName, role: role)
                .transition(.opacity)
        }
    }

    private var approveTitle: String {
        switch interrupt {
        case .authorization: "Approve"
        case .toolCall: "Approve Run"
        }
    }

    @ViewBuilder
    private var alwaysAllowMenu: some View {
        if let onAlwaysAllow {
            // Deliberately one step heavier than Approve (spec §5.4);
            // destructive calls demote it further.
            Menu("Always Allow") {
                Button("Always Allow for \(clientDisplayName)…", action: onAlwaysAllow)
            }
            .fixedSize()
            .controlSize(isDestructive ? .small : .regular)
        }
    }

    @ViewBuilder
    private var inlineOverflowMenu: some View {
        if let onAlwaysAllow {
            Menu {
                Button("Always Allow for \(clientDisplayName)…", action: onAlwaysAllow)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    // MARK: - Derived facts

    private var clientDisplayName: String {
        interrupt.clientName ?? "An app"
    }

    private var isDestructive: Bool {
        if case .toolCall(let request) = interrupt {
            return request.capability == .destructive
        }
        return false
    }

    static func fuse(for interrupt: PendingInterrupt) -> TimeInterval {
        switch interrupt {
        case .authorization: authorizationFuse
        case .toolCall: toolCallFuse
        }
    }

    static func endDate(for interrupt: PendingInterrupt) -> Date {
        interrupt.createdAt.addingTimeInterval(fuse(for: interrupt))
    }

    /// One severity scale everywhere: Read-only green · Write orange · Destructive red.
    static func capabilitySentence(_ capability: ToolCapability) -> String {
        switch capability {
        case .readOnly: "Read-only — this only reads data on your Mac"
        case .write: "Write — this can change files on your Mac"
        case .destructive: "Destructive — this can delete files on your Mac"
        }
    }

    // MARK: - Argument re-rendering (AP-12)

    struct ParsedToolArguments: Equatable {
        var rows: [KeyValueRow] = []
        var stdinCharacterCount: Int? = nil
    }

    /// Re-renders the coordinator's `key=value key2=value2` preview as
    /// structured rows. Heuristic: a space-separated token starting with an
    /// identifier followed by `=` opens a new pair; other tokens extend the
    /// previous value. Lossy by design — the raw string stays inside Details.
    static func parseArguments(fromPreview preview: String) -> ParsedToolArguments {
        var result = ParsedToolArguments()
        let trimmed = preview.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "No arguments" else { return result }

        var pairs: [(key: String, value: String)] = []
        for token in trimmed.split(separator: " ", omittingEmptySubsequences: true) {
            if let (key, value) = keyValueSplit(token) {
                pairs.append((key, value))
            } else if pairs.isEmpty {
                // The preview doesn't start with a pair — leave it raw-only.
                return result
            } else {
                pairs[pairs.count - 1].value += " " + token
            }
        }

        for (key, value) in pairs {
            if key == "stdin",
               value.hasPrefix("<"),
               value.hasSuffix(" chars>"),
               let count = Int(value.dropFirst().dropLast(" chars>".count)) {
                result.stdinCharacterCount = count
            } else {
                result.rows.append(KeyValueRow(key, value))
            }
        }
        return result
    }

    private static func keyValueSplit(_ token: Substring) -> (String, String)? {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return nil }
        let key = token[..<equals]
        guard let first = key.first, first.isLetter || first == "_" else { return nil }
        guard key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else {
            return nil
        }
        return (String(key), String(token[token.index(after: equals)...]))
    }

    static func stdinSummary(characterCount: Int) -> String {
        characterCount >= 1000
            ? String(format: "%.1f KB", Double(characterCount) / 1000)
            : "\(characterCount) characters"
    }
}

/// The summarized stdin row: "stdin · 4.2 KB ▸ view" (spec §5.4). The model
/// carries only the size — the expander says so instead of pretending.
struct StdinSummaryRow: View {
    let characterCount: Int

    @State private var isShowingNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Text("stdin")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                Text(ApprovalCard.stdinSummary(characterCount: characterCount))
                    .font(TypeRamp.machineCaption)
                Button(isShowingNote ? "Hide" : "View") {
                    withAnimation(.snappy) {
                        isShowingNote.toggle()
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if isShowingNote {
                Text("The tool receives the full text when you approve — MacRemote shows only its size.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The raw `argumentsPreview` string, preserved verbatim and selectable inside
/// Details (parity AP-12 — nothing lost to the structured re-render).
struct RawArgumentsBlock: View {
    let preview: String
    var onCopy: ((KeyValueRow) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("Raw arguments")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Space.s1) {
                Text(preview)
                    .machineText(TypeRamp.machineCaption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(value: preview, help: "Copy Raw Arguments") {
                    onCopy?(KeyValueRow("Raw arguments", preview))
                }
                .controlSize(.small)
            }
            .padding(Space.s2)
            .background(.quaternary.opacity(0.4), in: AppShape.mono)
        }
    }
}

/// D13: the one-time contextual notifications ask, rendered wherever the first
/// approval resolves (Approval window, Requests, onboarding S5).
struct NotificationOfferRow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: Space.s2) {
            Image(systemName: "bell.badge")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
            Text("Want requests to reach you anywhere?")
                .font(TypeRamp.rowDetail)
            Button("Allow Notifications") {
                appModel.requestNotificationPermission()
            }
            Spacer()
            Button {
                appModel.dismissNotificationPrompt()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .padding(Space.s3)
        .background(.quaternary.opacity(0.4), in: AppShape.card)
    }
}

extension ConnectorProviderProfile {
    /// Best-effort provider glyph for a connecting app. Client names are
    /// recovered server-side from redirect hosts ("Claude", "Notion",
    /// "Raycast"), so name matching is the only signal available.
    static func inferred(fromClientName name: String?) -> ConnectorProviderProfile {
        guard let name = name?.lowercased() else { return .generic }
        if name.contains("claude") { return .claude }
        if name.contains("notion") { return .notion }
        if name.contains("raycast") { return .raycast }
        return .generic
    }
}
