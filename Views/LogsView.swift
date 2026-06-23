import SwiftUI

struct LogsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HeaderView(
                title: "Logs",
                subtitle: "Redacted local audit trail for auth, tunnel, server, and tool events."
            )

            List(appModel.logs) { entry in
                LogRow(entry: entry)
            }
        }
        .padding(24)
        .navigationTitle("Logs")
    }
}

struct LogRow: View {
    let entry: AppLogEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.date.shortTimeString)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Text(entry.level.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 58, alignment: .leading)

            Text(entry.message)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
    }

    private var color: Color {
        switch entry.level {
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
