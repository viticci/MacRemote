import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "Dashboard",
                    subtitle: "Local MCP server, RemCTL profile, and tunnel readiness."
                )

                HStack(alignment: .top, spacing: 14) {
                    StatusPanel(
                        title: "Local Server",
                        value: appModel.serverStatus.title,
                        systemImage: "server.rack",
                        detail: serverDetail
                    ) {
                        if appModel.serverStatus.isRunning {
                            Button("Stop", systemImage: "stop.fill") {
                                appModel.stopLocalServer()
                            }
                        } else {
                            Button("Start", systemImage: "play.fill") {
                                appModel.startLocalServer()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    StatusPanel(
                        title: "Tunnel",
                        value: appModel.tunnelStatus.title,
                        systemImage: "point.3.connected.trianglepath.dotted",
                        detail: tunnelDetail
                    ) {
                        Button("Refresh", systemImage: "arrow.clockwise") {
                            appModel.refreshTunnelStatus()
                        }
                    }

                    StatusPanel(
                        title: "Tools",
                        value: "\(appModel.tools.count) read-only",
                        systemImage: "wrench.and.screwdriver",
                        detail: "Only `/Users/viticci/bin/remctl` is enabled."
                    ) {
                        Button("Run Safe Test", systemImage: "checkmark.circle") {
                            appModel.runRemCTLTodayTest()
                        }
                    }
                }

                SecurityChecklistView()

                RecentLogsPreview()
            }
            .padding(24)
        }
        .navigationTitle("Dashboard")
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
            return "`cloudflared` was not found in Homebrew paths."
        case .ready:
            return "Cloudflare can forward to the local server."
        case .running(let url):
            return url.absoluteString
        case .failed(let message):
            return message
        case .stopped:
            return "Start the local server before creating a tunnel."
        }
    }
}

private struct SecurityChecklistView: View {
    private let items = [
        "Loopback-only local server",
        "Host approval required before token issuance",
        "No arbitrary shell commands",
        "RemCTL profile starts read-only",
        "Cloudflare Tunnel forwards one local port"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Security Gates")
                .font(.headline)

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
