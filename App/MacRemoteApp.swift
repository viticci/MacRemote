import AppKit
import SwiftUI

@main
struct MacRemoteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup("MacRemote", id: "main") {
            ContentView()
                .environment(appModel)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .commands {
            CommandMenu("Server") {
                Button("Start Local Server") {
                    appModel.startLocalServer()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(appModel.serverStatus.isRunning)

                Button("Stop Local Server") {
                    appModel.stopLocalServer()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!appModel.serverStatus.isRunning)
            }
        }

        Settings {
            SettingsView()
                .environment(appModel)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        .terminateNow
    }
}
