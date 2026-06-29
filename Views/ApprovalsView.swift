import SwiftUI

struct ApprovalsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(
                title: "Approvals",
                subtitle: "Approve new remote clients and one-off write-capable tool calls on this Mac."
            )

            if appModel.approvals.isEmpty && appModel.toolCallApprovals.isEmpty {
                ContentUnavailableView(
                    "No Pending Requests",
                    systemImage: "checkmark.shield",
                    description: Text("Client authorization and host-gated tool calls will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !appModel.approvals.isEmpty {
                        Section("Client Authorization") {
                            ForEach(appModel.approvals) { request in
                                AuthorizationApprovalRow(request: request)
                            }
                        }
                    }

                    if !appModel.toolCallApprovals.isEmpty {
                        Section("Tool Calls") {
                            ForEach(appModel.toolCallApprovals) { request in
                                ToolCallApprovalRow(request: request)
                            }
                        }
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("Approvals")
    }
}

private struct AuthorizationApprovalRow: View {
    @Environment(AppModel.self) private var appModel
    let request: ApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.clientName)
                        .font(.headline)
                    Text(request.resource)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                Text(request.stateTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: request.state))
            }

            ApprovalDetailGrid(request: request)

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

    private func color(for state: ApprovalRequest.State) -> Color {
        switch state {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        case .expired: .secondary
        }
    }
}

private struct ApprovalDetailGrid: View {
    let request: ApprovalRequest

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ApprovalDetailRow(title: "Request", value: request.id.uuidString)
            ApprovalDetailRow(title: "Client ID", value: request.clientID)
            ApprovalDetailRow(title: "Trust ID", value: request.clientTrustID)
            ApprovalDetailRow(title: "Resource", value: request.resource)
            ApprovalDetailRow(title: "Issuer", value: request.issuer)
            ApprovalDetailRow(title: "Redirect", value: request.redirectURI)
        }
        .font(.caption)
    }
}

private struct ApprovalDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct ToolCallApprovalRow: View {
    @Environment(AppModel.self) private var appModel
    let request: ToolCallApprovalRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.toolName)
                        .font(.headline)
                    Text(request.toolID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let clientName = request.clientName {
                        Text(clientName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let clientID = request.clientID {
                        Text(clientID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Spacer()

                Text(request.stateTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color(for: request.state))
            }

            HStack(spacing: 8) {
                Text(request.capability.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.orange.opacity(0.18), in: Capsule())

                Text(request.createdAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(request.argumentsPreview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            ToolCallIdentityGrid(request: request)

            if request.state == .pending {
                HStack {
                    Button("Deny", systemImage: "xmark") {
                        appModel.denyToolCallRequest(request.id)
                    }

                    Button("Approve Run", systemImage: "play.fill") {
                        appModel.approveToolCallRequest(request.id)
                    }
                    .buttonStyle(.borderedProminent)

                    if request.clientID != nil {
                        Button("Always Allow", systemImage: "checkmark.shield") {
                            appModel.approveToolCallForever(request.id)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func color(for state: ToolCallApprovalRequest.State) -> Color {
        switch state {
        case .pending: .orange
        case .approved: .green
        case .denied: .red
        case .expired: .secondary
        }
    }
}

private struct ToolCallIdentityGrid: View {
    let request: ToolCallApprovalRequest

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ApprovalDetailRow(title: "Request", value: request.id.uuidString)
            if let clientID = request.clientID {
                ApprovalDetailRow(title: "Client ID", value: clientID)
            }
            if let trustID = request.clientTrustID {
                ApprovalDetailRow(title: "Trust ID", value: trustID)
            }
        }
        .font(.caption)
    }
}
