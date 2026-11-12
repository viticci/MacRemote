import Foundation
import Testing
@testable import MacRemote

// CloudflareURLProtocolMock keeps install()/requestedPaths() state in class-level
// statics shared by every test below, so the suite must run serially (XCTest's
// serial-by-class runner hid this; Swift Testing runs tests in parallel by default).
@Suite(.serialized)
struct CloudflareServiceTests {
    @Test func hostnameNormalizesSubdomain() throws {
        #expect(
            try CloudflareService.hostname(subdomain: "  MacRemote-Home  ", zoneName: "example.com") ==
            "macremote-home.example.com"
        )
    }

    @Test func hostnameRejectsInvalidSubdomain() {
        #expect(throws: CloudflareServiceError.invalidSubdomain) { try CloudflareService.hostname(subdomain: "-macremote", zoneName: "example.com") }
        #expect(CloudflareService.isValidSubdomain("macremote_iphone") == false)
        #expect(CloudflareService.isValidSubdomain("macremote-") == false)
        #expect(CloudflareService.isValidSubdomain("") == false)
    }

    @Test func subdomainAcceptsOnlyASCIILettersDigitsAndHyphens() {
        #expect(CloudflareService.isValidSubdomain("MacRemote-01.home"))
        #expect(CloudflareService.isValidSubdomain("xn--caf-dma"))
        for invalid in ["café", "macremote²", "١٢٣", "mac remote", "a..b", ".a", "a.", "*"] {
            #expect(CloudflareService.isValidSubdomain(invalid) == false, "\(invalid)")
        }
        // The Kelvin sign lowercases to an ordinary "k". It is refused as
        // typed instead of quietly becoming a different name.
        #expect(throws: CloudflareServiceError.invalidSubdomain) {
            try CloudflareService.hostname(subdomain: "mac\u{212A}", zoneName: "example.com")
        }
    }

    @Test func subdomainLabelsHoldAtMost63Characters() {
        #expect(CloudflareService.isValidSubdomain(String(repeating: "a", count: 63)))
        #expect(CloudflareService.isValidSubdomain(String(repeating: "a", count: 64)) == false)
    }

    @Test func hostnameHoldsAtMost253Characters() throws {
        // Four 49-character labels and the dots between them, then the zone.
        let zone = "example.com"
        let labels = Array(repeating: String(repeating: "a", count: 49), count: 4).joined(separator: ".")
        let longest = labels + "." + String(repeating: "b", count: 253 - labels.count - zone.count - 2)
        #expect(try CloudflareService.hostname(subdomain: longest, zoneName: zone).count == 253)
        #expect(throws: CloudflareServiceError.invalidSubdomain) {
            try CloudflareService.hostname(subdomain: longest + "b", zoneName: zone)
        }
    }

    @Test func zoneListFollowsEveryPage() async throws {
        func zone(_ name: String) -> [String: Any] {
            ["id": "id-\(name)", "name": name, "account": ["id": "account-id", "name": "Example"]]
        }
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/zones", result: [zone("b.example"), zone("c.example")],
                     resultInfo: ["page": 1, "per_page": 50, "total_pages": 2]),
            .success(method: "GET", path: "/zones", result: [zone("a.example")],
                     resultInfo: ["page": 2, "per_page": 50, "total_pages": 2])
        ])
        let service = CloudflareService(session: Self.mockSession(), executablePath: { _ in nil })

        let zones = try await service.loadZones(apiToken: "test-token")

        #expect(zones.map(\.name) == ["a.example", "b.example", "c.example"])
        #expect(CloudflareURLProtocolMock.requestedPaths() == [
            "GET /zones?per_page=50&status=active",
            "GET /zones?per_page=50&status=active&page=2"
        ])
    }

    @Test func listStopsAtAnEmptyPageEvenWhenMoreArePromised() async throws {
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/zones", result: [[
                "id": "zone-id", "name": "example.com", "account": ["id": "account-id", "name": "Example"]
            ]], resultInfo: ["total_pages": 9]),
            .success(method: "GET", path: "/zones", result: [], resultInfo: ["total_pages": 9])
        ])
        let service = CloudflareService(session: Self.mockSession(), executablePath: { _ in nil })

        #expect(try await service.loadZones(apiToken: "test-token").count == 1)
        #expect(CloudflareURLProtocolMock.requestedPaths().count == 2)
    }

    /// A live tunnel on a later page must be found. Missing it would make a
    /// resume look like "the saved tunnel is gone".
    @Test func tunnelLookupFollowsPagesThatReportOnlyAnItemCount() async throws {
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "deleted-tunnel", "name": tunnelName, "config_src": "cloudflare",
                "deleted_at": "2026-01-01T00:00:00Z"
            ]], resultInfo: ["total_count": 2]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "live-tunnel", "name": tunnelName, "config_src": "cloudflare", "deleted_at": NSNull()
            ]], resultInfo: ["total_count": 2]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [[
                "id": "foreign-dns-id", "type": "A", "name": hostname, "content": "192.0.2.1", "comment": NSNull()
            ]])
        ])

        // Reaching the DNS check proves the live tunnel on page 2 was found.
        await #expect(throws: CloudflareServiceError.existingDNSRecord(hostname)) {
            try await Self.deploy(Self.makeService(session: Self.mockSession()), expectedTunnelID: "live-tunnel")
        }
        #expect(CloudflareURLProtocolMock.requestedPaths() == [
            "GET /accounts/account-id/cfd_tunnel?per_page=50&name=\(tunnelName)",
            "GET /accounts/account-id/cfd_tunnel?per_page=50&name=\(tunnelName)&page=2",
            "GET /zones/zone-id/dns_records?name=\(hostname)"
        ])
    }

    @Test func tunnelNameIsStableAndDNSSafe() {
        #expect(
            CloudflareService.tunnelName(hostname: "macremote.home.example.com") ==
            "macremote-macremote-home-example-com"
        )
    }

    @Test func apiTokenPermissionCopyIncludesConfigRulesEdit() {
        #expect(CloudflareServiceError.apiTokenPermissions.contains("Config Rules Edit"))
        #expect(CloudflareServiceError.apiTokenPermissions.contains("Cloudflare Tunnel Edit"))
        #expect(CloudflareServiceError.apiTokenPermissions.contains("DNS Edit"))
        #expect(!CloudflareServiceError.apiTokenPermissions.contains("Read and Write"))
    }

    @Test func invalidTokenFailureStaysAZoneLoadError() async {
        let session = Self.mockSession()
        CloudflareURLProtocolMock.install([
            .failure(method: "GET", path: "/zones", message: "Invalid API token")
        ])
        let service = CloudflareService(session: session, executablePath: { _ in nil })

        do {
            _ = try await service.loadZones(apiToken: "invalid-token")
            Issue.record("Expected an invalid API token to fail domain loading.")
        } catch let error as CloudflareServiceError {
            #expect(error == .api("Invalid API token"))
            #expect(error.localizedDescription == "Invalid API token")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func signedOutWranglerFailureUsesSourceNeutralGuidance() async {
        let service = CloudflareService(
            executablePath: { name in name == "wrangler" ? "/usr/bin/false" : nil }
        )

        do {
            _ = try await service.loadZones()
            Issue.record("Expected signed-out Wrangler to fail domain loading.")
        } catch let error as CloudflareServiceError {
            #expect(error == .wranglerNotAuthenticated)
            #expect(error.localizedDescription.contains("signed out"))
            #expect(error.localizedDescription.contains("Terminal") == false)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func dnsOwnershipRequiresCNAMEAndExactMacRemoteMarker() {
        #expect(CloudflareService.dnsRecordIsOwnedByMacRemote(
            type: "CNAME",
            content: "tunnel-id.cfargotunnel.com",
            comment: nil,
            existingTunnelID: "tunnel-id"
        ))
        #expect(CloudflareService.dnsRecordIsOwnedByMacRemote(
            type: "cname",
            content: "stale-tunnel.cfargotunnel.com",
            comment: "MacRemote Cloudflare Tunnel",
            existingTunnelID: nil
        ))
        #expect(!CloudflareService.dnsRecordIsOwnedByMacRemote(
            type: "CNAME",
            content: "foreign.example.net",
            comment: "Owned by another service",
            existingTunnelID: "tunnel-id"
        ))
        #expect(!CloudflareService.dnsRecordIsOwnedByMacRemote(
            type: "A",
            content: "192.0.2.1",
            comment: "MacRemote Cloudflare Tunnel",
            existingTunnelID: nil
        ))
        #expect(!CloudflareService.dnsRecordIsOwnedByMacRemote(
            type: "CNAME",
            content: "foreign.example.net",
            comment: "MacRemote Backup",
            existingTunnelID: nil
        ))
    }

    private static func makeService(session: URLSession) -> CloudflareService {
        CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        return URLSession(configuration: config)
    }

    private static func deploy(
        _ service: CloudflareService,
        expectedTunnelID: String? = nil,
        progress: @escaping @Sendable (CloudflareDeployStage) async -> Void = { _ in }
    ) async throws -> CloudflareCustomDomainDeployment {
        try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "example.com",
                accountID: "account-id",
                accountName: "Example"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            apiToken: "test-token",
            expectedTunnelID: expectedTunnelID,
            progress: progress
        )
    }

    @Test func unavailableHelperFailsAtStartBeforeCloudflareChecks() async {
        let progress = CloudflareDeployProgressRecorder()
        CloudflareURLProtocolMock.install([])
        let service = CloudflareService(
            session: Self.mockSession(),
            executablePath: { _ in nil }
        )

        do {
            _ = try await Self.deploy(service) { stage in
                await progress.record(stage)
            }
            Issue.record("Expected a missing helper to block deployment.")
        } catch let error as CloudflareServiceError {
            #expect(error == .cloudflaredUnavailable)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(await progress.snapshot() == [.start])
        #expect(CloudflareURLProtocolMock.requestedPaths().isEmpty)
    }

    @Test(arguments: [false, true]) func deployCustomDomainProvisionsTunnelDNSAndBrowserCompatibility(useWrangler: Bool) async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let progress = CloudflareDeployProgressRecorder()

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .failure(
                method: "GET",
                path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
                message: "entry point ruleset not found",
                statusCode: 404
            ),
            .success(method: "POST", path: "/zones/zone-id/rulesets", result: [
                "id": "config-ruleset-id",
                "name": "MacRemote configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": []
            ]),
            .success(method: "POST", path: "/accounts/account-id/cfd_tunnel", result: [
                "id": "tunnel-id",
                "name": "macremote-macremote-example-com"
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session, runner: WranglerFixtureRunner(exitCode: useWrangler ? 0 : 1),
            executablePath: { _ in "/fixture/tool" }
        )
        let deployment = try await service.deployCustomDomain(
            zone: Self.testZone, subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            apiToken: useWrangler ? nil : "test-token"
        ) { stage in await progress.record(stage) }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(await progress.snapshot() == [.checkAccess, .createTunnel, .configureDNS, .start])
        #expect(deployment.hostname == hostname)
        #expect(deployment.tunnelToken == "tunnel-token")
        #expect((requests.contains { $0.contains("/access") }) == false)
        #expect((requests.contains { $0.contains("service_tokens") }) == false)
        #expect((requests.contains { $0.contains("/policies") }) == false)
        #expect((requests.contains { $0.contains("/workers/") }) == false)
        #expect((requests.contains { $0.contains("/workers/scripts/") }) == false)
    }

    @Test func resumeRejectsMissingOrDifferentTunnelBeforeAnyCloudWrite() async throws {
        let hostname = "macremote-m5.example.com"
        for existingID in ["source-tunnel", ""] {
            CloudflareURLProtocolMock.install([
                .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result:
                    existingID.isEmpty ? [] : [[
                        "id": existingID,
                        "name": CloudflareService.tunnelName(hostname: hostname),
                        "config_src": "cloudflare",
                        "deleted_at": NSNull()
                    ]]
                )
            ])
            do {
                _ = try await Self.makeService(session: Self.mockSession()).deployCustomDomain(
                    zone: Self.testZone,
                    subdomain: "macremote-m5",
                    localServerURL: URL(string: "http://127.0.0.1:54900")!,
                    apiToken: "test-token",
                    expectedTunnelID: "destination-tunnel"
                )
                Issue.record("Resume unexpectedly accepted a missing or replaced tunnel.")
            } catch let error as CloudflareServiceError {
                #expect(error == .savedTunnelChanged(hostname))
            }
            let requests = CloudflareURLProtocolMock.requestedPaths()
            #expect(requests.count == 1)
            #expect(requests.allSatisfy { $0.hasPrefix("GET /accounts/account-id/cfd_tunnel") })
        }
    }

    @Test func deployCustomDomainResumesItsOwnTunnelAndUpdatesItsDNSRecord() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "tunnel-id",
                "name": tunnelName,
                "config_src": "cloudflare",
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [[
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": NSNull()
            ]]),
            .failure(
                method: "GET",
                path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
                message: "entry point ruleset not found",
                statusCode: 404
            ),
            .success(method: "POST", path: "/zones/zone-id/rulesets", result: [
                "id": "config-ruleset-id",
                "name": "MacRemote configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": []
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [[
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": NSNull()
            ]]),
            .success(method: "PATCH", path: "/zones/zone-id/dns_records/dns-id", result: [
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let deployment = try await Self.deploy(Self.makeService(session: session), expectedTunnelID: "tunnel-id")

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect((requests.contains { $0.hasPrefix("DELETE ") }) == false)
        #expect(!requests.contains("GET /accounts/account-id/cfd_tunnel/tunnel-id/configurations"))
        #expect(deployment.tunnelID == "tunnel-id")
    }

    @Test func deployCustomDomainAdoptsTunnelWhoseConfigurationNamesTheHostname() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "tunnel-id",
                "name": tunnelName,
                "config_src": "cloudflare",
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [
                "config": [
                    "ingress": [
                        ["hostname": hostname, "service": "http://127.0.0.1:8765"],
                        ["service": "http_status:404"]
                    ]
                ]
            ]),
            .failure(
                method: "GET",
                path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
                message: "entry point ruleset not found",
                statusCode: 404
            ),
            .success(method: "POST", path: "/zones/zone-id/rulesets", result: [
                "id": "config-ruleset-id",
                "name": "MacRemote configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": []
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let deployment = try await Self.deploy(Self.makeService(session: session))

        #expect(deployment.hostname == hostname)
    }

    @Test func deployCustomDomainRejectsReadOnlyConfigRulesTokenBeforeOtherMutation() async throws {
        let session = Self.mockSession()
        let progress = CloudflareDeployProgressRecorder()
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(
                method: "GET",
                path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
                result: [
                    "id": "config-ruleset-id",
                    "name": "Existing configuration rules",
                    "kind": "zone",
                    "phase": "http_config_settings",
                    "rules": []
                ]
            ),
            .failure(
                method: "POST",
                path: "/zones/zone-id/rulesets/config-ruleset-id/rules",
                message: "Unauthorized to edit requested resource"
            )
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session)) { stage in
                await progress.record(stage)
            }
            Issue.record("Expected Config Rules Read without Edit to fail before deployment writes.")
        } catch let error as CloudflareServiceError {
            #expect(
                error == .insufficientPermissions(
                    "configure Browser Integrity Check for MacRemote's public hostname"
                )
            )
        }

        #expect(await progress.snapshot() == [.checkAccess])

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests == [
            "GET /accounts/account-id/cfd_tunnel?per_page=50&name=macremote-macremote-example-com",
            "GET /zones/zone-id/dns_records?name=macremote.example.com",
            "GET /zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
            "POST /zones/zone-id/rulesets/config-ruleset-id/rules"
        ])
        #expect(!requests.contains { $0.contains("/configurations") })
        #expect(!requests.contains("POST /accounts/account-id/cfd_tunnel"))
        #expect(!requests.contains { $0.hasPrefix("POST /zones/zone-id/dns_records") })
        #expect(!requests.contains { $0.hasPrefix("PATCH /zones/zone-id/dns_records") })
    }

    @Test func deployCustomDomainRejectsForeignARecordDespiteMacRemoteMarker() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let foreignDNS: [String: Any] = [
            "id": "foreign-dns-id",
            "type": "A",
            "name": hostname,
            "content": "192.0.2.1",
            "comment": "MacRemote Cloudflare Tunnel"
        ]
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "tunnel-id",
                "name": CloudflareService.tunnelName(hostname: hostname),
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [foreignDNS]),
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session))
            Issue.record("Expected a foreign DNS record to block deployment.")
        } catch let error as CloudflareServiceError {
            #expect(error == .existingDNSRecord(hostname))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests == [
            "GET /accounts/account-id/cfd_tunnel?per_page=50&name=macremote-macremote-example-com",
            "GET /zones/zone-id/dns_records?name=macremote.example.com"
        ])
        #expect(requests.allSatisfy { $0.hasPrefix("GET ") })
    }

    @Test func deployCustomDomainRejectsLocallyManagedSameNameTunnelBeforeBIC() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "foreign-tunnel-id",
                "name": tunnelName,
                "config_src": "local",
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [])
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session))
            Issue.record("Expected a locally managed same-name tunnel to be rejected.")
        } catch let error as CloudflareServiceError {
            #expect(error == .unownedTunnel(tunnelName))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests == [
            "GET /accounts/account-id/cfd_tunnel?per_page=50&name=macremote-macremote-example-com",
            "GET /zones/zone-id/dns_records?name=macremote.example.com"
        ])
        #expect(!requests.contains { $0.contains("/rulesets/") })
    }

    @Test func deployCustomDomainRejectsSameNameTunnelWithoutConfigSourceBeforeBIC() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "unproven-tunnel-id",
                "name": tunnelName,
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [])
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session))
            Issue.record("Expected a tunnel without config_src to be rejected.")
        } catch let error as CloudflareServiceError {
            #expect(error == .unownedTunnel(tunnelName))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.count == 2)
        #expect(!requests.contains { $0.contains("/configurations") })
        #expect(!requests.contains { $0.contains("/rulesets/") })
    }

    @Test func deployCustomDomainRejectsUnprovenSameNameTunnelBeforeBIC() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "foreign-tunnel-id",
                "name": tunnelName,
                "config_src": "cloudflare",
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/foreign-tunnel-id/configurations", result: [
                "config": [
                    "ingress": [
                        ["hostname": "other.example.com", "service": "http://127.0.0.1:9999"],
                        ["service": "http_status:404"]
                    ]
                ]
            ])
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session))
            Issue.record("Expected an unproven same-name tunnel to be rejected.")
        } catch let error as CloudflareServiceError {
            #expect(error == .unownedTunnel(tunnelName))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.last == "GET /accounts/account-id/cfd_tunnel/foreign-tunnel-id/configurations")
        #expect(!requests.contains { $0.contains("/rulesets/") })
        #expect(requests.allSatisfy { $0.hasPrefix("GET ") })
    }

    @Test func macRemoteDNSCommentAloneDoesNotProveSpecificTunnelOwnership() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "same-name-tunnel-id",
                "name": tunnelName,
                "config_src": "cloudflare",
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [[
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "stale-tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/same-name-tunnel-id/configurations", result: [
                "config": [
                    "ingress": [
                        ["hostname": "other.example.com", "service": "http://127.0.0.1:9999"],
                        ["service": "http_status:404"]
                    ]
                ]
            ])
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session))
            Issue.record("Expected a MacRemote DNS comment not to prove a different tunnel.")
        } catch let error as CloudflareServiceError {
            #expect(error == .unownedTunnel(tunnelName))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.last == "GET /accounts/account-id/cfd_tunnel/same-name-tunnel-id/configurations")
        #expect(!requests.contains { $0.contains("/rulesets/") })
    }

    @Test func deployCustomDomainRefusesPrefixedButInexactMarkerAfterPreflight() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.example.com"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        let ruleRef = CloudflareService.browserIntegrityRuleRef(hostname: hostname)
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [[
                "id": "tunnel-id",
                "name": tunnelName,
                "config_src": "cloudflare",
                "deleted_at": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [[
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": NSNull()
            ]]),
            .success(method: "GET", path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint", result: [
                "id": "config-ruleset-id",
                "name": "Existing configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": [[
                    "id": "macremote-rule-id",
                    "ref": ruleRef,
                    "action": "set_config",
                    "expression": "http.host eq \"\(hostname)\"",
                    "action_parameters": ["bic": false],
                    "enabled": true
                ]]
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [[
                "id": "dns-id",
                "type": "CNAME",
                "name": hostname,
                "content": "foreign.example.net",
                "comment": "MacRemote Backup"
            ]])
        ])

        do {
            _ = try await Self.deploy(Self.makeService(session: session))
            Issue.record("Expected the fresh foreign DNS record to block mutation.")
        } catch let error as CloudflareServiceError {
            #expect(error == .existingDNSRecord(hostname))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.filter { $0.hasPrefix("GET /zones/zone-id/dns_records") }.count == 2)
        #expect(!requests.contains { $0.hasPrefix("PATCH /zones/zone-id/dns_records") })
        #expect(!requests.contains { $0.hasPrefix("POST /zones/zone-id/dns_records") })
    }

    @Test func browserIntegrityRuleCreatesPhaseRulesetForExactHostname() async throws {
        let session = Self.mockSession()
        CloudflareURLProtocolMock.install([
            .failure(
                method: "GET",
                path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
                message: "entry point ruleset not found",
                statusCode: 404
            ),
            .success(method: "POST", path: "/zones/zone-id/rulesets", result: [
                "id": "config-ruleset-id",
                "name": "MacRemote configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": []
            ])
        ])

        try await Self.makeService(session: session).ensureBrowserIntegrityCheckDisabled(
            zoneID: "zone-id",
            hostname: "macremote.example.com",
            apiToken: "test-token"
        )

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests == [
            "GET /zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
            "POST /zones/zone-id/rulesets"
        ])
        let body = try #require(CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/rulesets"])
        #expect(body["kind"] as? String == "zone")
        #expect(body["phase"] as? String == "http_config_settings")
        let rules = try #require(body["rules"] as? [[String: Any]])
        let rule = try #require(rules.first)
        #expect(rule["ref"] as? String == CloudflareService.browserIntegrityRuleRef(hostname: "macremote.example.com"))
        #expect(rule["expression"] as? String == "http.host eq \"macremote.example.com\"")
        #expect(rule["action"] as? String == "set_config")
        #expect((rule["action_parameters"] as? [String: Any])?["bic"] as? Bool == false)
    }

    @Test func browserIntegrityRuleAppendsWithoutReplacingUnrelatedRules() async throws {
        let session = Self.mockSession()
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint", result: [
                "id": "config-ruleset-id",
                "name": "Existing configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": [[
                    "id": "foreign-rule-id",
                    "ref": "foreign_rule",
                    "action": "set_config",
                    "expression": "http.host eq \"other.example.com\"",
                    "action_parameters": ["bic": true],
                    "enabled": true
                ]]
            ]),
            .success(method: "POST", path: "/zones/zone-id/rulesets/config-ruleset-id/rules", result: [
                "id": "config-ruleset-id",
                "name": "Existing configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": []
            ])
        ])

        try await Self.makeService(session: session).ensureBrowserIntegrityCheckDisabled(
            zoneID: "zone-id",
            hostname: "macremote.example.com",
            apiToken: "test-token"
        )

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.contains("POST /zones/zone-id/rulesets/config-ruleset-id/rules"))
        #expect(!requests.contains("PUT /zones/zone-id/rulesets/config-ruleset-id"))
        #expect(!requests.contains { $0.contains("foreign-rule-id") })
        let body = try #require(
            CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/rulesets/config-ruleset-id/rules"]
        )
        #expect(body["ref"] as? String == CloudflareService.browserIntegrityRuleRef(hostname: "macremote.example.com"))
        #expect((body["position"] as? [String: Any])?["after"] as? String == "")
    }

    @Test func browserIntegrityRuleIsIdempotentWhenAlreadyCorrect() async throws {
        let session = Self.mockSession()
        let ruleRef = CloudflareService.browserIntegrityRuleRef(hostname: "macremote.example.com")
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint", result: [
                "id": "config-ruleset-id",
                "name": "Existing configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": [[
                    "id": "macremote-rule-id",
                    "ref": ruleRef,
                    "action": "set_config",
                    "expression": "http.host eq \"macremote.example.com\"",
                    "action_parameters": ["bic": false],
                    "enabled": true
                ]]
            ])
        ])

        try await Self.makeService(session: session).ensureBrowserIntegrityCheckDisabled(
            zoneID: "zone-id",
            hostname: "macremote.example.com",
            apiToken: "test-token"
        )

        #expect(CloudflareURLProtocolMock.requestedPaths() == [
            "GET /zones/zone-id/rulesets/phases/http_config_settings/entrypoint"
        ])
    }

    @Test func browserIntegrityRuleRepairsOnlyItsOwnDriftedRule() async throws {
        let session = Self.mockSession()
        let ruleRef = CloudflareService.browserIntegrityRuleRef(hostname: "macremote.example.com")
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint", result: [
                "id": "config-ruleset-id",
                "name": "Existing configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": [
                    [
                        "id": "foreign-rule-id",
                        "ref": "foreign_rule",
                        "action": "set_config",
                        "expression": "http.host eq \"other.example.com\"",
                        "action_parameters": ["bic": true],
                        "enabled": true
                    ],
                    [
                        "id": "macremote-rule-id",
                        "ref": ruleRef,
                        "action": "set_config",
                        "expression": "http.host eq \"stale.example.com\"",
                        "action_parameters": ["bic": true],
                        "enabled": false
                    ]
                ]
            ]),
            .success(
                method: "PATCH",
                path: "/zones/zone-id/rulesets/config-ruleset-id/rules/macremote-rule-id",
                result: [
                    "id": "config-ruleset-id",
                    "name": "Existing configuration rules",
                    "kind": "zone",
                    "phase": "http_config_settings",
                    "rules": []
                ]
            )
        ])

        try await Self.makeService(session: session).ensureBrowserIntegrityCheckDisabled(
            zoneID: "zone-id",
            hostname: "macremote.example.com",
            apiToken: "test-token"
        )

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.last == "PATCH /zones/zone-id/rulesets/config-ruleset-id/rules/macremote-rule-id")
        #expect(!requests.contains { $0.contains("foreign-rule-id") })
        #expect(!requests.contains("PUT /zones/zone-id/rulesets/config-ruleset-id"))
        let body = try #require(
            CloudflareURLProtocolMock.requestBodies()[
                "PATCH /zones/zone-id/rulesets/config-ruleset-id/rules/macremote-rule-id"
            ]
        )
        #expect(body["ref"] as? String == ruleRef)
        #expect(body["expression"] as? String == "http.host eq \"macremote.example.com\"")
        #expect((body["action_parameters"] as? [String: Any])?["bic"] as? Bool == false)
        #expect(body["enabled"] as? Bool == true)
        #expect((body["position"] as? [String: Any])?["after"] as? String == "")
    }

    @Test func browserIntegrityRuleMovesCorrectRuleAfterLaterMatchingRule() async throws {
        let session = Self.mockSession()
        let ruleRef = CloudflareService.browserIntegrityRuleRef(hostname: "macremote.example.com")
        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint", result: [
                "id": "config-ruleset-id",
                "name": "Existing configuration rules",
                "kind": "zone",
                "phase": "http_config_settings",
                "rules": [
                    [
                        "id": "macremote-rule-id",
                        "ref": ruleRef,
                        "action": "set_config",
                        "expression": "http.host eq \"macremote.example.com\"",
                        "action_parameters": ["bic": false],
                        "enabled": true
                    ],
                    [
                        "id": "foreign-rule-id",
                        "ref": "foreign_rule",
                        "action": "set_config",
                        "expression": "ends_with(http.host, \".example.com\")",
                        "action_parameters": ["bic": true],
                        "enabled": true
                    ]
                ]
            ]),
            .success(
                method: "PATCH",
                path: "/zones/zone-id/rulesets/config-ruleset-id/rules/macremote-rule-id",
                result: [
                    "id": "config-ruleset-id",
                    "name": "Existing configuration rules",
                    "kind": "zone",
                    "phase": "http_config_settings",
                    "rules": []
                ]
            )
        ])

        try await Self.makeService(session: session).ensureBrowserIntegrityCheckDisabled(
            zoneID: "zone-id",
            hostname: "macremote.example.com",
            apiToken: "test-token"
        )

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests == [
            "GET /zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
            "PATCH /zones/zone-id/rulesets/config-ruleset-id/rules/macremote-rule-id"
        ])
        #expect(!requests.contains { $0.contains("foreign-rule-id") })
        let body = try #require(
            CloudflareURLProtocolMock.requestBodies()[
                "PATCH /zones/zone-id/rulesets/config-ruleset-id/rules/macremote-rule-id"
            ]
        )
        #expect((body["position"] as? [String: Any])?["after"] as? String == "")
        #expect(!String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8)!.contains("foreign-rule-id"))
    }

    @Test func browserIntegrityRulePermissionFailureNamesExactPermission() async throws {
        let session = Self.mockSession()
        CloudflareURLProtocolMock.install([
            .failure(
                method: "GET",
                path: "/zones/zone-id/rulesets/phases/http_config_settings/entrypoint",
                message: "Unauthorized to access requested resource"
            )
        ])

        do {
            try await Self.makeService(session: session).ensureBrowserIntegrityCheckDisabled(
                zoneID: "zone-id",
                hostname: "macremote.example.com",
                apiToken: "test-token"
            )
            Issue.record("Expected the missing Config Rules permission to fail.")
        } catch let error as CloudflareServiceError {
            #expect(error == .insufficientPermissions("configure Browser Integrity Check for MacRemote's public hostname"))
            #expect(error.localizedDescription.contains("Config Rules Edit"))
        }
    }

    @Test func wranglerCredentialJSONRejectsMissingUnsupportedAndMalformedTokens() throws {
        #expect(try CloudflareService.wranglerToken(from: Data(#"{"type":"oauth","token":"fixture-token"}"#.utf8)) == "fixture-token")
        for invalid in ["not JSON", #"{"type":"oauth","token":" "}"#, #"{"type":"api_key","key":"private","email":"user"}"#] {
            #expect(throws: CloudflareServiceError.wranglerNotAuthenticated) {
                try CloudflareService.wranglerToken(from: Data(invalid.utf8))
            }
        }
    }

    @Test func signedInWranglerLoadsZonesWithoutPastedToken() async throws {
        CloudflareURLProtocolMock.install([.success(method: "GET", path: "/zones", result: [])])
        let service = CloudflareService(session: Self.mockSession(), runner: WranglerFixtureRunner(), executablePath: { _ in "/fixture/wrangler" })
        #expect(try await service.loadZones().isEmpty)
        #expect(CloudflareURLProtocolMock.requestedPaths().count == 1)
    }

    @Test func signedOutWranglerCannotWriteCloudResourcesOrLeakOutput() async throws {
        CloudflareURLProtocolMock.install([])
        let service = CloudflareService(session: Self.mockSession(), runner: WranglerFixtureRunner(exitCode: 1), executablePath: { _ in "/fixture/tool" })
        do {
            _ = try await service.deployCustomDomain(zone: Self.testZone, subdomain: "macremote", localServerURL: URL(string: "http://127.0.0.1:8765")!)
            Issue.record("Expected signed-out failure")
        } catch let error as CloudflareServiceError {
            #expect(error == .wranglerNotAuthenticated)
            #expect(!error.localizedDescription.contains("fixture-secret"))
        }
        #expect(CloudflareURLProtocolMock.requestedPaths().isEmpty)
    }

    private static let testZone = CloudflareZone(
        id: "zone-id",
        name: "example.com",
        accountID: "account-id",
        accountName: "Example"
    )
}

private actor CloudflareDeployProgressRecorder {
    private var stages: [CloudflareDeployStage] = []

    func record(_ stage: CloudflareDeployStage) {
        stages.append(stage)
    }

    func snapshot() -> [CloudflareDeployStage] {
        stages
    }
}

private struct CloudflareMockResponse: Sendable {
    let method: String
    let path: String
    let statusCode: Int
    let body: Data

    static func success(
        method: String,
        path: String,
        result: Any,
        resultInfo: [String: Int]? = nil
    ) -> CloudflareMockResponse {
        var payload: [String: Any] = [
            "success": true,
            "errors": [],
            "messages": [],
            "result": result
        ]
        payload["result_info"] = resultInfo
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return CloudflareMockResponse(method: method, path: path, statusCode: 200, body: body)
    }

    static func failure(method: String, path: String, message: String, statusCode: Int = 403) -> CloudflareMockResponse {
        let payload: [String: Any] = [
            "success": false,
            "errors": [["message": message]],
            "messages": [],
            "result": NSNull()
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return CloudflareMockResponse(method: method, path: path, statusCode: statusCode, body: body)
    }
}

private final class CloudflareURLProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [CloudflareMockResponse] = []
    nonisolated(unsafe) private static var requests: [String] = []
    nonisolated(unsafe) private static var bodies: [String: [String: Any]] = [:]

    static func install(_ newResponses: [CloudflareMockResponse]) {
        lock.lock()
        responses = newResponses
        requests = []
        bodies = [:]
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        let snapshot = requests
        lock.unlock()
        return snapshot
    }

    static func requestBodies() -> [String: [String: Any]] {
        lock.lock()
        let snapshot = bodies
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.cloudflare.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let method = request.httpMethod ?? "GET"
        let apiPath = url.path.hasPrefix("/client/v4")
            ? String(url.path.dropFirst("/client/v4".count))
            : url.path
        let requestPath = "\(method) \(apiPath)"
        let recordedPath = url.query.map { "\(requestPath)?\($0)" } ?? requestPath
        let response = Self.nextResponse(
            method: method,
            path: apiPath,
            recordedPath: recordedPath,
            requestBody: Self.bodyData(from: request)
        )
        let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data.isEmpty ? nil : data
    }

    private static func nextResponse(
        method: String,
        path: String,
        recordedPath: String,
        requestBody: Data?
    ) -> CloudflareMockResponse {
        lock.lock()
        requests.append(recordedPath)
        if let requestBody,
           let json = try? JSONSerialization.jsonObject(with: requestBody) as? [String: Any] {
            bodies["\(method) \(path)"] = json
        }
        defer { lock.unlock() }

        guard !responses.isEmpty else {
            return failure("Unexpected request: \(method) \(path)")
        }
        let response = responses.removeFirst()
        guard response.method == method, response.path == path else {
            return failure("Expected \(response.method) \(response.path), got \(method) \(path)")
        }
        return response
    }

    private static func failure(_ message: String) -> CloudflareMockResponse {
        let payload: [String: Any] = [
            "success": false,
            "errors": [["message": message]],
            "messages": [],
            "result": NSNull()
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return CloudflareMockResponse(method: "GET", path: "/", statusCode: 500, body: body)
    }
}

private struct WranglerFixtureRunner: ProcessRunning {
    var exitCode: Int32 = 0
    func run(executablePath: String, arguments: [String], timeoutSeconds: TimeInterval,
             outputByteLimit: Int, environment: [String: String], standardInput: String?) async throws -> CommandRunResult {
        #expect(arguments == ["auth", "token", "--json"])
        #expect(standardInput == nil)
        #expect(environment["WRANGLER_WRITE_LOGS"] == "false")
        return CommandRunResult(executablePath: executablePath, arguments: arguments, exitCode: exitCode,
            stdout: #"{"type":"oauth","token":"fixture-secret"}"#, stderr: "fixture-secret",
            duration: 0, timedOut: false, truncatedStdout: false, truncatedStderr: false)
    }
}
