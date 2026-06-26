import XCTest
@testable import MacRemote

final class CloudflareServiceTests: XCTestCase {
    func testHostnameNormalizesSubdomain() throws {
        XCTAssertEqual(
            try CloudflareService.hostname(subdomain: "  MacRemote-Home  ", zoneName: "viticci.net"),
            "macremote-home.viticci.net"
        )
    }

    func testHostnameRejectsInvalidSubdomain() {
        XCTAssertThrowsError(try CloudflareService.hostname(subdomain: "-macremote", zoneName: "viticci.net")) { error in
            XCTAssertEqual(error as? CloudflareServiceError, .invalidSubdomain)
        }
        XCTAssertFalse(CloudflareService.isValidSubdomain("macremote_iphone"))
        XCTAssertFalse(CloudflareService.isValidSubdomain("macremote-"))
        XCTAssertFalse(CloudflareService.isValidSubdomain(""))
    }

    func testTunnelNameIsStableAndDNSSafe() {
        XCTAssertEqual(
            CloudflareService.tunnelName(hostname: "macremote.home.viticci.net"),
            "macremote-macremote-home-viticci-net"
        )
    }

    func testAccessApplicationDomainProtectsOnlyMCPPath() {
        XCTAssertEqual(
            CloudflareService.accessApplicationDomain(hostname: "macremote.viticci.net"),
            "macremote.viticci.net/mcp/*"
        )
    }

    func testStandardHeadersJSONUsesCloudflareAccessHeaderNames() throws {
        let credentials = CloudflareAccessCredentials(
            clientID: "client-id",
            clientSecret: "client-secret"
        )
        let data = try XCTUnwrap(credentials.standardHeadersJSON.data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(decoded["CF-Access-Client-Id"], "client-id")
        XCTAssertEqual(decoded["CF-Access-Client-Secret"], "client-secret")
        XCTAssertNil(decoded["Authorization"])
    }

    func testAuthorizationHeaderJSONUsesCloudflareSingleHeaderPayload() throws {
        let credentials = CloudflareAccessCredentials(
            clientID: "client-id",
            clientSecret: "client-secret"
        )
        let data = try XCTUnwrap(credentials.authorizationHeaderJSON.data(using: .utf8))
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        let authorizationValue = try XCTUnwrap(decoded["Authorization"])
        let authorizationData = try XCTUnwrap(authorizationValue.data(using: .utf8))
        let authorizationPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: authorizationData) as? [String: String])

        XCTAssertEqual(authorizationPayload["cf-access-client-id"], "client-id")
        XCTAssertEqual(authorizationPayload["cf-access-client-secret"], "client-secret")
        XCTAssertNil(decoded["CF-Access-Client-Id"])
    }

    func testDeployCustomDomainUsesZoneScopedAccessEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
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
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
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
        XCTAssertEqual(deployment.hostname, hostname)
        XCTAssertEqual(deployment.accessCredentials?.clientID, "client-id")
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /zones/zone-id/access/apps") })
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /zones/zone-id/access/service_tokens") })
        XCTAssertTrue(requests.contains("POST /zones/zone-id/access/apps"))
        XCTAssertTrue(requests.contains("POST /zones/zone-id/access/service_tokens"))
        XCTAssertTrue(requests.contains { $0.hasPrefix("GET /zones/zone-id/access/apps/app-id/policies") })
        XCTAssertTrue(requests.contains("POST /zones/zone-id/access/apps/app-id/policies"))
        XCTAssertFalse(requests.contains { $0.contains("/accounts/account-id/access") })
    }

    func testDeployCustomDomainCanConfigureSingleAuthorizationHeaderAccess() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
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
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
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

        let appBody = try XCTUnwrap(CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/access/apps"])
        XCTAssertEqual(appBody["read_service_tokens_from_header"] as? String, "Authorization")
        XCTAssertEqual(deployment.accessMode, .serviceTokenAuthorizationHeader)
        XCTAssertTrue(deployment.accessCredentials?.authorizationHeaderJSON.contains("\"Authorization\"") == true)
    }

    func testDeployCustomDomainUsesNextFreePolicyPrecedence() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
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
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
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

        let policyBody = try XCTUnwrap(CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/access/apps/app-id/policies"])
        XCTAssertEqual(policyBody["precedence"] as? Int, 2)
    }

    func testDeployCustomDomainUpdatesExistingMacRemotePolicy() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/service_tokens", result: []),
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
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: []),
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

        let policyBody = try XCTUnwrap(CloudflareURLProtocolMock.requestBodies()["PUT /zones/zone-id/access/apps/app-id/policies/macremote-policy-id"])
        XCTAssertEqual(policyBody["precedence"] as? Int, 1)
        let include = try XCTUnwrap(policyBody["include"] as? [[String: [String: String]]])
        XCTAssertEqual(include.first?["service_token"]?["token_id"], "new-service-token-id")
        XCTAssertFalse(CloudflareURLProtocolMock.requestedPaths().contains("POST /zones/zone-id/access/apps/app-id/policies"))
    }

    func testDeployCustomDomainMigratesLegacyWholeHostAccessApplication() async throws {
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
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: [
                [
                    "id": "legacy-app-id",
                    "name": "MacRemote \(hostname)",
                    "domain": hostname
                ]
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

        XCTAssertTrue(
            CloudflareURLProtocolMock.requestedPaths().contains("PUT /zones/zone-id/access/apps/legacy-app-id")
        )
    }

    func testWranglerOAuthTokenProviderParsesQuotedToken() {
        let config = """
        expiration_time = "2026-06-25T12:00:00Z"
        oauth_token = "abc.def.ghi" # refreshed by wrangler
        refresh_token = 'refresh-value'
        """

        XCTAssertEqual(
            WranglerOAuthTokenProvider.value(named: "oauth_token", in: config),
            "abc.def.ghi"
        )
        XCTAssertEqual(
            WranglerOAuthTokenProvider.value(named: "refresh_token", in: config),
            "refresh-value"
        )
        XCTAssertNil(WranglerOAuthTokenProvider.value(named: "missing", in: config))
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
