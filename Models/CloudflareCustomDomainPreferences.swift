import Foundation

/// Only the address and resource identity survive relaunch here. The API
/// token stays session-only. The tunnel's run token is the one saved secret,
/// and it lives in the Keychain (`CloudflareRunTokenStore`), never in these
/// preferences. Restoring this value never starts or deploys a public link.
struct CloudflareCustomDomainPreferences: Codable, Equatable, Sendable {
    static let defaultsKey = "MacRemote.cloudflare.customDomain"

    var selectedZoneID: String?
    var subdomain: String
    var deployment: CloudflareCustomDomainIdentity?

    init(draft: CloudflareCustomDomainDraft, deployment: CloudflareCustomDomainIdentity?) {
        selectedZoneID = draft.selectedZoneID
        subdomain = draft.subdomain
        self.deployment = deployment
    }

    var draft: CloudflareCustomDomainDraft {
        CloudflareCustomDomainDraft(selectedZoneID: selectedZoneID, subdomain: subdomain, apiToken: "")
    }

    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else {
            // A missing or damaged preference must require an explicit address,
            // not quietly select another Mac's conventional "macremote" host.
            return Self(draft: CloudflareCustomDomainDraft(), deployment: nil)
        }
        return saved
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

struct CloudflareCustomDomainIdentity: Codable, Equatable, Sendable {
    let zoneID: String
    let accountID: String
    let hostname: String
    let tunnelID: String
    /// The zone's name, so the app can tell without asking Cloudflare whether
    /// the owner still has this address chosen. Missing from preferences
    /// saved before the run token was kept; those need one more deploy.
    let zoneName: String?
    /// The port of MacRemote's local server when the domain was deployed.
    /// Cloudflare's copy of the tunnel's settings sends requests to this
    /// port, so the saved run token is only useful while the server is on it.
    let localPort: Int?

    init(deployment: CloudflareCustomDomainDeployment) {
        zoneID = deployment.zone.id
        accountID = deployment.zone.accountID
        hostname = deployment.hostname
        tunnelID = deployment.tunnelID
        zoneName = deployment.zone.name
        localPort = deployment.localPort
    }

    func matches(zone: CloudflareZone, subdomain: String) -> Bool {
        zoneID == zone.id && accountID == zone.accountID &&
            hostname == (try? CloudflareService.hostname(subdomain: subdomain, zoneName: zone.name))
    }

    /// True while the address in the Your Domain form is still this deployed
    /// one. An empty domain choice counts as unchanged: the app clears the
    /// choice by itself when a domain list fails to load, and that must not
    /// throw away a working link.
    func isChosen(by draft: CloudflareCustomDomainDraft) -> Bool {
        guard let zoneName, draft.selectedZoneID == nil || draft.selectedZoneID == zoneID else {
            return false
        }
        return hostname == (try? CloudflareService.hostname(subdomain: draft.subdomain, zoneName: zoneName))
    }
}

extension CloudflareCustomDomainDeployment {
    /// Rebuilds what a deploy returned from what was saved, so a deployed
    /// domain can go public again without asking Cloudflare for anything.
    /// Fails for preferences saved before the port and zone name were kept,
    /// and for a saved hostname that is not a plain host name.
    init?(saved: CloudflareCustomDomainIdentity, tunnelToken: String) {
        guard let zoneName = saved.zoneName,
              let localPort = saved.localPort,
              URL(string: "https://\(saved.hostname)")?.host() == saved.hostname else {
            return nil
        }
        self.init(
            zone: CloudflareZone(id: saved.zoneID, name: zoneName, accountID: saved.accountID, accountName: ""),
            hostname: saved.hostname,
            tunnelID: saved.tunnelID,
            tunnelName: CloudflareService.tunnelName(hostname: saved.hostname),
            tunnelToken: tunnelToken,
            localPort: localPort
        )
    }
}
