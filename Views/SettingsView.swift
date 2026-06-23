import AppKit
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

                    if let firstTarget = appModel.fullDiskAccessReport.targets.first {
                        Button("Copy First Target", systemImage: "doc.on.doc") {
                            copyPath(firstTarget.path)
                            appModel.appendLog(level: .info, "Copied Full Disk Access target: \(firstTarget.title).")
                        }
                    }
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
                            FullDiskAccessTargetRow(
                                target: target,
                                copyAction: {
                                    copyPath(target.path)
                                    appModel.appendLog(level: .info, "Copied Full Disk Access target: \(target.title).")
                                },
                                revealAction: {
                                    NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
                                    appModel.appendLog(level: .info, "Revealed Full Disk Access target: \(target.title).")
                                }
                            )
                        }

                        HStack(spacing: 10) {
                            Button("Copy All Paths", systemImage: "doc.on.clipboard") {
                                copyAllTargetPaths(appModel.fullDiskAccessReport.targets)
                                appModel.appendLog(level: .info, "Copied all Full Disk Access target paths.")
                            }

                            Text("Drag a row into Full Disk Access, or copy a path and use Command-Shift-G in the file picker.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            Label("Open Guided Setup to launch RemCTL's helper and System Settings.", systemImage: "1.circle")
                            Label("Add every listed target to Full Disk Access.", systemImage: "2.circle")
                            Label("Relaunch MacRemote, then run Check Access.", systemImage: "3.circle")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if appModel.fullDiskAccessReport.targets.isEmpty {
                    Text("Run Check Access to ask RemCTL for the exact Full Disk Access targets for this MacRemote process.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("After changing Full Disk Access, relaunch MacRemote and check again before starting the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Settings")
    }

    private func copyPath(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        pasteboard.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
    }

    private func copyAllTargetPaths(_ targets: [FullDiskAccessTarget]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(targets.map(\.path).joined(separator: "\n"), forType: .string)
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

private struct FullDiskAccessTargetRow: View {
    let target: FullDiskAccessTarget
    let copyAction: () -> Void
    let revealAction: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: target.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(target.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(target.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if !target.subtitle.isEmpty {
                    Text(target.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                Button("Copy", systemImage: "doc.on.doc", action: copyAction)
                Button("Reveal", systemImage: "finder", action: revealAction)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.6), lineWidth: 1)
        }
        .draggable(URL(fileURLWithPath: target.path))
        .help("Drag this row into Full Disk Access, or copy the path and use Command-Shift-G.")
    }
}
