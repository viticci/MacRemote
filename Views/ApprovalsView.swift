import SwiftUI

struct ApprovalsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(
                title: "Approvals",
                subtitle: "Remote clients cannot authorize themselves. New clients must be approved on this Mac."
            )

            if appModel.approvals.isEmpty {
                ContentUnavailableView(
                    "No Pending Requests",
                    systemImage: "checkmark.shield",
                    description: Text("Authorization requests will appear here when a remote MCP client connects.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appModel.approvals) { request in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.clientName)
                            .font(.headline)
                        Text(request.redirectURI)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("Approvals")
    }
}
