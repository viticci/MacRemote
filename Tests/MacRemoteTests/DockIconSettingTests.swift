import Foundation
import Testing
@testable import MacRemote

/// D89: the Dock icon can be hidden, but never together with the menu bar
/// icon, because the app would then have no way back in.
@MainActor
struct DockIconSettingTests {
    @Test func dockAndMenuBarIconsAreNeverBothOff() throws {
        let suite = "MacRemoteDockIconSettingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ToolRegistryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("tools.json"))

        defaults.set(false, forKey: "MacRemote.menuBarExtraEnabled")
        let model = makeTestAppModel(userDefaults: defaults, toolStore: store)
        #expect(model.isDockIconEnabled)

        model.isDockIconEnabled = false
        #expect(model.isMenuBarExtraEnabled)

        // Removing the menu bar icon (Command-drag) brings the Dock icon back.
        model.isMenuBarExtraEnabled = false
        #expect(model.isDockIconEnabled)

        model.isDockIconEnabled = false
        let reloaded = makeTestAppModel(userDefaults: defaults, toolStore: store)
        #expect(!reloaded.isDockIconEnabled)
        #expect(reloaded.isMenuBarExtraEnabled)
    }
}
