import SwiftUI

// Skills on the Tools page (SPEC D84): a row beside the tools of the family a
// skill belongs to, and an inspector that shows what a connected app reads.

extension Skill {
    /// Where the skill comes from, in the words the Tools page uses.
    var originDescription: String {
        switch origin {
        case .builtIn:
            "Built into MacRemote"
        case .bridgedServer(_, let serverName, _):
            "From \(serverName)'s server"
        case .foundOnDisk(_, let source, _):
            switch source {
            case .claudeSkills: "Found in your Claude skills"
            case .codexSkills: "Found in your Codex skills"
            case .agentSkills: "Found in your agent skills"
            case .claudePlugin(let plugin): "Found in Claude's \(plugin) plugin"
            }
        }
    }
}

extension SkillState {
    /// The chip a row and the inspector header show; none while apps get it.
    /// A shared skill apps don't get reads Not Shared, with the attention
    /// symbol, because that is what apps see.
    @MainActor var chip: StateChip? {
        switch self {
        case .served:
            nil
        case .notShared:
            StateChip("Not Shared", role: .off)
        case .leftOut:
            StateChip("Not Shared", systemImage: StatusRole.attention.symbolName, role: .attention)
        case .refused:
            StateChip("Can't Share", systemImage: StatusRole.attention.symbolName, role: .attention)
        }
    }
}

/// A skill's row: icon, name, where it comes from, and a Shared switch that
/// behaves like a tool's. The chip and the line under the row say what apps
/// get (`SkillState`), not only where the switch is: a refused skill keeps
/// its switch off and says why, and a shared skill the catalog leaves out
/// says why apps don't get it.
struct SkillRowView: View {
    let skill: Skill
    let state: SkillState
    let error: String?
    let shareBinding: Binding<Bool>

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            // The name matters most: the row drops where the skill comes
            // from, then shows its chip as a symbol, before it shortens it.
            ViewThatFits(in: .horizontal) {
                line(showsOrigin: true, fullName: true, symbolOnly: false)
                line(showsOrigin: false, fullName: true, symbolOnly: false)
                line(showsOrigin: false, fullName: true, symbolOnly: true)
                line(showsOrigin: false, fullName: false, symbolOnly: true)
            }
            .opacity(state == .served ? 1 : 0.62)

            if let warning = state.warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .help(skill.originDescription)
    }

    private func line(showsOrigin: Bool, fullName: Bool, symbolOnly: Bool) -> some View {
        HStack(spacing: Space.s3) {
            SkillIcon()

            Text(skill.name)
                .lineLimit(1)
                .fixedSize(horizontal: fullName, vertical: false)

            if showsOrigin {
                Text(skill.originDescription)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }

            Spacer(minLength: 0)

            if let chip = state.chip {
                if symbolOnly {
                    chip.symbolOnly()
                } else {
                    chip
                }
            }

            Toggle("Share", isOn: shareBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(skill.refusal != nil)
                .accessibilityLabel("Share \(skill.name)")
        }
    }
}

/// The skill glyph, sized and tinted like a tool row's icon.
private struct SkillIcon: View {
    var body: some View {
        Image(systemName: "text.book.closed")
            .font(.callout)
            .foregroundStyle(.indigo)
            .frame(width: 24, height: 24)
            .background(Color.indigo.opacity(0.13), in: AppShape.mono)
            .accessibilityHidden(true)
    }
}

/// The inspector for a selected skill: what a connected app reads, exactly,
/// from `AppModel.skillPreview(_:)`. For a shared skill that is the served
/// copy (MacRemote's note included, and the new name if a clash renamed it);
/// for one that is not shared, what sharing it now would publish; for one
/// apps don't get, the reason and the files under a plain heading. Nothing
/// here edits the skill.
struct SkillInspector: View {
    @Environment(AppModel.self) private var appModel

    let skill: Skill

    var body: some View {
        let preview = appModel.skillPreview(skill)
        VStack(spacing: 0) {
            header(preview.state)
                .padding(Space.s4)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    Text(skill.originDescription)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)

                    if let warning = preview.warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if !skill.description.isEmpty {
                        // The skill's author wrote this, so it renders as
                        // plain text, never as Markdown (CLI-DISCOVERY R11).
                        Text(verbatim: skill.description)
                            .font(TypeRamp.rowDetail)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    KeyValueGrid(rows: detailRows(preview), onCopy: { row in
                        appModel.appendLog(level: .info, "Copied \(row.label) for the \(skill.name) skill.")
                    })

                    if !preview.files.isEmpty {
                        fileList(preview)
                    }
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(_ state: SkillState) -> some View {
        HStack(spacing: Space.s3) {
            SkillIcon()

            Text(skill.name)
                .font(TypeRamp.cardTitle)
                .lineLimit(1)

            Spacer()

            if let chip = state.chip {
                chip
            }
        }
    }

    private func detailRows(_ preview: SkillPreview) -> [KeyValueRow] {
        var rows = [KeyValueRow]()
        if let entry = preview.entry {
            // Not served yet: the name and address are what sharing gives it.
            let suffix = preview.state == .served ? "" : " When Shared"
            if case .string(let name)? = entry.frontmatter["name"], name != skill.name {
                rows.append(KeyValueRow("Name" + suffix, name))
            }
            rows.append(KeyValueRow("Address" + suffix, entry.uri))
        }
        if !preview.files.isEmpty {
            let bytes = preview.files.reduce(0) { $0 + $1.size }
            rows.append(KeyValueRow("Size", "\(bytes.formatted()) bytes in \(counted(preview.files.count, "file"))"))
        }
        switch skill.origin {
        case .builtIn:
            break
        case .bridgedServer(_, let serverName, _):
            rows.append(KeyValueRow("Server", serverName))
        case .foundOnDisk(_, _, let folder):
            rows.append(KeyValueRow("File", folder + "/" + Skill.skillFileName))
        }
        return rows
    }

    /// The preview's files, `SKILL.md` first and open, under a heading that
    /// says whether apps read them.
    private func fileList(_ preview: SkillPreview) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(preview.filesHeading)
                .font(TypeRamp.cardTitle)

            ForEach(preview.files) { file in
                DetailsDisclosure(
                    "\(file.path.removingPercentEncoding ?? file.path) · \(file.size.formatted()) bytes",
                    id: "skill.\(skill.id).\(file.path)",
                    initiallyExpanded: file.path == Skill.skillFileName
                ) {
                    Text(verbatim: file.text)
                        .machineText(TypeRamp.machineCaption)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s2)
                        .background(.quaternary.opacity(0.4), in: AppShape.mono)
                }
            }
        }
    }
}
