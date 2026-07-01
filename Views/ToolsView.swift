import SwiftUI

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingAddTool = false
    @State private var draft = ToolDefinitionDraft()
    @State private var errorMessage: String?
    @State private var selectedTab: ToolsTab = .clis

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    HeaderView(
                        title: "Tools",
                        subtitle: "Manage the exact commands MacRemote exposes over MCP."
                    )

                    Spacer()

                    Picker("Tool Type", selection: $selectedTab) {
                        ForEach(ToolsTab.allCases) { tab in
                            Label(tab.title, systemImage: tab.systemImage).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)

                    if selectedTab == .clis {
                        Button("Add Tool", systemImage: "plus") {
                            draft = ToolDefinitionDraft()
                            errorMessage = nil
                            isShowingAddTool = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                ToolSurfaceControlPanel(errorMessage: $errorMessage)

                switch selectedTab {
                case .clis:
                    CLIToolsSection(
                        tools: orderedCLITools,
                        addAction: {
                            draft = ToolDefinitionDraft()
                            errorMessage = nil
                            isShowingAddTool = true
                        },
                        deleteAction: { tool in
                            errorMessage = appModel.deleteUserTool(id: tool.id)
                        }
                    )
                case .localMCPs:
                    LocalMCPToolsView(errorMessage: $errorMessage)
                }
            }
            .padding(24)
        }
        .navigationTitle("Tools")
        .sheet(isPresented: $isShowingAddTool) {
            ToolEditorSheet(
                draft: $draft,
                errorMessage: $errorMessage,
                onCancel: {
                    isShowingAddTool = false
                },
                onSave: {
                    if let error = appModel.addUserTool(from: draft) {
                        errorMessage = error
                    } else {
                        isShowingAddTool = false
                    }
                },
                onAddPresetSet: { presetSet in
                    if let error = appModel.addUserTools(from: presetSet) {
                        errorMessage = error
                    } else {
                        isShowingAddTool = false
                    }
                }
            )
        }
    }

    private var orderedCLITools: [ToolDefinition] {
        appModel.tools.filter { !$0.isMCPBridge }.sorted { lhs, rhs in
            if lhs.category.title != rhs.category.title {
                return lhs.category.title < rhs.category.title
            }
            return lhs.name < rhs.name
        }
    }
}

private enum ToolsTab: String, CaseIterable, Identifiable {
    case clis
    case localMCPs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clis: "CLIs"
        case .localMCPs: "Local MCPs"
        }
    }

    var systemImage: String {
        switch self {
        case .clis: "terminal"
        case .localMCPs: "point.3.connected.trianglepath.dotted"
        }
    }
}

private struct CLIToolsSection: View {
    let tools: [ToolDefinition]
    let addAction: () -> Void
    let deleteAction: (ToolDefinition) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                "CLIs",
                subtitle: "Expose exact executables through CLI adapters or narrow command templates."
            )

            if tools.isEmpty {
                EmptyToolSurfaceView(addAction: addAction)
            } else {
                ForEach(tools) { tool in
                    ToolPanel(tool: tool) {
                        deleteAction(tool)
                    }
                }
            }
        }
    }
}

private struct EmptyToolSurfaceView: View {
    let addAction: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Tools Installed", systemImage: "wrench.and.screwdriver")
        } description: {
            Text("Add a detected CLI or command preset to expose it over MCP.")
        } actions: {
            Button("Add Tool", systemImage: "plus", action: addAction)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .panelStyle()
    }
}

private struct ToolSurfaceControlPanel: View {
    @Environment(AppModel.self) private var appModel
    @Binding var errorMessage: String?

    var body: some View {
        let exposedSummary = appModel.toolExposureSummary

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                "Tool Surface",
                subtitle: "Exposed tools are visible to MCP clients. Running clients can refresh tools/list after changes."
            )

            HStack(spacing: 10) {
                MetricPill(title: "Available", value: "\(appModel.tools.count)", systemImage: "wrench.and.screwdriver", tint: .blue)
                MetricPill(title: "Exposed", value: "\(exposedSummary.total)", systemImage: "antenna.radiowaves.left.and.right", tint: .green)
                MetricPill(title: "Read-only", value: "\(exposedSummary.readOnly)", systemImage: "eye", tint: .green)
                MetricPill(title: "Host-gated", value: "\(exposedSummary.gatedToolCount)", systemImage: "hand.raised", tint: .orange)
                MetricPill(title: "FDA", value: "\(exposedFullDiskAccessCount)", systemImage: "lock.shield", tint: .red)
            }

            if exposedSummary.total == 0 {
                Label("Expose at least one tool before starting the MCP server.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .panelStyle()
    }

    private var exposedFullDiskAccessCount: Int {
        appModel.tools.filter { tool in
            appModel.isToolExposed(tool) &&
                tool.permissionRequirements.contains(.fullDiskAccess)
        }.count
    }
}

private struct ToolPanel: View {
    @Environment(AppModel.self) private var appModel
    let tool: ToolDefinition
    let onDelete: () -> Void
    @State private var errorMessage: String?

    var body: some View {
        let isExposed = appModel.isToolExposed(tool)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tool.category.systemImage)
                    .font(.title3)
                    .foregroundStyle(categoryTint)
                    .frame(width: 28, height: 28)
                    .background(categoryTint.opacity(0.13), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(tool.name)
                            .font(.headline)

                        StatusBadge(
                            title: isExposed ? "Exposed" : "Disabled",
                            systemImage: isExposed ? "checkmark.circle.fill" : "pause.circle",
                            tint: isExposed ? .green : .secondary
                        )
                    }

                    Text(tool.summary)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ToolBadgeStrip(tool: tool)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    Toggle(
                        "Expose",
                        isOn: Binding(
                            get: { appModel.isToolExposed(tool) },
                            set: { enabled in
                                errorMessage = appModel.setToolEnabled(id: tool.id, enabled: enabled)
                            }
                        )
                    )
                    .toggleStyle(.switch)

                    if tool.isUserDefined {
                        Button("Remove", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                }
            }

            if let bridge = tool.mcpBridge {
                MCPBridgeLineView(bridge: bridge)
            } else {
                CommandLineView(executable: tool.executablePath, arguments: tool.argumentPattern)
            }

            if !tool.parameters.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Parameters")
                        .font(.subheadline.weight(.semibold))
                    ForEach(tool.parameters) { parameter in
                        Text("\(parameter.title) (`\(parameter.name)`)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
        .panelStyle()
        .opacity(isExposed ? 1 : 0.62)
    }

    private var categoryTint: Color {
        switch tool.category {
        case .reminders: .blue
        case .habits: .mint
        case .podcasts: .purple
        case .filesystem: .orange
        case .utilities: .green
        case .imageProcessing: .pink
        case .text: .indigo
        case .developer: .teal
        }
    }
}

private struct ToolBadgeStrip: View {
    let tool: ToolDefinition

    var body: some View {
        HStack(spacing: 7) {
            StatusBadge(title: tool.category.title, systemImage: tool.category.systemImage, tint: .secondary)
            StatusBadge(title: toolModeTitle, systemImage: tool.isMCPBridge ? "point.3.connected.trianglepath.dotted" : "slider.horizontal.3", tint: .blue)
            StatusBadge(title: tool.capability.title, systemImage: tool.capability.systemImage, tint: capabilityTint)

            ForEach(tool.permissionRequirements, id: \.self) { requirement in
                StatusBadge(title: requirement.title, systemImage: requirement.systemImage, tint: .red)
            }
        }
    }

    private var capabilityTint: Color {
        switch tool.capability {
        case .readOnly: .green
        case .write: .orange
        case .destructive: .red
        }
    }

    private var toolModeTitle: String {
        if tool.isMCPBridge {
            return "MCP Bridge"
        }
        return tool.isGenericCLIAdapter ? "CLI Adapter" : "Template"
    }
}

private struct ToolEditorSheet: View {
    @Binding var draft: ToolDefinitionDraft
    @Binding var errorMessage: String?
    let onCancel: () -> Void
    let onSave: () -> Void
    let onAddPresetSet: (DefaultToolPresetSet) -> Void
    @State private var selectedPresetCategory: ToolCategory = DefaultToolPresetCatalog.preferredCategory

    var body: some View {
        let featuredPresets = DefaultToolPresetCatalog.featuredPresets
        let presetSets = DefaultToolPresetCatalog.presetSets

        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Add Tool")
                    .font(.title2.weight(.semibold))
                Text("Start from a detected CLI or define one executable plus exact argv behavior.")
                    .foregroundStyle(.secondary)
            }

            Form {
                if !presetSets.isEmpty {
                    Section("Tool Sets") {
                        ForEach(presetSets) { presetSet in
                            ToolPresetSetButton(presetSet: presetSet) {
                                errorMessage = nil
                                onAddPresetSet(presetSet)
                            }
                        }
                    }
                }

                if !featuredPresets.isEmpty {
                    Section("Detected CLIs") {
                        ForEach(featuredPresets) { preset in
                            ToolPresetButton(preset: preset) {
                                draft = preset.draft
                                errorMessage = nil
                                selectedPresetCategory = preset.category
                            }
                        }
                    }
                }

                Section("Command Presets") {
                    Picker("Category", selection: $selectedPresetCategory) {
                        ForEach(DefaultToolPresetCatalog.categories) { category in
                            Text(category.title).tag(category)
                        }
                    }

                    ForEach(categoryPresets(excluding: featuredPresets)) { preset in
                        ToolPresetButton(preset: preset) {
                            draft = preset.draft
                            errorMessage = nil
                        }
                    }
                }

                Section("Mode") {
                    Picker("Mode", selection: $draft.mode) {
                        ForEach(ToolAdapterMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Command") {
                    TextField("Name", text: $draft.name)
                    TextField("Summary", text: $draft.summary)
                    TextField("Executable Path", text: $draft.executablePath)
                        .font(.system(.body, design: .monospaced))
                }

                if draft.mode == .commandTemplate {
                    Section("Arguments") {
                        TextEditor(text: $draft.argumentsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                        Text("One argv item per line. Use `{name}` placeholders for MCP parameters.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("Adapter") {
                        LabeledContent("MCP inputs") {
                            Text("args, stdin")
                                .font(.system(.body, design: .monospaced))
                        }
                        Text("Use this when you want the remote client to choose subcommands and arguments, with host approval for write-capable tools.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Limits") {
                    Picker("Category", selection: $draft.category) {
                        ForEach(ToolCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    Picker("Capability", selection: $draft.capability) {
                        ForEach(ToolCapability.allCases, id: \.self) { capability in
                            Text(capability.title).tag(capability)
                        }
                    }
                    Stepper("Timeout: \(Int(draft.timeoutSeconds))s", value: $draft.timeoutSeconds, in: 1...60, step: 1)
                    Stepper("Output: \(draft.outputLimitKB) KB", value: $draft.outputLimitKB, in: 1...5120, step: 64)
                }

                Section("macOS Permissions") {
                    ForEach(ToolPermissionRequirement.allCases, id: \.self) { requirement in
                        Toggle(isOn: permissionBinding(for: requirement)) {
                            Label(requirement.title, systemImage: requirement.systemImage)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 600, height: 720)
    }

    private func categoryPresets(excluding featuredPresets: [DefaultToolPreset]) -> [DefaultToolPreset] {
        let featuredIDs = Set(featuredPresets.map(\.id))
        return DefaultToolPresetCatalog
            .presets(in: selectedPresetCategory)
            .filter { !featuredIDs.contains($0.id) }
    }

    private func permissionBinding(for requirement: ToolPermissionRequirement) -> Binding<Bool> {
        Binding {
            if requirement.isFullDiskAccess {
                return draft.requiresFullDiskAccess || draft.permissionRequirements.contains(.fullDiskAccess)
            }
            return draft.permissionRequirements.contains(requirement)
        } set: { isEnabled in
            if requirement.isFullDiskAccess {
                draft.requiresFullDiskAccess = isEnabled
            }

            if isEnabled {
                if !draft.permissionRequirements.contains(requirement) {
                    draft.permissionRequirements.append(requirement)
                }
            } else {
                draft.permissionRequirements.removeAll { $0 == requirement }
            }
        }
    }
}

private struct ToolPresetButton: View {
    let preset: DefaultToolPreset
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: preset.category.systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.name)
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(preset.mode.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ToolPresetSetButton: View {
    let presetSet: DefaultToolPresetSet
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3")
                    .foregroundStyle(.blue)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 3) {
                    Text(presetSet.name)
                    Text(presetSet.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(presetSet.presets.count) tools")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private extension ToolCategory {
    var systemImage: String {
        switch self {
        case .reminders: "checklist"
        case .habits: "figure.mind.and.body"
        case .podcasts: "podcasts"
        case .filesystem: "folder"
        case .utilities: "wrench.and.screwdriver"
        case .imageProcessing: "photo"
        case .text: "text.alignleft"
        case .developer: "chevron.left.forwardslash.chevron.right"
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
