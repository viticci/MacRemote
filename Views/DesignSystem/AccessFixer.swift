import AppKit
import SwiftUI

// MARK: - TargetRow (GUIDELINES §2 — FullDiskAccessTargetRow anatomy kept verbatim)

struct TargetRow: View {
    let target: FullDiskAccessTarget
    let copyAction: () -> Void
    let revealAction: () -> Void

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s1) {
                    Text(target.title)
                        .font(TypeRamp.cardTitle)
                        .lineLimit(1)

                    Label(target.role.title, systemImage: target.role.systemImage)
                        .font(TypeRamp.chip)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, Space.s2)
                        .padding(.vertical, Space.s1)
                        .background(.quaternary, in: Capsule())
                }

                Text(target.path)
                    .font(TypeRamp.machineCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !target.subtitle.isEmpty {
                    Text(target.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Space.s3)

            HStack(spacing: Space.s2) {
                Button("Copy", systemImage: "doc.on.doc", action: copyAction)
                Button("Reveal", systemImage: "finder", action: revealAction)
            }
            .controlSize(.small)
        }
        .padding(Space.s3)
        .background(.quaternary.opacity(0.4), in: AppShape.mono)
        .draggable(URL(fileURLWithPath: target.path))
        .help("Drag this row into Full Disk Access, or copy the path and use Command-Shift-G.")
    }
}

// MARK: - AccessFixer (SPEC §5.8 — one component, three hosts)

enum AccessFixerState: Equatable {
    case checking
    case required
    /// Hosts auto-dismiss on ready, as today.
    case ready
    case failed(String)

    var statusWord: String {
        switch self {
        case .checking: "Checking"
        case .required: "Required"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    var role: StatusRole {
        switch self {
        case .checking: .working
        case .required: .attention
        case .ready: .ready
        case .failed: .error
        }
    }
}

/// Every action is injected — the component performs no work of its own.
/// Copy closures own their pasteboard writes and audit-log lines.
struct AccessFixerActions {
    var checkAgain: () -> Void
    var openSystemSettings: () -> Void
    var later: () -> Void
    var relaunch: () -> Void
    var readdInSystemSettings: () -> Void
    /// Shown only when non-nil (`requiresManualConfirmation`).
    var confirmSetup: (() -> Void)?
    var copyAllPaths: () -> Void
    var copyFirstTarget: () -> Void
    var openConnectionReadiness: () -> Void

    init(
        checkAgain: @escaping () -> Void,
        openSystemSettings: @escaping () -> Void,
        later: @escaping () -> Void,
        relaunch: @escaping () -> Void,
        readdInSystemSettings: @escaping () -> Void,
        confirmSetup: (() -> Void)? = nil,
        copyAllPaths: @escaping () -> Void,
        copyFirstTarget: @escaping () -> Void,
        openConnectionReadiness: @escaping () -> Void
    ) {
        self.checkAgain = checkAgain
        self.openSystemSettings = openSystemSettings
        self.later = later
        self.relaunch = relaunch
        self.readdInSystemSettings = readdInSystemSettings
        self.confirmSetup = confirmSetup
        self.copyAllPaths = copyAllPaths
        self.copyFirstTarget = copyFirstTarget
        self.openConnectionReadiness = openConnectionReadiness
    }
}

struct AccessFixer: View {
    static let defaultTitle = "Full Disk Access needed"
    /// Canonical rewrite (GUIDELINES §4.4 #6).
    static let defaultDetail = "MacRemote and some of its tools each need Full Disk Access. Add every item below — then relaunch and check again."
    /// The layering lecture — kept verbatim per SPEC §5.8 (ⓘ popover only).
    static let layeringExplainer = "Full Disk Access is layered: MacRemote may need access as the host app, and the CLI or its interpreter may also need access as the process that reads protected data. After changing System Settings, run Check Again — MacRemote relaunches itself once if macOS still serves the old answer."

    private let state: AccessFixerState
    private let title: String
    private let detail: String
    private let targets: [FullDiskAccessTarget]
    private let actions: AccessFixerActions
    private let onCopyTarget: (FullDiskAccessTarget) -> Void
    private let onRevealTarget: (FullDiskAccessTarget) -> Void

    @State private var isShowingLayeringInfo = false

    /// `title`/`detail` default to the canonical copy; sheet hosts pass the
    /// bespoke re-voiced `FullDiskAccessPrompt` reason copy instead.
    init(
        state: AccessFixerState,
        title: String = AccessFixer.defaultTitle,
        detail: String = AccessFixer.defaultDetail,
        targets: [FullDiskAccessTarget],
        actions: AccessFixerActions,
        onCopyTarget: @escaping (FullDiskAccessTarget) -> Void,
        onRevealTarget: @escaping (FullDiskAccessTarget) -> Void
    ) {
        self.state = state
        self.title = title
        self.detail = detail
        self.targets = targets
        self.actions = actions
        self.onCopyTarget = onCopyTarget
        self.onRevealTarget = onRevealTarget
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            header
            statusRow

            if case let .failed(errorDetail) = state {
                Text(errorDetail)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            targetList
            numberedStrip
            verbRow
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s1) {
                    Text(title)
                        .font(TypeRamp.cardTitle)
                    Button {
                        isShowingLayeringInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $isShowingLayeringInfo, arrowEdge: .bottom) {
                        Text(Self.layeringExplainer)
                            .font(TypeRamp.rowDetail)
                            .padding(Space.s4)
                            .frame(width: 340)
                    }
                    .accessibilityLabel("About Full Disk Access layering")
                }
                Text(detail)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack(spacing: Space.s2) {
                if state == .checking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(state.statusWord)
                    .foregroundStyle(state.role.tint)
            }
        }
    }

    @ViewBuilder
    private var targetList: some View {
        if targets.isEmpty {
            Text("No items yet — Check Again finds exactly which items need access.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: Space.s2) {
                ForEach(targets) { target in
                    TargetRow(
                        target: target,
                        copyAction: { onCopyTarget(target) },
                        revealAction: { onRevealTarget(target) }
                    )
                }
            }
        }
    }

    private var numberedStrip: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text("① Open System Settings   ② Drag rows in   ③ Check Again")
            Text("macOS caches the old answer, so MacRemote quits and reopens itself once if that's what it takes to see the access you granted.")
        }
        .font(TypeRamp.truthNote)
        .foregroundStyle(.secondary)
    }

    private var verbRow: some View {
        HStack(spacing: Space.s2) {
            Menu("Troubleshoot") {
                Button("Relaunch MacRemote", action: actions.relaunch)
                Button("Re-add MacRemote in System Settings", action: actions.readdInSystemSettings)
                if let confirmSetup = actions.confirmSetup {
                    Button("Confirm Setup Manually", action: confirmSetup)
                }
                Divider()
                Button("Copy All Paths", action: actions.copyAllPaths)
                    .disabled(targets.isEmpty)
                Button("Copy First Target", action: actions.copyFirstTarget)
                    .disabled(targets.isEmpty)
                Divider()
                Button("Open Connection Readiness", action: actions.openConnectionReadiness)
            }
            .fixedSize()
            .disabled(state == .checking)

            Spacer()

            Button("Later", action: actions.later)

            Button("Open System Settings", action: actions.openSystemSettings)
                .buttonStyle(.glass)
                .disabled(state == .checking)

            Button("Check Again", action: actions.checkAgain)
                .buttonStyle(.glassProminent)
                .disabled(state == .checking)
        }
    }
}
