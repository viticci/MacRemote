import SwiftUI

struct ClientsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "Clients",
                    subtitle: "Manage persistent tool approvals for OAuth clients that have connected to this Mac."
                )

                if appModel.connectedClients.isEmpty {
                    ContentUnavailableView(
                        "No Connected Clients",
                        systemImage: "person.2.slash",
                        description: Text("Approved clients will appear here after their first OAuth connection.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .panelStyle()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(
                            "Tool Trust",
                            subtitle: "Always-allowed tools run for that client without a host approval prompt."
                        )

                        ForEach(appModel.connectedClients) { client in
                            ClientTrustPanel(client: client, tools: sortedTools)
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("Clients")
    }

    private var sortedTools: [ToolDefinition] {
        appModel.tools.sorted { lhs, rhs in
            if lhs.category.title != rhs.category.title {
                return lhs.category.title < rhs.category.title
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

private struct ClientTrustPanel: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingDeleteConfirmation = false
    let client: ConnectedClient
    let tools: [ToolDefinition]

    var body: some View {
        let allowedToolIDs = appModel.alwaysAllowedToolIDs(for: client.id)
        let currentToolIDs = Set(tools.map(\.id))
        let allowedCurrentTools = allowedToolIDs.intersection(currentToolIDs)

        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.title3)
                    .foregroundStyle(.green)
                    .frame(width: 30, height: 30)
                    .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(client.name)
                        .font(.headline)
                    Text(client.id)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }

                Spacer()

                StatusBadge(
                    title: "\(allowedCurrentTools.count)/\(tools.count) Always Allowed",
                    systemImage: "checkmark.shield",
                    tint: allowedCurrentTools.isEmpty ? .secondary : .green
                )
            }

            ClientMetadataGrid(client: client)

            HStack(spacing: 8) {
                Button("Allow All Current Tools", systemImage: "checkmark.shield") {
                    appModel.allowAllCurrentTools(for: client.id)
                }
                .disabled(tools.isEmpty)

                Button("Clear Always Allow", systemImage: "xmark.shield") {
                    appModel.clearToolAllowances(for: client.id)
                }
                .disabled(allowedCurrentTools.isEmpty)

                Button("Delete Client", systemImage: "trash", role: .destructive) {
                    isShowingDeleteConfirmation = true
                }
            }

            Divider()

            if tools.isEmpty {
                Text("No tools installed.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(tools) { tool in
                        ClientToolPermissionRow(client: client, tool: tool)

                        if tool.id != tools.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .panelStyle()
        .confirmationDialog(
            "Delete \(client.name)?",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Client", role: .destructive) {
                _ = appModel.deleteOAuthClient(id: client.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacRemote will remove this client's OAuth registration, tokens, pending authorizations, and always-allow tool settings. The remote app must connect again.")
        }
    }
}

private struct ClientMetadataGrid: View {
    let client: ConnectedClient

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            ClientMetadataRow(title: "Client ID", value: client.id)
            ClientMetadataRow(title: "Trust ID", value: client.trustID)
            if let issuer = client.issuer {
                ClientMetadataRow(title: "Issuer", value: issuer)
            }
            if let resource = client.resource {
                ClientMetadataRow(title: "Resource", value: resource)
            }
            ClientMetadataRow(title: "Scopes", value: client.scopes.joined(separator: ", "))
            ClientMetadataRow(title: "Last Auth", value: client.lastAuthorizedAt.formatted(date: .abbreviated, time: .shortened))
        }
        .font(.caption)
    }
}

private struct ClientMetadataRow: View {
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

private struct ClientToolPermissionRow: View {
    @Environment(AppModel.self) private var appModel
    let client: ConnectedClient
    let tool: ToolDefinition

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(tool.name)
                        .font(.subheadline.weight(.semibold))
                    StatusBadge(title: tool.capability.title, systemImage: tool.capability.systemImage, tint: capabilityTint)
                    if !appModel.isToolExposed(tool) {
                        StatusBadge(title: "Disabled", systemImage: "pause.circle", tint: .secondary)
                    }
                }

                Text(tool.id)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            Spacer()

            Toggle(
                "Always Allow",
                isOn: Binding(
                    get: {
                        appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: client.id)
                    },
                    set: { isAllowed in
                        appModel.setToolAlwaysAllowed(isAllowed, toolID: tool.id, clientID: client.id)
                    }
                )
            )
            .toggleStyle(.switch)
        }
        .padding(.vertical, 9)
    }

    private var capabilityTint: Color {
        switch tool.capability {
        case .readOnly: .green
        case .write: .orange
        case .destructive: .red
        }
    }
}

private extension ToolCapability {
    var systemImage: String {
        switch self {
        case .readOnly: "eye"
        case .write: "square.and.pencil"
        case .destructive: "exclamationmark.triangle"
        }
    }
}
