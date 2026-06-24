import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            SidebarView(selection: $appModel.selection)
        } detail: {
            switch appModel.selection ?? .dashboard {
            case .dashboard:
                DashboardView()
            case .tools:
                ToolsView()
            case .approvals:
                ApprovalsView()
            case .tunnel:
                TunnelView()
            case .logs:
                LogsView()
            case .settings:
                SettingsView()
            }
        }
        .sheet(item: $appModel.fullDiskAccessPrompt) { prompt in
            FullDiskAccessPermissionSheet(prompt: prompt)
                .environment(appModel)
        }
    }
}
