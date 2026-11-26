import SwiftUI

/// Everything the Tools page knows about one imported MCP server family.
struct ServerHeaderModel {
    let identity: String
    let name: String
    let totalCount: Int
    let sharedCount: Int
    let candidate: LocalMCPServerCandidate?
    let serverURL: String?
    let usesUpstreamOAuth: Bool
}

/// The header of every Tools page: a tinted icon, the source's name, one
/// count line, optional chips and machine detail, verbs on the right, and
/// progress or error lines underneath. Content layer, never glass.
struct ToolsPageHeader<Chips: View, Detail: View, Actions: View, Notes: View>: View {
    let systemImage: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let chips: Chips
    @ViewBuilder let detail: Detail
    @ViewBuilder let actions: Actions
    @ViewBuilder let notes: Notes

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            // Verbs sit beside the identity when the page is wide enough and
            // drop under it when the inspector leaves little room.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Space.s3) {
                    identity
                    Spacer(minLength: Space.s3)
                    actionsRow
                }
                VStack(alignment: .leading, spacing: Space.s3) {
                    identity
                    actionsRow
                }
            }

            notes
        }
        .padding(.horizontal, Space.s5)
        .padding(.top, Space.s5)
        .padding(.bottom, Space.s2)
    }

    private var identity: some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.13), in: AppShape.mono)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s2) {
                    Text(title)
                        .font(TypeRamp.sourceTitle)
                        .lineLimit(1)
                    chips
                }
                Text(subtitle)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .countText()
                detail
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: Space.s2) {
            actions
        }
    }
}

/// The page of one imported MCP server: identity, status, and every verb
/// that used to sit on the group row (Sign In, Refresh, Share All), plus
/// inline progress and errors.
struct ImportedServerHeader: View {
    @Environment(AppModel.self) private var appModel

    let server: ServerHeaderModel
    let status: MCPServerStatus
    let error: String?
    let shareAllBinding: Binding<Bool>
    let signInAction: () -> Void
    let refreshAction: () -> Void

    var body: some View {
        ToolsPageHeader(
            systemImage: "point.3.connected.trianglepath.dotted",
            tint: .teal,
            title: server.name,
            subtitle: subtitle
        ) {
            status.chip
            if let candidate = server.candidate {
                StateChip(ToolsView.sourceTitle(candidate.source), systemImage: "app.connected.to.app.below.fill", tint: .secondary)
            }
            if server.sharedCount > 0, server.sharedCount < server.totalCount {
                StateChip("Partially Shared", tint: .orange)
            }
        } detail: {
            if let candidate = server.candidate {
                MonoValue(candidate.displayEndpoint, font: TypeRamp.machineCaption, onCopy: {
                    appModel.appendLog(level: .info, "Copied MCP server address for \(server.name).")
                })
                .foregroundStyle(.secondary)
            }
            if let description = server.candidate?.probe?.serverInfo.description, !description.isEmpty {
                Text(description)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if status.kind == .needsSignIn, server.candidate != nil {
                Button("Sign In…", systemImage: "person.crop.circle.badge.checkmark", action: signInAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.mcpSignInServerID != nil)
                    .help("Open \(server.name)'s approval page in your browser")
            }

            if server.candidate != nil {
                // Off while any first-party import runs or waits: a
                // first-party Refresh takes its turn in that queue (D86).
                Button("Refresh", systemImage: "arrow.clockwise", action: refreshAction)
                    .disabled(appModel.hasPendingFirstPartyImports || status.kind == .signingIn || status.kind == .checking)
                    .help("Fetch this server's tools again")
            }

            Toggle("Share All", isOn: shareAllBinding)
                .toggleStyle(.switch)
                .controlSize(.small)
                .fixedSize()

            if let candidate = server.candidate, status.kind == .signedIn {
                Menu {
                    Button("Sign Out", role: .destructive) {
                        appModel.signOutOfMCPServer(candidateID: candidate.id)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .labelStyle(.iconOnly)
                .fixedSize()
                .help("Sign out of \(server.name)")
            }
        } notes: {
            ServerStatusNotes(status: status, serverName: server.name)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var subtitle: String {
        "\(server.sharedCount) of \(server.totalCount) shared"
    }
}

/// The page of a server found on this Mac but not imported yet.
struct CandidateServerHeader: View {
    @Environment(AppModel.self) private var appModel

    let candidate: LocalMCPServerCandidate
    let status: MCPServerStatus
    let importError: String?
    let signInAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        ToolsPageHeader(
            systemImage: candidate.bridgeable ? "point.3.connected.trianglepath.dotted" : "eye",
            tint: candidate.bridgeable ? .teal : .secondary,
            title: candidate.displayName,
            subtitle: subtitle
        ) {
            status.chip
            StateChip(ToolsView.sourceTitle(candidate.source), systemImage: "app.connected.to.app.below.fill", tint: .secondary)
            if candidate.isNewSinceLastScan {
                StateChip("New", role: .working)
            }
        } detail: {
            MonoValue(candidate.displayEndpoint, font: TypeRamp.machineCaption, onCopy: {
                appModel.appendLog(level: .info, "Copied MCP server address for \(candidate.displayName).")
            })
            .foregroundStyle(.secondary)

            if let description = candidate.probe?.serverInfo.description, !description.isEmpty {
                Text(description)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if status.kind == .needsSignIn {
                Button("Sign In…", systemImage: "person.crop.circle.badge.checkmark", action: signInAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.mcpSignInServerID != nil)
                    .help("Open \(candidate.displayName)'s approval page in your browser")
            } else if candidate.bridgeable {
                Button("Import", systemImage: "tray.and.arrow.down", action: importAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.hasPendingFirstPartyImports || status.kind == .signingIn)
                    .help("Import this server's tools so apps can use them through MacRemote")
            }
        } notes: {
            ServerStatusNotes(status: status, serverName: candidate.displayName)

            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private var subtitle: String {
        if let tools = candidate.probe?.tools, !tools.isEmpty {
            return "\(tools.count) \(tools.count == 1 ? "tool" : "tools") found · not imported"
        }
        return "Not imported"
    }
}

/// Progress and status sentences shared by both server pages.
struct ServerStatusNotes: View {
    let status: MCPServerStatus
    let serverName: String

    var body: some View {
        switch status.kind {
        case .signingIn:
            HStack(spacing: Space.s2) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for your approval in \(serverName)…")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
        case .importing:
            HStack(spacing: Space.s2) {
                ProgressView()
                    .controlSize(.small)
                Text("Importing tools…")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
        case .checking:
            HStack(spacing: Space.s2) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking \(serverName)…")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
        case .needsSignIn:
            if let detail = status.detail {
                Label(detail, systemImage: "person.crop.circle.badge.exclamationmark")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.orange)
            }
        case .checkFailed, .viewOnly:
            if let detail = status.detail {
                Label(detail, systemImage: status.kind == .viewOnly ? "info.circle" : "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(status.kind == .viewOnly ? Color.secondary : Color.orange)
                    .textSelection(.enabled)
            }
        case .signedIn, .ready, .unknown:
            EmptyView()
        }
    }
}
