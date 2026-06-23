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
                                copyPreflightCommand()
                            }
                        }
                    }
                }
                .panelStyle()

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

    private func copyPreflightCommand() {
        guard let url = appModel.currentPublicMCPURL else { return }
        let command = """
        MACREMOTE_MCP_URL="\(url.absoluteString)" \\
        ./script/anthropic_mcp_smoke.py --mcp-preflight-only
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        appModel.appendLog(level: .info, "Copied MacRemote MCP preflight command.")
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
