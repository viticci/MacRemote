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
                            ? "\(counted(appModel.pendingRequestCount, "request")) waiting"
                            : Self.toolsBadgeExplanation(
                                count: section == .tools
                                    ? appModel.newUnimportedMCPCandidateCount
                                    : 0
                            ) ?? ""
                    )
                    .modifier(
                        SidebarBadgeHelp(
                            text: section == .tools
                                ? Self.toolsBadgeExplanation(
                                    count: appModel.newUnimportedMCPCandidateCount
                                )
                                : nil
                        )
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

    nonisolated static func toolsBadgeExplanation(count: Int) -> String? {
        guard count > 0 else { return nil }
        if count == 1 {
            return "1 new MCP server found. Open Tools to review it; nothing was imported automatically."
        }
        return "\(count) new MCP servers found. Open Tools to review them; nothing was imported automatically."
    }
}

private struct SidebarBadgeHelp: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}
