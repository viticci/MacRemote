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

    // The real fuses (spec §5.4): each coordinator's own wait.
    static let toolCallFuse = ToolCallApprovalCoordinator.defaultTimeoutSeconds
    static let authorizationFuse = OAuthCoordinator.pendingAuthorizationLifetime

    let interrupt: PendingInterrupt
    var variant: Variant
    /// Icons the app sent about itself. Hosts pass these in — the card stays a
    /// pure view — and they are the lowest of the three artwork tiers.
    var clientSuppliedIcons: ClientSuppliedIconSet? = nil
    var phase: Phase = .pending
    var pagingLabel: String? = nil
    var oauthConsequence: String? = nil
    /// D18: non-nil renders the reason and disables every verb — no silent no-ops.
    var unavailableReason: String? = nil
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}
    /// nil hides Always Allow (OAuth requests, tool calls without a client ID).
    var onAlwaysAllow: (() -> Void)? = nil
    /// Non-nil marks a tool that asks every time by default: the caption gets
    /// the stronger sentence and Always Allow gains a confirmation step.
    var alwaysAllowConsequence: String? = nil
    /// Audit hook — hosts write the log line for every copy (parity CC-2).
    var onCopyDetail: ((KeyValueRow) -> Void)? = nil
    var expandAll: Binding<DetailsExpandAll>? = nil

    @State private var isConfirmingAlwaysAllow = false

    var body: some View {
        Group {
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
        .confirmationDialog(
            "Always allow \u{201C}\(toolDisplayName)\u{201D} for \(clientDisplayName)?",
            isPresented: $isConfirmingAlwaysAllow,
            titleVisibility: .visible
        ) {
            Button("Always Allow") { onAlwaysAllow?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(alwaysAllowConsequence ?? "")
        }
    }

    /// Only a tool call names a tool; the dialog never opens for the other kind.
    private var toolDisplayName: String {
        switch interrupt {
        case .toolCall(let request): request.toolName
        case .authorization: ""
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
                capabilitySentenceText(for: request)
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
                    .fixedSize(horizontal: false, vertical: true)
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
                capabilitySentenceText(for: request)
                argumentSection(for: request)
            case .authorization:
                consequenceSection
            }

            detailsSection

            if let caption = undoCaption {
                Text(caption)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
            ConnectedAppIconView(
                clientName: interrupt.clientName,
                redirectURIs: redirectURIs,
                clientSuppliedIcons: clientSuppliedIcons,
                size: iconSize >= 48 ? .hero : .compact
            )
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

    /// A Flexible Command labeled Read-only gets no "only reads" promise:
    /// it runs its program with whatever arguments are shown, and nothing
    /// checks that those only read.
    private func capabilitySentenceText(for request: ToolCallApprovalRequest) -> some View {
        let isUncheckedReadOnly = request.isFlexibleCommand && request.capability == .readOnly
        return Text(isUncheckedReadOnly
            ? "Flexible Command — it runs with exactly the arguments below"
            : Self.capabilitySentence(request.capability))
            .font(TypeRamp.rowDetail)
            .foregroundStyle(isUncheckedReadOnly ? Color.orange : request.capability.chipTint)
    }

    private func argumentSection(for request: ToolCallApprovalRequest) -> some View {
        ApprovalArgumentList(arguments: request.arguments, onCopy: onCopyDetail)
    }

    @ViewBuilder
    private var consequenceSection: some View {
        if case .authorization(let request) = interrupt {
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text("Code")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                    Text(request.verificationCode)
                        .font(TypeRamp.cardTitle.monospacedDigit())
                        .textSelection(.enabled)
                }
                .accessibilityElement(children: .combine)
                Text("Approve only if your sign-in page shows this code. Anyone with your public link can ask to connect under any name. After approval the sign-in returns to \(request.redirectDestination).")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let oauthConsequence {
                // Never cut short: this sentence is what approving grants.
                Text(oauthConsequence)
                    .font(TypeRamp.rowDetail.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
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
            KeyValueGrid(rows: identityRows, onCopy: onCopyDetail)
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
        guard onAlwaysAllow != nil else { return "Allowing once runs it now." }
        if let alwaysAllowConsequence {
            return "Allowing once runs it now. \u{201C}Always Allow\u{201D} means \(alwaysAllowConsequence)"
        }
        return "Allowing once runs it now. \u{201C}Always Allow\u{201D} lets \(clientDisplayName) run this tool without asking again — you can undo it in Apps."
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
        if onAlwaysAllow != nil {
            // Deliberately one step heavier than Approve (spec §5.4);
            // destructive calls demote it further.
            Menu("Always Allow") {
                alwaysAllowButton
            }
            .fixedSize()
            .controlSize(isDestructive ? .small : .regular)
        }
    }

    @ViewBuilder
    private var inlineOverflowMenu: some View {
        if onAlwaysAllow != nil {
            Menu {
                alwaysAllowButton
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    /// A tool that asks every time by default earns one more confirmation
    /// before the grant is written; everything else grants straight away.
    @ViewBuilder
    private var alwaysAllowButton: some View {
        Button("Always Allow for \(clientDisplayName)…") {
            if alwaysAllowConsequence == nil {
                onAlwaysAllow?()
            } else {
                isConfirmingAlwaysAllow = true
            }
        }
    }

    // MARK: - Derived facts

    private var clientDisplayName: String {
        interrupt.clientName ?? "An app"
    }

    /// Only a connection request carries a redirect. A running tool call has
    /// no URL to reason about, so the glyph falls back to the name alone.
    private var redirectURIs: [String] {
        switch interrupt {
        case .authorization(let request): [request.redirectURI]
        case .toolCall: []
        }
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
}

/// Every argument of a waiting tool call, in full. Each value sits in its own
/// box so text inside one value cannot pass for another argument, and the
/// list scrolls instead of shortening anything: the owner approves exactly
/// what is shown.
struct ApprovalArgumentList: View {
    let arguments: [ToolCallApprovalArgument]
    var onCopy: ((KeyValueRow) -> Void)? = nil

    var body: some View {
        if arguments.isEmpty {
            Text("No arguments")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(arguments) { argument in
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(argument.name)
                                .font(TypeRamp.rowDetail)
                                .foregroundStyle(.secondary)
                            HStack(alignment: .top, spacing: Space.s1) {
                                Text(argument.displayValue)
                                    .machineText(TypeRamp.machineCaption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                CopyButton(value: argument.value, help: "Copy \(argument.name)") {
                                    onCopy?(KeyValueRow(argument.name, argument.value))
                                }
                                .controlSize(.small)
                            }
                            .padding(Space.s2)
                            .background(.quaternary.opacity(0.4), in: AppShape.mono)
                        }
                    }
                }
            }
            // Hug short argument lists; scroll long ones inside a bounded box.
            .frame(maxHeight: 240)
            .fixedSize(horizontal: false, vertical: true)
            .scrollBounceBehavior(.basedOnSize)
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
