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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(request.clientName)
                                    .font(.headline)
                                Text(request.redirectURI)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }

                            Spacer()

                            Text(request.stateTitle)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(color(for: request.state))
                        }

                        if !request.requestedScopes.isEmpty {
                            Text(request.requestedScopes.joined(separator: ", "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if request.state == .pending {
                            HStack {
                                Button("Deny", systemImage: "xmark") {
                                    appModel.denyAuthorizationRequest(request.id)
                                }

                                Button("Approve", systemImage: "checkmark") {
                                    appModel.approveAuthorizationRequest(request.id)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .padding(24)
        .navigationTitle("Approvals")
    }

    private func color(for state: ApprovalRequest.State) -> Color {
        switch state {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        case .expired: .secondary
        }
    }
}
