import SwiftUI

struct ToolsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HeaderView(
                    title: "Tools",
                    subtitle: "Only explicit executable paths and validated argv templates can be exposed."
                )

                ForEach(appModel.tools) { tool in
                    ToolPanel(tool: tool)
                }
            }
            .padding(24)
        }
        .navigationTitle("Tools")
    }
}

private struct ToolPanel: View {
    let tool: ToolDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(tool.name)
                        .font(.headline)
                    Text(tool.summary)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(tool.capability.title)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.16), in: Capsule())
            }

            LabeledContent("Executable") {
                Text(tool.executablePath)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            LabeledContent("Arguments") {
                Text(tool.argumentPattern.joined(separator: " "))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
            }

            if !tool.parameters.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Parameters")
                        .font(.subheadline.weight(.semibold))
                    ForEach(tool.parameters) { parameter in
                        Text("\(parameter.title) (`\(parameter.name)`)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .panelStyle()
    }
}
