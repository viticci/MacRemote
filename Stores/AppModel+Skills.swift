import Foundation

/// Whether apps get a skill, as the Tools page shows it (SPEC D84). The Share
/// switch is the owner's choice; this is what the served catalog does with
/// that choice, so a shared skill the catalog leaves out never looks shared.
enum SkillState: Equatable {
    /// Shared, and apps get it.
    case served
    /// The owner has not shared it.
    case notShared
    /// Shared, but apps don't get it, for this reason (one sentence).
    case leftOut(String)
    /// It can't be shared, for this reason (`Skill.refusal`).
    case refused(String)

    /// The line under a skill's row: why apps don't get a skill that is
    /// shared but left out, or can't be shared. Nil otherwise.
    var warning: String? {
        switch self {
        case .served, .notShared: nil
        case .leftOut(let reason): "Apps don't get this skill. \(reason)"
        case .refused(let reason): reason
        }
    }
}

/// What the skill inspector shows (SPEC D84), computed by the same catalog
/// code that serves.
struct SkillPreview {
    struct File: Identifiable {
        /// As the skill's address spells it (`Skill.File.path`).
        let path: String
        let text: String
        let size: Int

        var id: String { path }
    }

    let state: SkillState
    /// What apps read: the served entry for a shared skill, and for one that
    /// is not shared, the entry sharing it now would publish (its name,
    /// address, and bytes). Nil when apps don't or wouldn't get it.
    let entry: ServedSkillCatalog.Entry?
    /// For a skill that is not shared: why sharing it now would still leave
    /// it out. Nil otherwise.
    let omissionIfShared: String?
    /// The files listed under `filesHeading`: the entry's bytes when there is
    /// an entry, otherwise the skill's files as MacRemote holds them (none
    /// for a refused skill).
    let files: [File]

    /// The heading over `files`, true in each state: only bytes apps read,
    /// or would read once shared, are called that.
    var filesHeading: String {
        switch state {
        case .served: "What Apps Read"
        case .notShared where entry != nil: "What Apps Would Read"
        case .notShared, .leftOut, .refused: "Files"
        }
    }

    /// The warning under the inspector header, or nil.
    var warning: String? {
        if case .notShared = state, let omissionIfShared {
            return "If you share it, apps still won't get it. \(omissionIfShared)"
        }
        return state.warning
    }
}

/// Skills over MCP (SPEC D84): what the Skills UI binds to. `knownSkills`
/// lists every skill with its origin, name, description, size, and any
/// refusal; these add the Shared flag, the way to set it, what an app gets,
/// and the look for skills already on this Mac.
extension AppModel {
    /// True when the owner shares this skill and it has no refusal: the Share
    /// switch. A shared skill can still be left out of what apps get; see
    /// `skillState(_:)`.
    func isSkillShared(_ skill: Skill) -> Bool {
        skill.refusal == nil && skillSharing.isShared(skill)
    }

    /// Saves the owner's Shared choice. Returns why it cannot be made, or nil.
    @discardableResult
    func setSkillShared(_ skill: Skill, isShared: Bool) -> String? {
        if isShared {
            if let refusal = skill.refusal {
                return "Can't share \(skill.name): \(refusal)"
            }
            let othersShared = knownSkills.count { $0.id != skill.id && isSkillShared($0) }
            if othersShared >= ServedSkillCatalog.maximumSkills {
                return "Apps load at most \(ServedSkillCatalog.maximumSkills) skills from MacRemote. Turn one off first."
            }
        }
        skillSharing.choices[skill.id] = isShared
        return nil
    }

    /// Whether apps get `skill` right now, from the catalog the server
    /// serves. The row, the section's shared count, the filters, and the
    /// inspector header all show this.
    func skillState(_ skill: Skill) -> SkillState {
        if let refusal = skill.refusal { return .refused(refusal) }
        guard skillSharing.isShared(skill) else { return .notShared }
        let catalog = skillRegistry.servedCatalog(sharing: skillSharing)
        if catalog.entries.contains(where: { $0.skillID == skill.id }) { return .served }
        return .leftOut(catalog.omissions[skill.id] ?? Self.unlistedSkillOmission)
    }

    /// What the inspector shows for `skill`. For one that is not shared, the
    /// catalog is built as if the owner shared it now, beside every skill
    /// already shared, so the preview carries the name, address, and bytes
    /// sharing would publish, or the reason sharing would still leave it out.
    func skillPreview(_ skill: Skill) -> SkillPreview {
        let state = skillState(skill)
        var entry: ServedSkillCatalog.Entry?
        var omissionIfShared: String?
        switch state {
        case .served:
            entry = skillRegistry.servedCatalog(sharing: skillSharing).entries.first { $0.skillID == skill.id }
        case .notShared:
            var sharing = skillSharing
            sharing.choices[skill.id] = true
            let catalog = skillRegistry.catalog(sharing: sharing)
            entry = catalog.entries.first { $0.skillID == skill.id }
            if entry == nil {
                omissionIfShared = catalog.omissions[skill.id] ?? Self.unlistedSkillOmission
            }
        case .leftOut, .refused:
            break
        }
        // The catalog serves a skill's files in order, at `<root><path>`.
        let files = entry.map { entry in
            let root = entry.uri.dropLast(Skill.skillFileName.count)
            return entry.files.map { SkillPreview.File(path: String($0.uri.dropFirst(root.count)), text: $0.text, size: $0.size) }
        } ?? skill.files.map {
            SkillPreview.File(path: $0.path, text: String(decoding: $0.data, as: UTF8.self), size: $0.data.count)
        }
        return SkillPreview(state: state, entry: entry, omissionIfShared: omissionIfShared, files: files)
    }

    /// The reason for a skill the registry does not hold, such as a stale
    /// copy a view kept after its family's tools were removed.
    private static let unlistedSkillOmission = "MacRemote no longer lists this skill."

    /// Rebuilds `knownSkills` from the current tools: a bridged or found
    /// skill follows its family's tools, and is dropped when they are removed.
    /// Notes name only the tools the server lists to apps (the tool surface),
    /// so this runs again whenever sharing changes (`syncRunningToolSurface`).
    func refreshKnownSkills() {
        knownSkills = skillRegistry.rebuild(
            tools: tools,
            sharedToolIDs: Set(toolSurfaceRuntime.toolsSnapshot().map(\.id)),
            pruning: true
        )
    }

    /// Saves the skills a probe read from a server whose tools were just
    /// imported or refreshed. They start Not Shared. A quiet first-party
    /// import passes `announce: false` and folds a change into its own one
    /// Activity line (D86). Returns true when the saved skills changed.
    @discardableResult
    func recordBridgedSkills(_ skills: [MCPUpstreamSkill], importedTools: [ToolDefinition], announce: Bool = true) -> Bool {
        guard let tool = importedTools.first else { return false }
        let family = ToolFamily(tool)
        var changed = false
        do {
            changed = try skillRegistry.replaceBridgedSkills(skills, familyID: family.id, serverName: family.name)
        } catch {
            appendLog(level: .warning, "Could not save the skills of \(family.name): \(error.localizedDescription)")
        }
        refreshKnownSkills()
        if announce, !skills.isEmpty {
            appendLog(level: .info, "\(family.name) offers \(counted(skills.count, "skill")). Each one is Not Shared until you share it.")
        }
        return changed
    }

    /// Looks for skills already on this Mac for the families of the current
    /// tools (`FoundSkillScanner`). MacRemote calls it at launch and when the
    /// owner scans for tools, never because an app asked. Found skills start
    /// Not Shared. The log carries a count, never names.
    @discardableResult
    func refreshFoundSkills() -> Task<Void, Never> {
        let scanner = foundSkillScanner
        let families = FoundSkillScanner.families(of: tools)
        return Task {
            let found = await Task.detached(priority: .utility) {
                scanner.scan(families: families)
            }.value
            skillRegistry.replaceFoundSkills(found)
            refreshKnownSkills()
            if !found.isEmpty {
                appendLog(
                    level: .info,
                    "Found \(counted(found.count, "skill")) on this Mac for your tools. Each one is Not Shared until you share it."
                )
            }
        }
    }
}
