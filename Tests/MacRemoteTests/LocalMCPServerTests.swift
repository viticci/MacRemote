import CryptoKit
import Foundation
import Network
import Testing
@testable import MacRemote

// Every test here binds its own 127.0.0.1 listener on a port chosen by a
// probe-then-bind scan, so concurrently running tests can race the probe and
// end up talking to another test's server (XCTest ran these serially; Swift
// Testing is parallel by default). Serialize the suite to keep one live
// server at a time.
@Suite(.serialized)
struct LocalMCPServerTests {
    @Test func listenerParametersRequireIPv4Loopback() throws {
        let port = try #require(NWEndpoint.Port(rawValue: 54_321))
        let endpoint = try #require(
            LocalMCPServer.loopbackListenerParameters(on: port).requiredLocalEndpoint
        )
        guard case .hostPort(let host, let boundPort) = endpoint else {
            Issue.record("The local listener must use an explicit host and port.")
            return
        }
        #expect(String(describing: host) == "127.0.0.1")
        #expect(boundPort == port)
    }

    /// A deployed Your Domain reaches the server only on the port it was
    /// deployed with, so a restart asks for that port again, even right
    /// after the previous server answered requests on it.
    @Test func startReusesThePreferredPortWhenFreeAndPicksAnotherWhenTaken() async throws {
        func makeServer() -> LocalMCPServer {
            LocalMCPServer(
                instanceID: "test-instance",
                tools: [],
                authCoordinator: OAuthCoordinator(),
                toolExecutor: FakeToolExecutor()
            )
        }
        let first = makeServer()
        let port = try first.start()
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        _ = try await getJSON(url: base.appendingPathComponent("health"))
        await first.stop().value

        // The listener lets go of the port a moment after it is cancelled.
        var restarted = makeServer()
        var restartedPort = try restarted.start(preferredPort: port)
        for _ in 0..<100 where restartedPort != port {
            restarted.stop()
            try await Task.sleep(for: .milliseconds(20))
            restarted = makeServer()
            restartedPort = try restarted.start(preferredPort: port)
        }
        defer { restarted.stop() }
        #expect(restartedPort == port)

        let other = makeServer()
        defer { other.stop() }
        #expect(try other.start(preferredPort: port) != port)
    }

    @Test func publicHealthDoesNotDiscloseInstanceOrToolSurface() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024,
                    origin: .userDefined
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com"
        ]
        try await waitForServerReady(base: base)

        let localHealth = try await getJSON(url: base.appendingPathComponent("health"))
        #expect(localHealth.json["ok"] as? Bool == true)
        #expect(localHealth.json["public_metadata"] as? Bool == false)
        #expect(localHealth.json["instance_id"] as? String == "test-instance")
        #expect(localHealth.json["tool_count"] as? Int == 1)

        let publicHealth = try await getJSON(url: base.appendingPathComponent("health"), headers: forwardedHeaders)
        #expect(publicHealth.json["ok"] as? Bool == true)
        #expect(publicHealth.json["public_metadata"] as? Bool == true)
        #expect(publicHealth.json["instance_id"] == nil)
        #expect(publicHealth.json["tool_count"] == nil)
        #expect(publicHealth.json["tool_profile"] == nil)
    }

    /// A sign-in MacRemote refuses never reaches the approval window, so the
    /// person connecting must be told in the browser and the owner in Activity.
    @Test func refusedSignInIsExplainedInTheBrowserAndLogged() async throws {
        let logged = LockedLogLines()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor(),
            eventHandler: { event in
                if case let .log(_, message) = event { logged.append(message) }
            }
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        var components = URLComponents(url: base.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: "https://example.net/oauth/client-metadata.json"),
            URLQueryItem(name: "redirect_uri", value: "https://example.net/callback"),
            URLQueryItem(name: "scope", value: "mcp:tools"),
            URLQueryItem(name: "code_challenge", value: OAuthCoordinator.pkceChallenge(for: String(repeating: "v", count: 64))),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        let url = try #require(components.url)

        let page = try await getWithHeaders(url: url, headers: ["Accept": "text/html,application/xhtml+xml"])
        #expect(page.statusCode == 400)
        #expect(headerValue(page.headers, named: "Content-Type") == "text/html; charset=utf-8")
        let html = try #require(String(data: page.data, encoding: .utf8))
        #expect(html.contains("This sign-in can’t start."))
        #expect(html.contains("Unknown client_id."))

        let plain = try await getJSON(url: url)
        #expect(plain.statusCode == 400)
        #expect(plain.json["error"] as? String == "invalid_request")
        #expect(logged.lines.filter { $0 == "Refused a sign-in request: Unknown client_id." }.count == 2)
    }

    @Test func iconEndpointsServePublicAssets() async throws {
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        let connectorIcon = try await getWithHeaders(url: base.appendingPathComponent("macremote-icon.png"))
        #expect(connectorIcon.statusCode == 200)
        #expect(Data(connectorIcon.data.prefix(8)) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(headerValue(connectorIcon.headers, named: "Content-Type") == "image/png")

        let faviconPNG = try await getWithHeaders(url: base.appendingPathComponent("favicon.png"))
        #expect(faviconPNG.statusCode == 200)
        #expect(Data(faviconPNG.data.prefix(8)) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(headerValue(faviconPNG.headers, named: "Content-Type") == "image/png")

        let faviconICO = try await getWithHeaders(url: base.appendingPathComponent("favicon.ico"))
        #expect(faviconICO.statusCode == 200)
        #expect(Data(faviconICO.data.prefix(4)) == Data([0x00, 0x00, 0x01, 0x00]))
        #expect(headerValue(faviconICO.headers, named: "Content-Type") == "image/x-icon")

        let connectorIcon128 = try await getWithHeaders(url: base.appendingPathComponent("macremote-icon-128.png"))
        #expect(connectorIcon128.statusCode == 200)
        #expect(Data(connectorIcon128.data.prefix(8)) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(headerValue(connectorIcon128.headers, named: "Content-Type") == "image/png")

        // ChatGPT's "Add custom MCP server" form takes a PNG of up to 10 KB.
        let connectorIcon256 = try await getWithHeaders(url: base.appendingPathComponent("macremote-icon-256.png"))
        #expect(connectorIcon256.statusCode == 200)
        #expect(Data(connectorIcon256.data.prefix(8)) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        #expect(connectorIcon256.data.count < 10_000)

        let landing = try await getWithHeaders(url: base)
        #expect(landing.statusCode == 200)
        #expect(headerValue(landing.headers, named: "Content-Type") == "text/html; charset=utf-8")
        let landingHTML = try #require(String(data: landing.data, encoding: .utf8))
        #expect(landingHTML.contains("<link rel=\"icon\" href=\"/favicon.ico\""))
        #expect(landingHTML.contains("MacRemote"))
        #expect(landingHTML.contains(
            "This Mac shares only the tools you choose. Apps use the selected sign-in method. " +
                "Tools marked Asks First ask before running unless you choose Always Allow."
        ))
        #expect(!landingHTML.contains("write-capable"))
    }

    @Test func publicOAuthRegistrationIsRateLimitedButLoopbackIsNot() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com"
        ]
        try await waitForServerReady(base: base)

        for index in 0..<20 {
            let response = try await postJSON(
                url: base.appendingPathComponent("register"),
                headers: forwardedHeaders,
                body: [
                    "client_name": "Public HTTP Test \(index)",
                    "redirect_uris": ["http://127.0.0.1/callback"],
                    "scope": "mcp:tools"
                ]
            )
            #expect(response.statusCode == 201)
        }

        let limited = try await postJSON(
            url: base.appendingPathComponent("register"),
            headers: forwardedHeaders,
            body: [
                "client_name": "Public HTTP Test Limited",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        #expect(limited.statusCode == 429)
        #expect(limited.json["error"] as? String == "rate_limited")
        #expect(headerValue(limited.headers, named: "Retry-After") != nil)

        // One caller's flood must not lock a different caller out.
        let otherCaller = try await postJSON(
            url: base.appendingPathComponent("register"),
            headers: forwardedHeaders.merging(["CF-Connecting-IP": "203.0.113.9"]) { _, new in new },
            body: [
                "client_name": "Another Caller",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        #expect(otherCaller.statusCode == 201)

        let loopback = try await postJSON(
            url: base.appendingPathComponent("register"),
            body: [
                "client_name": "Loopback HTTP Test",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        #expect(loopback.statusCode == 201)
    }

    @Test func forwardedHTTPSHostIsUsedForOAuthMetadata() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com"
        ]
        try await waitForServerReady(base: base)

        let protectedResource = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource"),
            headers: forwardedHeaders
        )
        #expect(protectedResource.json["resource"] as? String == "https://macremote-test.trycloudflare.com/mcp")
        #expect(protectedResource.json["authorization_servers"] as? [String] == ["https://macremote-test.trycloudflare.com"])
        #expect(protectedResource.json["mcp_protocol_version"] as? String == "2025-11-25")
        #expect(
            protectedResource.json["mcp_protocol_versions_supported"] as? [String]
                == ["2025-11-25", "2025-06-18", "2025-03-26"]
        )

        let aliasProtectedResource = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource/mcp"),
            headers: forwardedHeaders
        )
        #expect(aliasProtectedResource.json["resource"] as? String == "https://macremote-test.trycloudflare.com/mcp")
        #expect(aliasProtectedResource.json["authorization_servers"] as? [String] == ["https://macremote-test.trycloudflare.com"])

        let pathProtectedResource = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource/mcp/test-instance"),
            headers: forwardedHeaders
        )
        #expect(pathProtectedResource.json["resource"] as? String == "https://macremote-test.trycloudflare.com/mcp")
        #expect(pathProtectedResource.json["authorization_servers"] as? [String] == ["https://macremote-test.trycloudflare.com"])

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
            headers: forwardedHeaders
        )
        #expect(authorizationServer.json["issuer"] as? String == "https://macremote-test.trycloudflare.com")
        #expect(authorizationServer.json["registration_endpoint"] as? String == "https://macremote-test.trycloudflare.com/register")
        #expect(authorizationServer.json["resource_indicators_supported"] as? Bool == true)
        #expect(authorizationServer.json["token_endpoint_auth_methods_supported"] as? [String]
            == ["none", "client_secret_basic", "client_secret_post"])

        let chatGPTAuthorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server/mcp"),
            headers: forwardedHeaders
        )
        #expect(chatGPTAuthorizationServer.statusCode == 200)
        #expect(chatGPTAuthorizationServer.json["issuer"] as? String == "https://macremote-test.trycloudflare.com")
        #expect(
            chatGPTAuthorizationServer.json["registration_endpoint"] as? String ==
            "https://macremote-test.trycloudflare.com/register"
        )
        #expect(
            try JSONSerialization.data(withJSONObject: chatGPTAuthorizationServer.json, options: .sortedKeys) ==
            JSONSerialization.data(withJSONObject: authorizationServer.json, options: .sortedKeys)
        )
    }

    @Test func confidentialOAuthMetadataOmitsDynamicRegistration() async throws {
        let coordinator = OAuthCoordinator(
            clientAuthentication: .confidentialClientRequired(
                OAuthConfidentialClientCredentials(
                    clientID: "macremote-oauth-confidential",
                    clientSecret: "client-secret"
                )
            )
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server")
        )
        #expect(authorizationServer.json["registration_endpoint"] == nil)
        #expect(
            authorizationServer.json["token_endpoint_auth_methods_supported"] as? [String] ==
            ["client_secret_basic", "client_secret_post"]
        )

        let registration = try await postJSON(
            url: base.appendingPathComponent("register"),
            body: [
                "client_name": "Dynamic Client",
                "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
                "scope": "mcp:tools"
            ]
        )
        #expect(registration.statusCode == 400)
        #expect(registration.json["error"] as? String == "invalid_request")
    }

    @Test func staticHeaderAuthCoexistsWithDynamicRegistrationOverHTTP() async throws {
        let coordinator = OAuthCoordinator(clientAuthentication: .dynamicPublicClients)
        coordinator.updateStaticHeaderToken(
            "static-header-token",
            clientName: "Static Header Client"
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server")
        )
        #expect(authorizationServer.statusCode == 200)
        #expect(
            authorizationServer.json["registration_endpoint"] as? String ==
            "\(base.absoluteString)/register"
        )

        let initializeBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "static-header-init",
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-11-25",
                "capabilities": [:],
                "clientInfo": [
                    "name": "Static Header Client",
                    "version": "1.0"
                ]
            ]
        ]
        let rejected = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: "wrong-token",
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: initializeBody
        )
        #expect(rejected.statusCode == 401)

        let initialized = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: "static-header-token",
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: initializeBody
        )
        #expect(initialized.statusCode == 200)
        let result = try #require(initialized.json["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-11-25")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "MacRemote")
    }

    @Test func chatGPTOriginCompletesPublicDynamicOAuthAndMCPFlow() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [
                        ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
                    ],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let publicBase = "https://macremote-test.trycloudflare.com"
        let resource = "\(publicBase)/mcp"
        let origin = "https://chatgpt.com"
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com",
            "Origin": origin
        ]
        try await waitForServerReady(base: base)

        let protectedResource = try await getWithHeaders(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource/mcp"),
            headers: forwardedHeaders
        )
        #expect(protectedResource.statusCode == 200)
        #expect(try decodeJSON(protectedResource.data)["resource"] as? String == resource)
        #expect(headerValue(protectedResource.headers, named: "Access-Control-Allow-Origin") == origin)
        #expect(headerValue(protectedResource.headers, named: "Vary") == "Origin")

        let authorizationServer = try await getWithHeaders(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server/mcp"),
            headers: forwardedHeaders
        )
        #expect(authorizationServer.statusCode == 200)
        let authorizationMetadata = try decodeJSON(authorizationServer.data)
        #expect(authorizationMetadata["registration_endpoint"] as? String == "\(publicBase)/register")
        #expect(authorizationMetadata["code_challenge_methods_supported"] as? [String] == ["S256"])
        #expect(headerValue(authorizationServer.headers, named: "Access-Control-Allow-Origin") == origin)
        #expect(headerValue(authorizationServer.headers, named: "Cache-Control") == "no-store")

        let legacyOriginDiscovery = try await getWithHeaders(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
            headers: [
                "Host": "macremote-test.trycloudflare.com",
                "Origin": "https://chat.openai.com"
            ]
        )
        #expect(legacyOriginDiscovery.statusCode == 200)
        #expect(
            headerValue(legacyOriginDiscovery.headers, named: "Access-Control-Allow-Origin") ==
            "https://chat.openai.com"
        )

        for untrustedOrigin in ["null", "https://chatgpt.com.evil.example"] {
            let rejected = try await getWithHeaders(
                url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
                headers: [
                    "Host": "macremote-test.trycloudflare.com",
                    "Origin": untrustedOrigin
                ]
            )
            #expect(rejected.statusCode == 403)
            #expect(headerValue(rejected.headers, named: "Access-Control-Allow-Origin") == nil)
        }

        let preflight = try await sendRequest(
            method: "OPTIONS",
            url: base.appendingPathComponent("register"),
            headers: forwardedHeaders.merging([
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "content-type"
            ]) { _, new in new }
        )
        #expect(preflight.statusCode == 204)
        #expect(preflight.data.isEmpty)
        #expect(headerValue(preflight.headers, named: "Content-Type") == nil)
        #expect(headerValue(preflight.headers, named: "Access-Control-Allow-Origin") == origin)
        #expect(headerValue(preflight.headers, named: "Access-Control-Allow-Methods") == "POST, OPTIONS")
        #expect(
            headerValue(preflight.headers, named: "Access-Control-Allow-Headers")?.contains("content-type") == true
        )
        #expect(headerValue(preflight.headers, named: "Vary") == "Origin")

        let redirectURI = "https://chatgpt.com/connector/oauth/test-callback"
        let registration = try await postJSON(
            url: base.appendingPathComponent("register"),
            headers: forwardedHeaders,
            body: [
                "client_name": "ChatGPT",
                "redirect_uris": [redirectURI],
                "grant_types": ["authorization_code", "refresh_token"],
                "response_types": ["code"],
                "token_endpoint_auth_method": "none",
                "scope": "mcp:tools"
            ]
        )
        #expect(registration.statusCode == 201)
        #expect(headerValue(registration.headers, named: "Access-Control-Allow-Origin") == origin)
        let clientID = try #require(registration.json["client_id"] as? String)
        #expect((registration.json["client_id_issued_at"] as? Int ?? 0) > 0)

        let verifier = "chatgpt-public-pkce-verifier-0123456789-ABCDEFGHIJKLMNO"
        var authorize = URLComponents(url: base.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "mcp:tools"),
            URLQueryItem(name: "state", value: "chatgpt-state"),
            URLQueryItem(name: "code_challenge", value: OAuthCoordinator.pkceChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource)
        ]
        let authorizationPage = try await getWithHeaders(
            url: try #require(authorize.url),
            headers: forwardedHeaders
        )
        #expect(authorizationPage.statusCode == 200)
        #expect(headerValue(authorizationPage.headers, named: "Access-Control-Allow-Origin") == origin)

        let requestID = try #require(coordinator.approvalSnapshot().first?.id)
        #expect(server.approveAuthorizationRequest(id: requestID))

        var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
        statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
        let authorizationStatus = try await getWithHeaders(
            url: try #require(statusURL.url),
            headers: forwardedHeaders
        )
        #expect(authorizationStatus.statusCode == 200)
        #expect(headerValue(authorizationStatus.headers, named: "Access-Control-Allow-Origin") == origin)
        let redirect = try #require(try decodeJSON(authorizationStatus.data)["redirect_uri"] as? String)
        let code = try #require(
            URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value
        )

        let token = try await postForm(
            url: base.appendingPathComponent("token"),
            headers: forwardedHeaders,
            form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ]
        )
        #expect(token.statusCode == 200)
        #expect(token.json["resource"] as? String == resource)
        #expect(headerValue(token.headers, named: "Cache-Control") == "no-store")
        #expect(headerValue(token.headers, named: "Pragma") == "no-cache")
        #expect(headerValue(token.headers, named: "Access-Control-Allow-Origin") == origin)
        let accessToken = try #require(token.json["access_token"] as? String)

        let unauthenticatedMCP = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            headers: forwardedHeaders,
            body: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]
        )
        #expect(unauthenticatedMCP.statusCode == 401)
        #expect(headerValue(unauthenticatedMCP.headers, named: "Access-Control-Allow-Origin") == origin)
        let exposed = try #require(
            headerValue(unauthenticatedMCP.headers, named: "Access-Control-Expose-Headers")
        )
        #expect(exposed.contains("WWW-Authenticate"))
        #expect(exposed.contains("MCP-Session-Id"))
        #expect(exposed.contains("MCP-Protocol-Version"))
        #expect(
            headerValue(unauthenticatedMCP.headers, named: "WWW-Authenticate")?.contains(
                "resource_metadata=\"\(publicBase)/.well-known/oauth-protected-resource/mcp\""
            ) == true
        )

        let initialize = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: accessToken,
            headers: forwardedHeaders.merging(["MCP-Protocol-Version": "2025-11-25"]) { _, new in new },
            body: [
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": ["name": "ChatGPT", "version": "1.0"]
                ]
            ]
        )
        #expect(initialize.statusCode == 200)
        #expect(headerValue(initialize.headers, named: "Access-Control-Allow-Origin") == origin)
        let initializeResult = try #require(initialize.json["result"] as? [String: Any])
        #expect((initializeResult["instructions"] as? String)?.contains("require approval") == true)

        let listed = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: accessToken,
            headers: forwardedHeaders.merging(["MCP-Protocol-Version": "2025-11-25"]) { _, new in new },
            body: ["jsonrpc": "2.0", "id": "tools", "method": "tools/list"]
        )
        #expect(listed.statusCode == 200)
        let tools = try #require((listed.json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let tool = try #require(tools.first)
        #expect((tool["securitySchemes"] as? [[String: Any]])?.first?["type"] as? String == "oauth2")
        #expect(
            ((tool["_meta"] as? [String: Any])?["securitySchemes"] as? [[String: Any]])?.first?["type"] as? String ==
            "oauth2"
        )

        // Captured ChatGPT shape (2026-08-01): after a successful legacy
        // initialize/list, ChatGPT sends a legacy tool call with only the
        // namespaced clientCapabilities field. That field must not promote the
        // request into modern validation without a protocolVersion claim.
        for headers in [
            forwardedHeaders,
            forwardedHeaders.merging(["MCP-Protocol-Version": "2025-11-25"]) { _, new in new }
        ] {
            let called = try await postJSON(
                url: base.appendingPathComponent("mcp"),
                bearerToken: accessToken,
                headers: headers,
                body: [
                    "jsonrpc": "2.0",
                    "id": "chatgpt-hybrid-call",
                    "method": "tools/call",
                    "params": [
                        "name": "test_echo",
                        "arguments": ["value": "chatgpt"],
                        "_meta": [
                            "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]
                        ]
                    ]
                ]
            )
            #expect(called.statusCode == 200)
            #expect(called.json["error"] == nil)
            let result = try #require(called.json["result"] as? [String: Any])
            #expect(result["resultType"] == nil)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["stdout"] as? String == "echo:chatgpt")
            #expect(structured["reason"] as? String == "ok")
        }
    }

    /// An app that asks for a secret of its own gets one. A method the server
    /// does not offer is refused, and neither answer is ever cached.
    @Test func registrationIssuesASecretOnlyForOfferedMethodsOverHTTP() async throws {
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com",
            "Origin": "https://chatgpt.com"
        ]
        try await waitForServerReady(base: base)

        for method in ["client_secret_basic", "client_secret_post"] {
            let registered = try await postJSON(
                url: base.appendingPathComponent("register"),
                headers: forwardedHeaders,
                body: [
                    "client_name": "ChatGPT",
                    "redirect_uris": ["https://chatgpt.com/connector/oauth/confidential-callback"],
                    "token_endpoint_auth_method": method,
                    "scope": "mcp:tools"
                ]
            )
            #expect(registered.statusCode == 201)
            #expect(registered.json["token_endpoint_auth_method"] as? String == method)
            #expect((registered.json["client_secret"] as? String)?.isEmpty == false)
            #expect(headerValue(registered.headers, named: "Cache-Control") == "no-store")
        }

        for method in ["tls_client_auth"] {
            let rejected = try await postJSON(
                url: base.appendingPathComponent("register"),
                headers: forwardedHeaders,
                body: [
                    "client_name": "ChatGPT",
                    "redirect_uris": ["https://chatgpt.com/connector/oauth/confidential-callback"],
                    "token_endpoint_auth_method": method,
                    "scope": "mcp:tools"
                ]
            )
            #expect(rejected.statusCode == 400)
            #expect(rejected.json["error"] as? String == "invalid_client_metadata")
            #expect(headerValue(rejected.headers, named: "Cache-Control") == "no-store")
            #expect(headerValue(rejected.headers, named: "Pragma") == "no-cache")
        }
    }

    @Test func oAuthProtectedMCPToolFlowOverHTTP() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [
                        ToolParameter(
                            name: "value",
                            title: "Value",
                            kind: .string,
                            maximumLength: 64
                        )
                    ],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        let noAuth = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        #expect(noAuth.statusCode == 401)
        let challenge = try #require(headerValue(noAuth.headers, named: "WWW-Authenticate"))
        #expect(challenge.contains("resource_metadata=\"http://127.0.0.1:\(port)/.well-known/oauth-protected-resource/mcp\""))
        #expect(challenge.contains("scope=\"mcp:tools\""))

        let invalidOrigin = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: ["Origin": "https://evil.example"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        #expect(invalidOrigin.statusCode == 403)

        let publicClientOriginOnDirectLocalServer = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: ["Origin": "https://chatgpt.com"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        #expect(publicClientOriginOnDirectLocalServer.statusCode == 403)

        let unsupportedProtocol = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: ["MCP-Protocol-Version": "2099-01-01"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        #expect(unsupportedProtocol.statusCode == 401)

        let getMCP = try await get(url: base.appendingPathComponent("mcp/test-instance"))
        #expect(getMCP.statusCode == 401)

        let deleteMCP = try await sendRequest(
            method: "DELETE",
            url: base.appendingPathComponent("mcp/test-instance")
        )
        #expect(deleteMCP.statusCode == 401)

        let verifier = "server-flow-verifier-0123456789-ABCDEFGHIJKLMNO"
        let registered = try await postJSON(
            url: base.appendingPathComponent("register"),
            body: [
                "client_name": "HTTP Test",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        #expect(registered.statusCode == 201)
        let clientID = try #require(registered.json["client_id"] as? String)

        var authorize = URLComponents(url: base.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/callback"),
            URLQueryItem(name: "scope", value: "mcp:tools"),
            URLQueryItem(name: "state", value: "state-token"),
            URLQueryItem(name: "code_challenge", value: OAuthCoordinator.pkceChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        let authorizationPage = try await get(url: try #require(authorize.url))
        #expect(authorizationPage.statusCode == 200)

        let requestID = try #require(coordinator.approvalSnapshot().first?.id)
        #expect(server.approveAuthorizationRequest(id: requestID))

        var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
        statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
        let status = try await getJSON(url: try #require(statusURL.url))
        let redirectURI = try #require(status.json["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let token = try await postForm(
            url: base.appendingPathComponent("token"),
            form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "code": code,
                "code_verifier": verifier
            ]
        )
        #expect(token.statusCode == 200)
        let accessToken = try #require(token.json["access_token"] as? String)

        let initialize = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "init",
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [:],
                    "clientInfo": [
                        "name": "HTTP Test",
                        "version": "1.0"
                    ]
                ]
            ]
        )
        #expect(initialize.statusCode == 200)
        let initializeResult = try #require(initialize.json["result"] as? [String: Any])
        let instructions = try #require(initializeResult["instructions"] as? String)
        #expect(instructions.contains("only tools the person shared"))
        #expect(instructions.contains("require approval on the Mac"))
        // Host-neutral: the instructions go to every app, whatever is installed.
        #expect(!instructions.contains("Federico"))
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "MacRemote")
        #expect(serverInfo["title"] as? String == "MacRemote")
        #expect(serverInfo["websiteUrl"] as? String == "https://www.macstories.net")
        #expect((serverInfo["description"] as? String) != nil)
        let icons = try #require(serverInfo["icons"] as? [[String: Any]])
        #expect(icons.count == 3)
        let icon128 = try #require(icons.first)
        #expect(icon128["src"] as? String == "http://127.0.0.1:\(port)/macremote-icon-128.png")
        #expect(icon128["mimeType"] as? String == "image/png")
        #expect(icon128["sizes"] as? [String] == ["128x128"])
        #expect(icons[1]["src"] as? String == "http://127.0.0.1:\(port)/macremote-icon.png")
        #expect(icons[1]["sizes"] as? [String] == ["512x512"])
        let dataIcon = try #require(icons.last)
        #expect((dataIcon["src"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(dataIcon["sizes"] as? [String] == ["64x64"])

        let toolsList = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "tools",
                "method": "tools/list"
            ]
        )
        #expect(toolsList.statusCode == 200)
        let toolsResult = try #require(toolsList.json["result"] as? [String: Any])
        let tools = try #require(toolsResult["tools"] as? [[String: Any]])
        let listedTool = try #require(tools.first)
        #expect(listedTool["name"] as? String == "test_echo")
        #expect(listedTool["title"] as? String == "Echo")
        let description = try #require(listedTool["description"] as? String)
        #expect(description.contains("Echo a test value."))
        #expect(description.contains("Read-only"))
        #expect((listedTool["outputSchema"] as? [String: Any]) != nil)
        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let valueSchema = try #require(properties["value"] as? [String: Any])
        #expect(valueSchema["title"] as? String == "Value")
        #expect(valueSchema["description"] as? String == "Value")
        #expect(valueSchema["maxLength"] as? Int == 64)
        let annotations = try #require(listedTool["annotations"] as? [String: Any])
        #expect(annotations["readOnlyHint"] as? Bool == true)
        #expect(annotations["destructiveHint"] as? Bool == false)
        #expect(annotations["idempotentHint"] as? Bool == true)
        #expect(annotations["openWorldHint"] as? Bool == false)
        let securitySchemes = try #require(listedTool["securitySchemes"] as? [[String: Any]])
        #expect(securitySchemes.first?["type"] as? String == "oauth2")
        #expect(securitySchemes.first?["scopes"] as? [String] == ["mcp:tools"])
        let toolMeta = try #require(listedTool["_meta"] as? [String: Any])
        let mirroredSecuritySchemes = try #require(toolMeta["securitySchemes"] as? [[String: Any]])
        #expect(mirroredSecuritySchemes.first?["scopes"] as? [String] == ["mcp:tools"])

        let authenticatedUnsupportedProtocol = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2099-01-01"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        #expect(authenticatedUnsupportedProtocol.statusCode == 400)
        let unsupportedProtocolError = try #require(
            authenticatedUnsupportedProtocol.json["error"] as? [String: Any]
        )
        #expect(unsupportedProtocolError["code"] as? Int == -32022)
        #expect(unsupportedProtocolError["message"] as? String == "Unsupported protocol version.")
        let unsupportedProtocolData = try #require(
            unsupportedProtocolError["data"] as? [String: Any]
        )
        #expect(unsupportedProtocolData["requested"] as? String == "2099-01-01")
        #expect(
            Set(try #require(unsupportedProtocolData["supported"] as? [String]))
                == ["2025-11-25", "2025-06-18", "2025-03-26"]
        )

        for method in ["GET", "DELETE"] {
            let authenticatedUnsupportedMethod = try await sendRequest(
                method: method,
                url: base.appendingPathComponent("mcp/test-instance"),
                headers: ["Authorization": "Bearer \(accessToken)"]
            )
            #expect(authenticatedUnsupportedMethod.statusCode == 405)
        }

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "call",
                "method": "tools/call",
                "params": [
                    "name": "test_echo",
                    "arguments": [
                        "value": "hello"
                    ]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let callResult = try #require(toolCall.json["result"] as? [String: Any])
        let structuredContent = try #require(callResult["structuredContent"] as? [String: Any])
        #expect(structuredContent["toolID"] as? String == "test_echo")
        #expect(structuredContent["stdout"] as? String == "echo:hello")
        #expect(structuredContent["succeeded"] as? Bool == true)
        #expect(structuredContent["reason"] as? String == "ok")
        let content = try #require(callResult["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("\"stdout\":\"echo:hello\""))

        let legacyMCPPath = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: accessToken,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy",
                "method": "ping"
            ]
        )
        #expect(legacyMCPPath.statusCode == 200)
    }

    @Test func tokenEndpointAcceptsPublicClientCodeExchangeWithoutRepeatedRedirectURI() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let resource = "\(base.absoluteString)/mcp/test-instance"
        let verifier = "server-public-client-verifier-0123456789-ABCDEFGHIJ"
        try await waitForServerReady(base: base)

        let registered = try await postJSON(
            url: base.appendingPathComponent("register"),
            body: [
                "client_name": "Public HTTP Test",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        #expect(registered.statusCode == 201)
        let clientID = try #require(registered.json["client_id"] as? String)

        var authorize = URLComponents(url: base.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/callback"),
            URLQueryItem(name: "scope", value: "mcp:tools"),
            URLQueryItem(name: "code_challenge", value: OAuthCoordinator.pkceChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: "\(resource)/")
        ]
        let authorizationPage = try await get(url: try #require(authorize.url))
        #expect(authorizationPage.statusCode == 200)

        let requestID = try #require(coordinator.approvalSnapshot().first?.id)
        #expect(server.approveAuthorizationRequest(id: requestID))

        var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
        statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
        let status = try await getJSON(url: try #require(statusURL.url))
        let redirectURI = try #require(status.json["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let token = try await postForm(
            url: base.appendingPathComponent("token"),
            headers: ["Authorization": basicAuthorizationHeader(username: clientID)],
            form: [
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": verifier,
                "resource": "\(resource)/"
            ]
        )
        #expect(token.statusCode == 200)
        #expect(token.json["resource"] as? String == resource)

        let accessToken = try #require(token.json["access_token"] as? String)
        let toolsList = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "tools",
                "method": "tools/list"
            ]
        )
        #expect(toolsList.statusCode == 200)
    }

    @Test func confidentialOAuthFlowAcceptsClientSecretBasic() async throws {
        let credentials = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-confidential",
            clientSecret: "correct-secret"
        )
        let coordinator = OAuthCoordinator(
            clientAuthentication: .confidentialClientRequired(credentials)
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let resource = "\(base.absoluteString)/mcp/test-instance"
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"
        let verifier = "server-confidential-verifier-0123456789-ABCDEFGHIJ"
        try await waitForServerReady(base: base)

        var authorize = URLComponents(url: base.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
        authorize.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: credentials.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: "mcp:tools"),
            URLQueryItem(name: "state", value: "state-token"),
            URLQueryItem(name: "code_challenge", value: OAuthCoordinator.pkceChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "resource", value: resource)
        ]
        let authorizationPage = try await get(url: try #require(authorize.url))
        #expect(authorizationPage.statusCode == 200)

        let requestID = try #require(coordinator.approvalSnapshot().first?.id)
        #expect(server.approveAuthorizationRequest(id: requestID))

        var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
        statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
        let status = try await getJSON(url: try #require(statusURL.url))
        let redirect = try #require(status.json["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let missingSecret = try await postForm(
            url: base.appendingPathComponent("token"),
            form: [
                "grant_type": "authorization_code",
                "client_id": credentials.clientID,
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ]
        )
        #expect(missingSecret.statusCode == 401)
        #expect(missingSecret.json["error"] as? String == "invalid_client")

        let token = try await postForm(
            url: base.appendingPathComponent("token"),
            headers: [
                "Authorization": basicAuthorizationHeader(
                    username: credentials.clientID,
                    password: credentials.clientSecret
                )
            ],
            form: [
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ]
        )
        #expect(token.statusCode == 200)
        let accessToken = try #require(token.json["access_token"] as? String)
        let refreshToken = try #require(token.json["refresh_token"] as? String)
        #expect(coordinator.connectedClientSnapshot().first?.redirectURIs == [redirectURI])

        let refreshWithoutSecret = try await postForm(
            url: base.appendingPathComponent("token"),
            form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ]
        )
        #expect(refreshWithoutSecret.statusCode == 401)
        #expect(refreshWithoutSecret.json["error"] as? String == "invalid_client")

        let toolsList = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "tools",
                "method": "tools/list"
            ]
        )
        #expect(toolsList.statusCode == 200)
    }

    @Test func dottedToolNamesRemainCallableForExistingClients() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [
                        ToolParameter(
                            name: "value",
                            title: "Value",
                            kind: .string,
                            maximumLength: 64
                        )
                    ],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "call",
                "method": "tools/call",
                "params": [
                    "name": "test_echo",
                    "arguments": [
                        "value": "legacy"
                    ]
                ]
            ]
        )

        #expect(toolCall.statusCode == 200)
        let callResult = try #require(toolCall.json["result"] as? [String: Any])
        let structuredContent = try #require(callResult["structuredContent"] as? [String: Any])
        #expect(structuredContent["toolID"] as? String == "test_echo")
        #expect(structuredContent["stdout"] as? String == "echo:legacy")
    }

    @Test func publicForwardedMCPAliasRequiresBearerAndUsesSameGrant() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com"
        ]
        try await waitForServerReady(base: base)

        let unauthenticatedPublicAlias = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            headers: forwardedHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-public-unauthenticated",
                "method": "ping"
            ]
        )
        #expect(unauthenticatedPublicAlias.statusCode == 401)
        #expect(
            headerValue(unauthenticatedPublicAlias.headers, named: "WWW-Authenticate")?
                .contains("resource_metadata=\"https://macremote-test.trycloudflare.com/.well-known/oauth-protected-resource/mcp\"") == true)

        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server,
            headers: forwardedHeaders
        )

        var lowercaseBearerHeaders = forwardedHeaders
        lowercaseBearerHeaders["Authorization"] = "bearer \(accessToken)"
        let lowercaseBearer = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: lowercaseBearerHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "lowercase-bearer",
                "method": "ping"
            ]
        )
        #expect(lowercaseBearer.statusCode == 200)

        let authenticatedPublicAlias = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: accessToken,
            headers: forwardedHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-public-authenticated",
                "method": "ping"
            ]
        )
        #expect(authenticatedPublicAlias.statusCode == 200)

        let instancePublicPath = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: forwardedHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "instance-public",
                "method": "ping"
            ]
        )
        #expect(instancePublicPath.statusCode == 200)
    }

    @Test func forwardedHostHeaderNeverChangesWhichAddressWasUsed() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let spoofedHeaders = [
            "Host": "macremote-test.trycloudflare.com",
            "X-Forwarded-Host": "127.0.0.1:\(port)",
            "X-Forwarded-Proto": "http"
        ]
        try await waitForServerReady(base: base)

        let publicHealth = try await getJSON(url: base.appendingPathComponent("health"), headers: spoofedHeaders)
        #expect(publicHealth.json["public_metadata"] as? Bool == true)
        #expect(publicHealth.json["instance_id"] == nil)
        #expect(publicHealth.json["tool_count"] == nil)

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
            headers: spoofedHeaders
        )
        #expect(authorizationServer.json["issuer"] as? String == "https://macremote-test.trycloudflare.com")

        let legacyPublicPath = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            headers: spoofedHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-public",
                "method": "ping"
            ]
        )
        #expect(legacyPublicPath.statusCode == 401)

        // The other direction: a caller on this Mac cannot pass for the
        // public link by naming it in a forwarding header.
        let localHealth = try await getJSON(
            url: base.appendingPathComponent("health"),
            headers: ["X-Forwarded-Host": "macremote-test.trycloudflare.com"]
        )
        #expect(localHealth.json["public_metadata"] as? Bool == false)
        #expect(localHealth.json["instance_id"] as? String == "test-instance")
    }

    @Test func hostsThisMacDoesNotServeAreRefused() async throws {
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        // A web page that points its own name at 127.0.0.1, another public
        // address, and loopback names that are not this server's port.
        let refusedHosts = [
            "attacker.example:\(port)",
            "macremote-other.trycloudflare.com",
            "127.0.0.1:1",
            "localhost"
        ]
        for host in refusedHosts {
            let refused = try await getJSON(
                url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
                headers: ["Host": host]
            )
            #expect(refused.statusCode == 421, "\(host)")
            #expect(refused.json["error"] as? String == "misdirected_request", "\(host)")
            #expect(refused.json["issuer"] == nil, "\(host)")
        }

        let servedHosts = [
            "localhost:\(port)": "http://127.0.0.1:\(port)",
            "[::1]:\(port)": "http://127.0.0.1:\(port)",
            "MacRemote-Test.TryCloudflare.com": "https://macremote-test.trycloudflare.com",
            "macremote-test.trycloudflare.com:443": "https://macremote-test.trycloudflare.com"
        ]
        for (host, issuer) in servedHosts {
            let served = try await getJSON(
                url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
                headers: ["Host": host]
            )
            #expect(served.statusCode == 200, "\(host)")
            #expect(served.json["issuer"] as? String == issuer, "\(host)")
        }
    }

    @Test func tokenIssuedThroughOnePublicHostIsRejectedThroughAnother() async throws {
        let coordinator = OAuthCoordinator()
        let publicHost = CurrentPublicHost("macremote-one.trycloudflare.com")
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [
                        ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
                    ],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            publicHost: { publicHost.value },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let originalOrigin = [
            "Host": "macremote-one.trycloudflare.com"
        ]
        let replayOrigin = [
            "Host": "macremote-two.trycloudflare.com"
        ]
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server,
            headers: originalOrigin
        )

        let authorized = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: originalOrigin,
            body: [
                "jsonrpc": "2.0",
                "id": "same-origin",
                "method": "tools/list"
            ]
        )
        #expect(authorized.statusCode == 200)

        // A token issued through the public link is not a local token.
        let local = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            body: [
                "jsonrpc": "2.0",
                "id": "local",
                "method": "tools/list"
            ]
        )
        #expect(local.statusCode == 401)

        // An Instant Link gets a new address every time it starts.
        publicHost.value = "macremote-two.trycloudflare.com"

        let replayed = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: replayOrigin,
            body: [
                "jsonrpc": "2.0",
                "id": "replay-origin",
                "method": "tools/list"
            ]
        )
        #expect(replayed.statusCode == 401)

        let previousAddress = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: originalOrigin,
            body: [
                "jsonrpc": "2.0",
                "id": "previous-address",
                "method": "tools/list"
            ]
        )
        #expect(previousAddress.statusCode == 421)
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.pocketCTLExecutablePath != nil, "PocketCTL is not installed on this Mac."))
    func mcpRunsInstalledPocketCTLReadOnlyCommand() async throws {
        let pocketCTLPath = try #require(DefaultToolPresetCatalog.pocketCTLExecutablePath)

        let tool = ToolDefinition(
            id: "pocketctl_whoami",
            name: "PocketCTL Whoami",
            summary: "Return cached Pocket Casts account metadata.",
            executablePath: pocketCTLPath,
            argumentPattern: ["whoami", "--json"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 512 * 1024,
            origin: .userDefined,
            category: .podcasts
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: [
                    "HOME": ExecutableLocator.homeDirectory,
                    "PATH": ExecutableLocator.searchDirectories.joined(separator: ":")
                ]
            )
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let health = try await getJSON(url: base.appendingPathComponent("health"))
        #expect(health.json["tool_count"] as? Int == 1)

        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "pocketctl",
                "method": "tools/call",
                "params": [
                    "name": "pocketctl_whoami",
                    "arguments": [:]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)

        let callResult = try #require(toolCall.json["result"] as? [String: Any])
        let structuredContent = try #require(callResult["structuredContent"] as? [String: Any])
        #expect(structuredContent["succeeded"] as? Bool == true)
        #expect(structuredContent["exitCode"] as? Int == 0)
        let stdout = try #require(structuredContent["stdout"] as? String)
        #expect(stdout.contains("\"email\""))
        #expect(stdout.contains("\"user_uuid\""))
    }

    @Test func fileReadToolsListServesTypedChunkDefaults() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                FileTransferToolCatalog.readFileTool,
                FileTransferToolCatalog.listTreeTool
            ],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server
        )

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let readTool = try #require(
            tools.first { $0["name"] as? String == FileTransferToolCatalog.readFileTool.id }
        )
        let readInput = try #require(readTool["inputSchema"] as? [String: Any])
        let readProperties = try #require(readInput["properties"] as? [String: Any])
        let length = try #require(readProperties["length"] as? [String: Any])
        #expect(length["type"] as? String == "integer")
        #expect(length["default"] as? Int == FileTransferToolCatalog.readFileChunkByteLimit)
        #expect(length["minimum"] as? Int == 1)
        #expect(length["maximum"] as? Int == FileTransferToolCatalog.readFileChunkByteLimit)

        let listTool = try #require(
            tools.first { $0["name"] as? String == FileTransferToolCatalog.listTreeTool.id }
        )
        let listInput = try #require(listTool["inputSchema"] as? [String: Any])
        let listProperties = try #require(listInput["properties"] as? [String: Any])
        let includeSizes = try #require(listProperties["include_sizes"] as? [String: Any])
        #expect(includeSizes["type"] as? String == "boolean")
        #expect(includeSizes["default"] as? Bool == true)
    }

    @Test func genericCLIAdapterDescriptionExplainsDirectArgvSemantics() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test_codex",
            name: "Codex CLI",
            summary: "Run Codex by passing argv directly.",
            executablePath: "/usr/local/bin/codex",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                ),
                ToolParameter(
                    name: "stdin",
                    title: "Standard Input",
                    kind: .string,
                    required: false
                )
            ],
            capability: .destructive,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            permissionRequirements: [.screenRecording, .accessibility]
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(tools.first)
        let description = try #require(listedTool["description"] as? String)
        #expect(description.contains("No shell"))
        #expect(description.contains("no `~`"))
        #expect(description.contains("global options such as `--ask-for-approval` and `--sandbox` must appear before `exec`"))
        #expect(description.contains("May require macOS privacy permission for Screen Recording, Accessibility"))

        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let argsSchema = try #require(properties["args"] as? [String: Any])
        #expect((argsSchema["description"] as? String)?.contains("No shell is used") == true)

        let annotations = try #require(listedTool["annotations"] as? [String: Any])
        #expect(annotations["openWorldHint"] as? Bool == true)
        #expect(annotations["idempotentHint"] as? Bool == false)
    }

    @Test func claudeCLIAdapterDescriptionExplainsMCPFriendlyInvocation() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test_claude",
            name: "Claude Code",
            summary: "Run Claude Code by passing argv directly.",
            executablePath: "/usr/local/bin/claude",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                ),
                ToolParameter(
                    name: "stdin",
                    title: "Standard Input",
                    kind: .string,
                    required: false
                )
            ],
            capability: .destructive,
            timeoutSeconds: 60,
            outputByteLimit: 5 * 1024 * 1024
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(tools.first)
        let description = try #require(listedTool["description"] as? String)
        #expect(description.contains("non-interactive MCP-safe calls"))
        #expect(description.contains("`--print`"))
        #expect(description.contains("`--output-format text`, `json`, or `stream-json`"))
        #expect(description.contains("`--mcp-config`"))
        #expect(description.contains("Avoid bare interactive sessions"))
    }

    // DL-10/R10 snapshot: a harvested publisher summary composes LAST, quoted and
    // provenance-labeled, after every piece of MacRemote's product-authored text.
    @Test func harvestedSummaryComposesLastWithProvenanceFrame() async throws {
        let coordinator = OAuthCoordinator()
        let tool = makeScannedAdapterTool(
            summary: "Search tool like grep and The Silver Searcher",
            summaryIsHarvested: true,
            summaryOrigin: "Homebrew"
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(tools.first)
        let description = try #require(listedTool["description"] as? String)

        #expect(description == [
            "Pass exact argv items in `args` (optional `stdin`). No shell: absolute paths only; no `~`, `$HOME`, pipes, redirection, globs, substitution, or env assignments; one flag/value per argv item.",
            "Destructive or broad CLI access: requires host approval.",
            "Publisher's description (Homebrew, unverified): \"Search tool like grep and The Silver Searcher\""
        ].joined(separator: " "))
    }

    @Test func userEditedSummaryComposesFirstWithoutFrame() async throws {
        let coordinator = OAuthCoordinator()
        let tool = makeScannedAdapterTool(
            summary: "My own words about ripgrep.",
            summaryIsHarvested: false,
            summaryOrigin: nil
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(tools.first)
        let description = try #require(listedTool["description"] as? String)

        #expect(description.hasPrefix("My own words about ripgrep. Pass exact argv items"))
        #expect(!description.contains("Publisher's description"))
    }

    @Test func pocketCTLCLIAdapterDescriptionExplainsJSONAndDryRun() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test_pocketctl",
            name: "Run PocketCTL",
            summary: "Run PocketCTL by passing argv directly.",
            executablePath: "/usr/local/bin/pocketctl",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .destructive,
            timeoutSeconds: 30,
            outputByteLimit: 2048 * 1024,
            category: .podcasts
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(tools.first)

        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let argsSchema = try #require(properties["args"] as? [String: Any])
        let argsDescription = try #require(argsSchema["description"] as? String)
        #expect(argsDescription.contains("Exact PocketCTL argv items"))
        #expect(argsDescription.contains("open URL --json"))
        #expect(argsDescription.contains("open URL --seek"))
        #expect(argsDescription.contains("played-state writes"))
    }

    @Test func habitCTLCLIAdapterDescriptionExplainsJSONAndDryRun() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test_habitctl",
            name: "Run HabitCTL",
            summary: "Run HabitCTL by passing argv directly.",
            executablePath: "/usr/local/bin/habitctl",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .destructive,
            timeoutSeconds: 30,
            outputByteLimit: 2048 * 1024,
            category: .habits
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(tools.first)

        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let argsSchema = try #require(properties["args"] as? [String: Any])
        let argsDescription = try #require(argsSchema["description"] as? String)
        #expect(argsDescription.contains("Exact HabitCTL argv items"))
        #expect(argsDescription.contains("note writes"))
    }

    @Test func federicoCLIAdapterDescriptionsExplainProductSafeUsage() async throws {
        let coordinator = OAuthCoordinator()
        let expectations = [
            ("goodlinksctl", "Resolve exact link IDs", "links delete ID --dry-run"),
            ("frames", "Prefer a leading `--json`", "`setup` changes downloaded assets"),
            ("iris", "Always pass `--json`", "13 confirmation actions"),
            ("iphone", "Always pass `--json`", "transport management stay blocked")
        ]
        let tools = expectations.map { executable, _, _ in
            ToolDefinition(
                id: "test_\(executable)",
                name: executable,
                summary: "Run \(executable) with exact arguments.",
                executablePath: "/usr/local/bin/\(executable)",
                argumentPattern: ["{args}"],
                parameters: [
                    ToolParameter(
                        name: "args",
                        title: "Arguments",
                        kind: .stringArray,
                        required: false
                    )
                ],
                capability: .destructive,
                timeoutSeconds: 90,
                outputByteLimit: 8192 * 1024,
                category: .readLater
            )
        }
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let listedTools = try await toolsList(base: base, accessToken: accessToken)

        for (executable, firstExpectedPhrase, secondExpectedPhrase) in expectations {
            let listedTool = try #require(listedTools.first { $0["name"] as? String == "test_\(executable)" })
            let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
            let properties = try #require(inputSchema["properties"] as? [String: Any])
            let argsSchema = try #require(properties["args"] as? [String: Any])
            let argsDescription = try #require(argsSchema["description"] as? String)
            #expect(argsDescription.contains("No shell is used"))
            #expect(argsDescription.contains(firstExpectedPhrase))
            #expect(argsDescription.contains(secondExpectedPhrase))
        }
    }

    @Test func dedicatedFedericoToolsExposeTypedAgentSchemas() async throws {
        let presetIDs = [
            "preset.habitctl.log_value",
            "preset.goodlinksctl.save"
        ]
        let configuredTools = try presetIDs.map { presetID in
            let preset = try #require(DefaultToolPresetCatalog.preset(id: presetID))
            return try preset.draft.makeTool(id: preset.toolID)
        }
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: configuredTools,
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server
        )
        let listedTools = try await toolsList(base: base, accessToken: accessToken)

        func property(_ toolID: String, _ parameter: String) throws -> [String: Any] {
            let tool = try #require(listedTools.first { $0["name"] as? String == toolID })
            let input = try #require(tool["inputSchema"] as? [String: Any])
            let properties = try #require(input["properties"] as? [String: Any])
            return try #require(properties[parameter] as? [String: Any])
        }

        let habitValue = try property("habitctl_log_value", "value")
        #expect(habitValue["type"] as? String == "number")
        #expect(habitValue["minimum"] as? Double == -1_000_000_000)
        #expect(habitValue["maximum"] as? Double == 1_000_000_000)

        let url = try property("goodlinksctl_save", "url")
        #expect(url["type"] as? String == "string")
        #expect(url["format"] as? String == "uri")
    }

    @Test func toolsListReturnsFullCatalogInOneResponse() async throws {
        let coordinator = OAuthCoordinator()
        // Deliberately far above the old 60-tool page size: a large shared
        // catalog must come back whole, with no nextCursor, so clients that
        // don't follow pagination (Raycast, Minis) still see every tool.
        let tools = makePaginationTestTools(count: 257)
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let response = try await toolsListResponse(base: base, accessToken: accessToken)
        let listedTools = try #require(response.tools)
        #expect(listedTools.count == tools.count)
        #expect(response.nextCursor == nil)
        let meta = try #require(response.meta)
        #expect((meta[MCPCatalogMetadata.revisionMetaKey] as? String)?.hasPrefix("sha256:") == true)
        #expect(listedTools.map { $0["title"] as? String } == tools.map(\.name))
    }

    @Test func toolsListIgnoresUnsolicitedCursor() async throws {
        let coordinator = OAuthCoordinator()
        // The server never issues a cursor, so any cursor a client sends is
        // stale/unsolicited. It must be ignored and the full catalog returned
        // — never a -32602 that would strand a client on an empty list.
        let tools = makePaginationTestTools(count: 130)
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let response = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "stale-cursor",
                "method": "tools/list",
                "params": [
                    "cursor": "whatever-a-client-cached"
                ]
            ]
        )
        #expect(response.statusCode == 200)
        #expect(response.json["error"] == nil)
        let result = try #require(response.json["result"] as? [String: Any])
        let listedTools = try #require(result["tools"] as? [[String: Any]])
        #expect(listedTools.count == tools.count)
        #expect(result["nextCursor"] == nil)
    }

    @Test func catalogRevisionIsOrderIndependentAndContractSensitive() {
        let first: [String: Any] = [
            "name": "alpha_tool",
            "title": "Alpha",
            "inputSchema": ["type": "object", "properties": [:]],
            "outputSchema": ["type": "object"],
            "annotations": ["readOnlyHint": true],
            "securitySchemes": [["type": "oauth2", "scopes": ["mcp:tools"]]]
        ]
        let second: [String: Any] = [
            "name": "beta_tool",
            "title": "Beta",
            "inputSchema": ["type": "object", "properties": [:]],
            "outputSchema": ["type": "object"],
            "annotations": ["readOnlyHint": true],
            "securitySchemes": [["type": "oauth2", "scopes": ["mcp:tools"]]]
        ]

        let forward = MCPCatalogMetadata.revision(for: [first, second])
        let reversed = MCPCatalogMetadata.revision(for: [second, first])
        #expect(forward == reversed)

        var changed = first
        changed["inputSchema"] = [
            "type": "object",
            "properties": ["query": ["type": "string"]]
        ]
        #expect(MCPCatalogMetadata.revision(for: [changed, second]) != forward)
    }

    /// An app that gives up on a call (the user pressed Stop, or it timed
    /// out) must not leave a prompt the owner can still approve.
    @Test func disconnectingWithdrawsTheWaitingApproval() async throws {
        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 30)
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_write",
                    name: "Write",
                    summary: "Writes.",
                    executablePath: "/bin/echo",
                    argumentPattern: [],
                    parameters: [],
                    capability: .write,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let callTask = Task {
            _ = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: accessToken,
                headers: ["MCP-Protocol-Version": "2025-11-25"],
                body: [
                    "jsonrpc": "2.0",
                    "id": "call",
                    "method": "tools/call",
                    "params": ["name": "test_write", "arguments": [:]]
                ]
            )
        }
        let approval = try await waitForPendingToolApproval(in: toolApprovals)

        // Cancelling the request closes its connection.
        callTask.cancel()
        _ = await callTask.result

        var state = approval.state
        for _ in 0..<100 where state == .pending {
            try await Task.sleep(nanoseconds: 20_000_000)
            state = toolApprovals.approvalSnapshot().first { $0.id == approval.id }?.state ?? .pending
        }
        #expect(state == .expired)
        #expect(!toolApprovals.approve(requestID: approval.id))
    }

    /// The owner must never be asked to approve a call that cannot run: the
    /// write below names a protected folder and is refused with no prompt.
    @Test func aCallThatCannotRunIsRefusedBeforeAnyApprovalPrompt() async throws {
        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let tool = FileTransferToolCatalog.writeFileTool
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: ExecutableLocator.toolEnvironment
            )
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "call",
                "method": "tools/call",
                "params": [
                    "name": tool.id,
                    "arguments": ["path": "~/.ssh/authorized_keys", "data": "x", "encoding": "utf8"]
                ]
            ]
        )

        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["reason"] as? String == "invalid_argument")
        #expect(toolApprovals.approvalSnapshot().isEmpty)
    }

    @Test func destructiveMCPToolCallRequiresHostApproval() async throws {
        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_remctl_run",
                    name: "Run RemCTL",
                    summary: "Run full RemCTL.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{args}"],
                    parameters: [
                        ToolParameter(
                            name: "args",
                            title: "Arguments",
                            kind: .stringArray,
                            required: false
                        )
                    ],
                    capability: .destructive,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let callTask = Task { () throws -> ToolCallResultResponse in
            let response = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: accessToken,
                headers: ["MCP-Protocol-Version": "2025-11-25"],
                body: [
                    "jsonrpc": "2.0",
                    "id": "call",
                    "method": "tools/call",
                    "params": [
                        "name": "test_remctl_run",
                        "arguments": [
                            "args": ["add", "Test", "-l", "Work"]
                        ]
                    ]
                ]
            )
            let result = response.json["result"] as? [String: Any]
            let structuredContent = result?["structuredContent"] as? [String: Any]
            return ToolCallResultResponse(
                statusCode: response.statusCode,
                isError: result?["isError"] as? Bool,
                stderr: structuredContent?["stderr"] as? String,
                reason: structuredContent?["reason"] as? String
            )
        }

        let approval = try await waitForPendingToolApproval(in: toolApprovals)
        #expect(approval.toolID == "test_remctl_run")
        #expect(approval.clientName == "HTTP Test")
        #expect(approval.argumentsSummary.contains("args=add Test -l Work"))
        #expect(toolApprovals.deny(requestID: approval.id))

        let deniedCall = try await callTask.value
        #expect(deniedCall.statusCode == 200)
        #expect(deniedCall.isError == true)
        #expect(deniedCall.stderr == "Tool call was not approved on the host Mac.")
        #expect(deniedCall.reason == "not_approved")
    }

    @Test func clientToolPermissionSkipsHostApprovalForDestructiveTool() async throws {
        let defaultsSuite = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 1)
        let permissions = ClientToolPermissionStore(userDefaults: defaults)
        let tool = ToolDefinition(
            id: "test_remctl_run",
            name: "Run RemCTL",
            summary: "Run full RemCTL.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .destructive,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: FakeToolExecutor(),
            clientToolPermissionStore: permissions
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let client = try #require(coordinator.connectedClientSnapshot().first)
        _ = permissions.setAllowed(true, clientTrustID: client.trustID, tool: tool)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "call",
                "method": "tools/call",
                "params": [
                    "name": "test_remctl_run",
                    "arguments": [
                        "args": ["--help"]
                    ]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let result = try #require(toolCall.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(toolApprovals.approvalSnapshot().isEmpty)
    }

    /// D49 end to end: the every-call default no longer survives an explicit
    /// grant. `pocketctl_run` is the exact tool that kept prompting Federico.
    @Test func clientToolPermissionSkipsApprovalForEveryCallFlexibleCommand() async throws {
        let defaultsSuite = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 1)
        let permissions = ClientToolPermissionStore(userDefaults: defaults)
        let decisionLogURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("approval-decisions-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: decisionLogURL) }
        let decisionLog = ApprovalDecisionLog(fileURL: decisionLogURL)
        let tool = ToolDefinition(
            id: "pocketctl_run",
            name: "PocketCTL Flexible Command",
            summary: "Run full PocketCTL.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .destructive,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            approvalPolicy: .everyCall
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: FakeToolExecutor(),
            clientToolPermissionStore: permissions,
            approvalDecisionLog: decisionLog
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let client = try #require(coordinator.connectedClientSnapshot().first)
        _ = permissions.setAllowed(true, clientTrustID: client.trustID, tool: tool)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "call",
                "method": "tools/call",
                "params": [
                    "name": "pocketctl_run",
                    "arguments": [
                        "args": ["show", "--json"]
                    ]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let result = try #require(toolCall.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(toolApprovals.approvalSnapshot().isEmpty)

        // The grant-hit decision was recorded with identifiers only.
        let grantDecision = try #require(decisionLog.snapshot.last)
        #expect(grantDecision.toolID == "pocketctl_run")
        #expect(grantDecision.source == .alwaysAllowGrant)
        #expect(grantDecision.grantStoreHit)
        #expect(grantDecision.capability == "destructive")
        #expect(grantDecision.approvalPolicy == "everyCall")
        #expect(grantDecision.clientTrustIDPrefix == String(client.trustID.prefix(24)))

        // Revoking the grant puts the tool back behind the approval gate.
        _ = permissions.setAllowed(false, clientTrustID: client.trustID, tool: tool)
        let gatedCall = Task { () throws -> ToolCallResultResponse in
            let response = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: accessToken,
                headers: ["MCP-Protocol-Version": "2025-11-25"],
                body: [
                    "jsonrpc": "2.0",
                    "id": "gated",
                    "method": "tools/call",
                    "params": [
                        "name": "pocketctl_run",
                        "arguments": ["args": ["show", "--json"]]
                    ]
                ]
            )
            let gatedResult = response.json["result"] as? [String: Any]
            let structuredContent = gatedResult?["structuredContent"] as? [String: Any]
            return ToolCallResultResponse(
                statusCode: response.statusCode,
                isError: gatedResult?["isError"] as? Bool,
                stderr: structuredContent?["stderr"] as? String,
                reason: structuredContent?["reason"] as? String
            )
        }
        let approval = try await waitForPendingToolApproval(in: toolApprovals)
        #expect(approval.toolID == "pocketctl_run")
        #expect(toolApprovals.deny(requestID: approval.id))

        let denied = try await gatedCall.value
        #expect(denied.isError == true)
        #expect(denied.reason == "not_approved")

        // The denial was recorded as a grant-store miss, and the ring buffer
        // survives a "relaunch" (a fresh instance reading the same file).
        let deniedDecision = try #require(decisionLog.snapshot.last)
        #expect(deniedDecision.source == .userDenied)
        #expect(deniedDecision.grantStoreHit == false)
        let reloaded = ApprovalDecisionLog(fileURL: decisionLogURL)
        #expect(reloaded.snapshot == decisionLog.snapshot)
    }

    @Test func toolsListReflectsRuntimeUpdatesWithoutRestart() async throws {
        let coordinator = OAuthCoordinator()
        let firstTool = ToolDefinition(
            id: "test_first",
            name: "First",
            summary: "First dynamic tool.",
            executablePath: "/bin/echo",
            argumentPattern: ["first"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let secondTool = ToolDefinition(
            id: "test_second",
            name: "Second",
            summary: "Second dynamic tool.",
            executablePath: "/bin/echo",
            argumentPattern: ["second"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let runtime = ToolSurfaceRuntime(
            tools: [firstTool],
            environment: [:]
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            toolProvider: {
                runtime.toolsSnapshot()
            },
            authCoordinator: coordinator,
            toolExecutor: runtime
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let initialResponse = try await toolsListResponse(base: base, accessToken: accessToken)
        let initialList = try #require(initialResponse.tools)
        let initialRevision = try #require(
            initialResponse.meta?[MCPCatalogMetadata.revisionMetaKey] as? String
        )
        #expect(initialList.map { $0["name"] as? String } == ["test_first"])

        runtime.update(tools: [firstTool, secondTool])
        let updatedResponse = try await toolsListResponse(base: base, accessToken: accessToken)
        let updatedList = try #require(updatedResponse.tools)
        let updatedRevision = try #require(
            updatedResponse.meta?[MCPCatalogMetadata.revisionMetaKey] as? String
        )
        #expect(
            Set(updatedList.compactMap { $0["name"] as? String }) ==
            Set(["test_first", "test_second"])
        )
        #expect(initialRevision != updatedRevision)
    }

    @Test func bridgeSessionURLIsNotExposedOrIncludedInCatalogRevision() async throws {
        func bridgeTool(session: String) -> ToolDefinition {
            ToolDefinition(
                id: "stable_server_find",
                permissionEpoch: "stable-bridge-generation",
                name: "Stable Server: Find",
                summary: "Find an upstream item.",
                executablePath: "",
                argumentPattern: [],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 30,
                outputByteLimit: 1_024,
                origin: .userDefined,
                category: .developer,
                backend: .mcpHTTPBridge,
                mcpBridge: MCPBridgeConfiguration(
                    serverIdentity: "source.stable_server",
                    serverName: "Stable Server",
                    serverURL: "http://127.0.0.1:9000/mcp?session=\(session)&access_token=secret-\(session)",
                    toolName: "find"
                )
            )
        }

        let coordinator = OAuthCoordinator()
        let runtime = ToolSurfaceRuntime(tools: [bridgeTool(session: "first")], environment: [:])
        let server = LocalMCPServer(
            instanceID: "test-instance",
            toolProvider: { runtime.toolsSnapshot() },
            authCoordinator: coordinator,
            toolExecutor: runtime
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let first = try await toolsListResponse(base: base, accessToken: accessToken)
        let firstRevision = try #require(first.meta?[MCPCatalogMetadata.revisionMetaKey] as? String)
        let firstDescriptorData = try JSONSerialization.data(withJSONObject: try #require(first.tools))
        let firstDescriptorText = String(decoding: firstDescriptorData, as: UTF8.self)
        #expect(!firstDescriptorText.contains("session="))
        #expect(!firstDescriptorText.contains("access_token"))
        #expect(!firstDescriptorText.contains("secret-first"))

        runtime.update(tools: [bridgeTool(session: "second")])
        let second = try await toolsListResponse(base: base, accessToken: accessToken)
        let secondRevision = try #require(second.meta?[MCPCatalogMetadata.revisionMetaKey] as? String)
        #expect(secondRevision == firstRevision)
    }

    @Test func mcpToolNamesUseStableSemanticIDsDirectly() async throws {
        let coordinator = OAuthCoordinator()
        let tools = [
            ToolDefinition(
                id: "preset_filesystem_list_directory",
                name: "List Directory",
                summary: "List a directory.",
                executablePath: "/bin/ls",
                argumentPattern: ["{path}"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024
            ),
            ToolDefinition(
                id: "remctl_today",
                name: "Today",
                summary: "Return reminders.",
                executablePath: "/bin/echo",
                argumentPattern: ["today"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024
            ),
            ToolDefinition(
                id: "very_long_semantic_tool_name",
                name: "Long",
                summary: "Long internal id.",
                executablePath: "/bin/echo",
                argumentPattern: ["long"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024
            ),
            ToolDefinition(
                id: "same_name",
                name: "Same Name",
                summary: "First colliding id.",
                executablePath: "/bin/echo",
                argumentPattern: ["same"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024
            ),
            ToolDefinition(
                id: "same_name_2",
                name: "Same Name Collision",
                summary: "Second colliding id.",
                executablePath: "/bin/echo",
                argumentPattern: ["same"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024
            )
        ]
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let listedTools = try await toolsList(base: base, accessToken: accessToken)
        let names = listedTools.compactMap { $0["name"] as? String }
        #expect(names == tools.map(\.id))
        #expect(names.contains("remctl_today"))
        #expect(names.allSatisfy { !$0.hasPrefix("custom_") })

        for name in names {
            #expect(name.count <= 64)
            #expect(name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
        }
    }

    @Test func mcpBridgeToolExposesUpstreamSchemaAndForwardsJSONArguments() async throws {
        let bridgeTool = ToolDefinition(
            id: "mcp_paste_search",
            name: "Paste Search",
            summary: "Search Paste through its local MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            permissionRequirements: [.localNetwork],
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "paste",
                serverURL: "http://127.0.0.1:39725/mcp",
                toolName: "search",
                toolTitle: "Search",
                toolDescription: "Search clipboard history.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "payload": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "query": .object(["type": .string("string")]),
                                "count": .object(["type": .string("integer")])
                            ])
                        ])
                    ]),
                    "required": .array([.string("payload")])
                ]),
                annotations: .object([
                    "readOnlyHint": .bool(true),
                    "openWorldHint": .bool(false)
                ])
            )
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [bridgeTool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)


        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let listedTools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try #require(listedTools.first)
        let toolName = try #require(listedTool["name"] as? String)
        #expect(listedTool["title"] as? String == "Paste Search")

        let schema = try #require(listedTool["inputSchema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect((properties["payload"] as? [String: Any]) != nil)

        let annotations = try #require(listedTool["annotations"] as? [String: Any])
        #expect(annotations["title"] as? String == "Paste Search")
        #expect(annotations["readOnlyHint"] as? Bool == true)
        #expect(annotations["destructiveHint"] as? Bool == false)
        #expect(annotations["openWorldHint"] as? Bool == false)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "call",
                "method": "tools/call",
                "params": [
                    "name": toolName,
                    "arguments": [
                        "payload": [
                            "query": "clip",
                            "count": 2,
                            "nested": ["enabled": true]
                        ]
                    ]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let result = try #require(toolCall.json["result"] as? [String: Any])
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        let stdout = try #require(structuredContent["stdout"] as? String)
        let echoedPayload = try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])

        #expect(echoedPayload["query"] as? String == "clip")
        #expect(echoedPayload["count"] as? Int == 2)
        #expect((echoedPayload["nested"] as? [String: Any])?["enabled"] as? Bool == true)
    }

    @Test func longStringArraySchemaMatchesRuntimeAndOversizedStdinIsAResultError() async throws {
        let notesSizedTool = ToolDefinition(
            id: "test_notes_long_input",
            name: "Notes Long Input",
            summary: "Exercise Notes-sized inline process input.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false,
                    maximumLength: 64 * 1024
                ),
                ToolParameter(
                    name: "stdin",
                    title: "Standard Input",
                    kind: .string,
                    required: false,
                    maximumLength: 64 * 1024
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 32 * 1024
        )
        let genericTool = ToolDefinition(
            id: "test_generic_input",
            name: "Generic Input",
            summary: "Exercise the default inline process input bound.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let tools = [notesSizedTool, genericTool]
        let coordinator = OAuthCoordinator()
        // Flexible Commands ask before running, so this test stands in for
        // an owner who approves each call.
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let approver = approveEveryToolCall(in: toolApprovals)
        defer { approver.cancel() }
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: ConfiguredToolExecutor(
                tools: tools,
                environment: ExecutableLocator.toolEnvironment
            )
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server
        )

        let listedTools = try await toolsList(base: base, accessToken: accessToken)
        let listedNotesTool = try #require(
            listedTools.first { $0["title"] as? String == notesSizedTool.name }
        )
        let notesToolName = try #require(listedNotesTool["name"] as? String)
        let notesInputSchema = try #require(listedNotesTool["inputSchema"] as? [String: Any])
        let notesProperties = try #require(notesInputSchema["properties"] as? [String: Any])
        let notesArgsSchema = try #require(notesProperties["args"] as? [String: Any])
        let notesArgItems = try #require(notesArgsSchema["items"] as? [String: Any])
        #expect(
            notesArgItems["maxLength"] as? Int ==
                64 * 1024
        )
        #expect((notesArgsSchema["description"] as? String)?.contains("96 KiB") == true)
        let notesStdinSchema = try #require(notesProperties["stdin"] as? [String: Any])
        #expect(
            notesStdinSchema["maxLength"] as? Int ==
                64 * 1024
        )

        let listedGenericTool = try #require(
            listedTools.first { $0["title"] as? String == genericTool.name }
        )
        let genericInputSchema = try #require(listedGenericTool["inputSchema"] as? [String: Any])
        let genericProperties = try #require(genericInputSchema["properties"] as? [String: Any])
        let genericArgsSchema = try #require(genericProperties["args"] as? [String: Any])
        let genericArgItems = try #require(genericArgsSchema["items"] as? [String: Any])
        #expect(
            genericArgItems["maxLength"] as? Int ==
                ToolArgumentResolver.defaultStringArrayItemMaximumLength
        )

        let longBody = String(repeating: "n", count: 8 * 1024)
        let longCallBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "long-call",
            "method": "tools/call",
            "params": [
                "name": notesToolName,
                "arguments": [
                    "args": ["create", "--body", longBody]
                ]
            ]
        ]
        #expect(
            try JSONSerialization.data(withJSONObject: longCallBody).count < 128 * 1024
        )
        let longCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: longCallBody
        )
        #expect(longCall.statusCode == 200)
        let longResult = try #require(longCall.json["result"] as? [String: Any])
        #expect(longResult["isError"] as? Bool == false)
        let longStructured = try #require(longResult["structuredContent"] as? [String: Any])
        #expect(longStructured["reason"] as? String == "ok")
        #expect((longStructured["stdout"] as? String)?.contains(longBody) == true)

        let oversizedStdinBody: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "oversized-stdin",
            "method": "tools/call",
            "params": [
                "name": notesToolName,
                "arguments": [
                    "stdin": String(
                        repeating: "s",
                        count: 64 * 1024 + 1
                    )
                ]
            ]
        ]
        #expect(
            try JSONSerialization.data(withJSONObject: oversizedStdinBody).count < 128 * 1024
        )
        let oversizedStdinCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: oversizedStdinBody
        )
        #expect(oversizedStdinCall.statusCode == 200)
        #expect(oversizedStdinCall.json["error"] == nil)
        let oversizedResult = try #require(
            oversizedStdinCall.json["result"] as? [String: Any]
        )
        #expect(oversizedResult["isError"] as? Bool == true)
        let oversizedStructured = try #require(
            oversizedResult["structuredContent"] as? [String: Any]
        )
        #expect(oversizedStructured["reason"] as? String == "invalid_argument")
        #expect((oversizedStructured["stderr"] as? String)?.contains("stdin") == true)
    }
}

private func makeScannedAdapterTool(
    summary: String,
    summaryIsHarvested: Bool,
    summaryOrigin: String?
) -> ToolDefinition {
    ToolDefinition(
        id: "scan_homebrew_formula_rg",
        name: "rg",
        summary: summary,
        executablePath: "/opt/homebrew/bin/rg",
        argumentPattern: ["{args}"],
        parameters: [
            ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false),
            ToolParameter(name: "stdin", title: "Standard Input", kind: .string, required: false)
        ],
        capability: .destructive,
        timeoutSeconds: 60,
        outputByteLimit: 2048 * 1024,
        origin: .userDefined,
        provenance: ToolProvenance(
            sourceKind: .homebrewFormula,
            packageName: "ripgrep",
            packageVersion: "14.1.0",
            addedDate: Date(timeIntervalSince1970: 1_780_000_000),
            resolvedPathAtAdd: "/opt/homebrew/Cellar/ripgrep/14.1.0/bin/rg",
            signingIdentityAtAdd: "ad-hoc",
            contentSHA256AtAdd: "abc123",
            wasQuarantinedAtAdd: false,
            summaryIsHarvested: summaryIsHarvested,
            summaryOrigin: summaryOrigin
        )
    )
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

private struct TimedOutToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Timeout",
            exitCode: 1,
            stdout: "",
            stderr: "Timed out.",
            duration: 2,
            timedOut: true,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct HoldingToolExecutor: ToolExecuting {
    private let gate: HoldingGate

    init(gate: HoldingGate) {
        self.gate = gate
    }

    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        await gate.holdUntilReleased()
        return ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Echo",
            exitCode: 0,
            stdout: "held",
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private actor HoldingGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdUntilReleased() async {
        entered = true
        let pendingEntered = enteredWaiters
        enteredWaiters.removeAll()
        for continuation in pendingEntered {
            continuation.resume()
        }

        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            if entered {
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
            }
        }
    }

    func release() {
        let pending = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private struct FakeToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        let stdout: String
        if parameters["value"]?.stringValue == "giant-stdout" {
            stdout = String(repeating: "a", count: 150_000)
        } else if let payload = parameters["payload"] {
            let data = try? JSONSerialization.data(
                withJSONObject: payload.jsonValue.anyValue,
                options: [.sortedKeys]
            )
            stdout = data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        } else {
            stdout = "echo:\(parameters["value"]?.stringValue ?? "")"
        }

        return ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Echo",
            exitCode: 0,
            stdout: stdout,
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct UpstreamMCPContextToolExecutor: ToolExecuting {
    let stdout: String
    let context: MCPBridgeUpstreamResultContext
    let exitCode: Int32

    func execute(
        toolID: String,
        parameters _: [String: ToolArgumentValue]
    ) async throws -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Bridge Fixture",
            exitCode: exitCode,
            stdout: stdout,
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false,
            upstreamMCPResult: context
        )
    }
}

private struct ChangedFingerprintToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        throw ToolSecurityFingerprintError.changed
    }

    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue],
        expectedSecurityFingerprint: String?
    ) async throws -> ToolExecutionOutcome {
        throw ToolSecurityFingerprintError.changed
    }
}

private struct ArtifactPayloadToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        let stdout = """
        {"artifact_path":"/artifact/test-token","artifact_token":"test-token","filename":"download.bin","size_bytes":4,"sha256":"ab","expires_in_seconds":600,"downloads_allowed":3}
        """
        return ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Artifact",
            exitCode: 0,
            stdout: stdout,
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct RegisteredArtifactPayloadToolExecutor: ToolExecuting {
    let artifactPath: String
    let filename: String
    let sizeBytes: Int64

    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        let stdout = """
        {"artifact_path":"\(artifactPath)","filename":"\(filename)","size_bytes":\(sizeBytes),"expires_in_seconds":600,"downloads_allowed":3}
        """
        return ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Artifact",
            exitCode: 0,
            stdout: stdout,
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct ToolCallResultResponse: Sendable {
    let statusCode: Int
    let isError: Bool?
    let stderr: String?
    let reason: String?
}

private struct ToolsListPageResponse {
    let tools: [[String: Any]]?
    let nextCursor: String?
    let meta: [String: Any]?
}

private func makePaginationTestTools(count: Int) -> [ToolDefinition] {
    (0..<count).map { index in
        ToolDefinition(
            id: "test_pagination_\(index)",
            name: "Pagination Tool \(index)",
            summary: "Pagination test tool \(index).",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(
                    name: "value",
                    title: "Value",
                    kind: .string,
                    maximumLength: 64
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
    }
}

private func toolsListResponse(
    base: URL,
    accessToken: String,
    cursor: String? = nil
) async throws -> ToolsListPageResponse {
    var body: [String: Any] = [
        "jsonrpc": "2.0",
        "id": "tools",
        "method": "tools/list"
    ]
    if let cursor {
        body["params"] = ["cursor": cursor]
    }
    let response = try await postJSON(
        url: base.appendingPathComponent("mcp/test-instance"),
        bearerToken: accessToken,
        headers: ["MCP-Protocol-Version": "2025-11-25"],
        body: body
    )
    #expect(response.statusCode == 200)
    let result = try #require(response.json["result"] as? [String: Any])
    return ToolsListPageResponse(
        tools: result["tools"] as? [[String: Any]],
        nextCursor: result["nextCursor"] as? String,
        meta: result["_meta"] as? [String: Any]
    )
}

private func toolsList(base: URL, accessToken: String) async throws -> [[String: Any]] {
    let response = try await postJSON(
        url: base.appendingPathComponent("mcp/test-instance"),
        bearerToken: accessToken,
        headers: ["MCP-Protocol-Version": "2025-11-25"],
        body: [
            "jsonrpc": "2.0",
            "id": "tools",
            "method": "tools/list"
        ]
    )
    #expect(response.statusCode == 200)
    let result = try #require(response.json["result"] as? [String: Any])
    return try #require(result["tools"] as? [[String: Any]])
}

/// Stands in for the tunnel: the public link's host as it changes over time.
private final class CurrentPublicHost: @unchecked Sendable {
    private let lock = NSLock()
    private var host: String?

    init(_ host: String?) {
        self.host = host
    }

    var value: String? {
        get { lock.withLock { host } }
        set { lock.withLock { host = newValue } }
    }
}

private func authorizedAccessToken(
    base: URL,
    coordinator: OAuthCoordinator,
    server: LocalMCPServer,
    headers: [String: String] = [:]
) async throws -> String {
    let verifier = "server-flow-verifier-0123456789-ABCDEFGHIJKLMNO"
    let resource = resourceURL(base: base, headers: headers, instanceID: "test-instance")
    let registered = try await postJSON(
        url: base.appendingPathComponent("register"),
        headers: headers,
        body: [
            "client_name": "HTTP Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ]
    )
    #expect(registered.statusCode == 201)
    let clientID = try #require(registered.json["client_id"] as? String)

    var authorize = URLComponents(url: base.appendingPathComponent("authorize"), resolvingAgainstBaseURL: false)!
    authorize.queryItems = [
        URLQueryItem(name: "response_type", value: "code"),
        URLQueryItem(name: "client_id", value: clientID),
        URLQueryItem(name: "redirect_uri", value: "http://127.0.0.1/callback"),
        URLQueryItem(name: "scope", value: "mcp:tools"),
        URLQueryItem(name: "state", value: "state-token"),
        URLQueryItem(name: "code_challenge", value: OAuthCoordinator.pkceChallenge(for: verifier)),
        URLQueryItem(name: "code_challenge_method", value: "S256"),
        URLQueryItem(name: "resource", value: resource)
    ]
    let authorizationPage = try await get(url: try #require(authorize.url), headers: headers)
    #expect(authorizationPage.statusCode == 200)

    let requestID = try #require(coordinator.approvalSnapshot().first?.id)
    #expect(server.approveAuthorizationRequest(id: requestID))

    var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
    statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
    let status = try await getJSON(url: try #require(statusURL.url), headers: headers)
    let redirectURI = try #require(status.json["redirect_uri"] as? String)
    let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

    let token = try await postForm(
        url: base.appendingPathComponent("token"),
        headers: headers,
        form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ]
    )
    #expect(token.statusCode == 200)
    return try #require(token.json["access_token"] as? String)
}

/// Approves every tool call as it arrives, for tests about what happens once
/// the owner has said yes.
private func approveEveryToolCall(in coordinator: ToolCallApprovalCoordinator) -> Task<Void, Never> {
    Task {
        while !Task.isCancelled {
            for request in coordinator.approvalSnapshot() where request.state == .pending {
                _ = coordinator.approve(requestID: request.id)
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private func waitForPendingToolApproval(
    in coordinator: ToolCallApprovalCoordinator,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> ToolCallApprovalRequest {
    for _ in 0..<50 {
        if let request = coordinator.approvalSnapshot().first(where: { $0.state == .pending }) {
            return request
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    Issue.record("Timed out waiting for pending tool approval.", sourceLocation: sourceLocation)
    throw NSError(domain: "MacRemoteTests", code: 1)
}

private func get(url: URL, headers: [String: String] = [:]) async throws -> (statusCode: Int, data: Data) {
    let response = try await getWithHeaders(url: url, headers: headers)
    return (response.statusCode, response.data)
}

private func waitForServerReady(
    base: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let healthURL = base.appendingPathComponent("health")
    var lastError: Error?
    // Parallel suites start dozens of listeners at once; the old flat
    // 50×20ms (~1s) budget occasionally expired on a loaded machine.
    // Poll fast at first, then back off — ~8s total before giving up.
    var delayNanoseconds: UInt64 = 20_000_000
    for _ in 0..<45 {
        do {
            let response = try await get(url: healthURL)
            if response.statusCode == 200 {
                return
            }
        } catch {
            lastError = error
        }
        try await Task.sleep(nanoseconds: delayNanoseconds)
        delayNanoseconds = min(delayNanoseconds * 3 / 2, 300_000_000)
    }

    Issue.record("Timed out waiting for local MCP test server: \(lastError?.localizedDescription ?? "no response")", sourceLocation: sourceLocation)
    throw NSError(domain: "MacRemoteTests", code: 2)
}

private func getWithHeaders(
    url: URL,
    headers: [String: String] = [:]
) async throws -> (statusCode: Int, data: Data, headers: [AnyHashable: Any]) {
    try await sendRequest(method: "GET", url: url, headers: headers)
}

private func sendRequest(
    method: String,
    url: URL,
    headers: [String: String] = [:]
) async throws -> (statusCode: Int, data: Data, headers: [AnyHashable: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return (http.statusCode, data, http.allHeaderFields)
}

private func getJSON(url: URL, headers: [String: String] = [:]) async throws -> (statusCode: Int, json: [String: Any]) {
    let response = try await get(url: url, headers: headers)
    return (response.statusCode, try decodeJSON(response.data))
}

private func postJSON(
    url: URL,
    bearerToken: String? = nil,
    headers: [String: String] = [:],
    body: [String: Any]
) async throws -> (
    statusCode: Int,
    json: [String: Any],
    headers: [AnyHashable: Any],
    data: Data
) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    if let bearerToken {
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return (http.statusCode, (try? decodeJSON(data)) ?? [:], http.allHeaderFields, data)
}

private func postForm(
    url: URL,
    headers: [String: String] = [:],
    form: [String: String]
) async throws -> (
    statusCode: Int,
    json: [String: Any],
    headers: [AnyHashable: Any],
    data: Data
) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    request.httpBody = form
        .map { key, value in
            "\(percentEncode(key))=\(percentEncode(value))"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try #require(response as? HTTPURLResponse)
    return (http.statusCode, try decodeJSON(data), http.allHeaderFields, data)
}

private func decodeJSON(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
}

private func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
}

private func basicAuthorizationHeader(username: String, password: String = "") -> String {
    let credentials = "\(username):\(password)"
    return "Basic \(Data(credentials.utf8).base64EncodedString())"
}

private func headerValue(_ headers: [AnyHashable: Any], named name: String) -> String? {
    headers.first { key, _ in
        guard let key = key as? String else { return false }
        return key.caseInsensitiveCompare(name) == .orderedSame
    }?.value as? String
}

private func assertArtifactRouteContentTypeMatchesDeclaredMIME(
    resourceLink: [String: Any]
) async throws {
    let declaredMIME = try #require(resourceLink["mimeType"] as? String)
    let uri = try #require(resourceLink["uri"] as? String)
    let url = try #require(URL(string: uri))
    let head = try await sendRequest(method: "HEAD", url: url)
    #expect(head.statusCode == 200)
    #expect(headerValue(head.headers, named: "Content-Type") == declaredMIME)
}

private func resourceURL(base: URL, headers: [String: String], instanceID: String) -> String {
    if let publicHost = headers["Host"] {
        return "https://\(publicHost)/mcp"
    }
    return "\(base.absoluteString)/mcp/\(instanceID)"
}

// MARK: - MCP Apps (SEP-1865) shared widget

/// One ui:// resource covers every registered tool. Catalog profiles refine
/// known result shapes, the semantic profile safely handles everything else,
/// hosts without the extension keep the mandated text fallback untouched, and
/// declared UI actions ride CallToolResult._meta with public tool names.
struct MCPUISupportTests {
    private func makeUITestServer(artifactStore: ArtifactStore = ArtifactStore()) -> (LocalMCPServer, OAuthCoordinator) {
        let coordinator = OAuthCoordinator()
        let listTool = ToolDefinition(
            id: "test_reminders",
            name: "Reminders List",
            summary: "Return reminder rows.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64),
                ToolParameter(name: "payload", title: "Payload", kind: .string, required: false, maximumLength: 512 * 1024)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024 * 1024,
            category: .reminders,
            uiActions: [
                ToolUIAction(
                    id: "complete",
                    title: "Mark Done",
                    kind: .checkOff,
                    toolID: "test_mutator",
                    arguments: .object(["args": .array([.string("done"), .string("{id}")])]),
                    requiredRowFields: ["id"],
                    completedWhenField: "completed"
                )
            ]
        )
        let mutatorTool = ToolDefinition(
            id: "test_mutator",
            name: "Mutator",
            summary: "Mutate a reminder.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)
            ],
            capability: .write,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let podcastsTool = ToolDefinition(
            id: "test_podcasts",
            name: "Episodes List",
            summary: "Return episode rows.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024 * 1024,
            category: .podcasts
        )
        // A category with no curated presentation hints uses the safe semantic
        // result profile rather than exposing host-native developer output.
        let plainTool = ToolDefinition(
            id: "test_plain",
            name: "Plain Utility",
            summary: "Return uncurated output.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024 * 1024,
            category: .utilities
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [listTool, mutatorTool, podcastsTool, plainTool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor(),
            artifactStore: artifactStore
        )
        return (server, coordinator)
    }

    @Test func authoredPresentationRefinesDefaultWidgetWithoutProviderIDDispatch() async throws {
        let coordinator = OAuthCoordinator()
        func fixed(
            id: String,
            category: ToolCategory,
            presentation: ToolWidgetPresentation? = nil
        ) -> ToolDefinition {
            ToolDefinition(
                id: id,
                name: id,
                summary: "Return a fixed payload.",
                executablePath: "/bin/echo",
                argumentPattern: ["{value}"],
                parameters: [
                    ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
                ],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024,
                category: category,
                widgetPresentation: presentation
            )
        }
        func flexible(id: String, category: ToolCategory) -> ToolDefinition {
            ToolDefinition(
                id: id,
                name: id,
                summary: "Run exact arguments.",
                executablePath: "/bin/echo",
                argumentPattern: ["{args}"],
                parameters: [
                    ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)
                ],
                capability: .destructive,
                timeoutSeconds: 2,
                outputByteLimit: 1024,
                category: category
            )
        }

        let episode = fixed(
            id: "arbitrary_feed_rows",
            category: .podcasts,
            presentation: ToolWidgetPresentation(
                profile: .episodeRows,
                accent: "light-dark(#9a4300, #ff9f0a)",
                rootPath: "data"
            )
        )
        let note = fixed(
            id: "arbitrary_document_rows",
            category: .utilities,
            presentation: ToolWidgetPresentation(
                profile: .noteRows,
                accent: "light-dark(#7a5900, #ffd60a)"
            )
        )
        let tools = [
            episode,
            note,
            fixed(id: "quiet_lookup", category: .utilities,
                  presentation: ToolWidgetPresentation(profile: .semanticResult, automatic: false)),
            fixed(id: "overctl_search", category: .utilities),
            fixed(id: "notesctl_recent", category: .utilities),
            flexible(id: "overctl_run", category: .podcasts),
            flexible(id: "notesctl_run", category: .notes)
        ]
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let mcp = base.appendingPathComponent("mcp/test-instance")
        _ = try await postJSON(
            url: mcp,
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [
                        "extensions": [
                            "io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]
                        ]
                    ],
                    "clientInfo": ["name": "UI Host", "version": "1.0"]
                ]
            ]
        )

        let listResponse = try await postJSON(
            url: mcp,
            bearerToken: token,
            body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]
        )
        let listed = try #require(
            (listResponse.json["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        for linked in tools.map(\.id).filter({ $0 != "quiet_lookup" }) {
            let descriptor = try #require(listed.first { $0["name"] as? String == linked })
            let meta = try #require(descriptor["_meta"] as? [String: Any])
            let ui = try #require(meta["ui"] as? [String: Any])
            #expect(ui["resourceUri"] as? String == MCPAppsMetadata.resourceURI)
            #expect(meta["ui/resourceUri"] as? String == MCPAppsMetadata.resourceURI)
            #expect(meta["openai/outputTemplate"] as? String == MCPAppsMetadata.resourceURI)
        }

        let quietDescriptor = try #require(listed.first { $0["name"] as? String == "quiet_lookup" })
        let quietMeta = try #require(quietDescriptor["_meta"] as? [String: Any])
        for key in ["ui", "ui/resourceUri", "openai/outputTemplate"] { #expect(quietMeta[key] == nil) }
        #expect(quietMeta["securitySchemes"] != nil)
        let quietCall = try await postJSON(url: mcp, bearerToken: token, body: [
            "jsonrpc": "2.0", "id": "quiet", "method": "tools/call",
            "params": ["name": "quiet_lookup", "arguments": ["value": "x"]]
        ])
        let quietResult = try #require(quietCall.json["result"] as? [String: Any])
        #expect(quietResult["structuredContent"] != nil)
        #expect(quietResult["content"] != nil)
        #expect((quietResult["_meta"] as? [String: Any])?[LocalMCPServer.resultUIMetaKey] == nil)

        let expectedPresentations: [(String, String, String?)] = [
            ("arbitrary_feed_rows", "light-dark(#9a4300, #ff9f0a)", "data"),
            ("arbitrary_document_rows", "light-dark(#7a5900, #ffd60a)", nil)
        ]
        for (name, accent, rootPath) in expectedPresentations {
            let call = try await postJSON(
                url: mcp,
                bearerToken: token,
                body: [
                    "jsonrpc": "2.0", "id": name, "method": "tools/call",
                    "params": ["name": name, "arguments": ["value": "x"]]
                ]
            )
            let ui = try #require(
                (call.json["result"] as? [String: Any])
                    .flatMap { $0["_meta"] as? [String: Any] }
                    .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
            )
            #expect(ui["accent"] as? String == accent)
            let table = try #require(ui["table"] as? [String: Any])
            #expect(table["rootPath"] as? String == rootPath)
            if name == "arbitrary_document_rows" {
                #expect(table["document"] is [String: Any])
                #expect(table["groups"] is [[String: Any]])
            }
        }

        let semanticCalls: [(String, [String: Any])] = [
            ("overctl_search", ["value": "x"]),
            ("notesctl_recent", ["value": "x"]),
            ("overctl_run", ["args": [String]()]),
            ("notesctl_run", ["args": [String]()])
        ]
        for (name, arguments) in semanticCalls {
            let call = try await postJSON(
                url: mcp,
                bearerToken: token,
                body: [
                    "jsonrpc": "2.0", "id": name, "method": "tools/call",
                    "params": ["name": name, "arguments": arguments]
                ]
            )
            let result = try #require(call.json["result"] as? [String: Any])
            #expect(result["content"] is [[String: Any]])
            #expect(result["structuredContent"] is [String: Any])
            let resultMeta = try #require(result["_meta"] as? [String: Any])
            let uiValue = resultMeta["net.viticci.macremote/ui"]
            let ui = try #require(uiValue as? [String: Any])
            #expect(ui["accent"] == nil)
            #expect((ui["table"] as? [String: Any])?.isEmpty == true)
        }
    }

    @Test func initializeAdvertisesResourcesAndToolsCarryWidgetMeta() async throws {
        #expect(LocalMCPServer.widgetHTML != nil)

        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let initialize = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [
                        "extensions": [
                            "io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]
                        ]
                    ],
                    "clientInfo": ["name": "UI Host", "version": "1.0"]
                ]
            ]
        )
        let capabilities = try #require((initialize.json["result"] as? [String: Any])?["capabilities"] as? [String: Any])
        #expect((capabilities["resources"] as? [String: Any]) != nil)

        let tools = try await toolsList(base: base, accessToken: token)
        for tool in tools {
            let securitySchemes = try #require(tool["securitySchemes"] as? [[String: Any]])
            #expect(securitySchemes.first?["type"] as? String == "oauth2")
            #expect(securitySchemes.first?["scopes"] as? [String] == ["mcp:tools"])
            let meta = try #require(tool["_meta"] as? [String: Any])
            let mirroredSecurity = try #require(meta["securitySchemes"] as? [[String: Any]])
            #expect(mirroredSecurity.first?["type"] as? String == "oauth2")
            let ui = try #require(meta["ui"] as? [String: Any])
            #expect(ui["resourceUri"] as? String == "ui://macremote/output-v8.html")
            #expect(ui["visibility"] as? [String] == ["model", "app"])
            // Deprecated flat form rides along for hosts that still read it.
            #expect(meta["ui/resourceUri"] as? String == "ui://macremote/output-v8.html")
            #expect(meta["openai/outputTemplate"] as? String == "ui://macremote/output-v8.html")
            #expect(meta["openai/widgetAccessible"] as? Bool == true)
        }
    }

    @Test func habitToolResultCarriesBlueAccentAndHabitColumns() async throws {
        let coordinator = OAuthCoordinator()
        let habitsTool = ToolDefinition(
            id: "test_habits",
            name: "Habits Today",
            summary: "Return habit rows.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024 * 1024,
            category: .habits
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [habitsTool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_habits", "arguments": ["value": "x"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let ui = try #require(meta["net.viticci.macremote/ui"] as? [String: Any])
        // Habits category → Habitify blue + habit-shaped curated columns
        // (streak quantity + goal fraction via nested dot-path fields).
        #expect(ui["accent"] as? String == "#2a9df4")
        let table = try #require(ui["table"] as? [String: Any])
        let columns = try #require(table["columns"] as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: columns.map { ($0["key"] as? String ?? "", $0) })
        #expect(byKey["name"]?["primary"] as? Bool == true)
        #expect(byKey["streak"]?["derive"] as? String == "quantity")
        #expect(byKey["streak"]?["sourceKey"] as? String == "currentStreak.length")
        #expect(byKey["streak"]?["unitKey"] as? String == "currentStreak.unit")
        #expect(byKey["goal"]?["derive"] as? String == "progress")
        #expect(byKey["goal"]?["sourceKey"] as? String == "progress.current")
        #expect(byKey["goal"]?["totalKey"] as? String == "progress.target")
        // No "format": habit goals label as count fractions, unlike the
        // podcasts played column which sets format=seconds.
        #expect(byKey["goal"]?["format"] == nil)
        let hidden = try #require(table["hiddenColumns"] as? [String])
        for dropped in ["id", "status", "color", "iconNamed", "timeOfDayIds"] {
            #expect(hidden.contains(dropped), "\(dropped) should be hidden")
        }
    }

    @Test func plainCategoryToolResultCarriesGenericWidgetMetaAndFallback() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_plain", "arguments": ["value": "x"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        // The schema-free presentation adds no curated columns or accent, and
        // the cross-host text/structured fallback stays intact.
        #expect((result["content"] as? [[String: Any]])?.first?["type"] as? String == "text")
        #expect((result["structuredContent"] as? [String: Any]) != nil)
        let meta = try #require(result["_meta"] as? [String: Any])
        #expect(meta["ui/resourceUri"] as? String == LocalMCPServer.widgetResourceURI)
        let ui = try #require(meta[LocalMCPServer.resultUIMetaKey] as? [String: Any])
        #expect(ui["toolTitle"] as? String == "Plain Utility")
        #expect(ui["profile"] as? String == "semanticResult")
        #expect(ui["accent"] == nil)
        #expect((ui["table"] as? [String: Any])?.isEmpty == true)
    }

    @Test func widgetResourceReadsBackWithSandboxMeta() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let mcp = base.appendingPathComponent("mcp/test-instance")

        let legacyNoCapabilityTools = try await toolsList(base: base, accessToken: token)
        let legacyEligibleTool = try #require(
            legacyNoCapabilityTools.first { $0["name"] as? String == "test_reminders" }
        )
        let legacyEligibleMeta = try #require(
            legacyEligibleTool["_meta"] as? [String: Any]
        )
        #expect(legacyEligibleMeta["ui"] == nil)
        #expect(
            legacyEligibleMeta["ui/resourceUri"] as? String ==
                "ui://macremote/output-v8.html"
        )
        #expect(
            legacyEligibleMeta["openai/outputTemplate"] as? String ==
                "ui://macremote/output-v8.html"
        )
        #expect(legacyEligibleMeta["openai/widgetAccessible"] as? Bool == true)

        // A legacy host that never negotiated MCP Apps gets the compatibility
        // aliases, the complete HTML fallback — and the sandbox policy, which
        // is not a capability-gated extra. Withholding `_meta.ui` withholds
        // `ui.csp`, and a host with no CSP applies its own default (`img-src
        // 'self' data:`), which blocks every piece of podcast artwork. `_meta`
        // is ignorable by contract, so a client that does not understand `ui`
        // simply drops it; nobody is harmed by receiving it.
        let legacyNoCapabilityRead = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "legacy-no-cap", "method": "resources/read",
                "params": ["uri": "ui://macremote/output-v8.html"]
            ]
        )
        let legacyNoCapabilityContents = try #require(
            (legacyNoCapabilityRead.json["result"] as? [String: Any])?["contents"]
                as? [[String: Any]]
        )
        let legacyNoCapabilityItem = try #require(legacyNoCapabilityContents.first)
        let legacyNoCapabilityMeta = try #require(
            legacyNoCapabilityItem["_meta"] as? [String: Any]
        )
        let legacyNoCapabilityUI = try #require(
            legacyNoCapabilityMeta["ui"] as? [String: Any]
        )
        let legacyNoCapabilityCSP = try #require(
            legacyNoCapabilityUI["csp"] as? [String: Any]
        )
        #expect(
            legacyNoCapabilityCSP["resourceDomains"] as? [String]
                == ["https://static.pocketcasts.com"]
        )
        #expect(legacyNoCapabilityUI["prefersBorder"] as? Bool == true)
        #expect(legacyNoCapabilityMeta["openai/widgetDescription"] as? String != nil)
        #expect(legacyNoCapabilityMeta["openai/widgetCSP"] is [String: Any])
        let legacyNoCapabilityHTML = try #require(
            legacyNoCapabilityItem["text"] as? String
        )
        #expect(legacyNoCapabilityHTML.contains("<!DOCTYPE html>"))
        #expect(legacyNoCapabilityHTML.contains("ui/initialize"))

        // Cache this legacy client's exact Apps capability before asserting
        // the final nested `_meta.ui` resource contract below.
        let initialize = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "apps-init", "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [
                        "extensions": [
                            "io.modelcontextprotocol/ui": [
                                "mimeTypes": ["text/html;profile=mcp-app"]
                            ]
                        ]
                    ],
                    "clientInfo": ["name": "UI Host", "version": "1.0"]
                ]
            ]
        )
        let initializeCapabilities = try #require(
            (initialize.json["result"] as? [String: Any])?["capabilities"]
                as? [String: Any]
        )
        let initializeExtensions = try #require(
            initializeCapabilities["extensions"] as? [String: Any]
        )
        #expect(initializeExtensions["io.modelcontextprotocol/ui"] != nil)

        let list = try await postJSON(
            url: mcp, bearerToken: token,
            body: ["jsonrpc": "2.0", "id": 1, "method": "resources/list"]
        )
        let resources = try #require((list.json["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        #expect(resources.count == 2)
        let catalogDescriptor = try #require(
            resources.first { $0["uri"] as? String == MCPCatalogMetadata.resourceURI }
        )
        #expect(catalogDescriptor["mimeType"] as? String == "application/json")
        let widgetDescriptor = try #require(
            resources.first { $0["uri"] as? String == "ui://macremote/output-v8.html" }
        )
        #expect(widgetDescriptor["mimeType"] as? String == "text/html;profile=mcp-app")
        let widgetDescription = try #require(widgetDescriptor["description"] as? String)
        #expect(widgetDescription.contains("semantic summaries"))
        #expect(widgetDescription.contains("attachments"))
        #expect(!widgetDescription.lowercased().contains("terminal"))
        #expect(!widgetDescription.lowercased().contains("tree"))
        // Hosts are told to look for the sandbox policy on the descriptor as
        // well as on the read result (the read result wins), so the listing
        // declares the same CSP — a host that sandboxes from the listing alone
        // must not end up blocking the artwork origin.
        let widgetDescriptorMeta = try #require(widgetDescriptor["_meta"] as? [String: Any])
        let widgetDescriptorUI = try #require(widgetDescriptorMeta["ui"] as? [String: Any])
        let widgetDescriptorCSP = try #require(widgetDescriptorUI["csp"] as? [String: Any])
        #expect(
            widgetDescriptorCSP["resourceDomains"] as? [String]
                == ["https://static.pocketcasts.com"]
        )
        #expect((widgetDescriptorCSP["connectDomains"] as? [String])?.isEmpty == true)
        #expect(widgetDescriptorUI["prefersBorder"] as? Bool == true)

        let catalogRead = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "catalog", "method": "resources/read",
                "params": ["uri": MCPCatalogMetadata.resourceURI]
            ]
        )
        let catalogContents = try #require(
            (catalogRead.json["result"] as? [String: Any])?["contents"] as? [[String: Any]]
        )
        let catalogItem = try #require(catalogContents.first)
        #expect(catalogItem["mimeType"] as? String == "application/json")
        let catalogText = try #require(catalogItem["text"] as? String)
        let catalogData = try #require(catalogText.data(using: .utf8))
        let catalog = try #require(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        #expect(catalog["version"] as? Int == 1)
        #expect((catalog["revision"] as? String)?.hasPrefix("sha256:") == true)
        let compactTools = try #require(catalog["tools"] as? [[String: Any]])
        let compactNames = compactTools.compactMap { $0["name"] as? String }
        #expect(compactNames == compactNames.sorted())
        #expect(compactTools.allSatisfy { ($0["schemaRevision"] as? String)?.hasPrefix("sha256:") == true })
        #expect(!catalogText.contains("executablePath"))
        #expect(!catalogText.contains("headers"))
        #expect(!catalogText.contains("permissionEpoch"))
        let listResponse = try await toolsListResponse(base: base, accessToken: token)
        #expect(
            catalog["revision"] as? String ==
            listResponse.meta?[MCPCatalogMetadata.revisionMetaKey] as? String
        )

        let read = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 2, "method": "resources/read",
                "params": ["uri": "ui://macremote/output-v8.html"]
            ]
        )
        let contents = try #require((read.json["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        let item = try #require(contents.first)
        #expect(item["uri"] as? String == "ui://macremote/output-v8.html")
        #expect(item["mimeType"] as? String == "text/html;profile=mcp-app")
        let html = try #require(item["text"] as? String)
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("ui/initialize"))
        #expect(html.contains("net.viticci.macremote/ui"))
        let itemMeta = try #require(item["_meta"] as? [String: Any])
        let ui = try #require(itemMeta["ui"] as? [String: Any])
        #expect(ui["prefersBorder"] as? Bool == true)
        // CSP: no fetch/XHR origins; images only from the Pocket Casts CDN
        // (episode artwork). Must stay in sync with podcastArtworkURLTemplate.
        let csp = try #require(ui["csp"] as? [String: Any])
        #expect((csp["connectDomains"] as? [String])?.isEmpty == true)
        #expect(csp["resourceDomains"] as? [String] == ["https://static.pocketcasts.com"])
        #expect(itemMeta["openai/widgetDescription"] as? String != nil)
        #expect(itemMeta["openai/widgetPrefersBorder"] as? Bool == true)
        let openAICSP = try #require(itemMeta["openai/widgetCSP"] as? [String: Any])
        #expect((openAICSP["connect_domains"] as? [String])?.isEmpty == true)
        #expect(openAICSP["resource_domains"] as? [String] == ["https://static.pocketcasts.com"])
        #expect(itemMeta["openai/widgetDomain"] == nil)

        // Every URI advertised by an older release stays readable. Hosts cache
        // widget linkage by URI, so every prior version and the unversioned
        // alias must keep resolving after the v6 bump.
        let compatibilityURIs =
            MCPAppsMetadata.priorResourceURIs + [MCPAppsMetadata.legacyResourceURI]
        for compatibilityURI in compatibilityURIs {
            let compatibilityRead = try await postJSON(
                url: mcp, bearerToken: token,
                body: [
                    "jsonrpc": "2.0",
                    "id": compatibilityURI,
                    "method": "resources/read",
                    "params": ["uri": compatibilityURI]
                ]
            )
            let compatibilityContents = try #require(
                (compatibilityRead.json["result"] as? [String: Any])?["contents"]
                    as? [[String: Any]]
            )
            #expect(compatibilityContents.first?["uri"] as? String == compatibilityURI)
            #expect(
                (compatibilityContents.first?["text"] as? String)?
                    .contains("<!DOCTYPE html>") == true
            )
        }

        let unknown = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 3, "method": "resources/read",
                "params": ["uri": "ui://macremote/other"]
            ]
        )
        #expect((unknown.json["error"] as? [String: Any])?["code"] as? Int == -32002)
    }

    /// Regression: the Apps capability was matched byte-for-byte, so a host
    /// declaring the same media type with a space after the semicolon (legal per
    /// RFC 9110) was still pointed at the widget through the deprecated aliases
    /// while `resources/read` dropped the standard `_meta.ui` sandbox block — a
    /// resource the host could not instantiate.
    @Test func appsCapabilityToleratesLegalMediaTypeSpellingOnResourcesRead() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let mcp = base.appendingPathComponent("mcp/test-instance")

        _ = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "spaced-init", "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [
                        "extensions": [
                            "io.modelcontextprotocol/ui": [
                                // One space, and a quoted parameter value.
                                "mimeTypes": ["text/html; profile=\"mcp-app\""]
                            ]
                        ]
                    ],
                    "clientInfo": ["name": "Spaced UI Host", "version": "1.0"]
                ]
            ]
        )

        let read = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "spaced-read", "method": "resources/read",
                "params": ["uri": "ui://macremote/output-v8.html"]
            ]
        )
        let contents = try #require(
            (read.json["result"] as? [String: Any])?["contents"] as? [[String: Any]]
        )
        let item = try #require(contents.first)
        let itemMeta = try #require(item["_meta"] as? [String: Any])
        let ui = try #require(
            itemMeta["ui"] as? [String: Any],
            "a legal media-type spelling must still receive the standard sandbox hints"
        )
        #expect(ui["prefersBorder"] as? Bool == true)
        #expect(ui["csp"] is [String: Any])

        // And the tool linkage uses the standard nested form, not just aliases.
        let list = try await toolsListResponse(base: base, accessToken: token)
        let listed = try #require(list.tools)
        let podcasts = try #require(listed.first { $0["name"] as? String == "test_podcasts" })
        let toolMeta = try #require(podcasts["_meta"] as? [String: Any])
        let toolUI = try #require(toolMeta["ui"] as? [String: Any])
        #expect(toolUI["resourceUri"] as? String == "ui://macremote/output-v8.html")
    }

    @Test func podcastToolResultCuratesGroupSectionsAndChangeConfirmation() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_podcasts", "arguments": ["value": "x"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let ui = try #require(meta["net.viticci.macremote/ui"] as? [String: Any])
        let table = try #require(ui["table"] as? [String: Any])

        // A triage-style payload carries four row arrays at once; these ordered
        // hints produce purpose-built sections instead of a generic summary. The
        // triage four lead the list (search adds its own two after them —
        // `podcastGroupsCoverCombinedSearchResults` covers those).
        let groups = try #require(table["groups"] as? [[String: Any]])
        #expect(groups.compactMap { $0["key"] as? String }.prefix(4) ==
                ["now", "up_next", "in_progress", "new_releases"])
        #expect(groups.compactMap { $0["title"] as? String }.prefix(4) ==
                ["Now Playing", "Up Next", "In Progress", "New Releases"])
        // The live episode reads as a card; the queue's order is data, so it
        // carries positions.
        #expect(groups.first?["style"] as? String == "card")
        #expect(groups.first?["numbered"] == nil)
        let upNext = try #require(groups.first { $0["key"] as? String == "up_next" })
        #expect(upNext["numbered"] as? Bool == true)
        #expect(upNext["style"] == nil)
        for plain in ["in_progress", "new_releases"] {
            let group = try #require(groups.first { $0["key"] as? String == plain })
            #expect(group["style"] == nil)
            #expect(group["numbered"] == nil)
        }

        // A queue-changing command answers with a confirmation, not rows.
        let change = try #require(table["change"] as? [String: Any])
        #expect(change["actionKey"] as? String == "action")
        #expect(change["episodeKey"] as? String == "episode")
        #expect(change["queueKey"] as? String == "up_next")
        #expect(change["queueTitle"] as? String == "Up Next")
        #expect(change["dryRunKey"] as? [String] == ["dry_run", "dryRun"])
        #expect(change["countKey"] as? String == "up_next_count")
        // `titles` is the recognition set as well as the copy: an action absent
        // from it is not a change result and falls through to the other states.
        // The queue commands' copy is pinned here; the episode-state writes are
        // pinned in `changeHintActionNamesMatchPocketCTLQueueActions`.
        let titles = try #require(change["titles"] as? [String: String])
        for (action, headline) in [
            "play-now": "Playing now",
            "play-next": "Queued to play next",
            "play-last": "Added to the end of Up Next",
            "remove-up-next": "Removed from Up Next"
        ] {
            #expect(titles[action] == headline)
        }
        // The confirmation reuses the same curated episode columns, so the
        // change hints must travel inside the one table payload.
        #expect(table["columns"] is [[String: Any]])

        // Grouped sections stay pocketctl's alone — only its reports answer
        // with several row arrays at once. Reminders do curate `change` (their
        // writes are confirmations too), but with their own keys.
        for reminderTool in ["test_reminders"] {
            let other = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: token,
                body: [
                    "jsonrpc": "2.0", "id": 2, "method": "tools/call",
                    "params": ["name": reminderTool, "arguments": ["value": "x"]]
                ]
            )
            let otherUI = try #require(
                (other.json["result"] as? [String: Any])
                    .flatMap { $0["_meta"] as? [String: Any] }
                    .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
            )
            let otherTable = try #require(otherUI["table"] as? [String: Any])
            #expect(otherTable["groups"] == nil)
            let otherChange = try #require(otherTable["change"] as? [String: Any])
            #expect(otherChange["actionKey"] as? String == "status")
            #expect(otherChange["episodeKey"] == nil)
            #expect(otherChange["queueKey"] == nil)
        }
    }

    /// remctl answers every write with a status object, not rows: this curation
    /// gives the commonest writes in the app (added, edited, completed, deleted)
    /// a purpose-built confirmation instead of a generic summary.
    @Test func reminderChangeHintNamesRemCTLWriteStatuses() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_reminders", "arguments": ["value": "x"]]
            ]
        )
        let change = try #require(
            (call.json["result"] as? [String: Any])
                .flatMap { $0["_meta"] as? [String: Any] }
                .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
                .flatMap { $0["table"] as? [String: Any] }
                .flatMap { $0["change"] as? [String: Any] }
        )
        // remctl's status field, and the one human-readable field it echoes.
        #expect(change["actionKey"] as? String == "status")
        #expect(change["titleKey"] as? String == "title")
        #expect(change["warningsKey"] as? String == "warnings")
        // A reminder write is about one reminder: nothing to count, so no
        // count line and no noun for it.
        #expect(change["countKey"] == nil)
        #expect(change["countNoun"] == nil)
        let titles = try #require(change["titles"] as? [String: String])
        #expect(titles == [
            "created": "Reminder created",
            "updated": "Reminder updated",
            "completed": "Marked done",
            "uncompleted": "Marked not done",
            "deleted": "Reminder deleted",
            "flagged": "Reminder flagged",
            "unflagged": "Reminder unflagged",
            "restored": "Reminder restored",
            "already_restored": "Reminder already restored",
            "moved": "Reminder moved",
            "partial": "Created, but one step failed",
            "unchanged": "No changes"
        ])
        // `titles` is the recognition set: a failed write must fall through to
        // the error/terminal states rather than be dressed up as a success.
        #expect(titles["error"] == nil)
        #expect(titles["failed"] == nil)
        #expect(change["warningActions"] as? [String] == ["partial"])
        #expect(change["batch"] is [String: Any])
        #expect(titles.values.allSatisfy { !$0.isEmpty })
    }

    /// habitctl real writes carry an action and the resolved habit name and
    /// nothing else renderable — the confirmation exists or the result is a
    /// two-key tree.
    @Test func habitChangeHintNamesHabitCTLWriteActions() async throws {
        let coordinator = OAuthCoordinator()
        let habitsTool = ToolDefinition(
            id: "test_habits",
            name: "Habits Today",
            summary: "Return habit rows.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024 * 1024,
            category: .habits
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [habitsTool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_habits", "arguments": ["value": "x"]]
            ]
        )
        let table = try #require(
            (call.json["result"] as? [String: Any])
                .flatMap { $0["_meta"] as? [String: Any] }
                .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
                .flatMap { $0["table"] as? [String: Any] }
        )
        // Habits answer with one habit at a time: no queue, no groups.
        #expect(table["groups"] == nil)
        let change = try #require(table["change"] as? [String: Any])
        #expect(change["actionKey"] as? String == "action")
        #expect(change["titleKey"] as? String == "habit")
        // A preview must read as a preview: habitctl's --dry-run flag is on
        // the payload, so the widget can chip it.
        #expect(change["dryRunKey"] as? String == "dry_run")
        #expect(change["countKey"] == nil)
        let titles = try #require(change["titles"] as? [String: String])
        #expect(
            titles == [
                "complete": "Checked off",
                "failed": "Marked failed",
                "skipped": "Skipped",
                "undo": "Check-off undone",
                "log": "Logged"
            ],
            "change.titles keys must stay in lockstep with habitctl's write actions"
        )
        #expect(titles["error"] == nil)
        #expect(titles.values.allSatisfy { !$0.isEmpty })
    }

    /// Definition-shape coexistence: `habitctl show`/`search` return habit
    /// definitions, not journal rows, and used to render raw `occurrence` JSON
    /// and `[object Object]` meta. Both shapes share one curated column set —
    /// the widget drops the columns whose source fields are absent.
    @Test func habitColumnsAlsoCoverDefinitionShapedRows() async throws {
        let coordinator = OAuthCoordinator()
        let habitsTool = ToolDefinition(
            id: "test_habits",
            name: "Habit Detail",
            summary: "Return a habit definition.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024 * 1024,
            category: .habits
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [habitsTool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_habits", "arguments": ["value": "x"]]
            ]
        )
        let table = try #require(
            (call.json["result"] as? [String: Any])
                .flatMap { $0["_meta"] as? [String: Any] }
                .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
                .flatMap { $0["table"] as? [String: Any] }
        )
        let columns = try #require(table["columns"] as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: columns.map { ($0["key"] as? String ?? "", $0) })
        // A definition's goal lives in an array: the dot-path indexes it.
        #expect(byKey["target"]?["derive"] as? String == "quantity")
        #expect(byKey["target"]?["sourceKey"] as? String == "goals.0.value")
        #expect(byKey["target"]?["unitKey"] as? String == "goals.0.unit")
        #expect(byKey["startDate"]?["derive"] as? String == "datetime")
        #expect(byKey["startDate"]?["sourceKey"] as? String == "startDate")
        // A start DAY serialized as a full ISO timestamp: the literal all-day
        // flag suppresses the meaningless midnight ("Jan 4", not
        // "Jan 4, 12:00 AM"). Reminders use `allDayKey` instead — a per-row
        // flag — so the two spellings must not be conflated.
        #expect(byKey["startDate"]?["allDay"] as? Bool == true)
        #expect(byKey["startDate"]?["allDayKey"] == nil)
        // The description is the habit's own note — a second line under the
        // name, not a column of its own and not a hidden-away field.
        #expect(byKey["name"]?["subtitleKey"] as? String == "description")
        // Journal-row columns survive alongside them: one curation, two shapes.
        #expect(byKey["streak"]?["sourceKey"] as? String == "currentStreak.length")
        let hidden = try #require(table["hiddenColumns"] as? [String])
        for dropped in ["occurrence", "goals", "timeOfDays", "reminders",
                        "colorHex", "icon", "logMethod", "createdAt",
                        "customUnitName", "isArchived", "description"] {
            #expect(hidden.contains(dropped), "\(dropped) should be hidden")
        }
    }

    /// Cross-repo coupling pinned on this side. The keys of `change.titles` are
    /// the recognition set for the change-confirmation state, and they must
    /// cover both of pocketctl's action maps — `QUEUE_ACTION_LABELS` (the four
    /// Up Next commands) and `EPISODE_ACTION_LABELS` (the eight episode-state
    /// writes) in `pocketctl/cli.py` (the PocketCTL repository). If
    /// pocketctl renames or adds an action, this test fails here instead of the
    /// widget silently falling back to a raw key/value dump for that command.
    /// Superset, not equality: a MacRemote-side title for an action pocketctl
    /// hasn't shipped yet is inert, while a missing one is a broken result.
    /// The label copy is intentionally ours, not pocketctl's — only the keys are
    /// shared vocabulary.
    @Test func changeHintActionNamesMatchPocketCTLQueueActions() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_podcasts", "arguments": ["value": "x"]]
            ]
        )
        let change = try #require(
            (call.json["result"] as? [String: Any])
                .flatMap { $0["_meta"] as? [String: Any] }
                .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
                .flatMap { $0["table"] as? [String: Any] }
                .flatMap { $0["change"] as? [String: Any] }
        )
        let titles = try #require(change["titles"] as? [String: String])
        let queueActions: Set<String> = ["play-now", "play-next", "play-last", "remove-up-next"]
        let episodeActions: Set<String> = [
            "episode-done", "episode-unplayed", "episode-star", "episode-unstar",
            "episode-archive", "episode-unarchive", "episode-progress",
            "episode-mark-played"
        ]
        #expect(
            queueActions.union(episodeActions).isSubset(of: Set(titles.keys)),
            "change.titles keys must cover pocketctl's QUEUE_ACTION_LABELS and EPISODE_ACTION_LABELS"
        )
        // Every headline is real copy: an empty title would recognize the action
        // and then render a blank confirmation.
        #expect(titles.values.allSatisfy { !$0.isEmpty })
        // The count line counts episodes; the widget's own default noun is the
        // domain-free "item"/"items", so the word has to come from here.
        #expect(change["countNoun"] as? String == "episode")
        #expect(change["countNounPlural"] as? String == "episodes")
    }

    /// `search-online --type combined` answers with podcast rows and episode
    /// rows in one object. Without a group entry per key that payload is a raw
    /// tree; the group keys are pocketctl's, the titles are ours.
    @Test func podcastGroupsCoverCombinedSearchResults() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_podcasts", "arguments": ["value": "x"]]
            ]
        )
        let groups = try #require(
            (call.json["result"] as? [String: Any])
                .flatMap { $0["_meta"] as? [String: Any] }
                .flatMap { $0["net.viticci.macremote/ui"] as? [String: Any] }
                .flatMap { $0["table"] as? [String: Any] }
                .flatMap { $0["groups"] as? [[String: Any]] }
        )
        // Order is render order: the triage report first, then the two search
        // sections. A payload only ever carries one family of keys.
        #expect(groups.compactMap { $0["key"] as? String } ==
                ["now", "up_next", "in_progress", "new_releases", "podcasts", "episodes", "items"])
        let podcasts = try #require(groups.first { $0["key"] as? String == "podcasts" })
        #expect(podcasts["title"] as? String == "Podcasts")
        // Search results are a flat list of matches: no card, no positions.
        #expect(podcasts["style"] == nil)
        #expect(podcasts["numbered"] == nil)
        let episodes = try #require(groups.first { $0["key"] as? String == "episodes" })
        #expect(episodes["title"] as? String == "Episodes")
        #expect(episodes["style"] == nil)
        #expect(episodes["numbered"] == nil)
    }

    @Test func toolResultCarriesActionsWithPublicToolNames() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_reminders", "arguments": ["value": "x"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        // Fallback stays intact for non-rendering hosts.
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.first?["type"] as? String == "text")
        #expect((result["structuredContent"] as? [String: Any]) != nil)

        let meta = try #require(result["_meta"] as? [String: Any])
        let ui = try #require(meta["net.viticci.macremote/ui"] as? [String: Any])
        #expect(ui["toolTitle"] as? String == "Reminders List")
        #expect(ui["toolName"] as? String == "test_reminders")
        // Reminders category → purple accent + curated table hints.
        #expect(ui["accent"] as? String == "#8b5cf6")
        let table = try #require(ui["table"] as? [String: Any])
        let hiddenColumns = try #require(table["hiddenColumns"] as? [String])
        for hidden in ["id", "completed", "recurrence", "flagged", "isFlagged"] {
            #expect(hiddenColumns.contains(hidden))
        }
        let columns = try #require(table["columns"] as? [[String: Any]])
        #expect(columns.first?["key"] as? String == "when")
        #expect(columns.first?["derive"] as? String == "datetime")
        #expect(columns.first?["sourceKey"] as? [String] == ["displayDate", "dueDate"])
        let columnsByKey = Dictionary(
            uniqueKeysWithValues: columns.compactMap { column -> (String, [String: Any])? in
                guard let key = column["key"] as? String else { return nil }
                return (key, column)
            }
        )
        let recurrence = try #require(columnsByKey["recurrence"])
        #expect(recurrence["title"] as? String == "Repeats")
        #expect(recurrence["derive"] as? String == "recurrence")
        #expect(recurrence["sourceKey"] as? String == "recurrence")
        let flag = try #require(columnsByKey["flag"])
        #expect(flag["title"] as? String == "Flag")
        #expect(flag["derive"] as? String == "booleanLabel")
        #expect(flag["sourceKey"] as? [String] == ["flagged", "isFlagged"])
        #expect(flag["trueLabel"] as? String == "Flagged")
        #expect(flag["falseLabel"] == nil)
        let actions = try #require(ui["actions"] as? [[String: Any]])
        let action = try #require(actions.first)
        #expect(action["id"] as? String == "complete")
        #expect(action["kind"] as? String == "checkOff")
        #expect(action["toolName"] as? String == "test_mutator")
        #expect(action["toolCapability"] as? String == "write")
        #expect(action["toolID"] == nil, "internal ids never leak to clients")
        #expect(action["completedWhenField"] as? String == "completed")

        // A widget action re-enters the ordinary authenticated tools/call path.
        // This write target has no approval coordinator in the test server, so
        // it must stop at the same Mac-side approval gate as every other host.
        let actionCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "widget-action", "method": "tools/call",
                "params": [
                    "name": try #require(action["toolName"] as? String),
                    "arguments": ["args": ["done", "23901"]]
                ]
            ]
        )
        let actionResult = try #require(actionCall.json["result"] as? [String: Any])
        #expect(actionResult["isError"] as? Bool == true)
        let actionStructured = try #require(
            actionResult["structuredContent"] as? [String: Any]
        )
        #expect(actionStructured["reason"] as? String == "unavailable")
        #expect(
            (actionStructured["stderr"] as? String)?.contains(
                "Host approval is required"
            ) == true
        )
    }

    @Test func podcastToolResultCarriesRedAccentAndEpisodeColumns() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_podcasts", "arguments": ["value": "x"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let ui = try #require(meta["net.viticci.macremote/ui"] as? [String: Any])
        // Podcasts category → Pocket Casts red + episode-shaped curated columns.
        #expect(ui["accent"] as? String == "#f43e37")
        let table = try #require(ui["table"] as? [String: Any])
        let columns = try #require(table["columns"] as? [[String: Any]])
        let byKey = Dictionary(uniqueKeysWithValues: columns.map { ($0["key"] as? String ?? "", $0) })
        #expect(byKey["artwork"]?["derive"] as? String == "artwork")
        // Fallback keys: up-next/now call the podcast uuid `podcast`.
        #expect(byKey["artwork"]?["sourceKey"] as? [String] == ["podcastUuid", "podcast"])
        #expect((byKey["artwork"]?["urlTemplate"] as? String)?.hasPrefix("https://static.pocketcasts.com/") == true)
        // Podcast name rides under the episode title, not as a column.
        #expect(byKey["title"]?["subtitleKey"] as? [String] == ["podcastTitle", "subtitle", "author"])
        #expect(byKey["podcastTitle"] == nil)
        #expect(byKey["duration"]?["derive"] as? String == "duration")
        #expect(byKey["progress"]?["derive"] as? String == "progress")
        #expect(byKey["progress"]?["sourceKey"] as? [String] == ["playedUpTo", "progressSeconds", "progress"])
        #expect(byKey["progress"]?["totalKey"] as? [String] == ["durationSeconds", "duration"])
        // seconds format → percent label + played-time tooltip (habit
        // goals omit it and label as count fractions instead).
        #expect(byKey["progress"]?["format"] as? String == "seconds")
        #expect(byKey["url"]?["derive"] as? String == "link")
        #expect(byKey["published"]?["sourceKey"] as? [String] == ["publishedAt", "published", "publishedDate"])
        let hidden = try #require(table["hiddenColumns"] as? [String])
        for dropped in ["uuid", "published", "fileType", "size", "podcast", "podcastTitle"] {
            #expect(hidden.contains(dropped), "\(dropped) should be hidden")
        }
        // A `search-online` PODCAST row carries none of the curated episode
        // fields, so its group falls back to auto columns. Without these it
        // rendered "Explicit: false", "Has Video Episodes: false" and
        // "Type: podcast" — API bookkeeping, in a widget whose whole point is
        // to stop showing API bookkeeping.
        for dropped in ["type", "explicit", "hasVideoEpisodes", "publishedDate", "slug"] {
            #expect(hidden.contains(dropped), "\(dropped) is search-online noise")
        }
    }

    @Test func oversizedStdoutIsCappedBelowWidgetHydrationCliff() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_reminders", "arguments": ["value": "giant-stdout"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let stdout = try #require(structured["stdout"] as? String)
        #expect(stdout.count == LocalMCPServer.mcpStdoutCharacterLimit)
        #expect(structured["truncatedStdout"] as? Bool == true)
        #expect(structured["reason"] as? String == "ok")
        #expect(structured["succeeded"] as? Bool == true)
    }

    @Test func validationFailureReturnsCallToolResultNotJSONRPCError() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test_limit",
            name: "Limit Test",
            summary: "Echo with a bounded limit parameter.",
            executablePath: "/bin/echo",
            argumentPattern: ["{limit}"],
            parameters: [
                ToolParameter(
                    name: "limit",
                    title: "Limit",
                    kind: .integer,
                    required: true,
                    integerRange: 1...100
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: [
                    "HOME": ExecutableLocator.homeDirectory,
                    "PATH": ExecutableLocator.searchDirectories.joined(separator: ":")
                ]
            )
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "invalid-limit",
                "method": "tools/call",
                "params": [
                    "name": "test_limit",
                    "arguments": [
                        "limit": "banana"
                    ]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        #expect(toolCall.json["error"] == nil)
        let result = try #require(toolCall.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        #expect(structuredContent["reason"] as? String == "invalid_argument")
        let stderr = try #require(structuredContent["stderr"] as? String)
        #expect(stderr.contains("limit"))
        #expect(stderr.contains("banana"))
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(text.contains("banana"))
    }

    @Test func unavailableExecutableReturnsPathFreeCallToolResult() async throws {
        let coordinator = OAuthCoordinator()
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemote-private-command-\(UUID().uuidString)")
            .path
        let secretArgument = "--private-terminal-argument"
        let tool = ToolDefinition(
            id: "test_missing_command",
            name: "Missing Command",
            summary: "Exercise a command that disappeared after it was added.",
            executablePath: missingPath,
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(
                    name: "args",
                    title: "Arguments",
                    kind: .stringArray,
                    required: false
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: ExecutableLocator.toolEnvironment
            )
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server
        )
        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "missing-command",
                "method": "tools/call",
                "params": [
                    "name": tool.id,
                    "arguments": ["args": [secretArgument]]
                ]
            ]
        )

        #expect(call.statusCode == 200)
        #expect(call.json["error"] == nil)
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["reason"] as? String == "unavailable")
        #expect(structured["succeeded"] as? Bool == false)
        let stderr = try #require(structured["stderr"] as? String)
        #expect(stderr.contains("not installed or is no longer available"))
        let resultMeta = try #require(result["_meta"] as? [String: Any])
        #expect(resultMeta["ui/resourceUri"] as? String == LocalMCPServer.widgetResourceURI)
        let presentationValue = resultMeta[LocalMCPServer.resultUIMetaKey]
        let presentation = try #require(presentationValue as? [String: Any])
        #expect(presentation["toolName"] as? String == tool.id)
        #expect((presentation["table"] as? [String: Any])?.isEmpty == true)

        let responseText = String(decoding: call.data, as: UTF8.self)
        #expect(responseText.contains(missingPath) == false)
        #expect(responseText.contains(secretArgument) == false)
        #expect(responseText.contains("Executable is not available") == false)
        #expect(responseText.contains("NSCocoaErrorDomain") == false)
    }

    @Test func changedToolAfterApprovalReturnsCallToolResultAndDoesNotExecute() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test_changed_authority",
            name: "Changed Authority",
            summary: "Exercise the approval-to-execution race guard.",
            executablePath: "/bin/echo",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ChangedFingerprintToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "changed-authority",
                "method": "tools/call",
                "params": [
                    "name": tool.id,
                    "arguments": [:]
                ]
            ]
        )

        #expect(toolCall.statusCode == 200)
        #expect(toolCall.json["error"] == nil)
        let result = try #require(toolCall.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["reason"] as? String == "not_approved")
        #expect((structured["stderr"] as? String)?.contains("Refresh tools/list") == true)
    }

    @Test func unknownToolReturnsJSONRPC32602() async throws {
        let coordinator = OAuthCoordinator()
        let currentTool = ToolDefinition(
            id: "remctl_today",
            name: "Today",
            summary: "Return today's reminders.",
            executablePath: "/bin/echo",
            argumentPattern: ["today"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [currentTool],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "missing-tool",
                "method": "tools/call",
                "params": [
                    "name": "remctl_toda",
                    "arguments": [:]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let error = try #require(toolCall.json["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32602)
        #expect((error["message"] as? String)?.contains("remctl_toda") == true)
        #expect((error["message"] as? String)?.contains("Refresh tools/list") == true)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["reason"] as? String == "unknown_tool")
        #expect(data["refreshRequired"] as? Bool == true)
        #expect((data["catalogRevision"] as? String)?.hasPrefix("sha256:") == true)
        #expect(data["catalogResourceUri"] as? String == MCPCatalogMetadata.resourceURI)
        let suggestions = try #require(data["suggestedTools"] as? [[String: Any]])
        #expect(suggestions.first?["name"] as? String == "remctl_today")
        #expect(suggestions.first?["title"] as? String == "Today")
        #expect(
            MCPCatalogMetadata.suggestions(for: "Today", tools: [currentTool]).first?["name"] as? String ==
                "remctl_today"
        )
        #expect(toolCall.json["result"] == nil)
    }

    @Test func concurrentToolCallBeyondExecutionLimitReturnsUnavailable() async throws {
        let coordinator = OAuthCoordinator()
        let gate = HoldingGate()
        let tool = ToolDefinition(
            id: "test_hold",
            name: "Hold Echo",
            summary: "Blocks until the test releases it.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let limiter = ToolExecutionLimiter(maxSlots: 1, acquireTimeout: .milliseconds(200))
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: HoldingToolExecutor(gate: gate),
            toolExecutionLimiter: limiter
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        async let firstCallResponse = postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "hold-first",
                "method": "tools/call",
                "params": [
                    "name": "test_hold",
                    "arguments": ["value": "one"]
                ]
            ]
        )

        await gate.waitUntilEntered()

        let secondCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "hold-second",
                "method": "tools/call",
                "params": [
                    "name": "test_hold",
                    "arguments": ["value": "two"]
                ]
            ]
        )

        #expect(secondCall.statusCode == 200)
        #expect(secondCall.json["error"] == nil)
        let secondResult = try #require(secondCall.json["result"] as? [String: Any])
        #expect(secondResult["isError"] as? Bool == true)
        let structuredContent = try #require(secondResult["structuredContent"] as? [String: Any])
        #expect(structuredContent["reason"] as? String == "unavailable")
        let stderr = try #require(structuredContent["stderr"] as? String)
        #expect(stderr.contains("busy"))

        await gate.release()
        let firstResponse = try await firstCallResponse
        #expect(firstResponse.statusCode == 200)
        let firstResult = try #require(firstResponse.json["result"] as? [String: Any])
        #expect(firstResult["isError"] as? Bool == false)
    }

    @Test func timedOutExecutionMapsToTimeoutReason() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_timeout",
                    name: "Timeout",
                    summary: "Timed out tool.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [
                        ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
                    ],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: TimedOutToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "timeout",
                "method": "tools/call",
                "params": [
                    "name": "test_timeout",
                    "arguments": ["value": "x"]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let result = try #require(toolCall.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structuredContent = try #require(result["structuredContent"] as? [String: Any])
        #expect(structuredContent["reason"] as? String == "timeout")
        #expect(structuredContent["timedOut"] as? Bool == true)
    }

    @Test func outputSchemaIncludesReasonField() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_echo",
                    name: "Echo",
                    summary: "Echo a test value.",
                    executablePath: "/bin/echo",
                    argumentPattern: ["{value}"],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let outputSchema = try #require(tools.first?["outputSchema"] as? [String: Any])
        let properties = try #require(outputSchema["properties"] as? [String: Any])
        let reasonSchema = try #require(properties["reason"] as? [String: Any])
        #expect(reasonSchema["type"] as? String == "string")
        #expect((reasonSchema["enum"] as? [String])?.contains("ok") == true)
        let required = try #require(outputSchema["required"] as? [String])
        #expect(required.contains("reason"))
    }

    @Test func notificationsCancelledReturnsAcceptedWithoutBody() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let cancelled = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "method": "notifications/cancelled",
                "params": [
                    "requestId": "call-1",
                    "reason": "user"
                ]
            ]
        )
        #expect(cancelled.statusCode == 202)
        #expect(cancelled.json.isEmpty)
    }

    @Test func unknownNotificationIsIgnoredWithAcceptedResponse() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let response = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "method": "notifications/unknown",
                "params": [:]
            ]
        )
        #expect(response.statusCode == 202)
        #expect(response.json.isEmpty)
    }

    @Test func unknownRequestMethodReturns32601() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let response = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "missing-method",
                "method": "tools/unknown",
                "params": [:]
            ]
        )
        #expect(response.statusCode == 200)
        let error = try #require(response.json["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test func smallOutputHasNoResourceLinkOrSpillArtifact() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_reminders", "arguments": ["value": "hello"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content[0]["type"] as? String == "text")
    }

    @Test func oversizedStdoutSpillsFullOutputToArtifactResourceLink() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-stdout-spill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let (server, coordinator) = makeUITestServer(artifactStore: artifactStore)
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let fullStdout = String(repeating: "a", count: 150_000)
        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_reminders", "arguments": ["value": "giant-stdout"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let stdout = try #require(structured["stdout"] as? String)
        #expect(stdout.count == LocalMCPServer.mcpStdoutCharacterLimit)
        #expect(structured["truncatedStdout"] as? Bool == true)
        #expect(structured["reason"] as? String == "ok")
        #expect(structured["succeeded"] as? Bool == true)
        #expect(result["isError"] as? Bool == false)

        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "text")
        let resourceLink = try #require(content[1] as? [String: Any])
        #expect(resourceLink["type"] as? String == "resource_link")
        let uri = try #require(resourceLink["uri"] as? String)
        #expect(uri.hasPrefix("http://127.0.0.1:\(port)/artifact/"))
        #expect(resourceLink["name"] as? String == "Echo-output.txt")
        #expect(resourceLink["mimeType"] as? String == "text/plain")
        try await assertArtifactRouteContentTypeMatchesDeclaredMIME(resourceLink: resourceLink)
        let note = try #require(content[2] as? [String: Any])
        #expect(note["type"] as? String == "text")
        #expect((note["text"] as? String)?.contains("150000 bytes") == true)
        let expectedSHA256 = SHA256.hash(data: Data(fullStdout.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect((note["text"] as? String)?.contains(expectedSHA256) == true)

        let tokenString = String(uri.dropFirst("http://127.0.0.1:\(port)/artifact/".count))
        let consumed = try #require(artifactStore.consume(token: tokenString))
        let artifactBytes = try Data(contentsOf: consumed.fileURL)
        #expect(String(decoding: artifactBytes, as: UTF8.self) == fullStdout)
    }
}

private actor SpoolCapturingToolExecutor: ToolExecuting {
    private let executor: ConfiguredToolExecutor
    private var spoolURL: URL?

    init(executor: ConfiguredToolExecutor) {
        self.executor = executor
    }

    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue]
    ) async throws -> ToolExecutionOutcome {
        let outcome = try await executor.execute(toolID: toolID, parameters: parameters)
        spoolURL = outcome.stdoutSpool?.fileURL
        return outcome
    }

    func capturedSpoolURL() -> URL? {
        spoolURL
    }
}

private struct MIMEFixtureToolExecutor: ToolExecuting {
    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue]
    ) async throws -> ToolExecutionOutcome {
        let fixture = parameters["value"]?.stringValue ?? "text"
        let padding = String(repeating: "x", count: 110_000)
        let identity: (id: String, name: String)
        let stdout: String

        switch fixture {
        case "drawing-json":
            identity = ("notesctl_drawing_svg", "Render Note Drawing as SVG")
            stdout = "{\"svg\":\"\(padding)\"}"
        case "html-json":
            identity = ("notesctl_export_html", "Export Notes as HTML")
            stdout = "{\"html\":\"\(padding)\"}"
        case "svg":
            identity = (toolID, "Drawing Output")
            stdout = "<svg xmlns=\"http://www.w3.org/2000/svg\"><desc>\(padding)</desc></svg>"
        case "html":
            identity = (toolID, "Web Output")
            stdout = "<!doctype html><html><body>\(padding)</body></html>"
        case "markdown":
            identity = (toolID, "Report Output")
            stdout = "# Report\n\n\(padding)"
        case "invalid-json-prefix":
            identity = (toolID, "Log Output")
            stdout = "[INFO] processing\n\(padding)"
        case "escaped-text":
            identity = (toolID, "Escaped Output")
            stdout = String(repeating: "\0\"", count: 55_000)
        default:
            identity = (toolID, "Plain Output")
            stdout = "plain\n\(padding)"
        }

        return ToolExecutionOutcome(
            toolID: identity.id,
            toolName: identity.name,
            exitCode: 0,
            stdout: stdout,
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

@Suite(.serialized)
struct StdoutArtifactTests {
    @Test func diskBackedStdoutRoundTripsExactBytesChecksumAndDownloadLifecycle() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-disk-stdout")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let tool = Self.makeOutputTool(
            id: "test_stdout_json",
            name: "JSON Export",
            script: #"import sys; sys.stdout.write('{"value":"' + 'a' * 149988 + '"}')"#,
            outputByteLimit: 5 * 1024 * 1024
        )
        let executor = SpoolCapturingToolExecutor(
            executor: ConfiguredToolExecutor(
                tools: [tool],
                environment: ExecutableLocator.toolEnvironment,
                artifactStore: artifactStore
            )
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: executor,
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let payload = "{\"value\":\"\(String(repeating: "a", count: 149_988))\"}"
        let expectedData = Data(payload.utf8)
        #expect(expectedData.count == 150_000)
        let expectedSHA256 = SHA256.hash(data: expectedData).map { String(format: "%02x", $0) }.joined()

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_stdout_json", "arguments": [:]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        #expect(call.data.count <= LocalMCPServer.mcpCallToolResultByteLimit)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        let stdout = try #require(structured["stdout"] as? String)
        #expect(stdout.utf8.count == LocalMCPServer.mcpStdoutByteLimit)
        #expect(structured["truncatedStdout"] as? Bool == true)
        #expect(structured["reason"] as? String == "ok")

        let content = try #require(result["content"] as? [[String: Any]])
        let resourceLink = try #require(content.first { $0["type"] as? String == "resource_link" })
        #expect(resourceLink["name"] as? String == "JSON Export-output.json")
        #expect(resourceLink["mimeType"] as? String == "application/json")
        let note = try #require(content.first { $0["type"] as? String == "text" && ($0["text"] as? String)?.contains("SHA-256") == true })
        #expect((note["text"] as? String)?.contains(expectedSHA256) == true)

        let capturedSpoolURL = await executor.capturedSpoolURL()
        let sourceSpoolURL = try #require(capturedSpoolURL)
        #expect(FileManager.default.fileExists(atPath: sourceSpoolURL.path) == false)

        let uri = try #require(resourceLink["uri"] as? String)
        let artifactURL = try #require(URL(string: uri))
        let head = try await sendRequest(method: "HEAD", url: artifactURL)
        #expect(head.statusCode == 200)
        #expect(headerValue(head.headers, named: "Content-Length") == String(expectedData.count))
        #expect(headerValue(head.headers, named: "Content-Type") == "application/json")

        for _ in 0..<3 {
            let download = try await getWithHeaders(url: artifactURL)
            #expect(download.statusCode == 200)
            #expect(download.data == expectedData)
            let downloadedSHA256 = SHA256.hash(data: download.data)
                .map { String(format: "%02x", $0) }
                .joined()
            #expect(downloadedSHA256 == expectedSHA256)
        }
        let exhausted = try await getWithHeaders(url: artifactURL)
        #expect(exhausted.statusCode == 404)
    }

    @Test func onlyHardCapLossUsesOutputLimitReason() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-capped-stdout")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let hardLimit = 120_000
        let tool = Self.makeOutputTool(
            id: "test_stdout_capped",
            name: "Text Export",
            script: "import sys; sys.stdout.write('z' * 150000)",
            outputByteLimit: hardLimit
        )
        let executor = ConfiguredToolExecutor(
            tools: [tool],
            environment: ExecutableLocator.toolEnvironment,
            artifactStore: artifactStore
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: executor,
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let payload = String(repeating: "z", count: 150_000)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_stdout_capped", "arguments": [:]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["truncatedStdout"] as? Bool == true)
        #expect(structured["reason"] as? String == "output_limit")
        let content = try #require(result["content"] as? [[String: Any]])
        let resourceLink = try #require(content.first { $0["type"] as? String == "resource_link" })
        #expect((resourceLink["description"] as? String)?.contains("configured limit") == true)
        let artifactURI = try #require(resourceLink["uri"] as? String)
        let artifactURL = try #require(URL(string: artifactURI))
        let download = try await getWithHeaders(url: artifactURL)
        #expect(download.statusCode == 200)
        #expect(download.data == Data(payload.utf8).prefix(hardLimit))
    }

    @Test func diskBackedStdoutPreservesExactPayloadAboveFormerFiveMiBCeiling() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-large-disk-stdout")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let payloadSize = 6 * 1024 * 1024 + 123
        let tool = Self.makeOutputTool(
            id: "test_stdout_above_five_mib",
            name: "Large Notes Export",
            script: "import sys; sys.stdout.buffer.write(b'q' * \(payloadSize))",
            outputByteLimit: 64 * 1024 * 1024
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: ExecutableLocator.toolEnvironment,
                artifactStore: artifactStore
            ),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_stdout_above_five_mib", "arguments": [:]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["reason"] as? String == "ok")
        #expect(structured["truncatedStdout"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        let resourceLink = try #require(content.first { $0["type"] as? String == "resource_link" })
        let artifactURI = try #require(resourceLink["uri"] as? String)
        let artifactURL = try #require(URL(string: artifactURI))
        let download = try await getWithHeaders(url: artifactURL)
        let expectedData = Data(repeating: 0x71, count: payloadSize)

        #expect(download.statusCode == 200)
        #expect(download.data.count == payloadSize)
        #expect(download.data == expectedData)
        #expect(
            SHA256.hash(data: download.data).elementsEqual(SHA256.hash(data: expectedData))
        )
    }

    @Test func stdoutArtifactMIMEUsesContentBeforeToolIdentity() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-stdout-mime")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let tool = ToolDefinition(
            id: "test_mime",
            name: "MIME Fixture",
            summary: "Return large format fixtures.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024 * 1024
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: MIMEFixtureToolExecutor(),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let cases: [(fixture: String, suffix: String, mimeType: String)] = [
            ("drawing-json", ".json", "application/json"),
            ("html-json", ".json", "application/json"),
            ("svg", ".svg", "image/svg+xml"),
            ("html", ".html", "text/html"),
            ("markdown", ".md", "text/markdown"),
            ("invalid-json-prefix", ".txt", "text/plain"),
            ("escaped-text", ".txt", "text/plain"),
            ("text", ".txt", "text/plain")
        ]

        for item in cases {
            let call = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: token,
                body: [
                    "jsonrpc": "2.0", "id": item.fixture, "method": "tools/call",
                    "params": ["name": "test_mime", "arguments": ["value": item.fixture]]
                ]
            )
            let result = try #require(call.json["result"] as? [String: Any])
            #expect(call.data.count <= LocalMCPServer.mcpCallToolResultByteLimit)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["truncatedStdout"] as? Bool == true)
            #expect(structured["reason"] as? String == "ok")
            let content = try #require(result["content"] as? [[String: Any]])
            let resourceLink = try #require(content.first { $0["type"] as? String == "resource_link" })
            #expect((resourceLink["name"] as? String)?.hasSuffix(item.suffix) == true)
            #expect(resourceLink["mimeType"] as? String == item.mimeType)
            try await assertArtifactRouteContentTypeMatchesDeclaredMIME(resourceLink: resourceLink)
        }
    }

    @Test func sharedArtifactMIMEMapCoversNotesAttachments() {
        let cases: [String: String] = [
            "json": "application/json",
            "svg": "image/svg+xml",
            "html": "text/html",
            "md": "text/markdown",
            "txt": "text/plain",
            "png": "image/png",
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "heic": "image/heic",
            "pdf": "application/pdf",
            "m4a": "audio/mp4",
            "mp4": "video/mp4",
            "mp3": "audio/mpeg",
            "wav": "audio/wav",
            "mov": "video/quicktime",
            "bin": "application/octet-stream"
        ]

        for (fileExtension, expectedMIME) in cases {
            #expect(LocalMCPServer.mimeType(forFilename: "Note.\(fileExtension)") == expectedMIME)
        }
    }

    @Test func nonUTF8StdoutBelowInlineLimitIsAnExactBinaryArtifact() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-binary-stdout")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(
            rootDirectory: root.appendingPathComponent("store", isDirectory: true)
        )
        let expected = Data([0x41, 0xff, 0x42])
        let tool = Self.makeOutputTool(
            id: "test_stdout_binary",
            name: "Binary Output",
            script: "import sys; sys.stdout.buffer.write(bytes([0x41, 0xff, 0x42]))",
            outputByteLimit: 1024
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: ExecutableLocator.toolEnvironment,
                artifactStore: artifactStore
            ),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server
        )

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_stdout_binary", "arguments": [:]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["reason"] as? String == "ok")
        #expect(structured["succeeded"] as? Bool == true)
        #expect(structured["truncatedStdout"] as? Bool == true)
        let content = try #require(result["content"] as? [[String: Any]])
        let resourceLink = try #require(
            content.first { $0["type"] as? String == "resource_link" }
        )
        #expect((resourceLink["name"] as? String)?.hasSuffix(".bin") == true)
        #expect(resourceLink["mimeType"] as? String == "application/octet-stream")
        let uri = try #require(resourceLink["uri"] as? String)
        let artifactURL = try #require(URL(string: uri))
        let download = try await getWithHeaders(url: artifactURL)
        #expect(download.statusCode == 200)
        #expect(download.data == expected)
    }

    @Test func artifactStagingFailureReturnsCompletedCommandResultNotProtocolError() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-failed-stdout-stage")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(
            rootDirectory: root.appendingPathComponent("store", isDirectory: true),
            maxSizeBytes: 1
        )
        let tool = ToolDefinition(
            id: "test_stage_failure",
            name: "Stage Failure",
            summary: "Return output that cannot fit in the test artifact store.",
            executablePath: "/bin/echo",
            argumentPattern: ["{value}"],
            parameters: [
                ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)
            ],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024 * 1024
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: MIMEFixtureToolExecutor(),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server
        )

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": "test_stage_failure", "arguments": ["value": "text"]]
            ]
        )
        #expect(call.statusCode == 200)
        #expect(call.json["error"] == nil)
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["exitCode"] as? Int == 0)
        #expect(structured["succeeded"] as? Bool == true)
        #expect(structured["reason"] as? String == "internal_error")
        #expect(structured["truncatedStdout"] as? Bool == true)
        #expect((structured["stderr"] as? String)?.contains("do not retry") == true)
    }

    @Test func bridgeContextForwardsRichContentAndNamespacesMetadataWithoutCollisions() async throws {
        let userOnlyText = "Private detail for the person."
        let tool = Self.makeOutputTool(
            id: "test_bridge_context",
            name: "Bridge Context",
            script: "",
            outputByteLimit: 1024 * 1024,
            category: .reminders
        )
        let context = MCPBridgeUpstreamResultContext(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string("One result."),
                    "annotations": .object([
                        "audience": .array([.string("assistant")])
                    ])
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string(userOnlyText),
                    "annotations": .object([
                        "audience": .array([.string("user")])
                    ])
                ])
            ],
            meta: .object([
                "ui/resourceUri": .string("ui://upstream/not-proxied.html"),
                LocalMCPServer.resultUIMetaKey: .string("upstream-collision")
            ]),
            extensions: ["vendorCursor": .string("cursor-2")]
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: UpstreamMCPContextToolExecutor(
                stdout: #"{"items":[{"id":"one"}]}"#,
                context: context,
                exitCode: 0
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool.id, "arguments": [:]]
            ]
        )

        let result = try #require(call.json["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["stdout"] as? String == #"{"items":[{"id":"one"}]}"#)
        #expect(!(structured["stdout"] as? String ?? "").contains(userOnlyText))
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 3)
        #expect(content[0]["type"] as? String == "text")
        #expect(!(content[0]["text"] as? String ?? "").contains(userOnlyText))
        #expect(content[1]["text"] as? String == "One result.")
        let assistantAnnotations = try #require(content[1]["annotations"] as? [String: Any])
        #expect(assistantAnnotations["audience"] as? [String] == ["assistant"])
        #expect(content[2]["text"] as? String == userOnlyText)
        let userAnnotations = try #require(content[2]["annotations"] as? [String: Any])
        #expect(userAnnotations["audience"] as? [String] == ["user"])

        let assistantVisibleContent = content.filter { item in
            let annotations = item["annotations"] as? [String: Any]
            let audience = annotations?["audience"] as? [String] ?? []
            return !audience.contains("user") || audience.contains("assistant")
        }
        let assistantVisibleData = try JSONSerialization.data(withJSONObject: assistantVisibleContent)
        #expect(!String(decoding: assistantVisibleData, as: UTF8.self).contains(userOnlyText))

        let meta = try #require(result["_meta"] as? [String: Any])
        let upstream = try #require(meta[LocalMCPServer.upstreamResultMetaKey] as? [String: Any])
        #expect(upstream["ui/resourceUri"] as? String == "ui://upstream/not-proxied.html")
        #expect(upstream[LocalMCPServer.resultUIMetaKey] as? String == "upstream-collision")
        // Upstream UI keys remain nested and cannot replace active MacRemote metadata.
        #expect(meta["ui/resourceUri"] as? String == LocalMCPServer.widgetResourceURI)
        #expect(meta[LocalMCPServer.resultUIMetaKey] is [String: Any])
        let extensions = try #require(meta[LocalMCPServer.upstreamExtensionsMetaKey] as? [String: Any])
        #expect(extensions["vendorCursor"] as? String == "cursor-2")
    }

    @Test func oversizedBridgeContextSeparatesAudienceContentAndHiddenMetadata() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-upstream-context")
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("artifacts"))
        let tool = Self.makeOutputTool(
            id: "test_bridge_context_spill",
            name: "Bridge Context Spill",
            script: "",
            outputByteLimit: 1024 * 1024
        )
        let assistantText = String(repeating: "assistant-data/", count: 12_000)
        let userOnlyText = String(repeating: "user-private-data/", count: 12_000)
        let context = MCPBridgeUpstreamResultContext(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string(assistantText),
                    "annotations": .object(["audience": .array([.string("assistant")])])
                ]),
                .object([
                    "type": .string("text"),
                    "text": .string(userOnlyText),
                    "annotations": .object(["audience": .array([.string("user")])])
                ])
            ],
            meta: .object(["cursor": .string("next")]),
            extensions: ["vendorState": .string("complete")]
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: UpstreamMCPContextToolExecutor(
                stdout: "ok",
                context: context,
                exitCode: 0
            ),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool.id, "arguments": [:]]
            ]
        )

        #expect(call.data.count <= LocalMCPServer.mcpCallToolResultByteLimit)
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["stdout"] as? String == "ok")
        #expect(structured["reason"] as? String == "ok")
        let meta = try #require(result["_meta"] as? [String: Any])
        #expect(meta[LocalMCPServer.upstreamResultMetaKey] == nil)
        #expect(meta[LocalMCPServer.upstreamExtensionsMetaKey] == nil)
        let preservation = try #require(
            meta[LocalMCPServer.upstreamPreservationMetaKey] as? [String: Any]
        )
        let assistantPreservation = try #require(
            preservation["assistantContent"] as? [String: Any]
        )
        let userPreservation = try #require(preservation["userContent"] as? [String: Any])
        let metadataPreservation = try #require(preservation["metadata"] as? [String: Any])
        let assistantURI = try #require(assistantPreservation["uri"] as? String)
        let userURI = try #require(userPreservation["uri"] as? String)
        let metadataURI = try #require(metadataPreservation["uri"] as? String)
        #expect(assistantURI.hasPrefix("http://127.0.0.1:\(port)/artifact/"))
        #expect(userURI.hasPrefix("http://127.0.0.1:\(port)/artifact/"))
        #expect(metadataURI.hasPrefix("http://127.0.0.1:\(port)/artifact/"))
        #expect(Set([assistantURI, userURI, metadataURI]).count == 3)

        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 5)
        #expect(content.contains { ($0["text"] as? String) == assistantText } == false)
        #expect(content.contains { ($0["text"] as? String) == userOnlyText } == false)
        let assistantResource = try #require(content.first {
            $0["type"] as? String == "resource_link" && $0["uri"] as? String == assistantURI
        })
        #expect(assistantResource["mimeType"] as? String == "application/json")
        let assistantAnnotations = try #require(
            assistantResource["annotations"] as? [String: Any]
        )
        #expect(assistantAnnotations["audience"] as? [String] == ["assistant"])
        let userResource = try #require(content.first {
            $0["type"] as? String == "resource_link" && $0["uri"] as? String == userURI
        })
        let userAnnotations = try #require(userResource["annotations"] as? [String: Any])
        #expect(userAnnotations["audience"] as? [String] == ["user"])
        #expect(content.filter {
            (($0["annotations"] as? [String: Any])?["audience"] as? [String]) == ["assistant"]
        }.count == 2)
        #expect(content.filter {
            (($0["annotations"] as? [String: Any])?["audience"] as? [String]) == ["user"]
        }.count == 2)

        let assistantVisibleContent = content.filter { item in
            let annotations = item["annotations"] as? [String: Any]
            let audience = annotations?["audience"] as? [String] ?? []
            return !audience.contains("user") || audience.contains("assistant")
        }
        let assistantVisibleData = try JSONSerialization.data(withJSONObject: assistantVisibleContent)
        let assistantVisibleJSON = String(decoding: assistantVisibleData, as: UTF8.self)
        #expect(!assistantVisibleJSON.contains(userOnlyText))
        #expect(!assistantVisibleJSON.contains(userURI))
        #expect(!assistantVisibleJSON.contains(metadataURI))

        let assistantToken = String(
            assistantURI.dropFirst("http://127.0.0.1:\(port)/artifact/".count)
        )
        let stagedAssistant = try #require(artifactStore.resolve(token: assistantToken))
        let assistantArtifactData = try Data(contentsOf: stagedAssistant.fileURL)
        let assistantBundle = try #require(
            JSONSerialization.jsonObject(with: assistantArtifactData) as? [String: Any]
        )
        let assistantBlocks = try #require(assistantBundle["content"] as? [[String: Any]])
        #expect(assistantBlocks.count == 1)
        #expect(assistantBlocks[0]["text"] as? String == assistantText)
        #expect(!String(decoding: assistantArtifactData, as: UTF8.self).contains(userOnlyText))
        #expect(assistantBundle["_meta"] == nil)
        #expect(assistantBundle["extensions"] == nil)

        let userToken = String(userURI.dropFirst("http://127.0.0.1:\(port)/artifact/".count))
        let stagedUser = try #require(artifactStore.resolve(token: userToken))
        let userArtifactData = try Data(contentsOf: stagedUser.fileURL)
        let userBundle = try #require(
            JSONSerialization.jsonObject(with: userArtifactData) as? [String: Any]
        )
        let userBlocks = try #require(userBundle["content"] as? [[String: Any]])
        #expect(userBlocks.count == 1)
        #expect(userBlocks[0]["text"] as? String == userOnlyText)
        #expect(!String(decoding: userArtifactData, as: UTF8.self).contains(assistantText))
        #expect(userBundle["_meta"] == nil)
        #expect(userBundle["extensions"] == nil)

        let metadataToken = String(metadataURI.dropFirst("http://127.0.0.1:\(port)/artifact/".count))
        let stagedMetadata = try #require(artifactStore.resolve(token: metadataToken))
        let metadataArtifactData = try Data(contentsOf: stagedMetadata.fileURL)
        let metadataBundle = try #require(
            JSONSerialization.jsonObject(with: metadataArtifactData) as? [String: Any]
        )
        #expect((metadataBundle["_meta"] as? [String: Any])?["cursor"] as? String == "next")
        #expect((metadataBundle["extensions"] as? [String: Any])?["vendorState"] as? String == "complete")
        #expect(metadataBundle["content"] == nil)
    }

    @Test func emptyBridgeContentKeepsMetadataOutOfModelVisibleFallback() async throws {
        let tool = Self.makeOutputTool(
            id: "test_bridge_empty_content",
            name: "Bridge Empty Content",
            script: "",
            outputByteLimit: 1024 * 1024
        )
        let context = MCPBridgeUpstreamResultContext(
            content: [],
            meta: .object(["privateCursor": .string("cursor-1")]),
            extensions: [:]
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: UpstreamMCPContextToolExecutor(
                stdout: "",
                context: context,
                exitCode: 0
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool.id, "arguments": [:]]
            ]
        )

        let result = try #require(call.json["result"] as? [String: Any])
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["stdout"] as? String == "")
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(!(content[0]["text"] as? String ?? "").contains("privateCursor"))
        let meta = try #require(result["_meta"] as? [String: Any])
        let upstream = try #require(meta[LocalMCPServer.upstreamResultMetaKey] as? [String: Any])
        #expect(upstream["privateCursor"] as? String == "cursor-1")
    }

    @Test func bridgeUpstreamErrorRetainsRichContentAndMapsFailure() async throws {
        let tool = Self.makeOutputTool(
            id: "test_bridge_error_context",
            name: "Bridge Error Context",
            script: "",
            outputByteLimit: 1024 * 1024
        )
        let context = MCPBridgeUpstreamResultContext(
            content: [
                .object([
                    "type": .string("text"),
                    "text": .string("Request denied."),
                    "annotations": .object(["audience": .array([.string("assistant")])])
                ])
            ],
            meta: .object(["errorID": .string("denied-1")]),
            extensions: [:]
        )
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: UpstreamMCPContextToolExecutor(
                stdout: "Request denied.",
                context: context,
                exitCode: 1
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": tool.id, "arguments": [:]]
            ]
        )

        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["exitCode"] as? Int == 1)
        #expect(structured["succeeded"] as? Bool == false)
        #expect(structured["reason"] as? String == "nonzero_exit")
        #expect(structured["stdout"] as? String == "Request denied.")
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[1]["text"] as? String == "Request denied.")
        let meta = try #require(result["_meta"] as? [String: Any])
        #expect(
            (meta[LocalMCPServer.upstreamResultMetaKey] as? [String: Any])?["errorID"] as? String
                == "denied-1"
        )
    }

    /// The whole path a remote agent takes on a Mac whose owner allowed the
    /// whole disk: find a file it knows only by name, read it as text, be
    /// refused a key without the owner being asked, and run a program that
    /// asks first on a file anywhere.
    @Test func anAppCanFindReadAndRunAnywhereOnceTheOwnerAllowsTheWholeMac() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-whole-mac")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let elsewhere = root.appendingPathComponent("elsewhere/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("key".utf8).write(to: home.appendingPathComponent(".ssh/quarterly-key"))
        let report = elsewhere.appendingPathComponent("quarterly-report.txt")
        try Data("Revenue is up 4%.".utf8).write(to: report)

        let runTool = ToolDefinition(
            id: "test_cat_run",
            name: "Cat CLI",
            summary: "Print files by passing argv directly.",
            executablePath: "/bin/cat",
            argumentPattern: ["{args}"],
            parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 64 * 1024
        )
        let tools = [FileTransferToolCatalog.findTool, FileTransferToolCatalog.readFileTool, runTool]
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("artifacts"))
        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: toolApprovals,
            toolExecutor: ConfiguredToolExecutor(
                tools: tools,
                environment: ExecutableLocator.toolEnvironment,
                artifactStore: artifactStore,
                fileTransferPolicy: FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: ["/"])
            ),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        func call(_ name: String, _ arguments: [String: Any]) async throws -> [String: Any] {
            let response = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: token,
                body: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": arguments]]
            )
            #expect(response.statusCode == 200)
            let result = try #require(response.json["result"] as? [String: Any])
            return try #require(result["structuredContent"] as? [String: Any])
        }
        func payload(_ structured: [String: Any]) throws -> [String: Any] {
            let stdout = try #require(structured["stdout"] as? String)
            return try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        }

        // Find by name, with no idea where the file is under this folder.
        let found = try payload(try await call("filesystem_find", ["name": "quarterly", "path": root.path]))
        let matches = try #require(found["matches"] as? [[String: Any]])
        // The key in .ssh has the same word in its name and is not listed.
        #expect(matches.compactMap { $0["path"] as? String }.map { ($0 as NSString).lastPathComponent }
            == ["quarterly-report.txt"])
        let foundPath = try #require(matches.first?["path"] as? String)

        // Read it as text. Nothing asked the owner so far.
        let read = try payload(try await call("filesystem_read_file", ["path": foundPath, "encoding": "utf8"]))
        #expect(read["text"] as? String == "Revenue is up 4%.")
        #expect(toolApprovals.approvalSnapshot().isEmpty)

        // The key is refused outright, again without a prompt.
        let refused = try await call(
            "filesystem_read_file",
            ["path": home.appendingPathComponent(".ssh/quarterly-key").path, "encoding": "utf8"]
        )
        #expect(refused["reason"] as? String == "invalid_argument")
        #expect(toolApprovals.approvalSnapshot().isEmpty)

        // A program that takes any arguments asks first, then runs anywhere.
        let approver = approveEveryToolCall(in: toolApprovals)
        defer { approver.cancel() }
        let ran = try await call("test_cat_run", ["args": [foundPath]])
        #expect(ran["reason"] as? String == "ok")
        #expect(ran["stdout"] as? String == "Revenue is up 4%.")
        #expect(toolApprovals.approvalSnapshot().count == 1)
    }

    @Test func nativeReadFileOversizedRequestReturnsCompleteTransportSafeChunk() async throws {
        let root = try Self.makeTemporaryDirectory(prefix: "macremote-native-read-envelope")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("report.md")
        // 0xff produces slash-heavy base64. Foundation escapes those slashes
        // unless explicitly told not to, amplifying every nested JSON layer.
        let fileData = Data(repeating: 0xff, count: 37_606)
        try fileData.write(to: fileURL)

        let tool = FileTransferToolCatalog.readFileTool
        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("artifacts"))
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [tool],
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: [tool],
                environment: ExecutableLocator.toolEnvironment,
                artifactStore: artifactStore,
                fileTransferPolicy: FileTransferPathPolicy(allowedFolders: [root.path])
            ),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": [
                    "name": tool.id,
                    "arguments": ["path": fileURL.path, "offset": 0, "length": 65_536]
                ]
            ]
        )

        #expect(call.statusCode == 200)
        #expect(call.data.count <= 65_536)
        let result = try #require(call.json["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == false)
        let structured = try #require(result["structuredContent"] as? [String: Any])
        #expect(structured["truncatedStdout"] as? Bool == false)
        #expect(structured["reason"] as? String == "ok")
        let stdout = try #require(structured["stdout"] as? String)
        let payload = try #require(
            JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        )
        #expect(payload["length_returned"] as? Int == FileTransferToolCatalog.readFileChunkByteLimit)
        #expect(payload["eof"] as? Bool == false)
        let encoded = try #require(payload["data_base64"] as? String)
        let chunk = try #require(Data(base64Encoded: encoded))
        #expect(chunk == fileData.prefix(FileTransferToolCatalog.readFileChunkByteLimit))

        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 1)
        #expect(content.contains { $0["type"] as? String == "resource_link" } == false)

    }

    private static func makeOutputTool(
        id: String,
        name: String,
        script: String,
        outputByteLimit: Int,
        category: ToolCategory = .developer
    ) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: name,
            summary: "Emit a deterministic output fixture.",
            executablePath: "/usr/bin/python3",
            argumentPattern: ["-c", script],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: outputByteLimit,
            category: category
        )
    }

    private static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Basename-targeted actions (for any user-created adapter) and the
/// input/style/equals fields added for reschedule, edit, and delete verbs.
struct MCPUIActionTargetingTests {
    @Test func basenameTargetedActionResolvesToSharedFlexibleAdapter() async throws {
        let coordinator = OAuthCoordinator()
        let listTool = ToolDefinition(
            id: "custom_aaa111",
            name: "Up Next",
            summary: "Queue rows.",
            executablePath: "/opt/homebrew/bin/pocketctl",
            argumentPattern: ["{value}"],
            parameters: [ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            origin: .userDefined,
            // Real preset-derived PocketCTL tools carry .podcasts so their
            // result keeps the richer episode profile and action layout.
            category: .podcasts,
            uiActions: [
                ToolUIAction(
                    id: "play_next",
                    title: "Play Next",
                    kind: .rowButton,
                    targetExecutableBasename: "pocketctl",
                    arguments: .object(["args": .array([.string("play-next"), .string("{uuid}")])]),
                    requiredRowFields: ["uuid"]
                ),
                ToolUIAction(
                    id: "reschedule",
                    title: "Reschedule",
                    kind: .rowButton,
                    targetExecutableBasename: "pocketctl",
                    arguments: .object(["args": .array([.string("edit"), .string("{input.due}")])]),
                    style: .destructive,
                    inputs: [ToolUIActionInput(name: "due", title: "New due", placeholder: "+1d")]
                ),
                ToolUIAction(
                    id: "orphan",
                    title: "Orphan",
                    kind: .rowButton,
                    targetExecutableBasename: "no-such-cli",
                    arguments: .object([:])
                )
            ]
        )
        let adapter = ToolDefinition(
            id: "custom_bbb222",
            name: "Run PocketCTL",
            summary: "Flexible adapter.",
            executablePath: "/opt/homebrew/bin/pocketctl",
            argumentPattern: ["{args}"],
            parameters: [ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)],
            capability: .destructive,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [listTool, adapter],
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let listed = try await toolsList(base: base, accessToken: token)
        let listName = try #require(listed.first { $0["title"] as? String == "Up Next" }?["name"] as? String)
        let adapterName = try #require(listed.first { $0["title"] as? String == "Run PocketCTL" }?["name"] as? String)

        let call = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                "params": ["name": listName, "arguments": ["value": "x"]]
            ]
        )
        let result = try #require(call.json["result"] as? [String: Any])
        let meta = try #require(result["_meta"] as? [String: Any])
        let ui = try #require(meta["net.viticci.macremote/ui"] as? [String: Any])
        let actions = try #require(ui["actions"] as? [[String: Any]])

        // Orphan action (unresolvable target) is dropped; the two real ones remain.
        #expect(actions.count == 2)
        let playNext = try #require(actions.first { $0["id"] as? String == "play_next" })
        #expect(playNext["toolName"] as? String == adapterName)
        #expect(playNext["toolCapability"] as? String == "destructive")
        #expect(playNext["targetExecutableBasename"] == nil, "internal addressing never leaks")

        let reschedule = try #require(actions.first { $0["id"] as? String == "reschedule" })
        #expect(reschedule["style"] as? String == "destructive")
        let inputs = try #require(reschedule["inputs"] as? [[String: Any]])
        #expect(inputs.first?["name"] as? String == "due")
        #expect(inputs.first?["placeholder"] as? String == "+1d")
    }

    @Test func artifactPayloadGainsAbsoluteDownloadURL() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_artifact",
                    name: "Artifact",
                    summary: "Return artifact metadata.",
                    executablePath: "/bin/echo",
                    argumentPattern: [],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024,
                    backend: .native,
                    nativeToolID: .fsDownloadFile
                )
            ],
            publicHost: { "macremote-test.trycloudflare.com" },
            authCoordinator: coordinator,
            toolExecutor: ArtifactPayloadToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "Host": "macremote-test.trycloudflare.com"
        ]
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server,
            headers: forwardedHeaders
        )

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: forwardedHeaders.merging(["MCP-Protocol-Version": "2025-11-25"]) { _, new in new },
            body: [
                "jsonrpc": "2.0",
                "id": "artifact",
                "method": "tools/call",
                "params": [
                    "name": "test_artifact",
                    "arguments": [:]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let callResult = try #require(toolCall.json["result"] as? [String: Any])
        let structuredContent = try #require(callResult["structuredContent"] as? [String: Any])
        let stdout = try #require(structuredContent["stdout"] as? String)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])
        #expect(payload["download_url"] as? String == "https://macremote-test.trycloudflare.com/artifact/test-token")

        let content = try #require(callResult["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        let resourceLink = try #require(content[1] as? [String: Any])
        #expect(resourceLink["type"] as? String == "resource_link")
        #expect(resourceLink["uri"] as? String == "https://macremote-test.trycloudflare.com/artifact/test-token")
        #expect(resourceLink["name"] as? String == "download.bin")
        #expect(resourceLink["mimeType"] as? String == "application/octet-stream")
        #expect((resourceLink["description"] as? String)?.contains("600") == true)
        #expect((resourceLink["description"] as? String)?.contains("4 bytes") == true)
    }

    @Test func artifactZipResourceLinkMimeTypeMatchesRouteContentType() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-artifact-zip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let artifactStore = ArtifactStore(rootDirectory: root.appendingPathComponent("store", isDirectory: true))
        let source = root.appendingPathComponent("archive.zip")
        try Data("zip-bytes".utf8).write(to: source)
        let handle = try artifactStore.register(fileURL: source, suggestedFilename: "archive.zip")

        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test_artifact_zip",
                    name: "Zip Artifact",
                    summary: "Return zip artifact metadata.",
                    executablePath: "/bin/echo",
                    argumentPattern: [],
                    parameters: [],
                    capability: .readOnly,
                    timeoutSeconds: 2,
                    outputByteLimit: 1024,
                    backend: .native,
                    nativeToolID: .fsDownloadFile
                )
            ],
            authCoordinator: coordinator,
            toolExecutor: RegisteredArtifactPayloadToolExecutor(
                artifactPath: handle.artifactPath,
                filename: handle.filename,
                sizeBytes: handle.sizeBytes
            ),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let toolCall = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: accessToken,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "artifact-zip",
                "method": "tools/call",
                "params": [
                    "name": "test_artifact_zip",
                    "arguments": [:]
                ]
            ]
        )
        #expect(toolCall.statusCode == 200)
        let callResult = try #require(toolCall.json["result"] as? [String: Any])
        let content = try #require(callResult["content"] as? [[String: Any]])
        let resourceLink = try #require(content.first { $0["type"] as? String == "resource_link" } as? [String: Any])
        #expect(resourceLink["name"] as? String == "archive.zip")
        #expect(resourceLink["mimeType"] as? String == "application/zip")
        try await assertArtifactRouteContentTypeMatchesDeclaredMIME(resourceLink: resourceLink)
    }

    @Test func artifactRouteServesBytesWithHeadersAndExpires() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-artifact-route-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let clock = TestClock(now: Date(timeIntervalSince1970: 2_000_000))
        let artifactStore = ArtifactStore(
            rootDirectory: root.appendingPathComponent("store", isDirectory: true),
            clock: { clock.now },
            expiryInterval: 60
        )
        let source = root.appendingPathComponent("download.bin")
        let payload = Data("artifact-bytes".utf8)
        try payload.write(to: source)
        let handle = try artifactStore.register(fileURL: source, suggestedFilename: "download.bin")

        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor(),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        let download = try await getWithHeaders(url: base.appendingPathComponent(handle.artifactPath))
        #expect(download.statusCode == 200)
        #expect(download.data == payload)
        #expect(headerValue(download.headers, named: "Content-Type") == "application/octet-stream")
        #expect(headerValue(download.headers, named: "Content-Disposition") == "attachment; filename=\"download.bin\"")
        #expect(headerValue(download.headers, named: "Cache-Control") == "no-store")

        let head = try await sendRequest(
            method: "HEAD",
            url: base.appendingPathComponent(handle.artifactPath)
        )
        #expect(head.statusCode == 200)
        #expect(head.data.isEmpty)
        #expect(headerValue(head.headers, named: "Content-Length") == String(payload.count))
        #expect(headerValue(head.headers, named: "Content-Type") == "application/octet-stream")
        #expect(headerValue(head.headers, named: "Content-Disposition") == "attachment; filename=\"download.bin\"")
        #expect(headerValue(head.headers, named: "Cache-Control") == "no-store")
        _ = artifactStore.consume(token: handle.token)
        _ = artifactStore.consume(token: handle.token)
        let exhausted = try await getWithHeaders(url: base.appendingPathComponent(handle.artifactPath))
        #expect(exhausted.statusCode == 404)

        let freshSource = root.appendingPathComponent("fresh.bin")
        try Data("fresh".utf8).write(to: freshSource)
        let freshHandle = try artifactStore.register(fileURL: freshSource, suggestedFilename: "fresh.bin")
        clock.now = clock.now.addingTimeInterval(61)
        let expired = try await getWithHeaders(url: base.appendingPathComponent(freshHandle.artifactPath))
        #expect(expired.statusCode == 404)
    }

    /// A download is read from disk and sent piece by piece. The bytes and
    /// the headers must come out the same as when it was sent in one block.
    @Test func downloadLargerThanOnePieceArrivesWhole() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-artifact-pieces-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifactStore = ArtifactStore(rootDirectory: root)
        // Three full pieces and a partial one, with bytes that differ by position.
        let payload = Data((0..<(3 * 256 * 1024 + 1234)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) })
        let handle = try artifactStore.register(data: payload, suggestedFilename: "large.bin")

        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor(),
            artifactStore: artifactStore
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)

        let origin = "http://127.0.0.1:\(port)"
        let download = try await getWithHeaders(
            url: base.appendingPathComponent(handle.artifactPath),
            headers: ["Origin": origin]
        )
        #expect(download.statusCode == 200)
        #expect(download.data == payload)
        #expect(headerValue(download.headers, named: "Content-Length") == String(payload.count))
        #expect(headerValue(download.headers, named: "Access-Control-Allow-Origin") == origin)
        #expect(artifactStore.resolve(token: handle.token)?.remainingDownloads == 2)
    }
}

/// Log lines collected from a server's event handler, which runs off the test's thread.
private final class LockedLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func append(_ line: String) {
        lock.withLock { stored.append(line) }
    }

    var lines: [String] {
        lock.withLock { stored }
    }
}

// MARK: - Result cards (SPEC D77)

/// Stands in for the saved Settings value, which the server reads on each request.
private final class CurrentResultCards: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ResultCardPreferences

    init(_ value: ResultCardPreferences) {
        stored = value
    }

    var value: ResultCardPreferences {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@Suite(.serialized)
struct ResultCardPreferenceTests {
    private static let linkageKeys = ["ui", "ui/resourceUri", "openai/outputTemplate", "openai/widgetAccessible"]

    private static func tool(id: String, executablePath: String) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: id,
            summary: "Return a fixed payload.",
            executablePath: executablePath,
            argumentPattern: ["{value}"],
            parameters: [ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            category: .utilities
        )
    }

    private static func call(_ name: String, base: URL, token: String) async throws -> [String: Any] {
        let response = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": name, "method": "tools/call",
                "params": ["name": name, "arguments": ["value": "x"]]
            ]
        )
        return try #require(response.json["result"] as? [String: Any])
    }

    /// The parts of a result an app shows when it draws no card.
    private static func plainResult(_ result: [String: Any]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: [
                "content": result["content"] ?? NSNull(),
                "structuredContent": result["structuredContent"] ?? NSNull()
            ],
            options: [.sortedKeys]
        )
    }

    private static func linkedToolNames(_ tools: [[String: Any]]) -> Set<String> {
        Set(tools.compactMap { tool -> String? in
            let meta = tool["_meta"] as? [String: Any] ?? [:]
            return linkageKeys.contains { meta[$0] != nil } ? tool["name"] as? String : nil
        })
    }

    @Test func savedChoiceDecidesUILinkageWhileResultsStayTheSame() async throws {
        let suiteName = "ResultCardPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // Nothing saved yet: a fresh install shows no cards.
        let cards = CurrentResultCards(ResultCardPreferences(userDefaults: defaults))
        #expect(cards.value.showsCards == false)

        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                Self.tool(id: "echo_tool", executablePath: "/bin/echo"),
                Self.tool(id: "cat_tool", executablePath: "/bin/cat")
            ],
            resultCardPreferences: { cards.value },
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        _ = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": [
                    "protocolVersion": "2025-06-18",
                    "capabilities": [
                        "extensions": [
                            "io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]
                        ]
                    ],
                    "clientInfo": ["name": "UI Host", "version": "1.0"]
                ]
            ]
        )

        // Off (the default): no linkage in tools/list or in the result.
        let offTools = try await toolsList(base: base, accessToken: token)
        #expect(Self.linkedToolNames(offTools).isEmpty)
        #expect(offTools.allSatisfy { ($0["_meta"] as? [String: Any])?["securitySchemes"] != nil })
        let offResult = try await Self.call("echo_tool", base: base, token: token)
        #expect(offResult["_meta"] == nil)
        // Old conversations can still load the card.
        let read = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": "read", "method": "resources/read",
                "params": ["uri": LocalMCPServer.widgetResourceURI]
            ]
        )
        #expect(((read.json["result"] as? [String: Any])?["contents"] as? [[String: Any]])?.isEmpty == false)

        // On: the very next requests carry linkage, and the result is otherwise unchanged.
        cards.value = ResultCardPreferences(showsCards: true)
        #expect(Self.linkedToolNames(try await toolsList(base: base, accessToken: token)) == ["echo_tool", "cat_tool"])
        let onResult = try await Self.call("echo_tool", base: base, token: token)
        let onMeta = try #require(onResult["_meta"] as? [String: Any])
        #expect(onMeta[LocalMCPServer.resultUIMetaKey] != nil)
        #expect(try Self.plainResult(onResult) == Self.plainResult(offResult))

        // One family off: only that family loses its card.
        cards.value = ResultCardPreferences(showsCards: true, hiddenFamilyIDs: ["executable:cat"])
        #expect(Self.linkedToolNames(try await toolsList(base: base, accessToken: token)) == ["echo_tool"])
        #expect((try await Self.call("cat_tool", base: base, token: token))["_meta"] == nil)
        #expect((try await Self.call("echo_tool", base: base, token: token))["_meta"] != nil)
    }

    @Test func familiesFollowServerProviderBuiltInAndExecutable() throws {
        let pocket = Self.tool(id: "pocketctl_up_next", executablePath: "/somewhere/pctl")
        #expect(ToolFamily(pocket) == ToolFamily(id: "provider.pocketctl", name: "PocketCTL"))

        let ripgrep = Self.tool(id: "scan_homebrew_rg", executablePath: "/opt/homebrew/bin/rg")
        #expect(ToolFamily(ripgrep) == ToolFamily(id: "executable:rg", name: "rg"))

        let fileTransfer = try #require(FileTransferToolCatalog.builtInTools.first)
        #expect(ToolFamily(fileTransfer).id == ToolFamily.fileTransferID)

        for definition in DefaultToolPresetCatalog.providerDefinitions {
            let toolID = ToolIdentifier.presetToolID(from: definition.presetIDPrefix + "example")
            #expect(DefaultToolPresetCatalog.provider(forToolID: toolID)?.id == definition.id)
        }
    }
}
