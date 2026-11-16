import Foundation

/// D76 — whether MacRemote may make a deployed Your Domain public by itself
/// when it opens. The owner confirmed the public link once, for one hostname,
/// in Settings › General. This answers the same question twice per launch:
/// before the local server starts (`server: .notStarted`) and after.
///
/// It never answers yes for an Instant Link: only a deployed Your Domain has
/// a stable address and a saved key, so only it can be confirmed ahead of time.
struct GoPublicAtLaunchCheck: Equatable, Sendable {
    enum Server: Equatable, Sendable {
        case notStarted
        case running(port: Int)
        case failed(String)
    }

    /// The hostname the owner confirmed. Nil while the setting is off.
    var confirmedHostname: String?
    var hasCompletedWelcome: Bool
    /// True when Your Domain, not Instant Link, is this Mac's chosen address.
    var prefersYourDomain: Bool
    /// The deployed Your Domain the Address card still has chosen.
    var chosenDeployedHostname: String?
    /// True when the Keychain holds a run token for that deployment, so it
    /// can go public without Cloudflare credentials.
    var hasSavedKey: Bool
    /// The local port Cloudflare sends the tunnel's requests to.
    var deployedPort: Int?
    var sharedToolCount: Int
    var server: Server

    var decision: GoPublicAtLaunchDecision {
        guard let confirmed = confirmedHostname else { return .off }
        guard hasCompletedWelcome else { return .blocked(.welcomeNotFinished) }
        guard prefersYourDomain else { return .blocked(.yourDomainNotChosen(confirmed: confirmed)) }
        guard let chosen = chosenDeployedHostname else { return .blocked(.notDeployed(confirmed: confirmed)) }
        guard chosen == confirmed else {
            return .blocked(.domainChanged(confirmed: confirmed, current: chosen))
        }
        guard hasSavedKey, let deployedPort else { return .blocked(.noSavedKey(hostname: confirmed)) }
        guard sharedToolCount > 0 else { return .blocked(.noSharedTools) }

        switch server {
        case .notStarted:
            return .startServer
        case .failed(let reason):
            return .blocked(.serverFailed(reason))
        case .running(let port):
            guard port == deployedPort else { return .blocked(.portTaken(port: deployedPort)) }
            return .goPublic(hostname: confirmed)
        }
    }
}

enum GoPublicAtLaunchDecision: Equatable, Sendable {
    /// The setting is off. Nothing happens and nothing is reported.
    case off
    /// Everything about the domain checks out; start the local server next.
    case startServer
    case goPublic(hostname: String)
    /// The setting is on but cannot run. Nothing goes public, and the owner
    /// is told why in Activity and in a notification.
    case blocked(GoPublicAtLaunchBlock)
}

enum GoPublicAtLaunchBlock: Equatable, Sendable {
    case welcomeNotFinished
    case yourDomainNotChosen(confirmed: String)
    case notDeployed(confirmed: String)
    case domainChanged(confirmed: String, current: String)
    case noSavedKey(hostname: String)
    case noSharedTools
    case serverFailed(String)
    case portTaken(port: Int)
    /// Cloudflare's helper refused to start. Reported by the app, not by
    /// `GoPublicAtLaunchCheck`, because it is only known after the attempt.
    case linkFailed(String)

    /// One sentence for Activity and the notification body: what stopped it
    /// and what to do.
    var reason: String {
        switch self {
        case .welcomeNotFinished:
            "Finish the Welcome steps first."
        case .yourDomainNotChosen(let confirmed):
            "Your Domain is no longer this Mac's address, and an Instant Link never goes public by itself. The setting is for \(confirmed)."
        case .notDeployed(let confirmed):
            "\(confirmed) isn't deployed now. Deploy it from Address, then turn the setting on again."
        case .domainChanged(let confirmed, let current):
            "It was turned on for \(confirmed), and your address is now \(current). Turn it on again in Settings › General to use the new address."
        case .noSavedKey(let hostname):
            "The saved key for \(hostname) is missing. Deploy your domain again from Address."
        case .noSharedTools:
            "No tools are shared. Share at least one tool in Tools."
        case .serverFailed(let detail):
            "The local server didn't start: \(detail)"
        case .portTaken(let port):
            "Port \(port) is in use, so your domain must be deployed again from Address."
        case .linkFailed(let detail):
            "Cloudflare's helper didn't start: \(detail)"
        }
    }
}
