import Foundation
import Testing
@testable import MacRemote

@Suite("Iris semantic catalog")
struct IrisToolCatalogTests {
    private static let dedicatedIDs = [
        "preset.iris.battery",
        "preset.iris.now_playing",
        "preset.iris.calendar_day",
        "preset.iris.alarms",
        "preset.iris.alarm_set",
        "preset.iris.timer_start",
        "preset.iris.open_url",
        "preset.iris.message_compose",
        "preset.iris.actions",
        "preset.iris.action_schema",
        "preset.iris.doctor"
    ]

    private static let writeIDs: Set<String> = [
        "preset.iris.alarm_set",
        "preset.iris.timer_start",
        "preset.iris.open_url",
        "preset.iris.message_compose"
    ]

    private static let localManifestIDs: Set<String> = [
        "preset.iris.actions",
        "preset.iris.action_schema"
    ]

    @Test(
        "Catalog exposes the exact sparse provider surface",
        .enabled(if: IrisToolPresetCatalog.detectedExecutablePath != nil, "Iris is not installed on this Mac.")
    )
    func exactSurface() throws {
        let presets = IrisToolPresetCatalog.presets
        #expect(presets.map(\.id) == Self.dedicatedIDs + ["preset.iris.run"])
        #expect(presets.map(\.toolID) == [
            "iris_battery",
            "iris_now_playing",
            "iris_calendar_day",
            "iris_alarms",
            "iris_alarm_set",
            "iris_timer_start",
            "iris_open_url",
            "iris_message_compose",
            "iris_actions",
            "iris_action_schema",
            "iris_doctor",
            "iris_run"
        ])
        #expect(presets.allSatisfy { $0.category == .iphone })
        #expect(presets.allSatisfy { $0.permissionRequirements.isEmpty })
        #expect(presets.allSatisfy { $0.widgetPresentation == nil })
        #expect(presets.allSatisfy { $0.uiActions == nil })
        #expect(presets.allSatisfy { $0.publisher == .federicoViticci })

        let capabilities: [String: ToolCapability] = [
            "preset.iris.battery": .readOnly,
            "preset.iris.now_playing": .readOnly,
            "preset.iris.calendar_day": .readOnly,
            "preset.iris.alarms": .readOnly,
            "preset.iris.alarm_set": .write,
            "preset.iris.timer_start": .write,
            "preset.iris.open_url": .write,
            "preset.iris.message_compose": .write,
            "preset.iris.actions": .readOnly,
            "preset.iris.action_schema": .readOnly,
            "preset.iris.doctor": .readOnly,
            "preset.iris.run": .destructive
        ]
        for preset in presets {
            #expect(preset.capability == capabilities[preset.id], "\(preset.id) capability")
        }

        #expect(presets.filter { $0.approvalPolicy == .everyCall }.map(\.id) == ["preset.iris.run"])
        let run = try #require(presets.first { $0.id == "preset.iris.run" })
        #expect(run.mode == .cliAdapter)
        #expect(run.argumentPattern == ["{args}"])
        #expect(run.processInvocation == nil)
        #expect(run.timeoutSeconds == 600)
        #expect(run.outputLimitKB == 64 * 1024)

        for preset in presets where preset.id != "preset.iris.run" {
            #expect(preset.mode == .commandTemplate)
            #expect(preset.timeoutSeconds == 60)
            #expect(preset.outputLimitKB == 8192)
            #expect(preset.approvalPolicy == .standard)
        }

        for preset in presets {
            if Self.writeIDs.contains(preset.id) {
                #expect(preset.processInvocation?.preflightSuffix == ["--dry-run", "--offline"])
                #expect(preset.processInvocation?.preflightRemovingArguments == nil)
            } else {
                #expect(preset.processInvocation?.preflightSuffix == nil)
            }
        }

        for preset in presets {
            if Self.localManifestIDs.contains(preset.id) {
                #expect(preset.annotationOverrides?.openWorldHint == false)
            } else {
                #expect(preset.annotationOverrides?.openWorldHint == true)
            }
            #expect(preset.annotationOverrides?.idempotentHint == nil)
        }

        #expect(DefaultToolPresetCatalog.appGroups(in: .iphone).contains {
            $0.id == "provider.iris" && $0.presets == presets
        })
    }

    @Test(
        "Typed recipes lower through the real resolver",
        .enabled(if: IrisToolPresetCatalog.detectedExecutablePath != nil, "Iris is not installed on this Mac.")
    )
    func argumentLowering() throws {
        #expect(try arguments("timer_start", [
            "duration": .string("10m")
        ]) == ["timer", "start", "10m", "--json"])

        #expect(try arguments("calendar_day", [
            "day": .string("tomorrow"),
            "limit": .json(.number(5))
        ]) == ["calendar", "tomorrow", "--limit", "5", "--json"])

        #expect(try arguments("message_compose", [
            "to": .string("Ada"),
            "body": .string("Hi")
        ]) == ["messages", "compose", "--to", "Ada", "--body", "Hi", "--json"])

        #expect(try arguments("battery") == ["device", "battery", "get", "--json"])
        #expect(try arguments("alarm_set", [
            "time": .string("07:30"),
            "label": .string("Wake")
        ]) == ["alarm", "set", "07:30", "--label", "Wake", "--json"])
        #expect(try arguments("open_url", [
            "url": .string("https://example.com")
        ]) == ["url", "open", "https://example.com", "--json"])
        #expect(try arguments("action_schema", [
            "action_id": .string("device.battery.get")
        ]) == ["actions", "schema", "device.battery.get", "--json"])
    }

    private func arguments(
        _ suffix: String,
        _ parameters: [String: ToolArgumentValue] = [:]
    ) throws -> [String] {
        let preset = try #require(
            IrisToolPresetCatalog.presets.first { $0.id == "preset.iris.\(suffix)" }
        )
        let tool = try preset.draft.makeTool(id: preset.toolID)
        return try ToolArgumentResolver.arguments(for: tool, parameters: parameters)
    }
}
