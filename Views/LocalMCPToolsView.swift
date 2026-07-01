import SwiftUI

struct LocalMCPToolsView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    "Local MCPs",
                    subtitle: "Find local MCP servers already connected to Mac AI clients, inspect their tools, and bridge HTTP or stdio transports through MacRemote."
                )

                Spacer()

                Button(scanButtonTitle, systemImage: "dot.radiowaves.left.and.right") {
                    appModel.scanLocalMCPServers()
                }
                .buttonStyle(.borderedProminent)
                .disabled(appModel.localMCPScanState.isScanning)
            }

            LocalMCPOverviewRow(
                candidates: appModel.localMCPScanState.candidates,
                importedGroups: importedGroups,
                isScanning: appModel.localMCPScanState.isScanning
            )

            if let lastScanDate = appModel.localMCPScanState.lastScanDate {
                Text("Last scan: \(lastScanDate.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = appModel.localMCPScanState {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let message = appModel.localMCPErrorMessage ?? errorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if appModel.localMCPScanState.isScanning {
                ProgressView("Scanning local agent configs and probing bridgeable MCP servers...")
                    .frame(maxWidth: .infinity, minHeight: 180)
                    .panelStyle()
            } else if appModel.localMCPScanState.candidates.isEmpty && importedGroups.isEmpty {
                ContentUnavailableView {
                    Label("No Local MCPs Scanned", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("Scan this Mac to find MCP servers from Claude, Codex, Grok, OpenCode, Cursor, LM Studio, Xcode Coding Assistant, and compatible configs.")
                } actions: {
                    Button("Scan This Mac", systemImage: "dot.radiowaves.left.and.right") {
                        appModel.scanLocalMCPServers()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 240)
                .panelStyle()
            } else {
                ForEach(mergedRows) { row in
                    LocalMCPServerPanel(
                        row: row,
                        isWorking: appModel.localMCPWorkingServerID == row.candidate?.id,
                        setError: { errorMessage = $0 }
                    )
                }
            }
        }
    }

    private var scanButtonTitle: String {
        appModel.localMCPScanState.isScanning ? "Scanning" : "Scan This Mac"
    }

    private var importedGroups: [ImportedMCPServerGroup] {
        Dictionary(grouping: appModel.tools.filter(\.isMCPBridge)) { tool in
            tool.mcpBridgeIdentity ?? tool.id
        }
        .map { bridgeIdentity, tools in
            ImportedMCPServerGroup(bridgeIdentity: bridgeIdentity, tools: tools, appModel: appModel)
        }
        .sorted { $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending }
    }

    private var mergedRows: [LocalMCPServerRow] {
        let groupsByIdentity = Dictionary(uniqueKeysWithValues: importedGroups.map { ($0.bridgeIdentity, $0) })
        var rows = appModel.localMCPScanState.candidates.map { candidate in
            LocalMCPServerRow(candidate: candidate, importedGroup: candidate.bridgeIdentity.flatMap { groupsByIdentity[$0] })
        }
        let detectedIdentities = Set(appModel.localMCPScanState.candidates.compactMap(\.bridgeIdentity))
        rows.append(contentsOf: importedGroups.filter { !detectedIdentities.contains($0.bridgeIdentity) }.map {
            LocalMCPServerRow(candidate: nil, importedGroup: $0)
        })
        return rows
    }
}

private struct LocalMCPOverviewRow: View {
    let candidates: [LocalMCPServerCandidate]
    let importedGroups: [ImportedMCPServerGroup]
    let isScanning: Bool

    var body: some View {
        HStack(spacing: 10) {
            MetricPill(title: "Detected", value: "\(candidates.count)", systemImage: isScanning ? "arrow.triangle.2.circlepath" : "sensor", tint: .blue)
            MetricPill(title: "Bridgeable", value: "\(candidates.filter(\.bridgeable).count)", systemImage: "link", tint: .green)
            MetricPill(title: "Imported", value: "\(importedGroups.count)", systemImage: "tray.and.arrow.down", tint: .teal)
            MetricPill(title: "Exposed Tools", value: "\(importedGroups.reduce(0) { $0 + $1.exposedCount })", systemImage: "antenna.radiowaves.left.and.right", tint: .green)
            MetricPill(title: "Host-gated", value: "\(importedGroups.reduce(0) { $0 + $1.hostGatedCount })", systemImage: "hand.raised", tint: .orange)
        }
    }
}

private struct LocalMCPServerRow: Identifiable {
    let candidate: LocalMCPServerCandidate?
    let importedGroup: ImportedMCPServerGroup?

    var id: String {
        candidate?.id ?? importedGroup?.bridgeIdentity ?? UUID().uuidString
    }
}

private struct ImportedMCPServerGroup: Identifiable {
    let bridgeIdentity: String
    let serverName: String
    let tools: [ToolDefinition]
    let exposedCount: Int
    let hostGatedCount: Int

    var id: String { bridgeIdentity }

    @MainActor
    init(bridgeIdentity: String, tools: [ToolDefinition], appModel: AppModel) {
        self.bridgeIdentity = bridgeIdentity
        self.tools = tools.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        self.serverName = tools.first?.mcpBridgeServerName ?? bridgeIdentity
        self.exposedCount = tools.filter { appModel.isToolExposed($0) }.count
        self.hostGatedCount = tools.filter { $0.capability != .readOnly }.count
    }

    var isFullyExposed: Bool {
        exposedCount == tools.count && !tools.isEmpty
    }

    var exposureTitle: String {
        if exposedCount == tools.count {
            return "Enabled"
        }
        if exposedCount == 0 {
            return "Disabled"
        }
        return "Partially Enabled"
    }
}

private struct LocalMCPServerPanel: View {
    @Environment(AppModel.self) private var appModel
    let row: LocalMCPServerRow
    let isWorking: Bool
    let setError: (String?) -> Void

    var body: some View {
        let title = row.candidate?.displayName ?? row.importedGroup?.serverName ?? "Local MCP"
        let endpoint = row.candidate?.displayEndpoint ?? row.importedGroup?.bridgeIdentity ?? ""
        let tools = row.candidate?.probe?.tools ?? importedToolSummaries
        let importedGroup = row.importedGroup

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3)
                    .foregroundStyle(.teal)
                    .frame(width: 30, height: 30)
                    .background(.teal.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(.headline)
                        statusBadges
                    }

                    Text(endpoint)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if let description = row.candidate?.probe?.serverInfo.description, !description.isEmpty {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if let candidate = row.candidate, candidate.bridgeable {
                        Button(importedGroup == nil ? "Import" : "Refresh", systemImage: importedGroup == nil ? "tray.and.arrow.down" : "arrow.clockwise") {
                            appModel.importLocalMCPServer(candidateID: candidate.id)
                        }
                        .disabled(isWorking)
                    }

                    if let importedGroup {
                        Toggle(
                            "Expose",
	                            isOn: Binding(
	                                get: { importedGroup.exposedCount > 0 },
	                                set: { enabled in
	                                    setError(appModel.setLocalMCPBridgeServerEnabled(bridgeIdentity: importedGroup.bridgeIdentity, enabled: enabled))
	                                }
	                            )
	                        )
                        .toggleStyle(.switch)
                    }
                }
            }

            if isWorking {
                ProgressView("Importing tools...")
            }

            if let reason = row.candidate?.reason, row.candidate?.bridgeable == false {
                Label(reason, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let probeError = row.candidate?.probeError {
                Label("Probe failed: \(probeError)", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Tools Exposed by Server")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(tools.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if tools.isEmpty {
                    Text("No tool list is available. Scan again to probe this server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 10)], alignment: .leading, spacing: 10) {
                        ForEach(tools) { tool in
                            LocalMCPToolRow(tool: tool, importedTool: importedTool(named: tool.name))
                        }
                    }
                }
            }
        }
        .panelStyle()
    }

    @ViewBuilder
    private var statusBadges: some View {
        if let candidate = row.candidate {
            StatusBadge(title: sourceTitle(candidate.source), systemImage: "app.connected.to.app.below.fill", tint: .secondary)
            StatusBadge(
                title: candidate.bridgeable ? "Bridgeable" : "Scan-only",
                systemImage: candidate.bridgeable ? "link.circle.fill" : "eye",
                tint: candidate.bridgeable ? .green : .secondary
            )
        }

        if let group = row.importedGroup {
            StatusBadge(
                title: group.exposureTitle,
                systemImage: group.exposedCount > 0 ? "checkmark.circle.fill" : "pause.circle",
                tint: group.exposedCount > 0 ? .green : .secondary
            )
            StatusBadge(title: "\(group.exposedCount)/\(group.tools.count) exposed", systemImage: "antenna.radiowaves.left.and.right", tint: .blue)
        } else {
            StatusBadge(title: "Not Imported", systemImage: "tray", tint: .secondary)
        }
    }

    private var importedToolSummaries: [LocalMCPToolSummary] {
        row.importedGroup?.tools.compactMap { tool in
            guard let toolName = tool.mcpBridgeToolName else { return nil }
            return LocalMCPToolSummary(
                name: toolName,
                title: tool.mcpBridgeToolTitle,
                description: tool.mcpBridgeToolDescription,
                inputSchema: tool.mcpBridgeInputSchema,
                annotations: tool.mcpBridgeAnnotations
            )
        } ?? []
    }

    private func importedTool(named name: String) -> ToolDefinition? {
        row.importedGroup?.tools.first { $0.mcpBridgeToolName == name }
    }

    private func sourceTitle(_ source: String) -> String {
        switch source {
        case "claude_extension": "Claude Extension"
        case "claude_runtime": "Claude Runtime"
        case "claude_desktop": "Claude Desktop"
        case "claude_code": "Claude Code"
        case "codex": "Codex"
        case "grok": "Grok"
        case "opencode": "OpenCode"
        case "cursor": "Cursor"
        case "lmstudio": "LM Studio"
        case "xcode_coding_assistant": "Xcode"
        default: source
        }
    }
}

private struct LocalMCPToolRow: View {
    let tool: LocalMCPToolSummary
    let importedTool: ToolDefinition?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: capabilitySystemImage)
                .foregroundStyle(capabilityTint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(tool.displayTitle)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    StatusBadge(title: tool.capability.title, tint: capabilityTint)
                }

                Text(tool.name)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let importedTool {
                    Text(importedTool.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let description = tool.description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.25), lineWidth: 1)
        }
    }

    private var capabilityTint: Color {
        switch tool.capability {
        case .readOnly: .green
        case .write: .orange
        case .destructive: .red
        }
    }

    private var capabilitySystemImage: String {
        switch tool.capability {
        case .readOnly: "eye"
        case .write: "square.and.pencil"
        case .destructive: "exclamationmark.triangle"
        }
    }
}
