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
                        Text(publicURLText)
                            .foregroundStyle(appModel.tunnelStatus.isRunning ? .primary : .secondary)
                            .textSelection(.enabled)
                    }

                    Divider()

                    Text("The public endpoint forwards only to the local MCP server port. OAuth registration, PKCE, bearer tokens, and host approval still gate every tool call.")
                        .foregroundStyle(.secondary)

                    HStack {
                        switch appModel.tunnelStatus {
                        case .ready:
                            Button("Start Tunnel", systemImage: "point.3.connected.trianglepath.dotted") {
                                appModel.startTunnel()
                            }
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
                    }
                }
                .panelStyle()

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
        switch appModel.tunnelStatus {
        case .running(let url):
            return appModel.publicMCPURL(for: url).absoluteString
        case .starting:
            return "Waiting for Cloudflare"
        case .failed(let message):
            return message
        default:
            return "Not created yet"
        }
    }
}
