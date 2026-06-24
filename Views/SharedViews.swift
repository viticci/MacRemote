import AppKit
import SwiftUI

struct HeaderView: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.largeTitle.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.headline)

            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusPanel<Actions: View>: View {
    let title: String
    let value: String
    let systemImage: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(value)
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack {
                Spacer()
                actions
            }
        }
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .panelStyle()
    }
}

enum FlowStepState {
    case ready
    case active
    case blocked
    case idle

    var tint: Color {
        switch self {
        case .ready: .green
        case .active: .blue
        case .blocked: .orange
        case .idle: .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .active: "arrow.right.circle.fill"
        case .blocked: "exclamationmark.triangle.fill"
        case .idle: "circle"
        }
    }
}

struct FlowStep<Actions: View>: View {
    let index: Int
    let title: String
    let detail: String
    let systemImage: String
    let state: FlowStepState
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(state.tint.opacity(0.16))
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(state.tint)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(index)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                        Text(title)
                            .font(.headline)
                            .lineLimit(1)
                    }

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: state.symbolName)
                    .foregroundStyle(state.tint)
                    .accessibilityHidden(true)
            }

            Spacer(minLength: 0)

            HStack {
                Spacer()
                actions
            }
        }
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .panelStyle()
    }
}

struct MetricPill: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .blue

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.28), lineWidth: 1)
        }
    }
}

struct StatusBadge: View {
    let title: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.13), in: Capsule())
    }
}

struct CommandLineView: View {
    let executable: String
    let arguments: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(([executable] + arguments).joined(separator: " "))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

struct StartTunnelButton: View {
    @Environment(AppModel.self) private var appModel
    let title: String
    @State private var isShowingStartConfirmation = false

    var body: some View {
        Button(title, systemImage: "point.3.connected.trianglepath.dotted") {
            isShowingStartConfirmation = true
        }
        .confirmationDialog(
            "Start Public Tunnel?",
            isPresented: $isShowingStartConfirmation,
            titleVisibility: .visible
        ) {
            Button("Start Tunnel", role: .destructive) {
                appModel.startTunnel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationMessage: String {
        let summary = appModel.toolExposureSummary
        return "Cloudflare will create a public HTTPS route to MacRemote's local MCP server, not to the whole Mac. The exposed surface is \(summary.total) tools: \(summary.readOnly) read-only and \(summary.gatedToolCount) write/destructive tools requiring per-call host approval. OAuth host approval is still required before any remote client receives tokens."
    }
}

extension View {
    func panelStyle() -> some View {
        self
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            }
    }
}

struct FullDiskAccessTargetRow: View {
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
                HStack(spacing: 6) {
                    Text(target.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Label(target.role.title, systemImage: target.role.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

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

struct FullDiskAccessPermissionSheet: View {
    @Environment(AppModel.self) private var appModel
    let prompt: FullDiskAccessPrompt

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "lock.shield.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text(sheetTitle)
                        .font(.title2.weight(.semibold))
                    Text(sheetDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            LabeledContent("Status") {
                HStack(spacing: 8) {
                    if case .checking = appModel.fullDiskAccessReport.state {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(appModel.fullDiskAccessReport.state.title)
                }
            }

            if !appModel.fullDiskAccessReport.detail.isEmpty {
                Text(appModel.fullDiskAccessReport.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if appModel.fullDiskAccessReport.targets.isEmpty {
                ContentUnavailableView(
                    "No Targets Yet",
                    systemImage: "questionmark.folder",
                    description: Text("Run Check Again to discover the exact Full Disk Access targets in this MacRemote process.")
                )
                .frame(minHeight: 120)
            } else {
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
                }
            }

            Text("Full Disk Access is layered: MacRemote may need access as the host app, and the CLI or its interpreter may also need access as the process that reads protected data. After changing System Settings, use Relaunch MacRemote and run Check Again before starting the server or remote proof.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Settings", systemImage: "gearshape") {
                    appModel.selection = .settings
                    appModel.dismissFullDiskAccessPrompt()
                }

                if !appModel.fullDiskAccessReport.targets.isEmpty {
                    Button("Copy All Paths", systemImage: "doc.on.clipboard") {
                        copyAllTargetPaths(appModel.fullDiskAccessReport.targets)
                        appModel.appendLog(level: .info, "Copied all Full Disk Access target paths.")
                    }
                }

                Spacer()

                Button("Later") {
                    appModel.dismissFullDiskAccessPrompt()
                }

                Button("Open Guided Setup", systemImage: "gearshape.2") {
                    appModel.openFullDiskAccessHelper()
                }
                .buttonStyle(.bordered)

                Button("Relaunch MacRemote", systemImage: "arrow.clockwise") {
                    appModel.relaunchMacRemote()
                }
                .buttonStyle(.bordered)

                Button("Reset App Row", systemImage: "arrow.triangle.2.circlepath") {
                    appModel.resetMacRemoteFullDiskAccessGrant()
                }
                .buttonStyle(.bordered)

                if appModel.fullDiskAccessReport.requiresManualConfirmation {
                    Button("Confirm Setup", systemImage: "checkmark.seal") {
                        appModel.confirmFullDiskAccessSetup()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Check Again", systemImage: "checkmark.shield") {
                    appModel.checkFullDiskAccess()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 680)
    }

    private var sheetTitle: String {
        if appModel.fullDiskAccessReport.state == .confirmationRequired {
            return "Confirm Full Disk Access Setup"
        }
        return prompt.reason.title
    }

    private var sheetDetail: String {
        if appModel.fullDiskAccessReport.state == .confirmationRequired {
            return "The automatic checks that can run have passed. Confirm this setup after granting the listed targets for tools MacRemote cannot safely verify automatically."
        }
        return prompt.reason.detail
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
}
