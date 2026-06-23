import SwiftUI

struct HeaderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusPanel<Actions: View>: View {
    let title: String
    let value: String
    let systemImage: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(value)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                actions
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .panelStyle()
    }
}

struct StartTunnelButton: View {
    @Environment(AppModel.self) private var appModel
    let title: String
    @State private var isShowingStartConfirmation = false

    var body: some View {
        Button(title, systemImage: "point.3.connected.trianglepath.dotted") {
            isShowingStartConfirmation = true
        }
        .confirmationDialog(
            "Start Public Tunnel?",
            isPresented: $isShowingStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Tunnel", role: .destructive) {
                appModel.startTunnel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        let summary = appModel.toolExposureSummary
        return "Cloudflare will create a public HTTPS route to MacRemote's local MCP server, not to the whole Mac. The exposed surface is \(summary.total) tools: \(summary.readOnly) read-only and \(summary.gatedToolCount) write/destructive tools requiring per-call host approval. OAuth host approval is still required before any remote client receives tokens."
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
    }
}
