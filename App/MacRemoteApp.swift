import AppKit
import SwiftUI

/// The executable has two jobs. Started normally it is the app. Started by
/// the app with `HelperTether.flag` it is a tether, which never shows a window.
@main
enum MacRemoteMain {
    @MainActor
    static func main() {
        HelperTether.runIfRequested()
        MacRemoteApp.main()
    }
}

struct MacRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        @Bindable var appModel = appDelegate.appModel

        WindowGroup("MacRemote", id: MacRemoteWindowID.main) {
            ContentView()
                .environment(appModel)
                .frame(minWidth: 1040, minHeight: 680)
                .modifier(AppSkeletonInstaller(appModel: appModel))
        }
        .commands {
            MacRemoteCommands(appModel: appModel)
        }

        // The security interrupt (spec §5.4). Non-activating presentation is
        // enforced by AppModel.presentApprovalWindow() (D4).
        Window("Approval", id: MacRemoteWindowID.approval) {
            ApprovalWindowView()
                .environment(appModel)
                .background(ApprovalWindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .windowLevel(.floating)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Window("Welcome to MacRemote", id: MacRemoteWindowID.welcome) {
            WelcomeView()
                .environment(appModel)
                .frame(width: 760, height: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environment(appModel)
        }

        MenuBarExtra(isInserted: $appModel.isMenuBarExtraEnabled) {
            MenuBarExtraMenu()
                .environment(appModel)
        } label: {
            MenuBarExtraLabel(appModel: appModel)
                .modifier(WindowOpenerInstaller(appModel: appModel))
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Owns the app model and the app-level launch and quit work. None of it
/// may depend on a window: at login, macOS can relaunch MacRemote with no
/// windows at all, and Go Public at Launch (D76) still runs then.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appModel: AppModel

    override init() {
        // Downloads staged by a launch that crashed can never be fetched:
        // their tokens were only in memory. Remove them before staging more.
        ArtifactStore.emptyStagingRoot()
        appModel = AppModel(
            helperTetherExecutableURL: Bundle.main.executableURL,
            runsLaunchActions: true
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        appModel.refreshNotificationPermissionStatus()
        appModel.startAutomaticDiscovery()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Warm upstream MCP processes never outlive the app.
        MCPStdioSessionPool.shared.drain()
        guard appModel.shouldConfirmQuit else { return .terminateNow }
        // A logout, restart, or shutdown never waits on the dialog (D80): on
        // a Mac nobody is watching, it would hold the restart until someone
        // answered. `applicationWillTerminate` still stops sharing.
        if QuitReason.isSessionEnding(NSAppleEventManager.shared().currentAppleEvent) {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Stop sharing and quit?"
        alert.informativeText = "Your public link stops working the moment MacRemote quits."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        return .terminateNow
    }

    /// Every quit path ends here, including the ones that skip the
    /// confirmation. Cloudflare's helper is a separate process: left running,
    /// it would keep the public address connected to a port nothing owns.
    /// A death that never reaches this method is covered by `HelperTether`.
    func applicationWillTerminate(_ notification: Notification) {
        appModel.prepareForConfirmedQuit()
    }
}

/// Main-window plumbing: the window opener and the first-run Welcome window.
/// A first run always opens the main window, so Welcome can wait for it.
private struct AppSkeletonInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let appModel: AppModel

    func body(content: Content) -> some View {
        content
            .modifier(WindowOpenerInstaller(appModel: appModel))
            .task {
                if !appModel.hasCompletedWelcome {
                    openWindow(id: MacRemoteWindowID.welcome)
                }
            }
    }
}

/// Gives the model SwiftUI's `openWindow`, which only a view can supply, so
/// it can present the Approval window. The menu bar icon installs it too:
/// after a windowless launch the icon is the only view that exists.
private struct WindowOpenerInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    let appModel: AppModel

    func body(content: Content) -> some View {
        content.onAppear {
            appModel.windowOpener = { openWindow(id: $0) }
        }
    }
}

/// AppKit window configuration SwiftUI does not expose: the Approval window
/// joins all Spaces and floats over full-screen apps (spec §5.4).
private struct ApprovalWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.hidesOnDeactivate = false
            window.isMovableByWindowBackground = true
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Menu commands (spec §2.3)

struct MacRemoteCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appModel: AppModel

    var body: some Commands {
        CommandMenu("Server") {
            Button("Start Local Server") {
                appModel.startLocalServer()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(appModel.serverStatus.isRunning || appModel.serverStatus == .starting)

            Button("Stop Local Server") {
                appModel.stopLocalServer()
            }
            .keyboardShortcut(".", modifiers: [.command])
            .disabled(!appModel.serverStatus.isRunning)

            Divider()

            Button("Go Public (Cloudflare Tunnel)…") {
                appModel.requestGoPublic()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(!appModel.serverStatus.isRunning || appModel.tunnelStatus.isRunning || appModel.tunnelStatus.isRecovering)

            Button("Stop Sharing") {
                appModel.stopTunnel()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(!(appModel.tunnelStatus.isRunning || appModel.tunnelStatus.isRecovering))

            Button("Copy Public URL") {
                appModel.copyPublicURL()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(appModel.currentPublicMCPURL == nil)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tool…") {
                appModel.requestNewTool()
            }
            .keyboardShortcut("n", modifiers: [.command])

            Button("Add from Library…") {
                appModel.requestAddFromLibrary()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("Scan for MCP Servers") {
                appModel.scanLocalMCPServers()
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])

            Button("Scan for Command-Line Tools…") {
                appModel.requestScanForCommandLineTools()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }

        CommandGroup(after: .textEditing) {
            Button("Find") {
                appModel.focusSearchField()
            }
            .keyboardShortcut("f", modifiers: [.command])
        }

        CommandGroup(after: .sidebar) {
            Divider()

            ForEach(NavigationSection.allCases) { section in
                Button(section.title) {
                    appModel.selection = section
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(section.keyboardShortcutNumber))),
                    modifiers: [.command]
                )
            }

            Divider()

            Button(appModel.isToolInspectorPresented ? "Hide Inspector" : "Show Inspector") {
                appModel.isToolInspectorPresented.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }

        // D4: approval verbs are app-level commands, so the floating window
        // never has to be key. They act only on the request that window is
        // showing, never on one waiting behind it.
        CommandMenu("Requests") {
            Button("Approve") {
                appModel.approvePresentedRequest()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(appModel.presentedPendingInterrupt == nil)

            Button("Always Allow for App") {
                appModel.alwaysAllowPresentedRequest()
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(!appModel.canAlwaysAllowPresentedRequest)

            Button("Deny") {
                appModel.denyPresentedRequest()
            }
            .keyboardShortcut(.delete, modifiers: [.command])
            .disabled(appModel.presentedPendingInterrupt == nil)
        }

        CommandGroup(replacing: .help) {
            Button("Welcome to MacRemote…") {
                openWindow(id: MacRemoteWindowID.welcome)
            }
        }
    }
}

// MARK: - MenuBarExtra (spec §2.5)

private struct MenuBarExtraLabel: View {
    let appModel: AppModel

    var body: some View {
        let pendingCount = appModel.pendingRequestCount

        Image(nsImage: MenuBarIconRenderer.image(
            isOff: !appModel.serverStatus.isRunning && !appModel.tunnelStatus.isRunning,
            showsBadge: appModel.currentPublicMCPURL != nil || pendingCount > 0
        ))

        if pendingCount > 0 {
            Text(String(pendingCount))
        }
    }
}

private struct MenuBarExtraMenu: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Text(appModel.menuBarStatusLine)

        Button("Copy Public URL") {
            appModel.copyPublicURL()
        }
        .disabled(appModel.currentPublicMCPURL == nil)

        Divider()

        if appModel.serverStatus.isRunning {
            Button("Stop Local Server") {
                appModel.stopLocalServer()
            }
            .keyboardShortcut(".", modifiers: [.command])
        } else {
            Button("Start Local Server") {
                appModel.startLocalServer()
            }
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(appModel.serverStatus == .starting)
        }

        if appModel.tunnelStatus.isRunning || appModel.tunnelStatus.isRecovering {
            Button("Stop Sharing") {
                appModel.stopTunnel()
            }
        } else {
            // D3-adjacent: the blast-radius confirmation never fires from a menu;
            // this opens the main window's confirmation instead.
            Button("Go Public…") {
                appModel.requestGoPublic()
            }
            .disabled(!appModel.serverStatus.isRunning)
        }

        Divider()

        if appModel.pendingRequestCount > 0 {
            // D3: opens the Approval window; never resolves a request inline.
            Button("\(appModel.pendingRequestCount) request\(appModel.pendingRequestCount == 1 ? "" : "s") waiting…") {
                appModel.presentApprovalWindow()
            }
        }

        Divider()

        Button("Open MacRemote") {
            appModel.openMainWindow()
        }
        Button("Quit MacRemote") {
            NSApp.terminate(nil)
        }
    }
}

/// Renders the menu bar glyph as a template NSImage so the badge dot survives
/// the menu bar's template tinting (SwiftUI shape overlays don't render there).
@MainActor
private enum MenuBarIconRenderer {
    static func image(isOff: Bool, showsBadge: Bool) -> NSImage {
        let symbolName = isOff ? "circle.dotted" : "dot.radiowaves.left.and.right"
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MacRemote")?
            .withSymbolConfiguration(configuration) else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }

        let padding: CGFloat = showsBadge ? 3 : 0
        let size = NSSize(width: symbol.size.width + padding, height: symbol.size.height + padding)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(
                at: NSPoint(x: 0, y: 0),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            if showsBadge {
                let badgeRect = NSRect(x: size.width - 5, y: size.height - 5, width: 5, height: 5)
                NSBezierPath(ovalIn: badgeRect).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
