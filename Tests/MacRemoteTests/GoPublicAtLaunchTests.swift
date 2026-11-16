import Foundation
import Testing
@testable import MacRemote

/// D76: Go Public at Launch makes a public link with no confirmation at the
/// Mac, so it may run only for the exact deployed Your Domain the owner
/// confirmed, and every other case must say why it did nothing.
struct GoPublicAtLaunchTests {
    /// A launch where everything lines up, before the server starts.
    private static let ready = GoPublicAtLaunchCheck(
        confirmedHostname: "mac.example.com",
        hasCompletedWelcome: true,
        prefersYourDomain: true,
        chosenDeployedHostname: "mac.example.com",
        hasSavedKey: true,
        deployedPort: 54_900,
        sharedToolCount: 3,
        server: .notStarted
    )

    private static func ready(_ change: (inout GoPublicAtLaunchCheck) -> Void) -> GoPublicAtLaunchCheck {
        var check = ready
        change(&check)
        return check
    }

    @Test func goesPublicOnlyAfterTheServerIsUpOnTheDeployedPort() {
        #expect(Self.ready.decision == .startServer)
        #expect(Self.ready { $0.server = .running(port: 54_900) }.decision == .goPublic(hostname: "mac.example.com"))
    }

    @Test func offDoesNothingAndReportsNothing() {
        // Off wins over every other condition, so a fresh install stays quiet.
        let check = Self.ready {
            $0.confirmedHostname = nil
            $0.hasCompletedWelcome = false
            $0.prefersYourDomain = false
        }
        #expect(check.decision == .off)
    }

    @Test(arguments: [
        (ready { $0.hasCompletedWelcome = false }, GoPublicAtLaunchBlock.welcomeNotFinished),
        (ready { $0.prefersYourDomain = false }, .yourDomainNotChosen(confirmed: "mac.example.com")),
        (ready { $0.chosenDeployedHostname = nil }, .notDeployed(confirmed: "mac.example.com")),
        (
            ready { $0.chosenDeployedHostname = "other.example.com" },
            .domainChanged(confirmed: "mac.example.com", current: "other.example.com")
        ),
        (ready { $0.hasSavedKey = false }, .noSavedKey(hostname: "mac.example.com")),
        // Preferences saved before the port was kept cannot resume either.
        (ready { $0.deployedPort = nil }, .noSavedKey(hostname: "mac.example.com")),
        (ready { $0.sharedToolCount = 0 }, .noSharedTools),
    ])
    func blocksBeforeStartingAnything(_ check: GoPublicAtLaunchCheck, expected: GoPublicAtLaunchBlock) {
        #expect(check.decision == .blocked(expected))
    }

    @Test func blocksWhenTheServerFailsOrLandsOnAnotherPort() {
        #expect(Self.ready { $0.server = .failed("Port busy") }.decision == .blocked(.serverFailed("Port busy")))
        // Cloudflare sends this tunnel's requests to the deployed port only.
        #expect(Self.ready { $0.server = .running(port: 55_001) }.decision == .blocked(.portTaken(port: 54_900)))
    }

    /// An Instant Link gets a new random address every time, so there is
    /// nothing the owner could have confirmed ahead of time.
    @MainActor
    @Test func anInstantLinkCannotTurnItOn() throws {
        let suite = "MacRemoteTests.GoPublicAtLaunch.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("instantLink", forKey: "MacRemote.addressMode")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: directory.appendingPathComponent("tools.json"))
        )

        #expect(model.goPublicAtLaunchCandidateHostname == nil)
        model.turnOnGoPublicAtLaunch()
        #expect(model.goPublicAtLaunchHostname == nil)
        #expect(defaults.string(forKey: "MacRemote.goPublicAtLaunch.hostname") == nil)
    }
}
