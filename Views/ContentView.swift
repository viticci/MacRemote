import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            SidebarView(selection: $appModel.selection)
                .navigationSplitViewColumnWidth(min: 184, ideal: 196, max: 220)
        } detail: {
            switch appModel.selection ?? .connection {
            case .connection:
                ConnectionView()
            case .tools:
                ToolsView()
            case .apps:
                AppsView()
            case .requests:
                RequestsView()
            case .activity:
                ActivityView()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $appModel.fullDiskAccessPrompt) { prompt in
            FullDiskAccessSheet(prompt: prompt)
                .environment(appModel)
        }
    }
}

/// App-global Access Fixer host (spec §5.8, parity SD-21). All four
/// `FullDiskAccessPrompt` reasons keep their bespoke re-voiced copy;
/// the model clears `fullDiskAccessPrompt` itself once access is ready.
private struct FullDiskAccessSheet: View {
    @Environment(AppModel.self) private var appModel
    let prompt: FullDiskAccessPrompt

    var body: some View {
        AccessFixer(
            state: fixerState,
            title: prompt.reason.title,
            detail: prompt.reason.detail,
            targets: appModel.fullDiskAccessReport.targets,
            automaticChecksPassed: appModel.fullDiskAccessReport.automaticChecksPassed,
            actions: AccessFixerActions(
                checkAgain: { appModel.checkFullDiskAccess() },
                openSystemSettings: { appModel.openFullDiskAccessHelper() },
                later: { appModel.dismissFullDiskAccessPrompt() },
                relaunch: { appModel.relaunchMacRemote() },
                readdInSystemSettings: { appModel.resetMacRemoteFullDiskAccessGrant() },
                confirmSetup: appModel.fullDiskAccessReport.requiresManualConfirmation
                    ? { appModel.confirmFullDiskAccessSetup() }
                    : nil,
                copyAllPaths: {
                    copyToPasteboard(appModel.fullDiskAccessReport.targets.map(\.path).joined(separator: "\n"))
                    appModel.appendLog(level: .info, "Copied all Full Disk Access target paths.")
                },
                copyFirstTarget: {
                    guard let first = appModel.fullDiskAccessReport.targets.first else { return }
                    copyTargetToPasteboard(first)
                    appModel.appendLog(level: .info, "Copied Full Disk Access target: \(first.title).")
                },
                openConnectionReadiness: {
                    appModel.revealReadinessRow(.fullDiskAccess)
                    appModel.dismissFullDiskAccessPrompt()
                }
            ),
            onCopyTarget: { target in
                copyTargetToPasteboard(target)
                appModel.appendLog(level: .info, "Copied Full Disk Access target: \(target.title).")
            },
            onRevealTarget: { target in
                NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
                appModel.appendLog(level: .info, "Revealed Full Disk Access target: \(target.title).")
            }
        )
        .padding(Space.s6)
        .frame(width: 680)
    }

    private var fixerState: AccessFixerState {
        switch appModel.fullDiskAccessReport.state {
        case .checking: .checking
        case .ready: .ready
        case .failed(let message): .failed(message)
        case .confirmationRequired: .confirmSetup
        case .unknown, .required, .helperOpened: .required
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    private func copyTargetToPasteboard(_ target: FullDiskAccessTarget) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(target.path, forType: .string)
        pasteboard.setString(URL(fileURLWithPath: target.path).absoluteString, forType: .fileURL)
    }
}
