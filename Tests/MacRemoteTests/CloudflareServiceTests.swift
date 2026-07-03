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

    private static func deploy(_ service: CloudflareService) async throws -> CloudflareCustomDomainDeployment {
        try await service.deployCustomDomain(
            zone: CloudflareZone(
                id: "zone-id",
                name: "viticci.net",
                accountID: "account-id",
                accountName: "Viticci"
            ),
            subdomain: "macremote",
            localServerURL: URL(string: "http://127.0.0.1:8765")!,
            apiToken: "test-token"
        )
    }

    @Test func deployCustomDomainProvisionsTunnelAndDNSOnly() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.viticci.net"

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
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
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let deployment = try await Self.deploy(Self.makeService(session: session))

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(deployment.hostname == hostname)
        #expect(deployment.tunnelToken == "tunnel-token")
        #expect(deployment.legacyAccessCleanup == nil)
        // Access is checked once, only to clean up pre-2026-07 leftovers —
        // nothing Access-related is ever created.
        #expect(requests.filter { $0.hasPrefix("GET /zones/zone-id/access/apps") }.count == 1)
        #expect((requests.contains { $0.hasPrefix("POST /zones/zone-id/access") }) == false)
        #expect((requests.contains { $0.contains("service_tokens") }) == false)
        #expect((requests.contains { $0.contains("/policies") }) == false)
    }

    @Test func deployCustomDomainDeletesLegacyMacRemoteAccessApplication() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.viticci.net"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
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

        let deployment = try await Self.deploy(Self.makeService(session: session))

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(requests.contains("DELETE /zones/zone-id/access/apps/access-app-id"))
        #expect(deployment.legacyAccessCleanup?.contains("Removed the Cloudflare Access app") == true)
    }

    @Test func deployCustomDomainLeavesForeignAccessApplicationUntouched() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.viticci.net"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "GET", path: "/zones/zone-id/access/apps", result: [
                [
                    "id": "other-access-app-id",
                    "name": "Other Product",
                    "domain": CloudflareService.accessApplicationDomain(hostname: hostname)
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
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: [
                "id": "dns-id",
                "name": hostname,
                "content": "tunnel-id.cfargotunnel.com",
                "comment": "MacRemote Cloudflare Tunnel"
            ]),
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel/tunnel-id/token", result: "tunnel-token")
        ])

        let deployment = try await Self.deploy(Self.makeService(session: session))

        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect((requests.contains { $0.hasPrefix("DELETE ") }) == false)
        #expect(deployment.legacyAccessCleanup?.contains("not created by MacRemote") == true)
    }

    @Test func deployCustomDomainToleratesAccessLookupFailure() async throws {
        let session = Self.mockSession()
        let hostname = "macremote.viticci.net"
        let tunnelName = CloudflareService.tunnelName(hostname: hostname)

        CloudflareURLProtocolMock.install([
            .success(method: "GET", path: "/accounts/account-id/cfd_tunnel", result: []),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            // A token without Access permissions: the legacy-cleanup lookup
            // fails, and the deploy must carry on regardless.
            .failure(method: "GET", path: "/zones/zone-id/access/apps", message: "Authentication error"),
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

        let deployment = try await Self.deploy(Self.makeService(session: session))

        #expect(deployment.hostname == hostname)
        #expect(deployment.legacyAccessCleanup == nil)
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

    // MARK: - Apex favicon (connector icon)

    private static let testZone = CloudflareZone(
        id: "zone-id",
        name: "viticci.net",
        accountID: "account-id",
        accountName: "Viticci"
    )

    @Test func apexFaviconRoutePatternsCoverOnlyFaviconPaths() {
        #expect(
            CloudflareService.apexFaviconRoutePatterns(zoneName: "viticci.net") ==
            ["viticci.net/favicon.ico", "viticci.net/favicon.png"]
        )
    }

    @Test func apexFaviconWorkerScriptEmbedsAssetsAndServesNothingElse() {
        let script = CloudflareService.apexFaviconWorkerScript(icoBase64: "SUNP", pngBase64: "UE5H")
        #expect(script.contains("\"/favicon.ico\": { b64: \"SUNP\", type: \"image/x-icon\" }"))
        #expect(script.contains("\"/favicon.png\": { b64: \"UE5H\", type: \"image/png\" }"))
        // Anything but the two favicon paths must 404 so the Worker can
        // never shadow real apex content.
        #expect(script.contains("status: 404"))
        #expect(script.contains("export default"))
    }

    @Test func bundledFaviconAssetsAreAvailable() throws {
        let assets = try #require(CloudflareService.bundledFaviconAssets())
        #expect(!assets.icoBase64.isEmpty)
        #expect(!assets.pngBase64.isEmpty)
    }

    @Test func workerUploadBodyIsWellFormedMultipart() {
        let body = String(
            decoding: CloudflareService.workerUploadBody(script: "export default {};", boundary: "B"),
            as: UTF8.self
        )
        #expect(body.contains("--B\r\nContent-Disposition: form-data; name=\"metadata\""))
        #expect(body.contains("\"main_module\":\"worker.js\""))
        #expect(body.contains("name=\"worker.js\"; filename=\"worker.js\""))
        #expect(body.contains("Content-Type: application/javascript+module"))
        #expect(body.hasSuffix("--B--\r\n"))
    }

    @Test func provisionApexFaviconSkipsWhenApexAlreadyServesOne() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        CloudflareURLProtocolMock.install([])
        let service = CloudflareService(
            session: URLSession(configuration: config),
            executablePath: { _ in nil },
            apexFaviconProbe: { _ in true }
        )

        let outcome = await service.provisionApexFavicon(zone: Self.testZone, apiToken: "test-token")

        #expect(outcome == .skippedExistingFavicon)
        #expect(CloudflareURLProtocolMock.requestedPaths().isEmpty)
    }

    @Test func provisionApexFaviconUploadsWorkerCreatesDNSAndRoutes() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        CloudflareURLProtocolMock.install([
            .success(method: "PUT", path: "/accounts/account-id/workers/scripts/macremote-apex-favicon", result: ["id": "script-id"]),
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: []),
            .success(method: "POST", path: "/zones/zone-id/dns_records", result: ["id": "apex-dns", "type": "AAAA", "proxied": true]),
            .success(method: "GET", path: "/zones/zone-id/workers/routes", result: []),
            .success(method: "POST", path: "/zones/zone-id/workers/routes", result: ["id": "route-ico"]),
            .success(method: "POST", path: "/zones/zone-id/workers/routes", result: ["id": "route-png"])
        ])
        let service = CloudflareService(
            session: URLSession(configuration: config),
            executablePath: { _ in nil },
            apexFaviconProbe: { _ in false }
        )

        let outcome = await service.provisionApexFavicon(zone: Self.testZone, apiToken: "test-token")

        guard case .provisioned(let detail) = outcome else {
            Issue.record("Expected .provisioned, got \(outcome)")
            return
        }
        #expect(detail.contains("https://viticci.net/favicon.ico"))

        let bodies = CloudflareURLProtocolMock.requestBodies()
        let dnsBody = try #require(bodies["POST /zones/zone-id/dns_records"])
        #expect(dnsBody["type"] as? String == "AAAA")
        #expect(dnsBody["content"] as? String == "100::")
        #expect(dnsBody["proxied"] as? Bool == true)
        // The bodies dictionary keeps the last body per endpoint — the
        // second route POST covers favicon.png.
        let routeBody = try #require(bodies["POST /zones/zone-id/workers/routes"])
        #expect(routeBody["pattern"] as? String == "viticci.net/favicon.png")
        #expect(routeBody["script"] as? String == "macremote-apex-favicon")
    }

    @Test func provisionApexFaviconLeavesForeignRoutesAndDNSAlone() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudflareURLProtocolMock.self]
        CloudflareURLProtocolMock.install([
            .success(method: "PUT", path: "/accounts/account-id/workers/scripts/macremote-apex-favicon", result: ["id": "script-id"]),
            // The apex already has a proxied address record: no DNS write.
            .success(method: "GET", path: "/zones/zone-id/dns_records", result: [
                ["id": "existing", "type": "A", "proxied": true]
            ]),
            // favicon.ico is routed to someone else's Worker: only the
            // missing favicon.png route is created, nothing is overwritten.
            .success(method: "GET", path: "/zones/zone-id/workers/routes", result: [
                ["id": "other", "pattern": "viticci.net/favicon.ico", "script": "someone-else"]
            ]),
            .success(method: "POST", path: "/zones/zone-id/workers/routes", result: ["id": "route-png"])
        ])
        let service = CloudflareService(
            session: URLSession(configuration: config),
            executablePath: { _ in nil },
            apexFaviconProbe: { _ in false }
        )

        let outcome = await service.provisionApexFavicon(zone: Self.testZone, apiToken: "test-token")

        guard case .provisioned(let detail) = outcome else {
            Issue.record("Expected .provisioned, got \(outcome)")
            return
        }
        #expect(detail.contains("someone-else"))
        let requests = CloudflareURLProtocolMock.requestedPaths()
        #expect(!requests.contains("POST /zones/zone-id/dns_records"))
        #expect(requests.filter { $0 == "POST /zones/zone-id/workers/routes" }.count == 1)
        let routeBody = try #require(CloudflareURLProtocolMock.requestBodies()["POST /zones/zone-id/workers/routes"])
        #expect(routeBody["pattern"] as? String == "viticci.net/favicon.png")
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
