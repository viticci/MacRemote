import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            Section("Local Server") {
                LabeledContent("Bind address") {
                    Text("127.0.0.1")
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Instance ID") {
                    Text(appModel.instanceID)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Tool Profile") {
                LabeledContent("Profile") {
                    Text("Full RemCTL CLI")
                }
                LabeledContent("Executable") {
                    Text(RemCTLToolCatalog.executablePath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("Full Disk Access") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Image(systemName: fullDiskAccessIcon)
                            .foregroundStyle(fullDiskAccessColor)
                        Text(appModel.fullDiskAccessReport.state.title)
                    }
                }

                Text("MacRemote exposes the full RemCTL CLI. Before the MCP server can start, the app runs `remctl doctor --for-agent --json` from its own process context. If that check cannot read Reminders, grant Full Disk Access to the targets below.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Check Access", systemImage: "checkmark.shield") {
                        appModel.checkFullDiskAccess()
                    }
                    .disabled(isCheckingFullDiskAccess)

                    Button("Open Guided Setup", systemImage: "gearshape.2") {
                        appModel.openFullDiskAccessHelper()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCheckingFullDiskAccess)
                }

                if isCheckingFullDiskAccess {
                    ProgressView()
                        .controlSize(.small)
                }

                if !appModel.fullDiskAccessReport.detail.isEmpty {
                    Text(appModel.fullDiskAccessReport.detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !appModel.fullDiskAccessReport.targets.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Grant Access To")
                            .font(.subheadline.weight(.semibold))

                        ForEach(appModel.fullDiskAccessReport.targets) { target in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(target.title)
                                Text(target.path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                if !target.subtitle.isEmpty {
                                    Text(target.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                Text("After changing Full Disk Access, relaunch MacRemote and check again before starting the server.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 520, minHeight: 320)
        .navigationTitle("Settings")
    }

    private var isCheckingFullDiskAccess: Bool {
        if case .checking = appModel.fullDiskAccessReport.state {
            true
        } else {
            false
        }
    }

    private var fullDiskAccessIcon: String {
        switch appModel.fullDiskAccessReport.state {
        case .ready:
            "checkmark.shield.fill"
        case .required, .failed(_):
            "exclamationmark.triangle.fill"
        case .checking:
            "hourglass"
        case .helperOpened:
            "gearshape.2.fill"
        case .unknown:
            "questionmark.circle"
        }
    }

    private var fullDiskAccessColor: Color {
        switch appModel.fullDiskAccessReport.state {
        case .ready:
            .green
        case .required, .failed(_):
            .orange
        case .checking:
            .blue
        case .helperOpened, .unknown:
            .secondary
        }
    }
}
