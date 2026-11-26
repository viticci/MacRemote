import SwiftUI

/// One of Federico's CLIs that ships its own MCP server, with its Add or
/// Update button. The Library's Presets, Bundles, and Found on This Mac tabs
/// and the Tools page's Federico Viticci source all draw this same row
/// (SPEC D86), so the button waits and the import error shows the same way
/// on each: the button is off while any first-party import runs or waits,
/// and the provider's last failed Add or Update shows under the row.
struct FirstPartyProviderRow: View {
    @Environment(AppModel.self) private var appModel

    let provider: FirstPartyMCPProvider

    var body: some View {
        let imported = appModel.importedFirstPartyMCPTools(for: provider)
        let candidate = appModel.firstPartyMCPCandidate(for: provider)
        let isImporting = appModel.isImportingLocalMCPServer(candidateID: candidate?.id)
        let probedCount = candidate?.probe?.tools.count

        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: provider.category.iconSystemImage)
                    .foregroundStyle(provider.category.iconTint)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text(provider.name)
                            .font(TypeRamp.cardTitle)
                        Text("MCP server")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !imported.isEmpty {
                            Text("Added ✓")
                                .font(TypeRamp.chip)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(summary(importedCount: imported.count, probedCount: probedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .countText()
                }

                Spacer()

                if isImporting {
                    ProgressView()
                        .controlSize(.small)
                }

                Button(imported.isEmpty ? "Add \(provider.name)" : "Update") {
                    appModel.importFirstPartyMCPProvider(provider, intent: imported.isEmpty ? .add : .update)
                }
                .controlSize(.small)
                .disabled(appModel.hasPendingFirstPartyImports)
            }

            if let error = appModel.firstPartyImportErrors[provider.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.leading, 20 + Space.s3)
            }
        }
    }

    private func summary(importedCount: Int, probedCount: Int?) -> String {
        let base = "Tools come from \(provider.name)’s own MCP server and match the installed version."
        if importedCount > 0 {
            return "\(base) \(counted(importedCount, "tool")) added."
        }
        if let probedCount {
            return "\(base) \(counted(probedCount, "tool")) available."
        }
        return base
    }
}
