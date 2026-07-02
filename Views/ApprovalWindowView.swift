import Accessibility
import SwiftUI

/// The floating security interrupt (spec §5.4). Presentation is the platform's
/// (`presentApprovalWindow()`, D4): the window never activates the app and
/// never owes key focus — so no verb here is a default button and Return can't
/// approve anything. The body is standard window material; glass appears only
/// via system button styles inside `ApprovalCard` (GUIDELINES §3).
struct ApprovalWindowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    @State private var displayed: PendingInterrupt?
    @State private var held: HeldResolution?
    @State private var holdTask: Task<Void, Never>?

    /// A just-resolved card frozen on screen: the minted rule or the quiet
    /// resolved word lingers 1.2 s before the queue advances (spec §5.4).
    private struct HeldResolution: Equatable {
        let interrupt: PendingInterrupt
        let phase: ApprovalCard.Phase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            if let held {
                card(for: held.interrupt, phase: held.phase)
            } else if let displayed {
                card(for: displayed, phase: .pending)
            } else {
                EmptyState(
                    "Nothing waiting",
                    systemImage: "hand.raised",
                    message: "New requests open this window the moment they arrive."
                )
                .frame(minHeight: 120)
            }

            if appModel.shouldOfferNotificationPrompt {
                NotificationOfferRow()
            }
        }
        .padding(Space.s6)
        .frame(width: 440)
        .task { syncQueue() }
        .onChange(of: appModel.pendingInterrupts) { syncQueue() }
        .onChange(of: appModel.shouldOfferNotificationPrompt) { syncQueue() }
    }

    private func card(for interrupt: PendingInterrupt, phase: ApprovalCard.Phase) -> some View {
        ApprovalCard(
            interrupt: interrupt,
            variant: .window,
            phase: phase,
            pagingLabel: pagingLabel,
            oauthConsequence: oauthConsequence(for: interrupt),
            unavailableReason: appModel.serverStatus.isRunning ? nil : "Start the server to respond.",
            onApprove: { approve(interrupt) },
            onDeny: { deny(interrupt) },
            onAlwaysAllow: alwaysAllowAction(for: interrupt),
            onCopyDetail: { row in
                appModel.appendLog(level: .info, "Copied \(row.label) from an approval request.")
            }
        )
    }

    /// The window always shows the frontmost pending interrupt so the Requests
    /// menu verbs (⌘⏎ / ⌥⌘⏎ / ⌘⌫) and this window agree on "frontmost" (D4).
    private var pagingLabel: String? {
        let count = appModel.pendingInterrupts.count
        return count > 1 ? "1 of \(count)" : nil
    }

    private func oauthConsequence(for interrupt: PendingInterrupt) -> String? {
        guard case .authorization(let request) = interrupt else { return nil }
        let summary = appModel.toolExposureSummary
        return "If you approve, \(request.clientName) can run your \(summary.readOnly) read-only tools without asking. The \(summary.gatedToolCount) tools marked Asks First will still ask every time."
    }

    // MARK: - Verbs (act on the displayed request, which is the frontmost)

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

    // MARK: - Queue advancement

    /// One watcher drives every morph: verbs (in-window, menu, or notification
    /// actions) resolve the model immediately; when the displayed request
    /// leaves the pending queue, its resolution is held on screen briefly,
    /// then the next request appears — or the window recedes.
    private func syncQueue() {
        guard held == nil else { return }
        let frontmost = appModel.pendingInterrupts.first

        if let current = displayed {
            guard frontmost?.id != current.id else { return }
            beginHold(HeldResolution(interrupt: current, phase: resolutionPhase(for: current)))
            return
        }

        if let frontmost {
            displayed = frontmost
            announce(frontmost)
        } else if !appModel.shouldOfferNotificationPrompt {
            dismiss()
        }
    }

    private func beginHold(_ resolution: HeldResolution) {
        withAnimation(.default) {
            displayed = nil
            held = resolution
        }
        holdTask?.cancel()
        holdTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            withAnimation(.default) {
                held = nil
            }
            syncQueue()
        }
    }

    private func resolutionPhase(for interrupt: PendingInterrupt) -> ApprovalCard.Phase {
        switch interrupt {
        case .authorization(let request):
            let state = appModel.approvals.first { $0.id == request.id }?.state ?? .expired
            switch state {
            case .approved:
                return .minted("\(request.clientName) can now connect to this Mac")
            case .denied:
                return deniedPhase(requestID: request.id)
            case .expired, .pending:
                return .resolved(word: "Expired", role: .off)
            }
        case .toolCall(let request):
            let state = appModel.toolCallApprovals.first { $0.id == request.id }?.state ?? .expired
            switch state {
            case .approved:
                let name = request.clientName ?? "This app"
                if let clientID = request.clientID,
                   appModel.isToolAlwaysAllowed(toolID: request.toolID, clientID: clientID) {
                    return .minted("\(name) can now run \(request.toolName) without asking")
                }
                return .minted("\(name) can now run \(request.toolName)")
            case .denied:
                return deniedPhase(requestID: request.id)
            case .expired, .pending:
                return .resolved(word: "Expired", role: .off)
            }
        }
    }

    private func deniedPhase(requestID: UUID) -> ApprovalCard.Phase {
        if let reason = appModel.requestDenialReasons[requestID] {
            return .resolved(word: "Denied — \(reason)", role: .error)
        }
        return .resolved(word: "Denied", role: .error)
    }

    /// §5 A11y: announce actor, capability, and expiry when a request appears.
    private func announce(_ interrupt: PendingInterrupt) {
        var parts = ["Approval request."]
        switch interrupt {
        case .authorization(let request):
            parts.append("\(request.clientName) wants to connect to this Mac.")
        case .toolCall(let request):
            parts.append("\(request.clientName ?? "An app") wants to run \(request.toolName).")
            parts.append("\(ApprovalCard.capabilitySentence(request.capability)).")
        }
        let remaining = max(0, ApprovalCard.endDate(for: interrupt).timeIntervalSinceNow)
        parts.append("Expires in \(CountdownRing<AnyView>.remainingDescription(remaining)).")
        AccessibilityNotification.Announcement(parts.joined(separator: " ")).post()
    }
}
