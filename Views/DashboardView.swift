import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "Dashboard",
                    subtitle: "Expose only the tool surface you choose, then approve every remote client on this Mac."
                )

                ConnectionFlowPanel()

                HStack(alignment: .top, spacing: 14) {
                    ToolSurfaceSummaryPanel()
                    RuntimeSummaryPanel()
                }

                SecurityChecklistView()

                RecentLogsPreview()
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
    }
}

private struct ConnectionFlowPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    "Connection Flow",
                    subtitle: "Follow this order for a safe remote MCP session."
                )

                Spacer()

                if appModel.serverStatus.isRunning {
                    Button("Run Reminders Test", systemImage: "checkmark.circle") {
                        appModel.runRemCTLTodayTest()
                    }
                    .disabled(!appModel.isToolIDExposed("remctl.today"))
                }
            }

            HStack(alignment: .top, spacing: 14) {
                FlowStep(
                    index: 1,
                    title: "Choose Tools",
                    detail: toolsStepDetail,
                    systemImage: "wrench.and.screwdriver",
                    state: toolsStepState
                ) {
                    Button("Tools", systemImage: "terminal") {
                        appModel.selection = .tools
                    }
                }

                FlowStep(
                    index: 2,
                    title: "Start Local Server",
                    detail: serverDetail,
                    systemImage: "server.rack",
                    state: serverStepState
                ) {
                    switch appModel.serverStatus {
                    case .running:
                        Button("Stop", systemImage: "stop.fill") {
                            appModel.stopLocalServer()
                        }
                    case .starting:
                        ProgressView()
                            .controlSize(.small)
                    default:
                        Button("Start", systemImage: "play.fill") {
                            appModel.startLocalServer()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appModel.toolExposureSummary.total == 0)
                    }
                }

                FlowStep(
                    index: 3,
                    title: "Open Public Tunnel",
                    detail: tunnelDetail,
                    systemImage: "point.3.connected.trianglepath.dotted",
                    state: tunnelStepState
                ) {
                    switch appModel.tunnelStatus {
                    case .ready:
                        StartTunnelButton(title: "Start")
                            .buttonStyle(.borderedProminent)
                    case .running:
                        HStack(spacing: 8) {
                            Button("Stop", systemImage: "stop.fill") {
                                appModel.stopTunnel()
                            }

                            Button("Copy URL", systemImage: "doc.on.doc") {
                                copyTunnelURL()
                            }
                            .disabled(appModel.currentPublicMCPURL == nil)
                        }
                    case .starting:
                        ProgressView()
                            .controlSize(.small)
                    default:
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            appModel.refreshTunnelStatus()
                        }
                    }
                }
            }
        }
    }

    private var serverDetail: String {
        if let localServerURL = appModel.localServerURL {
            return localServerURL.absoluteString
        }
        return "Bound to 127.0.0.1 only when running."
    }

    private var tunnelDetail: String {
        switch appModel.tunnelStatus {
        case .unavailable:
            return "`cloudflared` was not found on PATH or in Homebrew paths."
        case .starting:
            return "Waiting for Cloudflare to assign a public URL."
        case .ready:
            return "Cloudflare can forward to the local server."
        case .running(let url):
            return appModel.publicMCPURL(for: url).absoluteString
        case .failed(let message):
            return message
        case .stopped:
            return "Start the local server before creating a tunnel."
        }
    }

    private var toolsStepDetail: String {
        let summary = appModel.toolExposureSummary
        guard summary.total > 0 else {
            return "Expose at least one tool before the server can start."
        }
        return "\(summary.total) tools exposed: \(summary.capabilityDescription)."
    }

    private var toolsStepState: FlowStepState {
        appModel.toolExposureSummary.total > 0 ? .ready : .blocked
    }

    private var serverStepState: FlowStepState {
        switch appModel.serverStatus {
        case .running: .ready
        case .starting: .active
        case .failed: .blocked
        case .stopped: .idle
        }
    }

    private var tunnelStepState: FlowStepState {
        switch appModel.tunnelStatus {
        case .running: .ready
        case .starting, .ready: .active
        case .failed, .unavailable: .blocked
        case .stopped: .idle
        }
    }

    private func copyTunnelURL() {
        guard let url = appModel.currentPublicMCPURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        appModel.appendLog(level: .info, "Copied public MCP URL.")
    }
}

private struct ToolSurfaceSummaryPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let summary = appModel.toolExposureSummary

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                "Exposed Surface",
                subtitle: "These tools are currently visible to MCP clients. Write-capable calls still stop for host approval."
            )

            HStack(spacing: 10) {
                MetricPill(title: "Total", value: "\(summary.total)", systemImage: "wrench.adjustable", tint: .blue)
                MetricPill(title: "Read-only", value: "\(summary.readOnly)", systemImage: "eye", tint: .green)
                MetricPill(title: "Host-gated", value: "\(summary.gatedToolCount)", systemImage: "hand.raised", tint: .orange)
                MetricPill(title: "Adapters", value: "\(summary.genericAdapters)", systemImage: "terminal", tint: .purple)
            }

            if summary.nonReadOnlyToolNames.isEmpty {
                Label("No write-capable tools are exposed.", systemImage: "checkmark.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label("Approval required for \(summary.nonReadOnlyToolNames.joined(separator: ", ")).", systemImage: "lock.shield")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panelStyle()
    }
}

private struct RuntimeSummaryPanel: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader("Runtime", subtitle: "Current server, tunnel, and authorization state.")

            VStack(alignment: .leading, spacing: 10) {
                RuntimeRow(label: "Local server", value: appModel.serverStatus.title, detail: localServerDetail, tint: serverTint)
                RuntimeRow(label: "Tunnel", value: appModel.tunnelStatus.title, detail: tunnelDetail, tint: tunnelTint)
                RuntimeRow(label: "Pending approvals", value: "\(pendingApprovalCount)", detail: pendingApprovalDetail, tint: pendingApprovalCount > 0 ? .orange : .green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .panelStyle()
    }

    private var localServerDetail: String {
        appModel.localServerURL?.absoluteString ?? "Loopback only when running."
    }

    private var tunnelDetail: String {
        appModel.currentPublicMCPURL?.absoluteString ?? "No public MCP URL."
    }

    private var pendingApprovalCount: Int {
        appModel.approvals.filter { $0.state == .pending }.count +
            appModel.toolCallApprovals.filter { $0.state == .pending }.count
    }

    private var pendingApprovalDetail: String {
        pendingApprovalCount == 0 ? "No pending client or tool-call requests." : "Open Approvals before the request expires."
    }

    private var serverTint: Color {
        switch appModel.serverStatus {
        case .running: .green
        case .starting: .blue
        case .failed: .orange
        case .stopped: .secondary
        }
    }

    private var tunnelTint: Color {
        switch appModel.tunnelStatus {
        case .running: .green
        case .starting, .ready: .blue
        case .failed, .unavailable: .orange
        case .stopped: .secondary
        }
    }
}

private struct RuntimeRow: View {
    let label: String
    let value: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.callout.weight(.medium))
                    StatusBadge(title: value, tint: tint)
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct SecurityChecklistView: View {
    private let items = [
        "Loopback-only local server",
        "Host approval required before token issuance",
        "Write tools require per-call approval",
        "Full Disk Access checked before server start",
        "No arbitrary shell commands",
        "CLI adapters run as direct argv",
        "Cloudflare Tunnel forwards one local port",
        "Public tunnel start requires confirmation"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Security Gates", subtitle: "These checks stay active even when the public URL is live.")

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(items, id: \.self) { item in
                    GridRow {
                        Image(systemName: "checkmark.shield")
                            .foregroundStyle(.green)
                        Text(item)
                    }
                }
            }
        }
        .panelStyle()
    }
}

private struct RecentLogsPreview: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)

            if appModel.logs.isEmpty {
                Text("No activity yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appModel.logs.prefix(5)) { entry in
                    LogRow(entry: entry)
                }
            }
        }
        .panelStyle()
    }
}
