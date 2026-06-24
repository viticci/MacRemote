import SwiftUI

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingAddTool = false
    @State private var draft = ToolDefinitionDraft()
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    HeaderView(
                        title: "Tools",
                        subtitle: "Only explicit executable paths and validated argv templates can be exposed."
                    )

                    Spacer()

                    Button("Add Tool", systemImage: "plus") {
                        draft = ToolDefinitionDraft()
                        errorMessage = nil
                        isShowingAddTool = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appModel.serverStatus.isRunning)
                }

                ToolSurfaceControlPanel(errorMessage: $errorMessage)

                if appModel.serverStatus.isRunning {
                    Text("Stop the local server before changing the exposed tool surface.")
                        .foregroundStyle(.secondary)
                }

                ForEach(appModel.tools) { tool in
                    ToolPanel(tool: tool) {
                        errorMessage = appModel.deleteUserTool(id: tool.id)
                    }
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
                }
            )
        }
    }
}

private struct ToolSurfaceControlPanel: View {
    @Environment(AppModel.self) private var appModel
    @Binding var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Exposure")
                        .font(.headline)
                    Text(exposureDetail)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle(
                    "Full RemCTL Profile",
                    isOn: Binding(
                        get: { appModel.isRemCTLProfileEnabled },
                        set: { enabled in
                            errorMessage = appModel.setRemCTLProfileEnabled(enabled)
                        }
                    )
                )
                .toggleStyle(.switch)
                .disabled(appModel.serverStatus.isRunning)
            }

            if !appModel.isRemCTLProfileEnabled && appModel.toolExposureSummary.total == 0 {
                Text("Add a custom CLI tool before starting the MCP server.")
                    .foregroundStyle(.orange)
            }
        }
        .panelStyle()
    }

    private var exposureDetail: String {
        let summary = appModel.toolExposureSummary
        return "\(summary.total) tools exposed: \(summary.capabilityDescription), \(summary.custom) custom, \(summary.genericAdapters) generic adapters."
    }
}

private struct ToolPanel: View {
    @Environment(AppModel.self) private var appModel
    let tool: ToolDefinition
    let onDelete: () -> Void

    var body: some View {
        let isExposed = appModel.isToolExposed(tool)

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name)
                        .font(.headline)
                    Text(tool.summary)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(isExposed ? "Exposed" : "Disabled")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isExposed ? .green.opacity(0.16) : .secondary.opacity(0.12), in: Capsule())

                    Text(tool.category.title)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: Capsule())

                    Text(tool.isGenericCLIAdapter ? "CLI Adapter" : "Template")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.12), in: Capsule())

                    Text(tool.origin == .builtIn ? "Built-in" : "Custom")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.12), in: Capsule())

                    Text(tool.capability.title)
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(tool.capability == .readOnly ? .green.opacity(0.16) : .orange.opacity(0.18), in: Capsule())

                    ForEach(tool.permissionRequirements, id: \.self) { requirement in
                        Text(requirement.title)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.red.opacity(0.14), in: Capsule())
                    }

                    if tool.isUserDefined {
                        Button("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                            .disabled(appModel.serverStatus.isRunning)
                    }
                }
            }

            LabeledContent("Executable") {
                Text(tool.executablePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("Arguments") {
                Text(tool.argumentPattern.joined(separator: " "))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
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
        }
        .panelStyle()
        .opacity(isExposed ? 1 : 0.62)
    }
}

private struct ToolEditorSheet: View {
    @Binding var draft: ToolDefinitionDraft
    @Binding var errorMessage: String?
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var selectedPresetCategory: ToolCategory = .filesystem

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Add Tool")
                .font(.title2.weight(.semibold))

            Form {
                Section("Presets") {
                    Picker("Category", selection: $selectedPresetCategory) {
                        ForEach(DefaultToolPresetCatalog.categories) { category in
                            Text(category.title).tag(category)
                        }
                    }

                    ForEach(DefaultToolPresetCatalog.presets(in: selectedPresetCategory)) { preset in
                        Button {
                            draft = preset.draft
                            errorMessage = nil
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.name)
                                Text(preset.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
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
                    Toggle("Requires Full Disk Access", isOn: $draft.requiresFullDiskAccess)
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
}
