import Foundation
import Testing
@testable import MacRemote

// Every test here binds its own 127.0.0.1 listener on a port chosen by a
// probe-then-bind scan, so concurrently running tests can race the probe and
// end up talking to another test's server (XCTest ran these serially; Swift
// Testing is parallel by default). Serialize the suite to keep one live
// server at a time.
@Suite(.serialized)
struct LocalMCPServerTests {
    @Test func publicHealthDoesNotDiscloseInstanceOrToolSurface() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.echo",
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
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let forwardedHeaders = [
            "X-Forwarded-Host": "macremote-test.trycloudflare.com",
            "X-Forwarded-Proto": "https"
        ]
        try await waitForServerReady(base: base)

        let localHealth = try await getJSON(url: base.appendingPathComponent("health"))
        #expect(localHealth.json["ok"] as? Bool == true)
        #expect(localHealth.json["public_metadata"] as? Bool == false)
        #expect(localHealth.json["instance_id"] as? String == "test-instance")
        #expect(localHealth.json["tool_count"] as? Int == 1)
        #expect(localHealth.json["tool_profile"] as? String == "custom-cli")

        let publicHealth = try await getJSON(url: base.appendingPathComponent("health"), headers: forwardedHeaders)
        #expect(publicHealth.json["ok"] as? Bool == true)
        #expect(publicHealth.json["public_metadata"] as? Bool == true)
        #expect(publicHealth.json["instance_id"] == nil)
        #expect(publicHealth.json["tool_count"] == nil)
        #expect(publicHealth.json["tool_profile"] == nil)
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

        let landing = try await getWithHeaders(url: base)
        #expect(landing.statusCode == 200)
        #expect(headerValue(landing.headers, named: "Content-Type") == "text/html; charset=utf-8")
        let landingHTML = try #require(String(data: landing.data, encoding: .utf8))
        #expect(landingHTML.contains("<link rel=\"icon\" href=\"/favicon.ico\""))
        #expect(landingHTML.contains("MacRemote"))
    }

    @Test func publicOAuthRegistrationIsRateLimitedButLoopbackIsNot() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.echo",
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
        let forwardedHeaders = [
            "X-Forwarded-Host": "macremote-test.trycloudflare.com",
            "X-Forwarded-Proto": "https"
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
                    id: "test.echo",
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
        let forwardedHeaders = [
            "X-Forwarded-Host": "macremote-test.trycloudflare.com",
            "X-Forwarded-Proto": "https"
        ]
        try await waitForServerReady(base: base)

        let protectedResource = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource"),
            headers: forwardedHeaders
        )
        #expect(protectedResource.json["resource"] as? String == "https://macremote-test.trycloudflare.com/mcp")
        #expect(protectedResource.json["authorization_servers"] as? [String] == ["https://macremote-test.trycloudflare.com"])
        #expect(protectedResource.json["mcp_protocol_version"] as? String == "2025-11-25")

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
        #expect(authorizationServer.json["token_endpoint_auth_methods_supported"] as? [String] == ["none"])
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

    @Test func oAuthProtectedMCPToolFlowOverHTTP() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.echo",
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

        let unsupportedProtocol = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: ["MCP-Protocol-Version": "2099-01-01"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        #expect(unsupportedProtocol.statusCode == 400)

        let getMCP = try await get(url: base.appendingPathComponent("mcp/test-instance"))
        #expect(getMCP.statusCode == 405)

        let verifier = "server-flow-verifier"
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
        let serverInfo = try #require(initializeResult["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "MacRemote")
        #expect(serverInfo["title"] as? String == "MacRemote")
        #expect(serverInfo["websiteUrl"] as? String == "http://127.0.0.1:\(port)")
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
        #expect(description.contains("Only the documented schema parameters are accepted."))
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
        #expect(structuredContent["toolID"] as? String == "test.echo")
        #expect(structuredContent["stdout"] as? String == "echo:hello")
        #expect(structuredContent["succeeded"] as? Bool == true)
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
                    id: "test.echo",
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
        let verifier = "server-public-client-verifier"
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
                    id: "test.echo",
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
        let verifier = "server-confidential-verifier"
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
                    id: "test.echo",
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
                    "name": "test.echo",
                    "arguments": [
                        "value": "legacy"
                    ]
                ]
            ]
        )

        #expect(toolCall.statusCode == 200)
        let callResult = try #require(toolCall.json["result"] as? [String: Any])
        let structuredContent = try #require(callResult["structuredContent"] as? [String: Any])
        #expect(structuredContent["toolID"] as? String == "test.echo")
        #expect(structuredContent["stdout"] as? String == "echo:legacy")
    }

    @Test func publicForwardedMCPAliasRequiresBearerAndUsesSameGrant() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.echo",
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
        let forwardedHeaders = [
            "X-Forwarded-Host": "macremote-test.trycloudflare.com",
            "X-Forwarded-Proto": "https"
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

    @Test func publicHostCannotBeDowngradedBySpoofedForwardedHeaders() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.echo",
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
    }

    @Test func forwardedIssuerBindsBearerTokenToOrigin() async throws {
        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.echo",
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
            authCoordinator: coordinator,
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        let originalOrigin = [
            "X-Forwarded-Host": "macremote-one.trycloudflare.com",
            "X-Forwarded-Proto": "https"
        ]
        let replayOrigin = [
            "X-Forwarded-Host": "macremote-two.trycloudflare.com",
            "X-Forwarded-Proto": "https"
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
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.pocketCTLExecutablePath != nil, "PocketCTL is not installed on this Mac."))
    func mcpRunsInstalledPocketCTLReadOnlyCommand() async throws {
        let pocketCTLPath = try #require(DefaultToolPresetCatalog.pocketCTLExecutablePath)

        let tool = ToolDefinition(
            id: "pocketctl.whoami",
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
        #expect(health.json["tool_profile"] as? String == "pocketctl-cli")
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
                    "name": "pocketctl.whoami",
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

    @Test func genericCLIAdapterDescriptionExplainsDirectArgvSemantics() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test.codex",
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
        #expect(description.contains("without a shell"))
        #expect(description.contains("do not use `~`"))
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
            id: "test.claude",
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
            "Pass exact argv items as the `args` array; optional `stdin` is sent to standard input.",
            "MacRemote launches the executable directly without a shell: do not use `~`, `$HOME`, pipes, redirection, globs, command substitution, or environment assignments. Use absolute paths and separate every flag/value into its own argv item.",
            "Destructive or broad CLI access: requires host approval before execution.",
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

    @Test func remCTLCLIAdapterDescriptionExplainsNumericIDsAndPrivateFlag() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test.remctl",
            name: "Run RemCTL",
            summary: "Run RemCTL by passing argv directly.",
            executablePath: "/usr/local/bin/remctl",
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
        #expect(description.contains("numeric `id` field"))
        #expect(description.contains("do not pass the UUID embedded in `deepLink`"))
        #expect(description.contains("synced rich URL attachments"))
        #expect(description.contains("tag add/replace/remove"))
        #expect(description.contains("list groups, smart lists, and templates"))
        #expect(description.contains("Do not use `--private` for normal due dates, recurrence, or EventKit alarms"))

        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let argsSchema = try #require(properties["args"] as? [String: Any])
        let argsDescription = try #require(argsSchema["description"] as? String)
        #expect(argsDescription.contains("Use numeric reminder IDs"))
        #expect(argsDescription.contains("Use `--private --url`"))
        #expect(argsDescription.contains("edit --private --set-tags"))
        #expect(argsDescription.contains("add --private -f"))
        #expect(argsDescription.contains("section, list, group, smart-list, and template commands"))
        #expect(argsDescription.contains("ordinary due dates, recurrence, and EventKit alarms do not"))
        // The adapter can run `upcoming N` too — its window arithmetic must
        // be spelled out (N=1 already covers today AND tomorrow).
        #expect(description.contains("`upcoming 1` returns today and tomorrow"))
    }

    @Test func remCTLUpcomingDescriptionExplainsDayWindowArithmetic() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test.upcoming",
            name: "Upcoming",
            summary: "Return reminders due in the next N days.",
            executablePath: "/usr/local/bin/remctl",
            argumentPattern: ["--format", "json", "upcoming", "{days}"],
            parameters: [
                ToolParameter(
                    name: "days",
                    title: "Days",
                    kind: .integer,
                    required: false,
                    defaultValue: "7",
                    integerRange: 1...3650
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
        // remctl's window starts today and spans N further days; without
        // this line models pass days=2 for "today and tomorrow" and get a
        // third day in the widget.
        #expect(description.contains("days=1 returns today and tomorrow"))
    }

    @Test func pocketCTLCLIAdapterDescriptionExplainsJSONAndDryRun() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test.pocketctl",
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
        let description = try #require(listedTool["description"] as? String)
        #expect(description.contains("For PocketCTL, prefer `--json`"))
        #expect(description.contains("`--dry-run --json`"))

        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let argsSchema = try #require(properties["args"] as? [String: Any])
        let argsDescription = try #require(argsSchema["description"] as? String)
        #expect(argsDescription.contains("Exact PocketCTL argv items"))
        #expect(argsDescription.contains("played-state writes"))
    }

    @Test func habitCTLCLIAdapterDescriptionExplainsJSONAndDryRun() async throws {
        let coordinator = OAuthCoordinator()
        let tool = ToolDefinition(
            id: "test.habitctl",
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
        let description = try #require(listedTool["description"] as? String)
        #expect(description.contains("For HabitCTL, prefer `--json`"))
        #expect(description.contains("checking, logging, archiving"))

        let inputSchema = try #require(listedTool["inputSchema"] as? [String: Any])
        let properties = try #require(inputSchema["properties"] as? [String: Any])
        let argsSchema = try #require(properties["args"] as? [String: Any])
        let argsDescription = try #require(argsSchema["description"] as? String)
        #expect(argsDescription.contains("Exact HabitCTL argv items"))
        #expect(argsDescription.contains("note writes"))
    }

    @Test func destructiveMCPToolCallRequiresHostApproval() async throws {
        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 5)
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [
                ToolDefinition(
                    id: "test.remctl.run",
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
                stderr: structuredContent?["stderr"] as? String
            )
        }

        let approval = try await waitForPendingToolApproval(in: toolApprovals)
        #expect(approval.toolID == "test.remctl.run")
        #expect(approval.clientName == "HTTP Test")
        #expect(approval.argumentsPreview.contains("args=add Test -l Work"))
        #expect(toolApprovals.deny(requestID: approval.id))

        let deniedCall = try await callTask.value
        #expect(deniedCall.statusCode == 200)
        #expect(deniedCall.isError == true)
        #expect(deniedCall.stderr == "Tool call was not approved on the host Mac.")
    }

    @Test func clientToolPermissionSkipsHostApprovalForDestructiveTool() async throws {
        let defaultsSuite = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { defaults.removePersistentDomain(forName: defaultsSuite) }

        let coordinator = OAuthCoordinator()
        let toolApprovals = ToolCallApprovalCoordinator(timeoutSeconds: 1)
        let permissions = ClientToolPermissionStore(userDefaults: defaults)
        let tool = ToolDefinition(
            id: "test.remctl.run",
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
        _ = permissions.setAllowed(true, clientID: client.id, toolID: tool.id)

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

    @Test func toolsListReflectsRuntimeUpdatesWithoutRestart() async throws {
        let coordinator = OAuthCoordinator()
        let firstTool = ToolDefinition(
            id: "test.first",
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
            id: "test.second",
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

        let initialList = try await toolsList(base: base, accessToken: accessToken)
        #expect(initialList.map { $0["name"] as? String } == ["test_first"])

        runtime.update(tools: [firstTool, secondTool])
        let updatedList = try await toolsList(base: base, accessToken: accessToken)
        #expect(
            Set(updatedList.compactMap { $0["name"] as? String }) ==
            Set(["test_first", "test_second"])
        )
    }

    @Test func mcpToolNamesAreClaudeCompatible() async throws {
        let coordinator = OAuthCoordinator()
        let tools = [
            ToolDefinition(
                id: "preset.filesystem.list_directory",
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
                id: "custom.31a0edd6b19a5788",
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
                id: String(repeating: "very.long.", count: 10),
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
                id: "same.name",
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
                id: "same_name",
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
        #expect(names.count == tools.count)
        #expect(names.contains("preset_filesystem_list_directory"))
        #expect(names.contains("custom_31a0edd6b19a5788"))
        #expect(names.contains("same_name"))
        #expect(Set(names).count == names.count)

        for name in names {
            #expect(name.count <= 64)
            #expect(name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression) != nil)
        }
    }

    @Test func mcpBridgeToolExposesUpstreamSchemaAndForwardsJSONArguments() async throws {
        let bridgeTool = ToolDefinition(
            id: "mcp.paste.search",
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

        let health = try await getJSON(url: base.appendingPathComponent("health"))
        #expect(health.json["tool_profile"] as? String == "mcp-bridge")

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
}

private func makeScannedAdapterTool(
    summary: String,
    summaryIsHarvested: Bool,
    summaryOrigin: String?
) -> ToolDefinition {
    ToolDefinition(
        id: "scan.homebrewFormula.rg",
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

private struct ToolCallResultResponse: Sendable {
    let statusCode: Int
    let isError: Bool?
    let stderr: String?
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

private func authorizedAccessToken(
    base: URL,
    coordinator: OAuthCoordinator,
    server: LocalMCPServer,
    headers: [String: String] = [:]
) async throws -> String {
    let verifier = "server-flow-verifier"
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
    var request = URLRequest(url: url)
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
) async throws -> (statusCode: Int, json: [String: Any], headers: [AnyHashable: Any]) {
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
    return (http.statusCode, (try? decodeJSON(data)) ?? [:], http.allHeaderFields)
}

private func postForm(
    url: URL,
    headers: [String: String] = [:],
    form: [String: String]
) async throws -> (statusCode: Int, json: [String: Any]) {
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
    return (http.statusCode, try decodeJSON(data))
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

private func resourceURL(base: URL, headers: [String: String], instanceID: String) -> String {
    if let forwardedHost = headers["X-Forwarded-Host"] {
        let scheme = headers["X-Forwarded-Proto"] ?? "https"
        return "\(scheme)://\(forwardedHost)/mcp"
    }
    return "\(base.absoluteString)/mcp/\(instanceID)"
}

// MARK: - MCP Apps (SEP-1865) selective widget

/// The selective widget: one ui:// resource covers every widget-eligible
/// tool (curated categories only — reminders + podcasts), uncurated tools
/// return plain results for the host's native rendering, hosts without the
/// extension keep the mandated text fallback untouched, and declared UI
/// actions ride CallToolResult._meta with public tool names.
struct MCPUISupportTests {
    private func makeUITestServer() -> (LocalMCPServer, OAuthCoordinator) {
        let coordinator = OAuthCoordinator()
        let listTool = ToolDefinition(
            id: "test.reminders",
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
                    toolID: "test.mutator",
                    arguments: .object(["args": .array([.string("done"), .string("{id}")])]),
                    requiredRowFields: ["id"],
                    completedWhenField: "completed"
                )
            ]
        )
        let mutatorTool = ToolDefinition(
            id: "test.mutator",
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
            id: "test.podcasts",
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
        // A category with no curated presentation hints: must NOT link the
        // widget — the host renders its own native display instead.
        let plainTool = ToolDefinition(
            id: "test.plain",
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
            toolExecutor: FakeToolExecutor()
        )
        return (server, coordinator)
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
        // The widget attaches selectively: only categories with curated
        // presentation hints (reminders, podcasts). Plain categories keep
        // the host's native rendering.
        let eligibleNames: Set<String> = ["test_reminders", "test_podcasts"]
        var seenEligible = 0
        for tool in tools {
            let name = try #require(tool["name"] as? String)
            if eligibleNames.contains(name) {
                seenEligible += 1
                let meta = try #require(tool["_meta"] as? [String: Any], "\(name) links the widget")
                let ui = try #require(meta["ui"] as? [String: Any])
                #expect(ui["resourceUri"] as? String == "ui://macremote/output")
                // Deprecated flat form rides along for hosts that still read it.
                #expect(meta["ui/resourceUri"] as? String == "ui://macremote/output")
            } else {
                #expect(tool["_meta"] == nil, "\(name) must not link the widget")
            }
        }
        #expect(seenEligible == 2)
    }

    @Test func habitToolResultCarriesBlueAccentAndHabitColumns() async throws {
        let coordinator = OAuthCoordinator()
        let habitsTool = ToolDefinition(
            id: "test.habits",
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

    @Test func plainCategoryToolResultCarriesNoWidgetMeta() async throws {
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
        // Fallback content stays for every tool; only the widget linkage
        // and render hints are withheld from uncurated categories.
        #expect((result["content"] as? [[String: Any]])?.first?["type"] as? String == "text")
        #expect((result["structuredContent"] as? [String: Any]) != nil)
        #expect(result["_meta"] == nil, "uncurated categories return plain results")
    }

    @Test func widgetResourceReadsBackWithSandboxMeta() async throws {
        let (server, coordinator) = makeUITestServer()
        let port = try server.start()
        defer { server.stop() }
        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForServerReady(base: base)
        let token = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let mcp = base.appendingPathComponent("mcp/test-instance")

        let list = try await postJSON(
            url: mcp, bearerToken: token,
            body: ["jsonrpc": "2.0", "id": 1, "method": "resources/list"]
        )
        let resources = try #require((list.json["result"] as? [String: Any])?["resources"] as? [[String: Any]])
        #expect(resources.count == 1)
        #expect(resources.first?["uri"] as? String == "ui://macremote/output")
        #expect(resources.first?["mimeType"] as? String == "text/html;profile=mcp-app")

        let read = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 2, "method": "resources/read",
                "params": ["uri": "ui://macremote/output"]
            ]
        )
        let contents = try #require((read.json["result"] as? [String: Any])?["contents"] as? [[String: Any]])
        let item = try #require(contents.first)
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

        let unknown = try await postJSON(
            url: mcp, bearerToken: token,
            body: [
                "jsonrpc": "2.0", "id": 3, "method": "resources/read",
                "params": ["uri": "ui://macremote/other"]
            ]
        )
        #expect((unknown.json["error"] as? [String: Any])?["code"] as? Int == -32002)
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
        #expect((table["hiddenColumns"] as? [String])?.contains("id") == true)
        #expect((table["hiddenColumns"] as? [String])?.contains("completed") == true)
        let columns = try #require(table["columns"] as? [[String: Any]])
        #expect(columns.first?["key"] as? String == "when")
        #expect(columns.first?["derive"] as? String == "datetime")
        #expect(columns.first?["sourceKey"] as? String == "dueDate")
        let actions = try #require(ui["actions"] as? [[String: Any]])
        let action = try #require(actions.first)
        #expect(action["id"] as? String == "complete")
        #expect(action["kind"] as? String == "checkOff")
        #expect(action["toolName"] as? String == "test_mutator")
        #expect(action["toolCapability"] as? String == "write")
        #expect(action["toolID"] == nil, "internal ids never leak to clients")
        #expect(action["completedWhenField"] as? String == "completed")
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
        #expect(byKey["title"]?["subtitleKey"] as? String == "podcastTitle")
        #expect(byKey["podcastTitle"] == nil)
        #expect(byKey["duration"]?["derive"] as? String == "duration")
        #expect(byKey["progress"]?["derive"] as? String == "progress")
        #expect(byKey["progress"]?["sourceKey"] as? String == "playedUpTo")
        #expect(byKey["progress"]?["totalKey"] as? String == "duration")
        // seconds format → percent label + played-time tooltip (habit
        // goals omit it and label as count fractions instead).
        #expect(byKey["progress"]?["format"] as? String == "seconds")
        #expect(byKey["url"]?["derive"] as? String == "link")
        let hidden = try #require(table["hiddenColumns"] as? [String])
        for dropped in ["uuid", "published", "fileType", "size", "podcast", "podcastTitle"] {
            #expect(hidden.contains(dropped), "\(dropped) should be hidden")
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
    }
}

/// Basename-targeted actions (preset-derived tools have random ids) and the
/// input/style/equals fields added for reschedule, edit, and delete verbs.
struct MCPUIActionTargetingTests {
    @Test func basenameTargetedActionResolvesToSharedFlexibleAdapter() async throws {
        let coordinator = OAuthCoordinator()
        let listTool = ToolDefinition(
            id: "custom.aaa111",
            name: "Up Next",
            summary: "Queue rows.",
            executablePath: "/opt/homebrew/bin/pocketctl",
            argumentPattern: ["{value}"],
            parameters: [ToolParameter(name: "value", title: "Value", kind: .string, maximumLength: 64)],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024,
            origin: .userDefined,
            // Real preset-derived PocketCTL tools carry .podcasts — required
            // for widget eligibility now that the widget attaches selectively.
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
            id: "custom.bbb222",
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
}
