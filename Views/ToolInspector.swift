import SwiftUI
import UniformTypeIdentifiers

private func formattedToolTimeout(_ timeoutSeconds: Double) -> String {
    let seconds = max(0, Int(timeoutSeconds.rounded()))
    if seconds >= 3_600 {
        let hours = Double(seconds) / 3_600
        let value = hours.formatted(
            .number.precision(.fractionLength(hours == hours.rounded() ? 0 : 1))
        )
        return "\(value) \(hours == 1 ? "hour" : "hours")"
    }
    if seconds >= 60 {
        let minutes = Double(seconds) / 60
        let value = minutes.formatted(
            .number.precision(.fractionLength(minutes == minutes.rounded() ? 0 : 1))
        )
        return "\(value) \(minutes == 1 ? "minute" : "minutes")"
    }
    return "\(seconds) \(seconds == 1 ? "second" : "seconds")"
}

// MARK: - Draft helpers

extension ToolDefinitionDraft {
    init(tool: ToolDefinition) {
        self.init(
            mode: tool.isGenericCLIAdapter ? .cliAdapter : .commandTemplate,
            name: tool.name,
            summary: tool.summary,
            executablePath: tool.executablePath,
            argumentsText: tool.isGenericCLIAdapter ? "" : tool.argumentPattern.joined(separator: "\n"),
            capability: tool.capability,
            category: tool.category,
            timeoutSeconds: tool.timeoutSeconds,
            outputLimitKB: max(1, tool.outputByteLimit / 1024),
            requiresFullDiskAccess: tool.permissionRequirements.contains(.fullDiskAccess),
            permissionRequirements: tool.permissionRequirements.filter { !$0.isFullDiskAccess }
        )
        self.parameterOverrides = tool.parameters
        self.parameterOverrideArgumentPattern = tool.argumentPattern
        self.processInvocationOverride = tool.processInvocation
        self.processInvocationOverrideArgumentPattern = tool.argumentPattern
        self.approvalPolicy = tool.approvalPolicy
        self.annotationOverrides = tool.annotationOverrides
        self.uiActions = tool.uiActions
    }

    /// Per-field validation by dry-running the exact save-time validation, so the
    /// editor surfaces the same rules the model enforces (D8) — one error at a time,
    /// attributed to the field that caused it.
    var firstFieldError: (field: ToolDraftField, message: String)? {
        do {
            _ = try makeTool(id: "custom_validation_preview")
            return nil
        } catch let error as ToolValidationError {
            let message = error.errorDescription ?? "This tool can't be saved yet."
            switch error {
            case .emptyName:
                return (.name, message)
            case .executableNotAbsolute, .executableUnavailable, .blockedExecutable:
                return (.executable, message)
            case .invalidPlaceholder, .undefinedPlaceholder, .invalidArgument, .tooManyArguments, .nulByte:
                return (.arguments, message)
            case .invalidTimeout:
                return (.timeout, message)
            case .invalidOutputLimit:
                return (.output, message)
            default:
                return (.general, message)
            }
        } catch {
            return (.general, error.localizedDescription)
        }
    }
}

enum ToolDraftField {
    case name
    case executable
    case arguments
    case timeout
    case output
    case general
}

// MARK: - Tool test plumbing (MO-1)

enum ToolTestResult {
    case finished(ToolExecutionOutcome)
    case failed(String)
}

extension ToolExecutionOutcome {
    /// The inspector only renders the inline head when the runner moved the
    /// complete bounded stdout to disk, even when no bytes were lost.
    var inspectorStdoutIsPreview: Bool {
        truncatedStdout || stdoutSpool != nil
    }

    var inspectorHasCompleteSpoolBackedStdout: Bool {
        stdoutSpool != nil && !truncatedStdout
    }
}

extension AppModel {
    /// Runs a tool from the inspector's Test panel and returns the outcome for
    /// its exit/stdout/stderr/duration display. Built over all tools, so a Not
    /// Shared tool can be tested before it is shared.
    func runInspectorToolTest(toolID: String, parameters: [String: ToolArgumentValue]) async -> ToolTestResult {
        // R16 pre-execution revalidation: an identity change blocks the run
        // (the model has already flipped sharing off).
        if case .identityChanged = await revalidateToolProvenance(toolID: toolID) {
            let name = tool(id: toolID)?.name ?? "This tool"
            return .failed("\(name) changed publisher since you added it — review before sharing again.")
        }
        let executor = ConfiguredToolExecutor(tools: allTools, environment: ExecutableLocator.toolEnvironment)
        do {
            let outcome = try await executor.execute(toolID: toolID, parameters: parameters)
            if outcome.succeeded {
                appendLog(level: .info, "\(outcome.toolName) completed in \(outcome.duration.formattedDuration) with \(outcome.outputByteCount) bytes.")
            } else {
                appendLog(level: .warning, "\(outcome.toolName) exited \(outcome.exitCode) in \(outcome.duration.formattedDuration).")
            }
            return .finished(outcome)
        } catch {
            appendLog(level: .error, "Tool test failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }
}

// MARK: - ToolInspector

enum ToolInspectorTab: String, CaseIterable, Identifiable {
    case overview
    case definition
    case permissions
    case activity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .definition: "Definition"
        case .permissions: "Permissions"
        case .activity: "Activity"
        }
    }
}

struct ToolInspector: View {
    @Environment(AppModel.self) private var appModel

    let tool: ToolDefinition?
    @Binding var isCreatingNewTool: Bool
    let onCreated: (String) -> Void
    let onTest: (ToolDefinition) -> Void
    let onDuplicate: (ToolDefinition) -> Void
    let onRemove: (ToolDefinition) -> Void
    /// One-shot deep link (CLI-27 Edit → Definition, CLI-30 Review… → Overview).
    @Binding var requestedTab: ToolInspectorTab?

    @State private var selectedTab: ToolInspectorTab = .overview

    var body: some View {
        Group {
            if isCreatingNewTool {
                NewToolEditor(
                    onCancel: { isCreatingNewTool = false },
                    onCreated: { newToolID in
                        isCreatingNewTool = false
                        if let newToolID {
                            onCreated(newToolID)
                        }
                    }
                )
            } else if let tool {
                inspectorContent(for: tool)
            } else {
                EmptyState(
                    "No tool selected",
                    systemImage: "wrench.and.screwdriver",
                    message: "Select a tool to see what it runs, edit it, and control who can use it."
                )
            }
        }
        .onChange(of: requestedTab, initial: true) {
            guard let requested = requestedTab else { return }
            selectedTab = requested
            requestedTab = nil
        }
    }

    private func inspectorContent(for tool: ToolDefinition) -> some View {
        VStack(spacing: 0) {
            header(for: tool)
                .padding(Space.s4)

            Picker("Section", selection: $selectedTab) {
                ForEach(ToolInspectorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s3)

            tabContent(for: tool)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            footer(for: tool)
                .padding(Space.s3)
        }
    }

    private func header(for tool: ToolDefinition) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: tool.isMCPBridge ? "point.3.connected.trianglepath.dotted" : tool.category.iconSystemImage)
                .font(.callout)
                .foregroundStyle(tool.isMCPBridge ? .teal : tool.category.iconTint)
                .frame(width: 24, height: 24)
                .background((tool.isMCPBridge ? Color.teal : tool.category.iconTint).opacity(0.13), in: AppShape.mono)
                .accessibilityHidden(true)

            Text(tool.name)
                .font(TypeRamp.cardTitle)
                .lineLimit(1)

            Spacer()

            if !appModel.isToolExposed(tool) {
                StateChip("Not Shared", role: .off)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tool: ToolDefinition) -> some View {
        switch selectedTab {
        case .overview:
            ToolOverviewTab(tool: tool)
        case .definition:
            definitionTab(for: tool)
        case .permissions:
            ToolPermissionsTab(tool: tool)
        case .activity:
            ToolActivityTab(tool: tool)
        }
    }

    @ViewBuilder
    private func definitionTab(for tool: ToolDefinition) -> some View {
        if tool.isMCPBridge {
            BridgeDefinitionView(tool: tool)
        } else if tool.isUserDefined {
            ToolDefinitionEditor(tool: tool)
        } else {
            BuiltInDefinitionView(tool: tool)
        }
    }

    private func footer(for tool: ToolDefinition) -> some View {
        HStack(spacing: Space.s2) {
            Button("Test Tool", systemImage: "play.circle") { onTest(tool) }
                .help("Run this tool on this Mac and see the result")
            Button("Duplicate", systemImage: "plus.square.on.square") { onDuplicate(tool) }
                .disabled(tool.isMCPBridge)
                .help(tool.isMCPBridge ? "Imported tools can't be duplicated" : "Create an editable copy")

            Spacer()

            if appModel.isCatalogUpdateAvailable(for: tool) {
                Button(
                    "Update from Catalog",
                    systemImage: "arrow.trianglehead.2.clockwise.rotate.90"
                ) {
                    _ = appModel.updateUserToolFromCatalog(id: tool.id)
                }
            }

            if tool.isUserDefined {
                Button("Remove…", systemImage: "trash", role: .destructive) { onRemove(tool) }
            }
        }
        .labelStyle(.titleOnly)
    }
}

// MARK: - Overview tab

private struct ToolOverviewTab: View {
    @Environment(AppModel.self) private var appModel

    let tool: ToolDefinition

    @State private var trustError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                if let currentIdentity = appModel.provenanceIdentityChanges[tool.id],
                   let provenance = tool.provenance {
                    publisherChangeBlock(previous: provenance.signingIdentityAtAdd, current: currentIdentity)
                }

                if !tool.summary.isEmpty {
                    summaryBlock
                }

                chipRow

                commandBlock

                KeyValueGrid(rows: identityRows, onCopy: { row in
                    appModel.appendLog(level: .info, "Copied \(row.label) for \(tool.name).")
                })

                if let provenance = tool.provenance {
                    provenanceGroup(provenance)
                }

                if !tool.parameters.isEmpty {
                    parameterList
                }

                if !tool.permissionRequirements.isEmpty {
                    permissionList
                }

                longRunningToggle

                allowanceSummary
            }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// R11 — harvested summaries render verbatim and keep their source chip
    /// until the user edits the text (which clears the mark in the model).
    private var summaryBlock: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            if let origin = harvestedSummaryOrigin {
                StateChip("From \(origin)", tint: .secondary)
            }
            Text(verbatim: tool.summary)
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var harvestedSummaryOrigin: String? {
        guard let provenance = tool.provenance, provenance.summaryIsHarvested else { return nil }
        return provenance.summaryOrigin ?? provenance.sourceKind.displayName
    }

    private var chipRow: some View {
        HStack(spacing: Space.s1) {
            StateChip(capability: tool.capability)
            if tool.asksBeforeRunning {
                StateChip.asksFirst
            }
            StateChip(tool.modeDisplayTitle, tint: .blue)
        }
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(commandBlockTitle)
                .font(TypeRamp.cardTitle)
            if tool.isNativeExecution {
                Text(ToolDefinition.nativeExecutionSummary)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                    Text(tool.preview)
                        .machineText(TypeRamp.machineCaption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyButton(value: tool.preview, onCopy: {
                        appModel.appendLog(level: .info, "Copied command for \(tool.name).")
                    })
                }
                .padding(Space.s2)
                .background(.quaternary.opacity(0.4), in: AppShape.mono)
            }
        }
    }

    private var commandBlockTitle: String {
        if tool.isMCPBridge { return "Server" }
        if tool.isNativeExecution { return "Execution" }
        return "Command"
    }

    private var identityRows: [KeyValueRow] {
        var rows = [KeyValueRow("Tool ID", tool.id)]
        if tool.isMCPBridge {
            if let serverName = tool.mcpBridgeServerName {
                rows.append(KeyValueRow("Server", serverName))
            }
            if let toolName = tool.mcpBridgeToolName {
                rows.append(KeyValueRow("Upstream Tool", toolName))
            }
        } else if tool.provenance != nil {
            rows.append(KeyValueRow("Source", "Found on This Mac"))
        } else if let preset = DefaultToolPresetCatalog.preset(toolID: tool.id) {
            rows.append(KeyValueRow("Source", preset.publisher.title))
        } else {
            rows.append(KeyValueRow("Source", tool.isUserDefined ? "Added by You" : "Built-in"))
        }
        rows.append(
            KeyValueRow(
                "Limits",
                "\(formattedToolTimeout(tool.timeoutSeconds)) · \(tool.outputByteLimit / 1024) KB"
            )
        )
        rows.append(KeyValueRow("Result Card", appModel.resultCardStatus(for: tool)))
        return rows
    }

    // MARK: Publisher change (R16 — what Review… opens)

    /// First in Overview, so Review… lands on it. Trusting records the
    /// signature the file has now; sharing stays off until the owner turns
    /// it back on.
    private func publisherChangeBlock(previous: String, current: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Label(
                "Changed publisher since you added it — review before sharing again.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.orange)

            KeyValueGrid(rows: [
                KeyValueRow("When added", previous),
                KeyValueRow("Now", current)
            ])

            Text("Trust it only if you expected this, such as an update from the same developer. Always Allow stops applying, and the tool stays Not Shared until you share it.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Trust New Publisher") {
                Task { trustError = await appModel.trustNewPublisher(toolID: tool.id, reviewedSigner: current) }
            }

            if let trustError {
                Text(trustError)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: Provenance (CLI-25 / R15 — the permanent where-from record)

    private func provenanceGroup(_ provenance: ToolProvenance) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Provenance")
                .font(TypeRamp.cardTitle)

            HStack(spacing: Space.s2) {
                Image(systemName: provenance.sourceKind.badgeSystemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Added from a scan · \(provenance.sourceKind.displayName) · \(provenance.addedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }

            KeyValueGrid(rows: provenanceRows(provenance), onCopy: { row in
                appModel.appendLog(level: .info, "Copied \(row.label) for \(tool.name).")
            })

            if let updatedDate = appModel.provenanceContentUpdates[tool.id] {
                // R16 — content drift under the same identity is informational.
                Text("Binary updated \(updatedDate.formatted(date: .abbreviated, time: .omitted))")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }

            if provenance.wasQuarantinedAtAdd {
                Text("Was quarantined when added — downloaded from the web and not yet opened by macOS.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func provenanceRows(_ provenance: ToolProvenance) -> [KeyValueRow] {
        var rows: [KeyValueRow] = []
        if let packageName = provenance.packageName {
            rows.append(KeyValueRow("Package", packageName))
        }
        if let packageVersion = provenance.packageVersion {
            rows.append(KeyValueRow("Version at Add", packageVersion))
        }
        rows.append(KeyValueRow("Signing Identity", provenance.signingIdentityAtAdd))
        rows.append(KeyValueRow("File", provenance.resolvedPathAtAdd))
        if !provenance.contentSHA256AtAdd.isEmpty {
            rows.append(KeyValueRow("SHA-256", provenance.contentSHA256AtAdd))
        }
        return rows
    }

    private var parameterList: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Parameters")
                .font(TypeRamp.cardTitle)
            ForEach(tool.parameters) { parameter in
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text(parameter.title)
                        Text(parameter.name)
                            .font(TypeRamp.machineCaption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        if !parameter.required {
                            Text("optional")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    if let description = parameter.description {
                        Text(description)
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.secondary)
                    }
                    if let allowedValues = parameter.allowedValues {
                        Text("Allowed: \(allowedValues.joined(separator: ", "))")
                            .font(TypeRamp.machineCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var permissionList: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("macOS Permissions")
                .font(TypeRamp.cardTitle)
            ForEach(tool.permissionRequirements, id: \.self) { requirement in
                Label(requirement.title, systemImage: requirement.systemImage)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// SPEC D81 — the owner's say on which tools start in the background.
    private var longRunningToggle: some View {
        Toggle(isOn: Binding(
            get: { appModel.longRunningToolIDs.contains(tool.id) },
            set: { appModel.setLongRunning(tool, isOn: $0) }
        )) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Long-Running")
                    .font(TypeRamp.cardTitle)
                Text("Starts in the background in apps that support it. Other apps wait for the result.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var allowanceSummary: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Always Allow")
                .font(TypeRamp.cardTitle)
            Text(allowanceText)
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        }
    }

    private var allowanceText: String {
        guard tool.asksBeforeRunning else {
            return "Runs without asking for every app. Read-only tools never ask."
        }
        let names = appModel.connectedClients
            .filter { appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: $0.id) }
            .map(\.name)
        guard !names.isEmpty else {
            return "No app can run this without asking."
        }
        return "Always allowed for \(names.joined(separator: ", "))."
    }
}

// MARK: - Definition tab (D8 — edit in place)

private struct ToolDefinitionEditor: View {
    @Environment(AppModel.self) private var appModel

    let tool: ToolDefinition

    @State private var draft: ToolDefinitionDraft
    @State private var baseline: ToolDefinitionDraft
    @State private var saveError: String?

    init(tool: ToolDefinition) {
        self.tool = tool
        let initial = ToolDefinitionDraft(tool: tool)
        _draft = State(initialValue: initial)
        _baseline = State(initialValue: initial)
    }

    var body: some View {
        VStack(spacing: 0) {
            ToolDefinitionForm(draft: $draft)

            Divider()

            VStack(alignment: .leading, spacing: Space.s2) {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Revert") {
                        draft = baseline
                        saveError = nil
                    }
                    .disabled(!isDirty)

                    Spacer()

                    Button("Save") {
                        saveError = appModel.updateUserTool(id: tool.id, draft: draft)
                        if saveError == nil {
                            baseline = draft
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!isDirty)
                }
            }
            .padding(Space.s3)
        }
        .onChange(of: tool.id) {
            let fresh = ToolDefinitionDraft(tool: tool)
            draft = fresh
            baseline = fresh
            saveError = nil
        }
    }

    private var isDirty: Bool {
        draft != baseline
    }
}

private struct BuiltInDefinitionView: View {
    let tool: ToolDefinition

    var body: some View {
        VStack(spacing: 0) {
            Label("Built-in tools can't be edited.", systemImage: "lock")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)

            ToolDefinitionForm(
                draft: .constant(ToolDefinitionDraft(tool: tool)),
                isEditable: false,
                isNativeExecution: tool.isNativeExecution
            )
        }
    }
}

private struct BridgeDefinitionView: View {
    @Environment(AppModel.self) private var appModel

    let tool: ToolDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Label("Imported tools can't be edited. Refresh their MCP server instead.", systemImage: "lock")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)

            KeyValueGrid(rows: rows, onCopy: { row in
                appModel.appendLog(level: .info, "Copied \(row.label) for \(tool.name).")
            })

            Spacer()
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rows: [KeyValueRow] {
        var rows: [KeyValueRow] = []
        if let serverName = tool.mcpBridgeServerName {
            rows.append(KeyValueRow("Server", serverName))
        }
        if let bridge = tool.mcpBridge {
            rows.append(KeyValueRow("Address", bridge.serverURL))
            rows.append(KeyValueRow("Protocol", bridge.protocolVersion))
        }
        if let stdio = tool.mcpStdioBridge {
            rows.append(KeyValueRow("Runs", ([stdio.command] + stdio.args).joined(separator: " ")))
            rows.append(KeyValueRow("Protocol", stdio.protocolVersion))
        }
        if let toolName = tool.mcpBridgeToolName {
            rows.append(KeyValueRow("Upstream Tool", toolName))
        }
        return rows
    }
}

// MARK: - New tool editor (Add ▸ New Tool… inserts a draft here)

private struct NewToolEditor: View {
    @Environment(AppModel.self) private var appModel

    let onCancel: () -> Void
    let onCreated: (String?) -> Void

    @State private var draft = ToolDefinitionDraft()
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("New Tool")
                    .font(TypeRamp.cardTitle)
                Text("Define one executable and exactly how apps can call it.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s4)

            Divider()

            ToolDefinitionForm(draft: $draft)

            Divider()

            VStack(alignment: .leading, spacing: Space.s2) {
                if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Cancel", action: onCancel)
                    Spacer()
                    Button("Save") {
                        if let error = appModel.addUserTool(from: draft) {
                            saveError = error
                        } else {
                            onCreated(appModel.tools.last(where: \.isUserDefined)?.id)
                        }
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .padding(Space.s3)
        }
    }
}

// MARK: - The shared definition form (inspector Definition tab + Library Custom tab)

struct ToolDefinitionForm: View {
    @Binding var draft: ToolDefinitionDraft
    var isEditable = true
    /// Built-in native tools have no real executable or argument template.
    var isNativeExecution = false

    @State private var isExecutablePickerPresented = false

    var body: some View {
        Form {
            if isNativeExecution {
                nativeExecutionSection
            } else {
                modeSection
                commandSection
                argumentsSection
            }
            detailsSection
            limitsSection
            permissionsSection
        }
        .formStyle(.grouped)
        .disabled(!isEditable)
        .fileImporter(
            isPresented: $isExecutablePickerPresented,
            allowedContentTypes: [.unixExecutable, .executable]
        ) { result in
            if case .success(let url) = result {
                draft.executablePath = url.path(percentEncoded: false)
            }
        }
    }

    private var fieldError: (field: ToolDraftField, message: String)? {
        draft.firstFieldError
    }

    // MARK: Sections

    private var modeSection: some View {
        Section("Mode") {
            Picker("Mode", selection: $draft.mode) {
                ForEach(ToolAdapterMode.allCases) { mode in
                    Text(mode.displayTitle).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(modeConsequence)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeConsequence: String {
        switch draft.mode {
        case .cliAdapter:
            "Flexible Command lets the app choose exact arguments; advanced catalog fallbacks ask for every call by default"
        case .commandTemplate:
            "Fixed Command runs exactly the arguments you list — apps can only fill in the placeholders you define"
        }
    }

    private var nativeExecutionSection: some View {
        Section("Command") {
            TextField("Name", text: $draft.name)
            TextField("Summary", text: $draft.summary)
            LabeledContent("Execution") {
                Text(ToolDefinition.nativeExecutionSummary)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var commandSection: some View {
        Section("Command") {
            TextField("Name", text: $draft.name)
            errorText(for: .name)

            TextField("Summary", text: $draft.summary)

            HStack(spacing: Space.s2) {
                TextField("Executable", text: $draft.executablePath)
                    .font(TypeRamp.machineCallout)
                if isEditable {
                    Button("Browse…") { isExecutablePickerPresented = true }
                }
            }
            errorText(for: .executable)
        }
    }

    @ViewBuilder
    private var argumentsSection: some View {
        if draft.mode == .commandTemplate {
            Section("Arguments") {
                if draft.processInvocationOverride != nil,
                   draft.processInvocationOverrideArgumentPattern == draft.argumentPattern {
                    Label("Dedicated semantic workflow", systemImage: "sparkles")
                        .font(TypeRamp.rowDetail)
                    Text("The catalog maps the typed parameters below to an exact argument array. No shell is used.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextEditor(text: $draft.argumentsText)
                        .font(TypeRamp.machineCallout)
                        .frame(minHeight: 100)

                    Text("One argument per line. Placeholders like \(Text("{path}").font(TypeRamp.machineCaption)) become parameters the app fills in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let preview = parameterPreview {
                        Label(preview, systemImage: "sparkles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                errorText(for: .arguments)
            }
        } else {
            Section("Arguments") {
                LabeledContent("App provides") {
                    Text("args, stdin")
                        .font(TypeRamp.machineCallout)
                }
                Text("The app chooses the arguments. Every risky call still asks you first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The live parameter preview — inference made visible (SD-7).
    private var parameterPreview: String? {
        guard draft.mode == .commandTemplate else { return nil }
        guard let parameters = try? ToolDefinitionDraft.inferredParameters(from: draft.argumentPattern) else {
            return nil
        }
        if parameters.isEmpty {
            return "No parameters — apps run this exactly as written."
        }
        return "This creates parameters: \(parameters.map(\.title).joined(separator: ", "))"
    }

    private var detailsSection: some View {
        Section {
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
            Text("Write and Destructive tools ask first unless the app is Always Allowed. A few high-risk tools ask every time by default, and turning Always Allow on for one takes an extra confirmation.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var limitsSection: some View {
        Section("Limits") {
            LabeledContent("Timeout") {
                HStack(spacing: Space.s2) {
                    TextField("Timeout", value: $draft.timeoutSeconds, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 76)
                        .help("Enter seconds, from 1 second through 24 hours.")
                    Text("s")
                        .foregroundStyle(.secondary)
                    Stepper(
                        "Timeout",
                        value: $draft.timeoutSeconds,
                        in: 1...ToolArgumentResolver.maximumTimeoutSeconds,
                        step: 1
                    )
                        .labelsHidden()
                    Menu {
                        Button("5 seconds") { draft.timeoutSeconds = 5 }
                        Button("30 seconds") { draft.timeoutSeconds = 30 }
                        Button("1 minute") { draft.timeoutSeconds = 60 }
                        Button("5 minutes") { draft.timeoutSeconds = 300 }
                        Button("10 minutes") { draft.timeoutSeconds = 600 }
                        Button("1 hour") { draft.timeoutSeconds = 3_600 }
                        Button("6 hours") { draft.timeoutSeconds = 21_600 }
                        Button("24 hours") { draft.timeoutSeconds = 86_400 }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .fixedSize()
                    .help("Timeout presets")
                }
            }
            Text("Stops the tool after \(formattedToolTimeout(draft.timeoutSeconds)).")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
            errorText(for: .timeout)

            LabeledContent("Output Limit") {
                HStack(spacing: Space.s2) {
                    TextField("Output Limit", value: $draft.outputLimitKB, format: .number)
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Text("KB")
                        .foregroundStyle(.secondary)
                    Stepper(
                        "Output Limit",
                        value: $draft.outputLimitKB,
                        in: 1...(ToolArgumentResolver.maximumOutputByteLimit / 1024),
                        step: 64
                    )
                        .labelsHidden()
                    Menu {
                        Button("512 KB") { draft.outputLimitKB = 512 }
                        Button("2 MiB") { draft.outputLimitKB = 2048 }
                        Button("64 MiB") { draft.outputLimitKB = 64 * 1024 }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .fixedSize()
                    .help("Output limit presets")
                }
            }
            errorText(for: .output)

            errorText(for: .general)
        }
    }

    private var permissionsSection: some View {
        Section {
            ForEach(ToolPermissionRequirement.allCases, id: \.self) { requirement in
                Toggle(isOn: permissionBinding(for: requirement)) {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Label(requirement.title, systemImage: requirement.systemImage)
                        Text(Self.permissionFootnote(for: requirement))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("macOS Permissions")
        } footer: {
            Text("MacRemote checks these before sharing the tool — they power the Readiness checks on Connection.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func errorText(for field: ToolDraftField) -> some View {
        if isEditable, let fieldError, fieldError.field == field {
            Text(fieldError.message)
                .font(.caption)
                .foregroundStyle(.red)
        }
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

    private static func permissionFootnote(for requirement: ToolPermissionRequirement) -> String {
        switch requirement {
        case .fullDiskAccess: "Reads protected files and app data — you grant it in System Settings."
        case .reminders: "macOS asks the first time this tool reads your reminders."
        case .calendars: "macOS asks the first time this tool reads your calendars."
        case .contacts: "macOS asks the first time this tool reads your contacts."
        case .photos: "macOS asks the first time this tool touches your photo library."
        case .camera: "macOS asks before this tool can use the camera."
        case .microphone: "macOS asks before this tool can use the microphone."
        case .speechRecognition: "macOS asks before this tool can transcribe speech."
        case .location: "macOS asks before this tool can read your location."
        case .screenRecording: "You grant screen capture in System Settings."
        case .accessibility: "You grant control of this Mac in System Settings."
        case .automation: "macOS asks before this tool can control other apps."
        case .localNetwork: "macOS asks before this tool can reach devices on your network."
        }
    }
}

// MARK: - Permissions tab (MO-3 — the clientToolPermissionSnapshot pivot)

private struct ToolPermissionsTab: View {
    @Environment(AppModel.self) private var appModel

    let tool: ToolDefinition

    @State private var filterText = ""
    /// The app awaiting the D49 consent step, plus the switch position held for
    /// it so the control does not snap back while the dialog is up.
    @State private var pendingGrantRow: AppRow?

    private struct AppRow: Identifiable, Equatable {
        let id: String
        let name: String
        let trustID: String?
        let isConnected: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Who can run this without asking?")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)

            if !tool.asksBeforeRunning {
                // D79: a read-only tool never asks, so there is no switch to offer.
                Text("Every app. Read-only tools never ask, so there is nothing to allow.")
                    .font(TypeRamp.rowDetail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("Filter apps", text: $filterText)
                    .textFieldStyle(.roundedBorder)

                if filteredRows.isEmpty {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(filterText.isEmpty ? "No app can run this tool without asking." : "No apps match “\(filterText)”.")
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.secondary)
                        if filterText.isEmpty {
                            Text("Approve a request with Always Allow to change that.")
                                .font(TypeRamp.truthNote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.s3) {
                            ForEach(filteredRows) { row in
                                appRow(row)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if !staleKeys.isEmpty {
                HStack(spacing: Space.s2) {
                    Text(staleKeys.count == 1
                        ? "1 rule references an app that's no longer connected."
                        : "\(staleKeys.count) rules reference apps that are no longer connected.")
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                    Button("Clean Up") { cleanUpStaleRules() }
                        .controlSize(.small)
                }
            }
        }
        .padding(Space.s4)
        .confirmationDialog(
            "Always allow \u{201C}\(tool.name)\u{201D} for \(pendingGrantRow?.name ?? "this app")?",
            isPresented: Binding(
                get: { pendingGrantRow != nil },
                set: { if !$0 { pendingGrantRow = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Always Allow") {
                if let row = pendingGrantRow {
                    setAllowed(true, for: row)
                }
                pendingGrantRow = nil
            }
            Button("Cancel", role: .cancel) { pendingGrantRow = nil }
        } message: {
            Text(pendingGrantRow.flatMap { consequence(for: $0) } ?? "")
        }
    }

    private func appRow(_ row: AppRow) -> some View {
        Toggle(isOn: allowBinding(for: row)) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(row.name)
                MonoValue(row.id, font: TypeRamp.machineCaption, onCopy: {
                    appModel.appendLog(level: .info, "Copied app ID \(row.id).")
                })
                .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var allRows: [AppRow] {
        var rows = appModel.connectedClients.map {
            AppRow(id: $0.id, name: $0.name, trustID: $0.trustID, isConnected: true)
        }
        rows += staleKeys.map {
            AppRow(id: $0, name: "App no longer connected", trustID: $0, isConnected: false)
        }
        return rows
    }

    private var filteredRows: [AppRow] {
        guard !filterText.isEmpty else { return allRows }
        return allRows.filter {
            $0.name.localizedCaseInsensitiveContains(filterText) ||
                $0.id.localizedCaseInsensitiveContains(filterText)
        }
    }

    /// Snapshot keys (client or trust IDs) that still allow this tool but no longer
    /// match any connected app.
    private var staleKeys: [String] {
        let known = Set(appModel.connectedClients.map(\.id))
            .union(appModel.connectedClients.map(\.trustID))
        return appModel.clientToolPermissionSnapshot
            .filter { key, toolIDs in !known.contains(key) && toolIDs.contains(tool.id) }
            .keys
            .sorted()
    }

    private func allowBinding(for row: AppRow) -> Binding<Bool> {
        Binding(
            get: {
                if pendingGrantRow == row { return true }
                guard let trustID = row.trustID else {
                    return appModel.isToolAlwaysAllowed(toolID: tool.id, clientID: row.id)
                }
                return appModel.clientToolPermissionSnapshot[trustID]?.contains(tool.id) == true
            },
            set: { isAllowed in
                guard isAllowed, consequence(for: row) != nil else {
                    setAllowed(isAllowed, for: row)
                    return
                }
                pendingGrantRow = row
            }
        )
    }

    /// `nil` for ordinary tools — those grant straight from the switch.
    private func consequence(for row: AppRow) -> String? {
        AlwaysAllowConsequence.text(for: tool, clientName: row.name)
    }

    private func setAllowed(_ isAllowed: Bool, for row: AppRow) {
        appModel.setToolAlwaysAllowed(isAllowed, toolID: tool.id, clientID: row.id, clientTrustID: row.trustID)
    }

    private func cleanUpStaleRules() {
        for key in staleKeys {
            appModel.setToolAlwaysAllowed(false, toolID: tool.id, clientID: key, clientTrustID: key)
        }
    }
}

// MARK: - Activity tab (this tool's session calls)

private struct ToolActivityTab: View {
    @Environment(AppModel.self) private var appModel

    let tool: ToolDefinition

    private enum Entry: Identifiable {
        case request(ToolCallApprovalRequest)
        case log(AppLogEntry)

        var id: UUID {
            switch self {
            case .request(let request): request.id
            case .log(let entry): entry.id
            }
        }

        var date: Date {
            switch self {
            case .request(let request): request.createdAt
            case .log(let entry): entry.date
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if entries.isEmpty {
                Text("No calls yet this session.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Text("This session — cleared when MacRemote quits.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
        }
        .padding(Space.s4)
    }

    private var entries: [Entry] {
        let requests = appModel.toolCallApprovals
            .filter { $0.toolID == tool.id }
            .map(Entry.request)
        let logLines = appModel.logs
            .filter { $0.message.localizedCaseInsensitiveContains(tool.name) }
            .map(Entry.log)
        return Array((requests + logLines).sorted { $0.date > $1.date }.prefix(50))
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        switch entry {
        case .request(let request):
            VStack(alignment: .leading, spacing: Space.s1) {
                HStack(spacing: Space.s2) {
                    Text(request.createdAt, format: .dateTime.hour().minute().second())
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                    StateChip(request.stateTitle, role: stateRole(for: request.state))
                    Text(request.clientName ?? "App")
                        .font(TypeRamp.rowDetail)
                        .lineLimit(1)
                }
                if !request.arguments.isEmpty {
                    Text(request.argumentsSummary)
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        case .log(let logEntry):
            ActivityLogRow(
                time: logEntry.date,
                level: rowLevel(for: logEntry.level),
                message: logEntry.message
            )
        }
    }

    private func stateRole(for state: ToolCallApprovalRequest.State) -> StatusRole {
        switch state {
        case .pending: .attention
        case .approved: .ready
        case .denied: .error
        case .expired: .off
        }
    }

    private func rowLevel(for level: AppLogEntry.Level) -> ActivityLogRow.Level {
        switch level {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}

// MARK: - Test Tool sheet (MO-1)

struct ToolTestSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    let tool: ToolDefinition

    @State private var values: [String: String] = [:]
    @State private var isRunning = false
    @State private var outcome: ToolExecutionOutcome?
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Test \(tool.name)")
                    .font(TypeRamp.cardTitle)
                Text("Runs on this Mac right now — no app is involved.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.s5)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    parameterFields
                    resultView
                }
                .padding(Space.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Run Test") { run() }
                    .buttonStyle(.glassProminent)
                    .disabled(isRunning || !canRun)
            }
            .padding(Space.s4)
        }
        .frame(width: 560, height: 560)
        .task { prefillDefaults() }
    }

    // MARK: Parameters

    @ViewBuilder
    private var parameterFields: some View {
        if tool.parameters.isEmpty {
            Text("This tool takes no parameters.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Space.s3) {
                ForEach(tool.parameters) { parameter in
                    parameterField(for: parameter)
                }
            }
        }
    }

    @ViewBuilder
    private func parameterField(for parameter: ToolParameter) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s1) {
                Text(parameter.title)
                    .font(TypeRamp.rowDetail)
                if !parameter.required {
                    Text("optional")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            if parameter.kind == .boolean {
                Toggle(
                    parameter.title,
                    isOn: Binding(
                        get: { values[parameter.name] == "true" },
                        set: { values[parameter.name] = $0 ? "true" : "false" }
                    )
                )
                .labelsHidden()
            } else if let allowedValues = parameter.allowedValues {
                Picker(parameter.title, selection: valueBinding(for: parameter)) {
                    if !parameter.required {
                        Text("Not set").tag("")
                    }
                    ForEach(allowedValues, id: \.self) { value in
                        Text(value.replacingOccurrences(of: "_", with: " ").capitalized)
                            .tag(value)
                    }
                }
                .labelsHidden()
            } else if parameter.kind == .stringArray ||
                        parameter.kind == .json ||
                        parameter.name == "stdin" {
                TextEditor(text: valueBinding(for: parameter))
                    .font(TypeRamp.machineCallout)
                    .frame(minHeight: 64)
                if parameter.kind == .stringArray {
                    Text("One item per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if parameter.kind == .json {
                    Text("Enter a JSON object or array.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                TextField(parameter.title, text: valueBinding(for: parameter))
                    .textFieldStyle(.roundedBorder)
                    .font(
                        parameter.kind == .integer || parameter.kind == .number
                            ? TypeRamp.machineCallout
                            : .body
                    )
                    .labelsHidden()
            }
            if let description = parameter.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func valueBinding(for parameter: ToolParameter) -> Binding<String> {
        Binding(
            get: { values[parameter.name] ?? "" },
            set: { values[parameter.name] = $0 }
        )
    }

    private func prefillDefaults() {
        for parameter in tool.parameters {
            if values[parameter.name] == nil, let defaultValue = parameter.defaultValue {
                values[parameter.name] = defaultValue
            }
        }
    }

    private var canRun: Bool {
        tool.parameters.allSatisfy { parameter in
            guard parameter.required, parameter.defaultValue == nil else { return true }
            let raw = values[parameter.name] ?? ""
            return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: Run

    private func run() {
        isRunning = true
        outcome = nil
        failureMessage = nil
        let parameters = builtParameters()
        Task {
            let result = await appModel.runInspectorToolTest(toolID: tool.id, parameters: parameters)
            switch result {
            case .finished(let value):
                outcome = value
            case .failed(let message):
                failureMessage = message
            }
            isRunning = false
        }
    }

    private func builtParameters() -> [String: ToolArgumentValue] {
        var parameters: [String: ToolArgumentValue] = [:]
        for parameter in tool.parameters {
            let raw = values[parameter.name] ?? (parameter.kind == .boolean ? "false" : "")
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || parameter.kind == .boolean else { continue }
            switch parameter.kind {
            case .stringArray:
                let items = raw
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                parameters[parameter.name] = .stringArray(items)
            case .string, .integer, .number:
                parameters[parameter.name] = .string(parameter.name == "stdin" ? raw : trimmed)
            case .boolean:
                parameters[parameter.name] = .json(.bool(trimmed == "true"))
            case .json:
                guard let data = trimmed.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      let value = JSONValue.fromJSONObject(object) else {
                    continue
                }
                parameters[parameter.name] = .json(value)
            }
        }
        return parameters
    }

    // MARK: Result

    @ViewBuilder
    private var resultView: some View {
        if isRunning {
            HStack(spacing: Space.s2) {
                ProgressView()
                    .controlSize(.small)
                Text("Running…")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
        }

        if let failureMessage {
            Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }

        if let outcome {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(spacing: Space.s2) {
                    StateChip(
                        outcome.succeeded ? "Passed" : (outcome.timedOut ? "Timed Out" : "Failed"),
                        systemImage: outcome.succeeded ? "checkmark.circle.fill" : "xmark.octagon.fill",
                        role: outcome.succeeded ? .ready : .error
                    )
                    Text("exit \(outcome.exitCode)")
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text(outcome.duration.formattedDuration)
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                }

                if outcome.stdout.isEmpty && outcome.stderr.isEmpty {
                    Text("No output.")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                }

                if !outcome.stdout.isEmpty {
                    outputBlock(
                        title: "Output",
                        content: outcome.stdout,
                        truncated: outcome.inspectorStdoutIsPreview,
                        completeOutputPreserved: outcome.inspectorHasCompleteSpoolBackedStdout
                    )
                }

                if !outcome.stderr.isEmpty {
                    outputBlock(
                        title: "Errors",
                        content: outcome.stderr,
                        truncated: outcome.truncatedStderr
                    )
                }
            }
        }
    }

    private func outputBlock(
        title: String,
        content: String,
        truncated: Bool,
        completeOutputPreserved: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack {
                Text(title)
                    .font(TypeRamp.cardTitle)
                Spacer()
                CopyButton(value: content, onCopy: {
                    appModel.appendLog(level: .info, "Copied test \(title.lowercased()) for \(tool.name).")
                })
            }
            ScrollView {
                Text(content)
                    .machineText(TypeRamp.machineCaption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 140)
            .padding(Space.s2)
            .background(.quaternary.opacity(0.4), in: AppShape.mono)

            if completeOutputPreserved {
                Text("Showing a preview of the full output.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            } else if truncated {
                Text("Stopped at the output limit.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
