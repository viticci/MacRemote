import Foundation
import Testing
@testable import MacRemote

/// Round 2 of the MCP UI work gave the habits and podcasts catalogs their
/// first widget affordances. These tests pin the action shapes, the exact
/// set of tools that carry them, and — the part the RemCTL `--json` bug
/// taught us — the argv each action actually composes, so a rename in a
/// catalog can never quietly produce a button that no-ops.
struct HabitCatalogUIActionTests {
    @Test func checkOffTargetsTheRecordResultToolWithJournalFields() throws {
        let actions = HabitCTLToolPresetCatalog.habitRowUIActions
        #expect(actions.count == 1)

        let checkOff = try #require(actions.first)
        #expect(checkOff.id == "check_off")
        #expect(checkOff.title == "Check Off")
        #expect(checkOff.kind == .checkOff)
        #expect(checkOff.toolID == "habitctl_record_result")
        #expect(checkOff.targetExecutableBasename == nil)
        #expect(checkOff.arguments == .object([
            "habit": .string("{id}"),
            "result": .string("completed")
        ]))
        #expect(checkOff.requiredRowFields == ["id"])
        // Journal rows carry `status`; the filled circle reads it directly.
        #expect(checkOff.completedWhenField == "status")
        #expect(checkOff.completedWhenEquals == "completed")
        #expect(checkOff.style == nil)
        #expect(checkOff.inputs == nil)
    }

    @Test func onlyHabitShapedReadToolsCarryTheCheckOff() throws {
        let presets = HabitCTLToolPresetCatalog.presets
        try #require(!presets.isEmpty, "habitctl is not installed on this machine")

        let expected = HabitCTLToolPresetCatalog.habitRowUIActions
        let carrying = Set(presets.filter { $0.uiActions?.isEmpty == false }.map(\.id))
        #expect(carrying == [
            "preset.habitctl.today",
            "preset.habitctl.search",
            "preset.habitctl.show"
        ])
        for preset in presets where carrying.contains(preset.id) {
            #expect(preset.uiActions == expected)
        }
        // The write tools and the flexible command answer with confirmations,
        // not rows — an action there would render on nothing.
        for preset in presets where !carrying.contains(preset.id) {
            #expect(preset.uiActions == nil)
        }
    }

    @Test func checkOffComposesTheArgvHabitCTLParses() throws {
        let presets = HabitCTLToolPresetCatalog.presets
        try #require(!presets.isEmpty, "habitctl is not installed on this machine")

        let action = try #require(HabitCTLToolPresetCatalog.habitRowUIActions.first)
        let argv = try composedArguments(
            for: action,
            row: ["id": "-OwFKFbgUqv0T0pR37dr"],
            in: presets
        )
        // Smoke-tested live against habitctl with `--dry-run` appended:
        // `check <id> --date today --json --dry-run` → intent.action "complete".
        #expect(argv == ["check", "-OwFKFbgUqv0T0pR37dr", "--date", "today", "--json"])
    }
}

struct PodcastCatalogUIActionTests {
    @Test func dedicatedPocketToolsCarryCatalogAuthoredEpisodePresentation() throws {
        let presets = PocketCTLToolPresetCatalog.presets
        try #require(!presets.isEmpty, "pocketctl is not installed on this machine")
        let expected = ToolWidgetPresentation(profile: .episodeRows, accent: "#f43e37")

        for preset in presets where preset.id != "preset.pocketctl.run" {
            #expect(preset.widgetPresentation == expected, "\(preset.id) must carry the PocketCTL presentation")
        }
        #expect(presets.first { $0.id == "preset.pocketctl.run" }?.widgetPresentation == nil)
    }

    @Test func episodeActionsAreOrderedRowButtonsTargetingTheWriteTools() {
        let actions = PocketCTLToolPresetCatalog.episodeRowUIActions
        #expect(actions.map(\.id) == ["play_next", "play_last", "star", "archive"])
        #expect(actions.map(\.title) == ["Play Next", "Play Last", "Star", "Archive"])
        #expect(actions.allSatisfy { $0.kind == .rowButton })
        #expect(actions.allSatisfy { $0.requiredRowFields == ["uuid"] })
        #expect(actions.allSatisfy { $0.completedWhenField == nil })
        #expect(actions.allSatisfy { $0.inputs == nil })
        // Archive is reversible (`unarchive`), so nothing here arms the
        // widget's two-step destructive confirm.
        #expect(actions.allSatisfy { $0.style == nil })

        #expect(actions.map(\.toolID) == [
            "pocketctl_change_up_next",
            "pocketctl_change_up_next",
            "pocketctl_update_state",
            "pocketctl_update_state"
        ])
        #expect(actions.map(\.arguments) == [
            .object(["episode_uuid": .string("{uuid}"), "placement": .string("next")]),
            .object(["episode_uuid": .string("{uuid}"), "placement": .string("last")]),
            .object(["episode_uuid": .string("{uuid}"), "state": .string("starred")]),
            .object(["episode_uuid": .string("{uuid}"), "state": .string("archived")])
        ])
    }

    @Test func onlyOwnedEpisodeResultsCarryTheRowButtons() throws {
        let presets = PocketCTLToolPresetCatalog.presets
        try #require(!presets.isEmpty, "pocketctl is not installed on this machine")

        let expected = PocketCTLToolPresetCatalog.episodeRowUIActions
        let carrying = Set(presets.filter { $0.uiActions?.isEmpty == false }.map(\.id))
        // search_online is deliberately absent: its rows mix podcast records
        // (which also have a `uuid`) with episodes nobody is subscribed to.
        #expect(carrying == ["preset.pocketctl.triage", "preset.pocketctl.show"])
        for preset in presets where carrying.contains(preset.id) {
            #expect(preset.uiActions == expected)
        }
        for preset in presets where !carrying.contains(preset.id) {
            #expect(preset.uiActions == nil)
        }
    }

    @Test func episodeActionsComposeTheArgvPocketCTLParses() throws {
        let presets = PocketCTLToolPresetCatalog.presets
        try #require(!presets.isEmpty, "pocketctl is not installed on this machine")

        let uuid = "e3d202f8-5dc3-4eaf-bd3e-1ad19bd5442d"
        let argv = try PocketCTLToolPresetCatalog.episodeRowUIActions.map {
            try composedArguments(for: $0, row: ["uuid": uuid], in: presets)
        }
        // Each one smoke-tested live with `--dry-run` appended (the preflight
        // the executor runs before any real write).
        #expect(argv == [
            ["play-next", uuid, "--json"],
            ["play-last", uuid, "--json"],
            ["star", uuid, "--json"],
            ["archive", uuid, "--json"]
        ])
    }
}

/// Both catalogs at once: an action is only useful if its target exists,
/// its argument keys are real parameters, its literal values pass the
/// target's `allowedValues`, and every `{placeholder}` it substitutes is a
/// field the action already requires the row to have.
struct CatalogUIActionTargetIntegrityTests {
    @Test func everyActionResolvesAgainstItsOwnCatalog() throws {
        let presets = HabitCTLToolPresetCatalog.presets + PocketCTLToolPresetCatalog.presets
        try #require(!presets.isEmpty, "neither habitctl nor pocketctl is installed")

        for preset in presets {
            for action in preset.uiActions ?? [] {
                let toolID = try #require(action.toolID, "\(action.id) must target a semantic tool id")
                let target = try #require(
                    presets.first { $0.toolID == toolID },
                    "\(action.id) targets missing tool \(toolID)"
                )
                let parameters = try #require(target.parameters)
                guard case .object(let arguments) = action.arguments else {
                    Issue.record("\(action.id) arguments must be an object")
                    continue
                }

                for (key, value) in arguments {
                    let schema = try #require(
                        parameters.first { $0.name == key },
                        "\(toolID) has no parameter \(key)"
                    )
                    guard case .string(let raw) = value else { continue }
                    if raw.hasPrefix("{"), raw.hasSuffix("}") {
                        let field = String(raw.dropFirst().dropLast())
                        #expect(
                            action.requiredRowFields.contains(field),
                            "\(action.id) substitutes {\(field)} without requiring it on the row"
                        )
                    } else if let allowed = schema.allowedValues {
                        #expect(allowed.contains(raw), "\(toolID).\(key) rejects \(raw)")
                    }
                }

                for parameter in parameters where parameter.required {
                    #expect(
                        arguments[parameter.name] != nil,
                        "\(action.id) omits required \(toolID).\(parameter.name)"
                    )
                }
            }
        }
    }
}

/// The argv a widget button really produces: substitute the row fields the
/// way the widget does, then run the value through the same resolver the
/// executor uses. The executor appends the tool's `preflightSuffix`
/// (`--dry-run`) for the preflight run and nothing else.
private func composedArguments(
    for action: ToolUIAction,
    row: [String: String],
    in presets: [DefaultToolPreset]
) throws -> [String] {
    let toolID = try #require(action.toolID)
    let preset = try #require(presets.first { $0.toolID == toolID })
    let tool = try preset.draft.makeTool(id: preset.toolID)

    guard case .object(let arguments) = action.arguments else {
        throw ToolValidationError.invalidArgument("action arguments must be an object")
    }
    var resolved: [String: String] = [:]
    for (key, value) in arguments {
        guard case .string(let raw) = value else {
            throw ToolValidationError.invalidArgument(key)
        }
        if raw.hasPrefix("{"), raw.hasSuffix("}") {
            let field = String(raw.dropFirst().dropLast())
            resolved[key] = try #require(row[field], "row is missing \(field)")
        } else {
            resolved[key] = raw
        }
    }
    return try ToolArgumentResolver.arguments(for: tool, stringParameters: resolved)
}
