import AppKit
import SwiftUI

struct TunnelView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "Tunnel",
                    subtitle: "Cloudflare Tunnel is the default public transport for Claude-style remote MCP clients."
                )

                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Provider") {
                        Text("Cloudflare Tunnel")
                    }
                    LabeledContent("Status") {
                        Text(appModel.tunnelStatus.title)
                    }
                    LabeledContent("Local target") {
                        Text(appModel.localServerURL?.absoluteString ?? "Start the local server first")
                            .foregroundStyle(appModel.localServerURL == nil ? .secondary : .primary)
                    }
                    LabeledContent("Public URL") {
                        HStack(spacing: 8) {
                            Text(publicURLText)
                                .foregroundStyle(appModel.tunnelStatus.isRunning ? .primary : .secondary)
                                .textSelection(.enabled)

                            if appModel.currentPublicMCPURL != nil {
                                Button("Copy", systemImage: "doc.on.doc") {
                                    copyPublicURL()
                                }
                            }
                        }
                    }

                    Divider()

                    Text("The public endpoint forwards only to the local MCP server port. OAuth registration, PKCE, bearer tokens, and host approval still gate every tool call.")
                        .foregroundStyle(.secondary)

                    HStack {
                        switch appModel.tunnelStatus {
                        case .ready:
                            StartTunnelButton(title: "Start Tunnel")
                            .buttonStyle(.borderedProminent)
                        case .running:
                            Button("Stop Tunnel", systemImage: "stop.fill") {
                                appModel.stopTunnel()
                            }
                        case .starting:
                            ProgressView()
                                .controlSize(.small)
                        default:
                            Button("Refresh", systemImage: "arrow.clockwise") {
                                appModel.refreshTunnelStatus()
                            }
                        }

                        Button("Smoke Test Guide", systemImage: "terminal") {
                            openSmokeTestGuide()
                        }

                        if appModel.currentPublicMCPURL != nil {
                            Button("Copy Preflight", systemImage: "doc.on.clipboard") {
                                copySmokeTestCommand(mode: .preflight)
                            }

                            Button("Copy API Smoke", systemImage: "key.fill") {
                                copySmokeTestCommand(mode: .anthropicAPI)
                            }
                        }
                    }
                }
                .panelStyle()

                SmokeTestPanel()

                SmokeProofPanel(record: appModel.lastSmokeProof)

                ExposureSummaryPanel(summary: appModel.toolExposureSummary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Why Cloudflare")
                        .font(.headline)
                    Text("Remote MCP connectors originate from the provider cloud. Cloudflare Tunnel gives MacRemote a public HTTPS route without opening inbound ports, and can add Access or Managed OAuth later without changing the local server boundary.")
                        .foregroundStyle(.secondary)
                }
                .panelStyle()
            }
            .padding(24)
        }
        .navigationTitle("Tunnel")
    }

    private var publicURLText: String {
        if let currentPublicMCPURL = appModel.currentPublicMCPURL {
            return currentPublicMCPURL.absoluteString
        }

        switch appModel.tunnelStatus {
        case .starting:
            return "Waiting for Cloudflare"
        case .failed(let message):
            return message
        default:
            return "Not created yet"
        }
    }

    private func copyPublicURL() {
        guard let url = appModel.currentPublicMCPURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        appModel.appendLog(level: .info, "Copied public MCP URL.")
    }

    private func openSmokeTestGuide() {
        let url = URL(fileURLWithPath: "/Users/viticci/Projects/MacRemote/docs/END_TO_END_SMOKE_TEST.md")
        NSWorkspace.shared.open(url)
    }

    private func copySmokeTestCommand(mode: SmokeTestMode) {
        guard let url = appModel.currentPublicMCPURL else { return }
        let command = appModel.smokeTestCopyCommand(for: mode, mcpURL: url)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        appModel.appendLog(level: .info, "Copied \(mode.logTitle) command.")
    }
}

private struct SmokeTestPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let readiness = appModel.smokeReadiness

        VStack(alignment: .leading, spacing: 12) {
            Text("Remote MCP Verification")
                .font(.headline)

            LabeledContent("Status") {
                HStack(spacing: 8) {
                    if appModel.smokeTestState.isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Text(appModel.smokeTestState.title)
                }
            }

            Text(detailText)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(readiness.checks) { check in
                    SmokeReadinessRow(check: check)
                }
            }

            FullDiskAccessReadinessTargetsPanel()

            HStack {
                Button("Check Readiness", systemImage: "checklist") {
                    appModel.checkSmokeReadiness()
                }
                .disabled(appModel.smokeTestState.isRunning)

                Button("Run Preflight", systemImage: "checkmark.seal") {
                    appModel.runSmokeTest(mode: .preflight)
                }
                .disabled(!readiness.canRunPreflight)

                Button("Run API Smoke", systemImage: "network.badge.shield.half.filled") {
                    appModel.runSmokeTest(mode: .anthropicAPI)
                }
                .disabled(!readiness.canRunAnthropicAPI)
            }
        }
        .panelStyle()
    }

    private var canRun: Bool {
        appModel.currentPublicMCPURL != nil
    }

    private var detailText: String {
        if !canRun {
            return "Start the local server and public tunnel before running remote MCP verification."
        }

        return appModel.smokeTestState.detail
    }
}

private struct FullDiskAccessReadinessTargetsPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if shouldShow {
            VStack(alignment: .leading, spacing: 10) {
                Divider()

                HStack(alignment: .firstTextBaseline) {
                    Label("Full Disk Access Targets", systemImage: "lock.shield")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Button("Settings", systemImage: "gearshape") {
                        appModel.selection = .settings
                    }
                    .controlSize(.small)
                }

                Text("Remote MCP verification is blocked until every target below has Full Disk Access and MacRemote has been relaunched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(appModel.fullDiskAccessReport.targets) { target in
                    FullDiskAccessTargetRow(
                        target: target,
                        copyAction: {
                            copyPath(target.path)
                            appModel.appendLog(level: .info, "Copied Full Disk Access target: \(target.title).")
                        },
                        revealAction: {
                            NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
                            appModel.appendLog(level: .info, "Revealed Full Disk Access target: \(target.title).")
                        }
                    )
                }

                HStack(spacing: 10) {
                    Button("Copy All Paths", systemImage: "doc.on.clipboard") {
                        copyAllTargetPaths(appModel.fullDiskAccessReport.targets)
                        appModel.appendLog(level: .info, "Copied all Full Disk Access target paths.")
                    }

                    Button("Open Guided Setup", systemImage: "gearshape.2") {
                        appModel.openFullDiskAccessHelper()
                    }

                    Text("Drag a row into Full Disk Access, or copy a path and use Command-Shift-G in the file picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var shouldShow: Bool {
        !appModel.fullDiskAccessReport.isReady &&
            !appModel.fullDiskAccessReport.targets.isEmpty
    }

    private func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        pasteboard.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
    }

    private func copyAllTargetPaths(_ targets: [FullDiskAccessTarget]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
    }
}

private struct SmokeReadinessRow: View {
    let check: SmokeReadinessCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName)
                .foregroundStyle(color)
                .frame(width: 18)

            Text(check.title)
                .fontWeight(.medium)
                .frame(width: 128, alignment: .leading)

            Text(check.status.title)
                .foregroundStyle(color)
                .frame(width: 72, alignment: .leading)

            Text(check.detail)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .font(.caption)
    }

    private var symbolName: String {
        switch check.status {
        case .ready: "checkmark.circle.fill"
        case .checking: "arrow.triangle.2.circlepath.circle"
        case .warning: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch check.status {
        case .ready: .green
        case .checking: .blue
        case .warning: .orange
        case .blocked: .red
        }
    }
}

private struct SmokeProofPanel: View {
    @Environment(AppModel.self) private var appModel
    let record: SmokeProofRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Last Proof")
                    .font(.headline)

                Spacer()

                if let record {
                    Button("Copy Proof", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.clipboardText, forType: .string)
                        appModel.appendLog(level: .info, "Copied redacted remote MCP proof.")
                    }
                }
            }

            if let record {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    ProofRow(label: "Status", value: record.statusTitle)
                    ProofRow(label: "Mode", value: record.mode.title)
                    ProofRow(label: "MCP URL", value: record.mcpURL)
                    ProofRow(label: "Tool surface", value: record.toolSurface)
                    ProofRow(label: "Result", value: record.resultSummary)
                }

                if !record.markers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Markers")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(record.markers, id: \.self) { marker in
                            Text(marker)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            } else {
                Text("No remote MCP proof has been captured yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .panelStyle()
    }
}

private struct ProofRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

private struct ExposureSummaryPanel: View {
    let summary: ToolExposureSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Exposed Tool Surface")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                ExposureRow(label: "Total", value: "\(summary.total) tools")
                ExposureRow(label: "Read-only", value: "\(summary.readOnly)")
                ExposureRow(label: "Host-gated", value: "\(summary.gatedToolCount) write/destructive")
                ExposureRow(label: "Custom", value: "\(summary.custom)")
                ExposureRow(label: "Generic adapters", value: "\(summary.genericAdapters)")
            }

            if summary.nonReadOnlyToolNames.isEmpty {
                Text("No write-capable tools are currently exposed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Host approval required for: \(summary.nonReadOnlyToolNames.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .panelStyle()
    }
}

private struct ExposureRow: View {
    let label: String
    let value: String

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .monospaced))
        }
    }
}
