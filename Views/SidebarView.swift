import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationSection?

    var body: some View {
        List(selection: $selection) {
            Section("MacRemote") {
                ForEach(NavigationSection.allCases) { section in
                    HStack(spacing: 10) {
                        Image(systemName: section.systemImage)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(section.title)
                                .lineLimit(1)

                            if let detail = section.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("MacRemote")
    }
}
