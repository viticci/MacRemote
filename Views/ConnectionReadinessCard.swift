import AppKit
import SwiftUI

// MARK: - Readiness card (SPEC §4.2 — the real six-check machine; rows expand in EVERY state, D1/§8.4)

struct ConnectionReadinessCard: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @SceneStorage("connection.readinessCollapsed") private var isCollapsed = false
    @State private var expandedRows: Set<ReadinessRow> = []
    @State private var isShowingProtections = false

    var body: some View {
        let readiness = appModel.smokeReadiness

        Card(
            title: "Readiness",
            systemImage: "list.bullet.clipboard",
            isCollapsed: $isCollapsed,
            summary: { summaryLine(readiness) },
            content: {
                VStack(alignment: .leading, spacing: Space.s3) {
                    ForEach(ReadinessRow.allCases) { row in
                        ConnectionReadinessRowView(
                            row: row,
                            check: check(for: row, in: readiness),
                            isExpanded: expandedRows.contains(row),
                            toggle: { toggle(row) },
                            collapse: { expandedRows.remove(row) }
                        )
                    }
                    footer
                }
            }
        )
        .onChange(of: allRequiredClear(readiness)) { wasClear, isClear in
            // D16-style self-retirement: collapse on the transition to all clear.
            if isClear, !wasClear {
                withAnimation(.snappy) {
                    isCollapsed = true
                }
            }
        }
        .onChange(of: appModel.readinessRowToExpand) { _, row in
            reveal(row)
        }
        .onAppear {
            reveal(appModel.readinessRowToExpand)
        }
    }

    private func reveal(_ row: ReadinessRow?) {
        guard let row else { return }
        withAnimation(.snappy) {
            isCollapsed = false
            expandedRows.insert(row)
        }
        // Cleared on the next runloop so the page's scroll handler still sees
        // the one-shot signal (§2.4).
        Task { @MainActor in
            appModel.clearReadinessRowToExpand()
        }
    }

    private func toggle(_ row: ReadinessRow) {
        withAnimation(.snappy) {
            if expandedRows.contains(row) {
                expandedRows.remove(row)
            } else {
                expandedRows.insert(row)
            }
        }
    }

    private func check(for row: ReadinessRow, in readiness: SmokeReadiness) -> SmokeReadinessCheck? {
        readiness.checks.first { $0.id == row.rawValue }
    }

    /// "All clear" ignores the optional Anthropic key row (SPEC §4 wireframe).
    private func allRequiredClear(_ readiness: SmokeReadiness) -> Bool {
        readiness.checks
            .filter { $0.id != ReadinessRow.anthropicKey.rawValue }
            .allSatisfy { $0.status == .ready }
    }

    private func summaryLine(_ readiness: SmokeReadiness) -> some View {
        let unfinished = readiness.checks.filter {
            $0.status != .ready && $0.id != ReadinessRow.anthropicKey.rawValue
        }
        // A real problem (blocked/warning) is alarming; a row that is merely
        // waiting for the user to start the server is not.
        let problems = unfinished.filter { $0.status == .blocked || $0.status == .warning }

        return HStack(spacing: Space.s2) {
            if unfinished.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("All clear")
                    .font(TypeRamp.rowDetail)
            } else if problems.isEmpty {
                Image(systemName: "circle.dashed")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Ready when you start the server")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(problemSummary(problems))
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func problemSummary(_ problems: [SmokeReadinessCheck]) -> String {
        guard let first = problems.first,
              let row = ReadinessRow(rawValue: first.id) else {
            return "Checking"
        }
        let title = ConnectionReadinessRowView.title(for: row)
        return problems.count == 1 ? "\(title) needs attention" : "\(problems.count) checks need attention — first: \(title)"
    }

    private var footer: some View {
        HStack(spacing: Space.s2) {
            Button("Check Readiness", systemImage: "list.bullet.clipboard") {
                appModel.checkSmokeReadiness()
            }
            .disabled(appModel.smokeTestState.isRunning)

            Spacer()

            Button {
                isShowingProtections.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.borderless)
            .help("How MacRemote protects this Mac")
            .accessibilityLabel("How MacRemote protects this Mac")
            .popover(isPresented: $isShowingProtections, arrowEdge: .bottom) {
                ConnectionProtectionsPopover()
            }
        }
    }
}

// MARK: - The eight assurances (DA-16 — design guarantees, not status)

private struct ConnectionProtectionsPopover: View {
    // SPEC §4.2 — the eight former Security-Gates assurances, re-voiced per the
    // GUIDELINES §4.3 banned-words list (no "loopback"/"argv" in visible copy).
    private static let assurances = [
        "The server listens only on this Mac",
        "No shell — commands run exactly as written",
        "Tools are exact programs, never free-form commands",
        "Only one port is ever shared",
        "Apps need your approval before they can sign in",
        "Tools that change things ask you every time",
        "Going public always asks you first",
        "Full Disk Access is checked before the server starts"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("How MacRemote protects this Mac")
                .font(TypeRamp.cardTitle)
            Text("By design:")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            ForEach(Self.assurances, id: \.self) { assurance in
                HStack(spacing: Space.s2) {
                    Image(systemName: "checkmark.shield")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(assurance)
                        .font(.callout)
                }
            }
            Text("These are design guarantees, not live checks — the Readiness rows carry the live status.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Space.s1)
        }
        .padding(Space.s4)
        .frame(width: 320)
    }
}

// MARK: - Row

private struct ConnectionReadinessRowView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let row: ReadinessRow
    let check: SmokeReadinessCheck?
    let isExpanded: Bool
    let toggle: () -> Void
    let collapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Button(action: toggle) {
                HStack(spacing: Space.s2) {
                    glyph
                        .frame(width: 20)
                    Text(Self.title(for: row))
                        .font(.body)
                    Text(statusWord)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(statusTint)
                    Text(detail)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Space.s1)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(Self.title(for: row)): \(statusWord). \(detail)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                expansion
                    .padding(.leading, Space.s6)
            }
        }
    }

    static func title(for row: ReadinessRow) -> String {
        switch row {
        case .fullDiskAccess: "Full Disk Access"
        case .privacyPermissions: "Privacy Permissions"
        case .localServer: "Local Server"
        case .publicURL: "Public URL"
        case .sharedTools: "Shared Tools"
        case .anthropicKey: "Anthropic API Key"
        }
    }

    private var status: SmokeReadinessStatus {
        check?.status ?? .checking
    }

    private var statusWord: String {
        if row == .anthropicKey, status == .blocked {
            return "Optional"
        }
        return status.title
    }

    private var statusTint: Color {
        if row == .anthropicKey, status == .blocked {
            return .orange
        }
        return switch status {
        case .ready: .green
        case .checking: .blue
        case .warning: .orange
        case .blocked: .red
        case .waiting: .secondary
        }
    }

    private var symbolName: String {
        switch row {
        case .fullDiskAccess: "internaldrive"
        case .privacyPermissions: "checkmark.shield"
        case .localServer: "server.rack"
        case .publicURL: "globe"
        case .sharedTools: "wrench.and.screwdriver"
        case .anthropicKey: "key"
        }
    }

    @ViewBuilder
    private var glyph: some View {
        let base = Image(systemName: symbolName)
            .foregroundStyle(statusTint)
            .accessibilityHidden(true)
        if reduceMotion {
            base
        } else {
            // Signature moment 3: symbols sweep while checking, settle with a bounce.
            base
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeat(.continuous),
                    isActive: status == .checking
                )
                .symbolEffect(.bounce, options: .nonRepeating, value: status == .ready)
        }
    }

    /// Re-voiced live detail (GUIDELINES §4 — the machine's strings carry banned
    /// vocabulary; raw failure text passes through untouched).
    private var detail: String {
        guard let check else { return "" }
        switch row {
        case .fullDiskAccess:
            switch appModel.fullDiskAccessReport.state {
            case .required:
                return "Add every item below in System Settings, then relaunch"
            case .confirmationRequired:
                return "Confirm the current Full Disk Access setup below"
            case .failed(let message):
                return message
            default:
                if check.status == .ready {
                    return check.detail.hasPrefix("No exposed tools")
                        ? "No shared tools need Full Disk Access"
                        : "Protected-data tools can run from MacRemote"
                }
                if check.status == .checking {
                    return "Checking protected-data access"
                }
                return "Run Check Readiness to find out which items need access"
            }
        case .privacyPermissions:
            switch check.status {
            case .ready:
                return check.detail.hasPrefix("No exposed tools")
                    ? "No shared tools need checked privacy access"
                    : "Required privacy services are ready"
            case .checking:
                return "Checking app-service access"
            default:
                return appModel.macOSPrivacyAccessReport.detail
            }
        case .localServer:
            return check.detail
        case .publicURL:
            if check.status == .ready {
                return check.detail
            }
            if check.status == .checking {
                return "Waiting for Cloudflare"
            }
            if case .failed(let message) = appModel.tunnelStatus {
                return message
            }
            return "Go public after the server is running"
        case .sharedTools:
            let summary = appModel.toolExposureSummary
            switch check.status {
            case .ready:
                return "\(summary.total) shared: \(summary.readOnly) read-only, \(summary.gatedToolCount) ask first"
            case .warning:
                return "Shared tools cover the Quick Test; add a read-only tool for the Full Test"
            default:
                return "Share at least one tool before testing"
            }
        case .anthropicKey:
            switch appModel.anthropicCredentialState {
            case .ready:
                return "A key is available for the Full Test"
            case .checking:
                return check.detail
            case .failed(let message):
                return message
            case .unknown:
                return "For the Full Test — run Check Readiness to look for a key"
            }
        }
    }

    // MARK: Expansions (available in every state — D1)

    @ViewBuilder
    private var expansion: some View {
        switch row {
        case .fullDiskAccess:
            fullDiskAccessExpansion
        case .privacyPermissions:
            privacyExpansion
        case .localServer:
            localServerExpansion
        case .publicURL:
            publicURLExpansion
        case .sharedTools:
            sharedToolsExpansion
        case .anthropicKey:
            anthropicKeyExpansion
        }
    }

    private var fullDiskAccessExpansion: some View {
        AccessFixer(
            state: accessFixerState,
            targets: appModel.fullDiskAccessReport.targets,
            actions: AccessFixerActions(
                checkAgain: { appModel.checkFullDiskAccess() },
                openSystemSettings: { appModel.openFullDiskAccessHelper() },
                later: collapse,
                relaunch: { appModel.relaunchMacRemote() },
                readdInSystemSettings: { appModel.resetMacRemoteFullDiskAccessGrant() },
                confirmSetup: appModel.fullDiskAccessReport.requiresManualConfirmation
                    ? { appModel.confirmFullDiskAccessSetup() }
                    : nil,
                copyAllPaths: {
                    copyToPasteboard(appModel.fullDiskAccessReport.targets.map(\.path).joined(separator: "\n"))
                    appModel.appendLog(level: .info, "Copied all Full Disk Access target paths.")
                },
                copyFirstTarget: {
                    guard let first = appModel.fullDiskAccessReport.targets.first else { return }
                    copyTargetToPasteboard(first)
                    appModel.appendLog(level: .info, "Copied Full Disk Access target: \(first.title).")
                },
                openConnectionReadiness: { appModel.revealReadinessRow(.fullDiskAccess) }
            ),
            onCopyTarget: { target in
                copyTargetToPasteboard(target)
                appModel.appendLog(level: .info, "Copied Full Disk Access target: \(target.title).")
            },
            onRevealTarget: { target in
                NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
                appModel.appendLog(level: .info, "Revealed Full Disk Access target: \(target.title).")
            }
        )
    }

    private var accessFixerState: AccessFixerState {
        switch appModel.fullDiskAccessReport.state {
        case .checking: .checking
        case .ready: .ready
        case .failed(let message): .failed(message)
        case .confirmationRequired: .confirmSetup
        case .unknown, .required, .helperOpened: .required
        }
    }

    private var privacyExpansion: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(appModel.macOSPrivacyAccessReport.detail)
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !appModel.macOSPrivacyAccessReport.checkedRequirements.isEmpty {
                HStack(spacing: Space.s1) {
                    ForEach(appModel.macOSPrivacyAccessReport.checkedRequirements, id: \.self) { requirement in
                        StateChip(requirement.title, systemImage: requirement.systemImage, role: .working)
                    }
                }
            }

            HStack(spacing: Space.s2) {
                Button("Check Again", systemImage: "checkmark.shield") {
                    appModel.checkFullDiskAccess()
                }
                Button("Open Reminders Privacy", systemImage: "checklist") {
                    openPrivacySettings(anchor: "Privacy_Reminders")
                }
            }
        }
    }

    @ViewBuilder
    private var localServerExpansion: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let url = appModel.localServerURL {
                MonoValue(url.absoluteString) {
                    appModel.appendLog(level: .info, "Copied the local server address.")
                }
            }
            HStack(spacing: Space.s2) {
                if appModel.serverStatus.isRunning {
                    Button("Stop Server") { appModel.stopLocalServer() }
                } else {
                    Button("Start Server") { appModel.startLocalServer() }
                        .disabled(appModel.serverStatus == .starting || appModel.toolExposureSummary.total == 0)
                }
            }
        }
    }

    @ViewBuilder
    private var publicURLExpansion: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let url = appModel.currentPublicMCPURL {
                MonoValue(url.absoluteString) {
                    appModel.appendLog(level: .info, "Copied the public link for this Mac.")
                }
            } else if case .failed = appModel.tunnelStatus {
                Button("Retry") { appModel.startTunnel() }
            } else {
                Text("Going public creates the URL you paste into your app.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                Button("Go Public…") { requestGoPublicInline() }
                    .disabled(!appModel.serverStatus.isRunning || appModel.tunnelStatus == .starting || appModel.tunnelStatus == .unavailable)
            }
        }
    }

    private var sharedToolsExpansion: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            let summary = appModel.toolExposureSummary
            Text(summary.total == 0
                 ? "Nothing is shared yet — apps can't see any tools."
                 : "\(summary.total) shared: \(summary.readOnly) read-only, \(summary.gatedToolCount) ask first, \(summary.destructive) destructive.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            Button("Open Tools") { appModel.selection = .tools }
        }
    }

    private var anthropicKeyExpansion: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Optional — for the full test. The Full Test asks Claude to call one read-only tool through your public link, which needs an Anthropic API key (ANTHROPIC_API_KEY) available to MacRemote.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check Again", systemImage: "key") {
                appModel.checkSmokeReadiness()
            }
            .disabled(appModel.smokeTestState.isRunning)
        }
    }

    // MARK: Helpers

    private func requestGoPublicInline() {
        appModel.goPublicConfirmationRequested = true
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func copyTargetToPasteboard(_ target: FullDiskAccessTarget) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(target.path, forType: .string)
        pasteboard.setString(URL(fileURLWithPath: target.path).absoluteString, forType: .fileURL)
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
