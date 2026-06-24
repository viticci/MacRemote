import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingRotateInstanceConfirmation = false
    @State private var isShowingRevokeOAuthConfirmation = false

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

                HStack {
                    Button("Rotate Instance ID", systemImage: "arrow.triangle.2.circlepath") {
                        isShowingRotateInstanceConfirmation = true
                    }
                    .buttonStyle(.bordered)

                    Text("Stops exposure, clears grants, and changes the public MCP path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("OAuth Grants") {
                Text("Revokes registered remote clients, authorization codes, access tokens, and refresh tokens. The MCP URL stays the same; clients must authorize again on this Mac.")
                    .foregroundStyle(.secondary)

                Button("Revoke OAuth Grants", systemImage: "person.crop.circle.badge.xmark") {
                    isShowingRevokeOAuthConfirmation = true
                }
                .buttonStyle(.bordered)
            }

            Section("Full Disk Access") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Image(systemName: fullDiskAccessIcon)
                            .foregroundStyle(fullDiskAccessColor)
                        Text(appModel.fullDiskAccessReport.state.title)
                    }
                }

                Text("Full Disk Access is layered. MacRemote may need access as the host app, and an FDA-required CLI or its script interpreter may also need access as the process reading protected data.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button(isCheckingFullDiskAccess ? "Check Again" : "Check Access", systemImage: "checkmark.shield") {
                        appModel.checkFullDiskAccess()
                    }

                    Button("Open Guided Setup", systemImage: "gearshape.2") {
                        appModel.openFullDiskAccessHelper()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Relaunch MacRemote", systemImage: "arrow.clockwise") {
                        appModel.relaunchMacRemote()
                    }

                    Button("Reset App Row", systemImage: "arrow.triangle.2.circlepath") {
                        appModel.resetMacRemoteFullDiskAccessGrant()
                    }

                    if appModel.fullDiskAccessReport.requiresManualConfirmation {
                        Button("Confirm Setup", systemImage: "checkmark.seal") {
                            appModel.confirmFullDiskAccessSetup()
                        }
                    }

                    if let firstTarget = appModel.fullDiskAccessReport.targets.first {
                        Button("Copy First Target", systemImage: "doc.on.doc") {
                            copyPath(firstTarget.path)
                            appModel.appendLog(level: .info, "Copied Full Disk Access target: \(firstTarget.title).")
                        }
                    }
                }

                if isCheckingFullDiskAccess {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking the active process context.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                            Label("Open Guided Setup to launch the permission helper and System Settings.", systemImage: "1.circle")
                            Label("Add every listed target to Full Disk Access.", systemImage: "2.circle")
                            Label("Use Reset App Row if System Settings already shows MacRemote enabled but checks still fail.", systemImage: "3.circle")
                            Label("Use Relaunch MacRemote after changing System Settings.", systemImage: "4.circle")
                            Label("Run Check Access after the app reopens.", systemImage: "5.circle")
                            if appModel.fullDiskAccessReport.requiresManualConfirmation {
                                Label("Confirm Setup for tools MacRemote cannot automatically verify.", systemImage: "6.circle")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                if appModel.fullDiskAccessReport.targets.isEmpty {
                    Text("Run Check Access to discover the exact Full Disk Access targets for this MacRemote process.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("After changing Full Disk Access, use Relaunch MacRemote and check again before starting the server. macOS often keeps the old permission state cached until the process exits.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("macOS Privacy") {
                LabeledContent("Status") {
                    HStack(spacing: 8) {
                        Image(systemName: macOSPrivacyIcon)
                            .foregroundStyle(macOSPrivacyColor)
                        Text(appModel.macOSPrivacyAccessReport.state.title)
                    }
                }

                Text("Some command-line tools need app-service privacy access from the host app that launches them. Reminders edits, for example, require Reminders access for MacRemote itself.")
                    .foregroundStyle(.secondary)

                HStack {
                    Button(isCheckingMacOSPrivacy ? "Check Again" : "Check Access", systemImage: "checkmark.shield") {
                        appModel.checkFullDiskAccess()
                    }

                    Button("Open Reminders Privacy", systemImage: "checklist") {
                        openPrivacySettings(anchor: "Privacy_Reminders")
                    }
                }

                if isCheckingMacOSPrivacy {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Checking MacRemote's app-service access.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !appModel.macOSPrivacyAccessReport.detail.isEmpty {
                    Text(appModel.macOSPrivacyAccessReport.detail)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !appModel.macOSPrivacyAccessReport.checkedRequirements.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(appModel.macOSPrivacyAccessReport.checkedRequirements, id: \.self) { requirement in
                            StatusBadge(
                                title: requirement.title,
                                systemImage: requirement.systemImage,
                                tint: .blue
                            )
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 620, minHeight: 420)
        .navigationTitle("Settings")
        .confirmationDialog(
            "Rotate Instance ID?",
            isPresented: $isShowingRotateInstanceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rotate Instance ID", role: .destructive) {
                appModel.rotateInstanceID()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacRemote will stop the local server and tunnel, clear pending OAuth and tool approvals, and require remote clients to use a new MCP URL path.")
        }
        .confirmationDialog(
            "Revoke OAuth Grants?",
            isPresented: $isShowingRevokeOAuthConfirmation,
            titleVisibility: .visible
        ) {
            Button("Revoke Grants", role: .destructive) {
                appModel.revokeOAuthGrants()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacRemote will invalidate all registered clients and OAuth tokens. The public MCP URL will stay unchanged, and clients must request host approval again.")
        }
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

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private var isCheckingFullDiskAccess: Bool {
        if case .checking = appModel.fullDiskAccessReport.state {
            true
        } else {
            false
        }
    }

    private var isCheckingMacOSPrivacy: Bool {
        if case .checking = appModel.macOSPrivacyAccessReport.state {
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
        case .confirmationRequired:
            "checkmark.seal.fill"
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
        case .confirmationRequired:
            .blue
        case .checking:
            .blue
        case .helperOpened, .unknown:
            .secondary
        }
    }

    private var macOSPrivacyIcon: String {
        switch appModel.macOSPrivacyAccessReport.state {
        case .ready:
            "checkmark.shield.fill"
        case .required, .failed(_):
            "exclamationmark.triangle.fill"
        case .checking:
            "hourglass"
        case .unknown:
            "questionmark.circle"
        }
    }

    private var macOSPrivacyColor: Color {
        switch appModel.macOSPrivacyAccessReport.state {
        case .ready:
            .green
        case .required, .failed(_):
            .orange
        case .checking:
            .blue
        case .unknown:
            .secondary
        }
    }
}
