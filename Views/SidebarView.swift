import SwiftUI

struct SidebarView: View {
    @Binding var selection: NavigationSection?

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: 64)
                .accessibilityHidden(true)

            List(selection: $selection) {
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
            .listStyle(.sidebar)
        }
        .navigationTitle("MacRemote")
    }
}
