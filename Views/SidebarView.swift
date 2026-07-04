import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selection: NavigationSection?

    var body: some View {
        List(selection: $selection) {
            ForEach(NavigationSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(badgeCount(for: section))
                    .accessibilityValue(
                        section == .requests && appModel.pendingRequestCount > 0
                            ? "\(appModel.pendingRequestCount) requests waiting"
                            : section == .tools && appModel.newUnimportedMCPCandidateCount > 0
                                ? "\(appModel.newUnimportedMCPCandidateCount) new MCP servers"
                                : ""
                    )
                    .overlay(alignment: .trailing) {
                        if section == .connection, appModel.hasConnectionFailure {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel("Connection failed")
                        }
                    }
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MacRemote")
    }

    private func badgeCount(for section: NavigationSection) -> Int {
        switch section {
        case .requests:
            appModel.pendingRequestCount
        case .tools:
            appModel.newUnimportedMCPCandidateCount
        default:
            0
        }
    }
}
