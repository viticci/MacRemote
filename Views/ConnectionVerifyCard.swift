import AppKit
import SwiftUI

// MARK: - Verify card (SPEC §4.4 — Quick Test / Full Test / Test a Tool… / More ⌄)

struct ConnectionVerifyCard: View {
    @Environment(AppModel.self) private var appModel
    @Binding var isCollapsed: Bool
    var expandAll: Binding<DetailsExpandAll>?

    @State private var isShowingToolPicker = false
    @State private var selectedTestToolID: String?

    var body: some View {
        let readiness = appModel.smokeReadiness

        Card(
            title: "Verify",
            systemImage: "checkmark.seal",
            isCollapsed: $isCollapsed,
            summary: {
                Text(summaryLine)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            },
            content: {
                VStack(alignment: .leading, spacing: Space.s3) {
                    statusRow
                    detailRow
                    verbRow(readiness)
                    lastResultDetails
                }
            }
        )
    }

    // MARK: Summary + status

    private var summaryLine: String {
        guard let proof = appModel.lastSmokeProof else {
            return "No tests yet"
        }
        let date = proof.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return "Last test: \(Self.displayName(for: proof.mode)) \(proof.succeeded ? "passed" : "failed") · \(date)"
    }

    static func displayName(for mode: SmokeTestMode) -> String {
        switch mode {
        case .preflight: "Quick Test"
        case .anthropicAPI: "Full Test"
        }
    }

    private var statusRow: some View {
        LabeledContent("Status") {
            HStack(spacing: Space.s2) {
                if appModel.smokeTestState.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusText)
            }
        }
    }

    /// Re-voiced from `SmokeTestState.title` (glossary §4.2 — no Preflight/Smoke in visible copy).
    private var statusText: String {
        switch appModel.smokeTestState {
        case .idle: "Not Run"
        case .running(let mode): "Running \(Self.displayName(for: mode))"
        case .passed(let mode, _): "\(Self.displayName(for: mode)) Passed"
        case .failed(let mode, _): "\(Self.displayName(for: mode)) Failed"
        }
    }

    @ViewBuilder
    private var detailRow: some View {
        Text(detailText)
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailText: String {
        if appModel.currentPublicMCPURL == nil {
            // TU-22 blocked copy, re-voiced; gating kept.
            return "Start the server and go public before running tests."
        }
        switch appModel.smokeTestState {
        case .idle:
            return "Run the Quick Test first, then the Full Test."
        case .running:
            return "Running — approve the request when MacRemote asks."
        case .passed(_, let message), .failed(_, let message):
            return message
        }
    }

    // MARK: Verbs

    private func verbRow(_ readiness: SmokeReadiness) -> some View {
        HStack(spacing: Space.s2) {
            Button("Run Quick Test") {
                appModel.runSmokeTest(mode: .preflight)
            }
            .disabled(!readiness.canRunPreflight)

            Button("Run Full Test") {
                appModel.runSmokeTest(mode: .anthropicAPI)
            }
            .disabled(!readiness.canRunAnthropicAPI)

            Button("Test a Tool…") {
                prepareToolPickerSelection()
                isShowingToolPicker = true
            }
            .disabled(!appModel.serverStatus.isRunning || exposedTools.isEmpty)
            .popover(isPresented: $isShowingToolPicker, arrowEdge: .bottom) {
                toolPickerPopover
            }

            Spacer()

            Menu("More") {
                Button("Copy Quick Test Command") {
                    appModel.copyTestCommand(for: .preflight)
                }
                .disabled(appModel.currentPublicMCPURL == nil)
                Button("Copy Full Test Command") {
                    appModel.copyTestCommand(for: .anthropicAPI)
                }
                .disabled(appModel.currentPublicMCPURL == nil)
                Button("Copy Last Result") {
                    copyLastResult()
                }
                .disabled(appModel.lastSmokeProof == nil)
                Divider()
                Button("Refresh Tunnel Status") {
                    appModel.refreshTunnelStatus()
                }
                Divider()
                Button("Testing Guide…") {
                    appModel.isTestingGuidePresented = true
                }
            }
            .fixedSize()
        }
    }

    // MARK: Test a Tool… (D9 — visible, defaults to remctl.today)

    private var exposedTools: [ToolDefinition] {
        appModel.tools
            .filter { appModel.isToolExposed($0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func prepareToolPickerSelection() {
        let tools = exposedTools
        if let selectedTestToolID, tools.contains(where: { $0.id == selectedTestToolID }) {
            return
        }
        if appModel.canRunRemindersRoundTrip {
            selectedTestToolID = "remctl.today"
        } else {
            selectedTestToolID = tools.first?.id
        }
    }

    private var toolPickerPopover: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text("Test a Tool")
                .font(TypeRamp.cardTitle)
            Picker("Tool", selection: $selectedTestToolID) {
                ForEach(exposedTools) { tool in
                    Text(tool.name).tag(Optional(tool.id))
                }
            }
            .labelsHidden()
            .frame(width: 260)

            if let tool = exposedTools.first(where: { $0.id == selectedTestToolID }) {
                StateChip(capability: tool.capability)
            }

            Text("Runs on this Mac — the result lands in Activity.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Run Test") {
                    runSelectedToolTest()
                    isShowingToolPicker = false
                }
                .disabled(selectedTestToolID == nil || !appModel.serverStatus.isRunning)
            }
        }
        .padding(Space.s4)
        .frame(width: 300)
    }

    private func runSelectedToolTest() {
        guard let toolID = selectedTestToolID else { return }
        if toolID == "remctl.today" {
            // Keeps the Full Disk Access interlock the Reminders round-trip has always had.
            appModel.runRemCTLTodayTest()
        } else {
            Task {
                await appModel.runToolTest(toolID: toolID)
            }
        }
    }

    // MARK: Last result (TU-34 — grid behind Details, Copy Last Result kept technical)

    @ViewBuilder
    private var lastResultDetails: some View {
        if let proof = appModel.lastSmokeProof {
            DetailsDisclosure("Details", id: "connection.lastResult", expandAll: expandAll) {
                VStack(alignment: .leading, spacing: Space.s2) {
                    KeyValueGrid(rows: proofRows(proof)) { row in
                        appModel.appendLog(level: .info, "Copied \(row.label) from the last test result.")
                    }
                    if !proof.markers.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text("Technical detail")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(proof.markers, id: \.self) { marker in
                                Text(marker)
                                    .font(TypeRamp.machineCaption)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.4), in: AppShape.mono)
                    }
                }
            }
        }
    }

    private func proofRows(_ proof: SmokeProofRecord) -> [KeyValueRow] {
        var rows = [
            KeyValueRow("Status", proof.statusTitle),
            KeyValueRow("Mode", Self.displayName(for: proof.mode)),
            KeyValueRow("URL", proof.mcpURL),
            KeyValueRow("Tool count", proof.toolSurface),
            KeyValueRow("Result", proof.resultSummary)
        ]
        if let exitCode = proof.exitCode {
            rows.append(KeyValueRow("Exit code", "\(exitCode)"))
        }
        if let duration = proof.duration {
            rows.append(KeyValueRow("Duration", duration.formattedDuration))
        }
        return rows
    }

    private func copyLastResult() {
        guard let proof = appModel.lastSmokeProof else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(proof.clipboardText, forType: .string)
        appModel.appendLog(level: .info, "Copied the last test result.")
    }
}

// MARK: - Testing Guide (TU-8 — the in-app help sheet; Help menu + Verify More ⌄ open it)

struct ConnectionTestingGuideSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text("Connection Testing Guide")
                        .font(TypeRamp.heroStatus)

                    guideSection(
                        title: "Quick Test",
                        symbol: "checkmark.seal",
                        body: "Connects to your public link and confirms MacRemote answers with your shared tools. Nothing runs on this Mac."
                    )
                    guideSection(
                        title: "Full Test",
                        symbol: "sparkles",
                        body: "Asks Claude to call one read-only tool through your public link, end to end. Needs an Anthropic API key on this Mac — the Readiness card's optional row."
                    )
                    guideSection(
                        title: "Test a Tool…",
                        symbol: "wrench.and.screwdriver",
                        body: "Runs one shared tool directly on this Mac and logs the result in Activity. Nothing leaves your Mac."
                    )
                    guideSection(
                        title: "Check Readiness",
                        symbol: "checklist",
                        body: "Sweeps the six checks on the Connection page — permissions, server, public link, shared tools, and the optional API key."
                    )

                    Divider()

                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Prefer Terminal?")
                            .font(TypeRamp.cardTitle)
                        Text("Copy a ready-to-run command for your public link.")
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.secondary)
                        HStack(spacing: Space.s2) {
                            Button("Copy Quick Test Command") {
                                appModel.copyTestCommand(for: .preflight)
                            }
                            Button("Copy Full Test Command") {
                                appModel.copyTestCommand(for: .anthropicAPI)
                            }
                        }
                        .disabled(appModel.currentPublicMCPURL == nil)
                        if appModel.currentPublicMCPURL == nil {
                            Text("Go public first — the commands embed your public link.")
                                .font(TypeRamp.truthNote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Reading results")
                            .font(TypeRamp.cardTitle)
                        Text("The Verify card keeps the last result; Details holds the raw output, and Copy Last Result puts the technical record on the clipboard. Every test also writes a line to Activity.")
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Space.s5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.glassProminent)
            }
            .padding(Space.s4)
        }
        .frame(width: 520, height: 560)
    }

    private func guideSection(title: String, symbol: String, body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title)
                    .font(TypeRamp.cardTitle)
                Text(body)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
