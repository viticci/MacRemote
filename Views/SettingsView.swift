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
                    Text("RemCTL read-only")
                }
                LabeledContent("Executable") {
                    Text(RemCTLToolCatalog.executablePath)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section("macOS Permissions") {
                Text("Direct RemCTL reads require Full Disk Access for the MacRemote app bundle because RemCTL reads the local Reminders CoreData store.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(24)
        .frame(minWidth: 520, minHeight: 320)
        .navigationTitle("Settings")
    }
}
