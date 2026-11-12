import Accessibility
import SwiftUI

// MARK: - ConnectionHero (SPEC §4.1, GUIDELINES §3 — the app's ONLY custom glass)

/// The nine compound-honest states of the connection object (SPEC §4.1 table).
enum ConnectionHeroState: Equatable {
    case off
    /// "Add a tool to start" — Start stays visible but disabled (DA-4).
    case zeroTools
    case starting
    /// `canGoPublic` is false while cloudflared is missing; the Address card
    /// carries the remedy banner (SPEC §4.1 `unavailable` row).
    case local(localURL: String, canGoPublic: Bool)
    /// Tunnel starting — "Waiting for Cloudflare…".
    case publicPending
    /// Public link live. `captions` = provider/mode line + forwards-only line (TU-2).
    case publicRunning(url: String, captions: [String])
    /// Server running · link stopped. `message` is the raw tunnel failure.
    case partialFailure(message: String)
    /// Server failed. `message` is the raw server failure.
    case failed(message: String)
}

/// Every verb is injected — the hero performs no model work of its own, so
/// onboarding S4/S5 can reuse it. `copyPublicURL` owns pasteboard + audit line
/// (the host passes `AppModel.copyPublicURL`).
struct ConnectionHeroActions {
    var startServer: () -> Void = {}
    var stopServer: () -> Void = {}
    var goPublic: () -> Void = {}
    var stopSharing: () -> Void = {}
    var retry: () -> Void = {}
    var openTools: () -> Void = {}
    var copyPublicURL: () -> Void = {}
}

struct ConnectionHero: View {
    let state: ConnectionHeroState
    var isCompact = false
    var actions = ConnectionHeroActions()

    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isConfirmingCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var statusFrame: CGRect = .zero
    @State private var urlFrame: CGRect = .zero

    private nonisolated static let heroSpace = "hero.glassGroup"

    var body: some View {
        VStack(spacing: isCompact ? Space.s3 : Space.s4) {
            // Wider container spacing blends the Public pill and URL capsule
            // from further apart, so the connecting neck reads as one poured
            // form with gentle shoulders instead of a pinched weld.
            GlassEffectContainer(spacing: Space.s8) {
                // Tighter gap between the pill and the URL capsule: a shorter
                // span means the glass merges into a wider, gentler neck
                // rather than a pinched taper.
                VStack(spacing: isCompact ? Space.s1 : Space.s2) {
                    statusCapsule
                        .onGeometryChange(for: CGRect.self) { proxy in
                            proxy.frame(in: .named(Self.heroSpace))
                        } action: { statusFrame = $0 }
                    if let urlText {
                        urlPill(urlText)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Self.heroSpace))
                            } action: { urlFrame = $0 }
                    }
                    captionLines
                }
            }
            .overlay {
                // "Aurora Exchange" — one liquid light field over the whole
                // glass group, masked in-shader to the union silhouette
                // (GUIDELINES §3: a color layer, never a second glass
                // surface). Rendering under the glass looked right on paper,
                // but the frosted material crushed the field to invisibility;
                // above the glass, the shader tempers its hot light in the
                // URL text band instead.
                if showsConduit {
                    AuroraExchangeUnderlay(
                        tint: StatusRole.ready.tint,
                        statusFrame: statusFrame,
                        urlFrame: urlFrame
                    )
                    .transition(.opacity)
                }
            }
            .coordinateSpace(name: Self.heroSpace)
            // Reduce Motion: no morph animation — states swap in place (crossfade-class).
            .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: state)

            errorRow
            verbRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: Glass pieces

    private var statusCapsule: some View {
        HStack(spacing: Space.s2) {
            StatusOrb(state: orbState, size: isCompact ? 22 : 28)
            Text(statusWord)
                .font(isCompact ? .title3.weight(.semibold) : TypeRamp.heroStatus)
        }
        .padding(.horizontal, isCompact ? Space.s4 : Space.s5)
        .padding(.vertical, isCompact ? Space.s2 : Space.s3)
        .glassEffect(.regular.tint(glassTint), in: .capsule)
        .glassEffectID("hero.status", in: glassNamespace)
    }

    private func urlPill(_ text: String) -> some View {
        HStack(spacing: Space.s1) {
            Text(text)
                .font(urlFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .contentTransition(reduceMotion ? .opacity : .numericText())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.5), value: text)
                .padding(.horizontal, isCompact ? Space.s4 : Space.s5)
                .padding(.vertical, isCompact ? Space.s2 : Space.s3)
                .glassEffect(.regular.tint(glassTint), in: .capsule)
                .glassEffectID("hero.url", in: glassNamespace)
                .glassEffectUnion(id: "hero.urlGroup", namespace: glassNamespace)

            if showsCopy {
                copyButton
            }
        }
    }

    private var copyButton: some View {
        Button {
            actions.copyPublicURL()
            AccessibilityNotification.Announcement("Copied").post()
            withAnimation {
                isConfirmingCopy = true
            }
            copyResetTask?.cancel()
            copyResetTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation {
                    isConfirmingCopy = false
                }
            }
        } label: {
            Image(systemName: isConfirmingCopy ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
                .font(isCompact ? .body : .title3)
                .padding(.horizontal, isCompact ? Space.s3 : Space.s4)
                .padding(.vertical, isCompact ? Space.s2 : Space.s3)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(glassTint).interactive(), in: .capsule)
        .glassEffectID("hero.copy", in: glassNamespace)
        .glassEffectUnion(id: "hero.urlGroup", namespace: glassNamespace)
        .help("Copy Public URL")
        .accessibilityLabel("Copy Public URL")
    }

    @ViewBuilder
    private var captionLines: some View {
        let lines = captions
        if !lines.isEmpty {
            VStack(spacing: Space.s1) {
                ForEach(lines, id: \.self) { line in
                    Text(line)
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, Space.s1)
        }
    }

    // MARK: Error row (never in the URL slot — SPEC §4.1)

    @ViewBuilder
    private var errorRow: some View {
        if let failure {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(failure.headline)
                        .font(.body)
                    Text(failure.raw)
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.s3)
            .frame(maxWidth: 520, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: AppShape.mono)
        }
    }

    // MARK: Verbs (control is never fused — always-visible buttons beneath)

    @ViewBuilder
    private var verbRow: some View {
        HStack(spacing: Space.s3) {
            switch state {
            case .off:
                Button("Start Server", action: actions.startServer)
                    .buttonStyle(.glassProminent)
            case .zeroTools:
                Button("Start Server", action: actions.startServer)
                    .buttonStyle(.glass)
                    .disabled(true)
                    .help("Share at least one tool before starting the local server.")
                Button("Open Tools", action: actions.openTools)
                    .buttonStyle(.glassProminent)
            case .starting:
                EmptyView()
            case .local(_, let canGoPublic):
                Button("Stop Server", action: actions.stopServer)
                    .buttonStyle(.glass)
                Button("Go Public…", action: actions.goPublic)
                    .buttonStyle(.glassProminent)
                    .disabled(!canGoPublic)
                    .help(canGoPublic ? "Create a public link to your shared tools" : "Cloudflare's helper isn't installed — see the Address card.")
            case .publicPending:
                Button("Stop Server", action: actions.stopServer)
                    .buttonStyle(.glass)
            case .publicRunning:
                Button("Stop Server", action: actions.stopServer)
                    .buttonStyle(.glass)
                Button("Stop Sharing", action: actions.stopSharing)
                    .buttonStyle(.glassProminent)
            case .partialFailure:
                Button("Stop Server", action: actions.stopServer)
                    .buttonStyle(.glass)
                Button("Retry", action: actions.retry)
                    .buttonStyle(.glassProminent)
            case .failed:
                Button("Retry", action: actions.retry)
                    .buttonStyle(.glassProminent)
            }
        }
        .controlSize(isCompact ? .regular : .large)
    }

    // MARK: State mapping

    private var orbState: StatusOrb.OrbState {
        switch state {
        case .off, .zeroTools: .off
        case .starting, .publicPending: .starting
        case .local: .local
        case .publicRunning: .public
        case .partialFailure, .failed: .failed
        }
    }

    private var statusWord: String {
        switch state {
        case .off: "Off"
        case .zeroTools: "Add a tool to start"
        case .starting: "Starting"
        case .local: "Local only"
        case .publicPending: "Waiting for Cloudflare…"
        case .publicRunning: "Public"
        case .partialFailure: "Server running · link stopped"
        case .failed: "Server failed"
        }
    }

    private var glassTint: Color {
        let base: Color = switch state {
        case .off, .zeroTools: .secondary
        case .starting, .local, .publicPending: .blue
        case .publicRunning: .green
        case .partialFailure, .failed: .red
        }
        // Luminance-safe tint (GUIDELINES §5.1 — ≤0.35).
        return base.opacity(0.3)
    }

    private var urlText: String? {
        switch state {
        case .local(let localURL, _): localURL
        case .publicRunning(let url, _): url
        default: nil
        }
    }

    private var urlFont: Font {
        switch state {
        case .publicRunning: isCompact ? TypeRamp.machineCallout : TypeRamp.heroMachine
        default: TypeRamp.machineCallout
        }
    }

    private var showsCopy: Bool {
        if case .publicRunning = state { return true }
        return false
    }

    /// The conduit is decoration for the full hero only. The compact hero
    /// (onboarding S4/S5) skips it: its two lanes sit ~9 pt apart and would
    /// smear into shimmer at that size.
    private var showsConduit: Bool {
        if case .publicRunning = state { return !isCompact }
        return false
    }

    private var captions: [String] {
        switch state {
        case .local: ["Only on this Mac"]
        case .publicRunning(_, let captions): captions
        default: []
        }
    }

    private var failure: (headline: String, raw: String)? {
        switch state {
        case .partialFailure(let message): ("Your public link stopped.", message)
        case .failed(let message): ("The server couldn't start.", message)
        default: nil
        }
    }

    private var accessibilitySummary: String {
        var parts = ["Connection: \(statusWord)."]
        if let urlText {
            parts.append("\(urlText).")
        }
        switch state {
        case .off: parts.append("Start Server available.")
        case .zeroTools: parts.append("Open Tools available.")
        case .starting: break
        case .local: parts.append("Go Public and Stop Server available.")
        case .publicPending: parts.append("Stop Server available.")
        case .publicRunning: parts.append("Stop Sharing, Stop Server, Copy available.")
        case .partialFailure: parts.append("Retry and Stop Server available.")
        case .failed: parts.append("Retry available.")
        }
        return parts.joined(separator: " ")
    }
}
