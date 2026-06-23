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
                        Text("Not created yet")
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Text("The first implementation detects `cloudflared` and proves local server readiness. Tunnel creation stays gated until OAuth host approval is implemented.")
                        .foregroundStyle(.secondary)
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
}
