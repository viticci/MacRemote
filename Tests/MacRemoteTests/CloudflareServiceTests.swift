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
            try CloudflareService.hostname(subdomain: "  MacRemote-Home  ", zoneName: "viticci.net") ==
            "macremote-home.viticci.net"
        )
    }

    @Test func hostnameRejectsInvalidSubdomain() {
        #expect(throws: CloudflareServiceError.invalidSubdomain) { try CloudflareService.hostname(subdomain: "-macremote", zoneName: "viticci.net") }
        #expect(CloudflareService.isValidSubdomain("macremote_iphone") == false)
        #expect(CloudflareService.isValidSubdomain("macremote-") == false)
        #expect(CloudflareService.isValidSubdomain("") == false)
    }

    @Test func tunnelNameIsStableAndDNSSafe() {
        #expect(
            CloudflareService.tunnelName(hostname: "macremote.home.viticci.net") ==
            "macremote-macremote-home-viticci-net"
        )
    }

    @Test func accessApplicationDomainProtectsOnlyMCPPath() {
        #expect(
            CloudflareService.accessApplicationDomain(hostname: "macremote.viticci.net") ==
            "macremote.viticci.net/mcp*"
        )
    }

    @Test func standardHeadersJSONUsesCloudflareAccessHeaderNames() throws {
        let credentials = CloudflareAccessCredentials(
            clientID: "client-id",
            clientSecret: "client-secret"
        )
        let data = try #require(credentials.standardHeadersJSON.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])

        #expect(decoded["CF-Access-Client-Id"] == "client-id")
        #expect(decoded["CF-Access-Client-Secret"] == "client-secret")
        #expect(decoded["Authorization"] == nil)
    }

    @Test func singleHeaderJSONUsesCloudflareSingleHeaderPayload() throws {
        let credentials = CloudflareAccessCredentials(
            clientID: "client-id",
            clientSecret: "client-secret"
        )
        let data = try #require(credentials.singleHeaderJSON.data(using: .utf8))
        let decoded = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
        let headerValue = try #require(decoded["CF-Access-Service-Token"])
        let headerData = try #require(headerValue.data(using: .utf8))
        let headerPayload = try #require(JSONSerialization.jsonObject(with: headerData) as? [String: String])

        #expect(headerPayload["cf-access-client-id"] == "client-id")
        #expect(headerPayload["cf-access-client-secret"] == "client-secret")
        #expect(decoded["CF-Access-Client-Id"] == nil)
        #expect(decoded["Authorization"] == nil)
    }

    @Test func deployCustomDomainUsesZoneScopedAccessEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "POST", path: "/accounts/account-id/cfd_tunnel", result: [
                "id": "tunnel-id",
                "name": "macremote-macremote-viticci-net"
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/apps", result: [
                "id": "app-id",
                "name": "MacRemote \(hostname)",
                "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/service_tokens", result: [
                "id": "service-token-id",
                "client_id": "client-id",
                "client_secret": "client-secret"
            ]),
            .success(method: "GET", path: "/zones/zone-id/access/apps/app-id/policies", result: []),
            .success(method: "POST", path: "/zones/zone-id/access/apps/app-id/policies", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        let deployment = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .serviceTokenHeaders,
            apiToken: "test-token"
        )

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(deployment.hostname == hostname)
        #expect(deployment.accessCredentials?.clientID == "client-id")
        #expect(requests.contains { $0.hasPrefix("GET /zones/zone-id/access/apps") })
        #expect(requests.contains { $0.hasPrefix("GET /zones/zone-id/access/service_tokens") })
        #expect(requests.contains("POST /zones/zone-id/access/apps"))
        #expect(requests.contains("POST /zones/zone-id/access/service_tokens"))
        #expect(requests.contains { $0.hasPrefix("GET /zones/zone-id/access/apps/app-id/policies") })
        #expect(requests.contains("POST /zones/zone-id/access/apps/app-id/policies"))
        #expect((requests.contains { $0.contains("/accounts/account-id/access") }) == false)
    }

    @Test func deployCustomDomainCanConfigureSingleCloudflareAccessHeader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "POST", path: "/accounts/account-id/cfd_tunnel", result: [
                "id": "tunnel-id",
                "name": "macremote-macremote-viticci-net"
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/apps", result: [
                "id": "app-id",
                "name": "MacRemote \(hostname)",
                "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/service_tokens", result: [
                "id": "service-token-id",
                "client_id": "client-id",
                "client_secret": "client-secret"
            ]),
            .success(method: "GET", path: "/zones/zone-id/access/apps/app-id/policies", result: []),
            .success(method: "POST", path: "/zones/zone-id/access/apps/app-id/policies", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        let deployment = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .serviceTokenAuthorizationHeader,
            apiToken: "test-token"
        )

        let appBody = try #require(CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/access/apps"])
        #expect(appBody["read_service_tokens_from_header"] as? String == "CF-Access-Service-Token")
        #expect(deployment.accessMode == .serviceTokenAuthorizationHeader)
        #expect(deployment.accessCredentials?.singleHeaderJSON.contains("\"CF-Access-Service-Token\"") == true)
    }

    @Test func deployCustomDomainUsesNextFreePolicyPrecedence() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "POST", path: "/accounts/account-id/cfd_tunnel", result: [
                "id": "tunnel-id",
                "name": "macremote-macremote-viticci-net"
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/apps", result: [
                "id": "app-id",
                "name": "MacRemote \(hostname)",
                "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/service_tokens", result: [
                "id": "service-token-id",
                "client_id": "client-id",
                "client_secret": "client-secret"
            ]),
            .success(method: "GET", path: "/zones/zone-id/access/apps/app-id/policies", result: [
                [
                    "id": "other-policy-id",
                    "name": "Other Policy",
                    "precedence": 1
                ]
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/apps/app-id/policies", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        _ = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .serviceTokenHeaders,
            apiToken: "test-token"
        )

        let policyBody = try #require(CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/access/apps/app-id/policies"])
        #expect(policyBody["precedence"] as? Int == 2)
    }

    @Test func deployCustomDomainUpdatesExistingMacRemotePolicy() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "POST", path: "/accounts/account-id/cfd_tunnel", result: [
                "id": "tunnel-id",
                "name": "macremote-macremote-viticci-net"
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/apps", result: [
                "id": "app-id",
                "name": "MacRemote \(hostname)",
                "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/service_tokens", result: [
                "id": "new-service-token-id",
                "client_id": "client-id",
                "client_secret": "client-secret"
            ]),
            .success(method: "GET", path: "/zones/zone-id/access/apps/app-id/policies", result: [
                [
                    "id": "macremote-policy-id",
                    "name": "MacRemote Raycast Service Token old-token",
                    "precedence": 1
                ]
            ]),
            .success(method: "PUT", path: "/zones/zone-id/access/apps/app-id/policies/macremote-policy-id", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        _ = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .serviceTokenHeaders,
            apiToken: "test-token"
        )

        let policyBody = try #require(CloudflareURLProtocolMock.requestBodies()["PUT /zones/zone-id/access/apps/app-id/policies/macremote-policy-id"])
        #expect(policyBody["precedence"] as? Int == 1)
        let include = try #require(policyBody["include"] as? [[String: [String: String]]])
        #expect(include.first?["service_token"]?["token_id"] == "new-service-token-id")
        #expect(CloudflareURLProtocolMock.requestedPaths().contains("POST /zones/zone-id/access/apps/app-id/policies") == false)
    }

    @Test func deployCustomDomainMigratesLegacyWholeHostAccessApplication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        let accessDomain = CloudflareService.accessApplicationDomain(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: [
                [
                    "id": "legacy-app-id",
                    "name": "MacRemote \(hostname)",
                    "domain": hostname
                ]
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [
                [
                    "id": "tunnel-id",
                    "name": tunnelName,
                    "deleted_at": NSNull()
                ]
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [
                [
                    "id": "dns-id",
                    "name": hostname,
                    "content": "tunnel-id.cfargotunnel.com",
                    "comment": "MacRemote Cloudflare Tunnel"
                ]
            ]),
            .success(method: "PATCH", path: "/zones/zone-id/dns_records/dns-id", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "PUT", path: "/zones/zone-id/access/apps/legacy-app-id", result: [
                "id": "legacy-app-id",
                "name": "MacRemote \(hostname)",
                "domain": accessDomain
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/service_tokens", result: [
                "id": "service-token-id",
                "client_id": "client-id",
                "client_secret": "client-secret"
            ]),
            .success(method: "GET", path: "/zones/zone-id/access/apps/legacy-app-id/policies", result: []),
            .success(method: "POST", path: "/zones/zone-id/access/apps/legacy-app-id/policies", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        _ = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .serviceTokenHeaders,
            apiToken: "test-token"
        )

        #expect(
            CloudflareURLProtocolMock.requestedPaths().contains("PUT /zones/zone-id/access/apps/legacy-app-id"))
    }

    @Test func deployCustomDomainMigratesLegacyMCPWildcardAccessApplication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)
        let accessDomain = CloudflareService.accessApplicationDomain(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: [
                [
                    "id": "legacy-app-id",
                    "name": "MacRemote \(hostname)",
                    "domain": "\(hostname)/mcp/*"
                ]
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [
                [
                    "id": "tunnel-id",
                    "name": tunnelName,
                    "deleted_at": NSNull()
                ]
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [
                [
                    "id": "dns-id",
                    "name": hostname,
                    "content": "tunnel-id.cfargotunnel.com",
                    "comment": "MacRemote Cloudflare Tunnel"
                ]
            ]),
            .success(method: "PATCH", path: "/zones/zone-id/dns_records/dns-id", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "PUT", path: "/zones/zone-id/access/apps/legacy-app-id", result: [
                "id": "legacy-app-id",
                "name": "MacRemote \(hostname)",
                "domain": accessDomain
            ]),
            .success(method: "POST", path: "/zones/zone-id/access/service_tokens", result: [
                "id": "service-token-id",
                "client_id": "client-id",
                "client_secret": "client-secret"
            ]),
            .success(method: "GET", path: "/zones/zone-id/access/apps/legacy-app-id/policies", result: []),
            .success(method: "POST", path: "/zones/zone-id/access/apps/legacy-app-id/policies", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        _ = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .serviceTokenHeaders,
            apiToken: "test-token"
        )

        #expect(
            CloudflareURLProtocolMock.requestedPaths().contains("PUT /zones/zone-id/access/apps/legacy-app-id"))
        #expect(
            CloudflareURLProtocolMock.requestedPaths().contains("POST /zones/zone-id/access/apps") == false)
    }

    @Test func deployCustomDomainOAuthOnlyDeletesExistingMacRemoteAccessApplication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: [
                [
                    "id": "access-app-id",
                    "name": "MacRemote \(hostname)",
                    "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
                ]
            ]),
            .success(method: "DELETE", path: "/zones/zone-id/access/apps/access-app-id", result: [:]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: [
                [
                    "id": "tunnel-id",
                    "name": tunnelName,
                    "deleted_at": NSNull()
                ]
            ]),
            .success(method: "PUT", path: "/accounts/account-id/cfd_tunnel/tunnel-id/configurations", result: [:]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )
        let deployment = try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            accessMode: .macRemoteOAuthOnly,
            apiToken: "test-token"
        )

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(deployment.accessCredentials == nil)
        #expect(requests.contains("DELETE /zones/zone-id/access/apps/access-app-id"))
        #expect(requests.contains("POST /zones/zone-id/access/service_tokens") == false)
        #expect((requests.contains { $0.contains("/policies") }) == false)
    }

    @Test func deployCustomDomainOAuthOnlyRejectsNonMacRemoteAccessApplication() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: [
                [
                    "id": "other-access-app-id",
                    "name": "Other Product",
                    "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
                ]
            ])
        ])

        let service = CloudflareService(
            session: session,
            executablePath: { name in name == "cloudflared" ? "/usr/local/bin/cloudflared" : nil }
        )

        do {
            _ = try await service.deployCustomDomain(
                zone: CloudflareZone(
                    id: "zone-id",
                    name: "viticci.net",
                    accountID: "account-id",
                    accountName: "Viticci"
                ),
                subdomain: "macremote",
                localServerURL: URL(string: "http://127.0.0.1:8765")!,
                accessMode: .macRemoteOAuthOnly,
                apiToken: "test-token"
            )
            Issue.record("Expected deployment to reject the existing non-MacRemote Access application.")
        } catch {
            #expect(error as? CloudflareServiceError == .existingAccessApplication(hostname))
        }

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect((requests.contains { $0.contains("/configurations") }) == false)
        #expect((requests.contains { $0.hasPrefix("DELETE ") }) == false)
    }

    @Test func wranglerOAuthTokenProviderParsesQuotedToken() {
        let config = """
        expiration_time = "2026-06-25T12:00:00Z"
        oauth_token = "abc.def.ghi" # refreshed by wrangler
        refresh_token = 'refresh-value'
        """

        #expect(
            WranglerOAuthTokenProvider.value(named: "oauth_token", in: config) ==
            "abc.def.ghi"
        )
        #expect(
            WranglerOAuthTokenProvider.value(named: "refresh_token", in: config) ==
            "refresh-value"
        )
        #expect(WranglerOAuthTokenProvider.value(named: "missing", in: config) == nil)
    }
}

private struct CloudflareMockResponse: Sendable {
    let method: String
    let path: String
    let statusCode: Int
    let body: Data

    static func success(method: String, path: String, result: Any) -> CloudflareMockResponse {
        let payload: [String: Any] = [
            "success": true,
            "errors": [],
            "messages": [],
            "result": result
        ]
        let body = try! JSONSerialization.data(withJSONObject: payload)
        return CloudflareMockResponse(method: method, path: path, statusCode: 200, body: body)
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
