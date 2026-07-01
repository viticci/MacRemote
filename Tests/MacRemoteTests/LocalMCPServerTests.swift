import Foundation
import XCTest
@testable import MacRemote

final class LocalMCPServerTests: XCTestCase {
    func testPublicHealthDoesNotDiscloseInstanceOrToolSurface() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)

        let localHealth = try await getJSON(url: base.appendingPathComponent("health"))
        XCTAssertEqual(localHealth.json["ok"] as? Bool, true)
        XCTAssertEqual(localHealth.json["public_metadata"] as? Bool, false)
        XCTAssertEqual(localHealth.json["instance_id"] as? String, "test-instance")
        XCTAssertEqual(localHealth.json["tool_count"] as? Int, 1)
        XCTAssertEqual(localHealth.json["tool_profile"] as? String, "custom-cli")

        let publicHealth = try await getJSON(url: base.appendingPathComponent("health"), headers: forwardedHeaders)
        XCTAssertEqual(publicHealth.json["ok"] as? Bool, true)
        XCTAssertEqual(publicHealth.json["public_metadata"] as? Bool, true)
        XCTAssertNil(publicHealth.json["instance_id"])
        XCTAssertNil(publicHealth.json["tool_count"])
        XCTAssertNil(publicHealth.json["tool_profile"])
    }

    func testIconEndpointsServePublicAssets() async throws {
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FakeToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        let base = URL(string: "http://127.0.0.1:\(port)")!
        try await Task.sleep(nanoseconds: 100_000_000)

        let connectorIcon = try await getWithHeaders(url: base.appendingPathComponent("macremote-icon.png"))
        XCTAssertEqual(connectorIcon.statusCode, 200)
        XCTAssertEqual(Data(connectorIcon.data.prefix(8)), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(headerValue(connectorIcon.headers, named: "Content-Type"), "image/png")

        let faviconPNG = try await getWithHeaders(url: base.appendingPathComponent("favicon.png"))
        XCTAssertEqual(faviconPNG.statusCode, 200)
        XCTAssertEqual(Data(faviconPNG.data.prefix(8)), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(headerValue(faviconPNG.headers, named: "Content-Type"), "image/png")

        let faviconICO = try await getWithHeaders(url: base.appendingPathComponent("favicon.ico"))
        XCTAssertEqual(faviconICO.statusCode, 200)
        XCTAssertEqual(Data(faviconICO.data.prefix(4)), Data([0x00, 0x00, 0x01, 0x00]))
        XCTAssertEqual(headerValue(faviconICO.headers, named: "Content-Type"), "image/x-icon")
    }

    func testPublicOAuthRegistrationIsRateLimitedButLoopbackIsNot() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)

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
            XCTAssertEqual(response.statusCode, 201)
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
        XCTAssertEqual(limited.statusCode, 429)
        XCTAssertEqual(limited.json["error"] as? String, "rate_limited")
        XCTAssertNotNil(headerValue(limited.headers, named: "Retry-After"))

        let loopback = try await postJSON(
            url: base.appendingPathComponent("register"),
            body: [
                "client_name": "Loopback HTTP Test",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        XCTAssertEqual(loopback.statusCode, 201)
    }

    func testForwardedHTTPSHostIsUsedForOAuthMetadata() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)

        let protectedResource = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource"),
            headers: forwardedHeaders
        )
        XCTAssertEqual(protectedResource.json["resource"] as? String, "https://macremote-test.trycloudflare.com/mcp/test-instance")
        XCTAssertEqual(protectedResource.json["authorization_servers"] as? [String], ["https://macremote-test.trycloudflare.com"])
        XCTAssertEqual(protectedResource.json["mcp_protocol_version"] as? String, "2025-11-25")

        let pathProtectedResource = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-protected-resource/mcp/test-instance"),
            headers: forwardedHeaders
        )
        XCTAssertEqual(pathProtectedResource.json["resource"] as? String, "https://macremote-test.trycloudflare.com/mcp/test-instance")
        XCTAssertEqual(pathProtectedResource.json["authorization_servers"] as? [String], ["https://macremote-test.trycloudflare.com"])

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
            headers: forwardedHeaders
        )
        XCTAssertEqual(authorizationServer.json["issuer"] as? String, "https://macremote-test.trycloudflare.com")
        XCTAssertEqual(authorizationServer.json["registration_endpoint"] as? String, "https://macremote-test.trycloudflare.com/register")
        XCTAssertEqual(authorizationServer.json["resource_indicators_supported"] as? Bool, true)
    }

    func testOAuthProtectedMCPToolFlowOverHTTP() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)

        let noAuth = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        XCTAssertEqual(noAuth.statusCode, 401)
        let challenge = try XCTUnwrap(headerValue(noAuth.headers, named: "WWW-Authenticate"))
        XCTAssertTrue(challenge.contains("resource_metadata=\"http://127.0.0.1:\(port)/.well-known/oauth-protected-resource/mcp/test-instance\""))
        XCTAssertTrue(challenge.contains("scope=\"mcp:tools\""))

        let invalidOrigin = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: ["Origin": "https://evil.example"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        XCTAssertEqual(invalidOrigin.statusCode, 403)

        let unsupportedProtocol = try await postJSON(
            url: base.appendingPathComponent("mcp/test-instance"),
            headers: ["MCP-Protocol-Version": "2099-01-01"],
            body: [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ]
        )
        XCTAssertEqual(unsupportedProtocol.statusCode, 400)

        let getMCP = try await get(url: base.appendingPathComponent("mcp/test-instance"))
        XCTAssertEqual(getMCP.statusCode, 405)

        let verifier = "server-flow-verifier"
        let registered = try await postJSON(
            url: base.appendingPathComponent("register"),
            body: [
                "client_name": "HTTP Test",
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ]
        )
        XCTAssertEqual(registered.statusCode, 201)
        let clientID = try XCTUnwrap(registered.json["client_id"] as? String)

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
        let authorizationPage = try await get(url: try XCTUnwrap(authorize.url))
        XCTAssertEqual(authorizationPage.statusCode, 200)

        let requestID = try XCTUnwrap(coordinator.approvalSnapshot().first?.id)
        XCTAssertTrue(server.approveAuthorizationRequest(id: requestID))

        var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
        statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
        let status = try await getJSON(url: try XCTUnwrap(statusURL.url))
        let redirectURI = try XCTUnwrap(status.json["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

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
        XCTAssertEqual(token.statusCode, 200)
        let accessToken = try XCTUnwrap(token.json["access_token"] as? String)

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
        XCTAssertEqual(initialize.statusCode, 200)
        let initializeResult = try XCTUnwrap(initialize.json["result"] as? [String: Any])
        let serverInfo = try XCTUnwrap(initializeResult["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "MacRemote")
        XCTAssertEqual(serverInfo["title"] as? String, "MacRemote")
        let icons = try XCTUnwrap(serverInfo["icons"] as? [[String: Any]])
        let icon = try XCTUnwrap(icons.first)
        XCTAssertEqual(icon["src"] as? String, "http://127.0.0.1:\(port)/macremote-icon.png")
        XCTAssertEqual(icon["mimeType"] as? String, "image/png")
        XCTAssertEqual(icon["sizes"] as? [String], ["512x512"])

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
        XCTAssertEqual(toolsList.statusCode, 200)
        let toolsResult = try XCTUnwrap(toolsList.json["result"] as? [String: Any])
        let tools = try XCTUnwrap(toolsResult["tools"] as? [[String: Any]])
        let listedTool = try XCTUnwrap(tools.first)
        XCTAssertEqual(listedTool["name"] as? String, "test_echo")
        XCTAssertEqual(listedTool["title"] as? String, "Echo")
        let description = try XCTUnwrap(listedTool["description"] as? String)
        XCTAssertTrue(description.contains("Echo a test value."))
        XCTAssertTrue(description.contains("Only the documented schema parameters are accepted."))
        XCTAssertTrue(description.contains("Read-only"))
        XCTAssertNotNil(listedTool["outputSchema"] as? [String: Any])
        let inputSchema = try XCTUnwrap(listedTool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let valueSchema = try XCTUnwrap(properties["value"] as? [String: Any])
        XCTAssertEqual(valueSchema["title"] as? String, "Value")
        XCTAssertEqual(valueSchema["description"] as? String, "Value")
        XCTAssertEqual(valueSchema["maxLength"] as? Int, 64)
        let annotations = try XCTUnwrap(listedTool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
        XCTAssertEqual(annotations["idempotentHint"] as? Bool, true)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, false)

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
        XCTAssertEqual(toolCall.statusCode, 200)
        let callResult = try XCTUnwrap(toolCall.json["result"] as? [String: Any])
        let structuredContent = try XCTUnwrap(callResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structuredContent["toolID"] as? String, "test.echo")
        XCTAssertEqual(structuredContent["stdout"] as? String, "echo:hello")
        XCTAssertEqual(structuredContent["succeeded"] as? Bool, true)
        let content = try XCTUnwrap(callResult["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.first?["text"] as? String)
        XCTAssertTrue(text.contains("\"stdout\":\"echo:hello\""))

        let legacyMCPPath = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: accessToken,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy",
                "method": "ping"
            ]
        )
        XCTAssertEqual(legacyMCPPath.statusCode, 200)
    }

    func testDottedToolNamesRemainCallableForExistingClients() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
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

        XCTAssertEqual(toolCall.statusCode, 200)
        let callResult = try XCTUnwrap(toolCall.json["result"] as? [String: Any])
        let structuredContent = try XCTUnwrap(callResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structuredContent["toolID"] as? String, "test.echo")
        XCTAssertEqual(structuredContent["stdout"] as? String, "echo:legacy")
    }

    func testPublicForwardedRequestsMustUseInstanceMCPPath() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(
            base: base,
            coordinator: coordinator,
            server: server,
            headers: forwardedHeaders
        )

        let legacyPublicPath = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            bearerToken: accessToken,
            headers: forwardedHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-public",
                "method": "ping"
            ]
        )
        XCTAssertEqual(legacyPublicPath.statusCode, 404)

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
        XCTAssertEqual(instancePublicPath.statusCode, 200)
    }

    func testPublicHostCannotBeDowngradedBySpoofedForwardedHeaders() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)

        let publicHealth = try await getJSON(url: base.appendingPathComponent("health"), headers: spoofedHeaders)
        XCTAssertEqual(publicHealth.json["public_metadata"] as? Bool, true)
        XCTAssertNil(publicHealth.json["instance_id"])
        XCTAssertNil(publicHealth.json["tool_count"])

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
            headers: spoofedHeaders
        )
        XCTAssertEqual(authorizationServer.json["issuer"] as? String, "https://macremote-test.trycloudflare.com")

        let legacyPublicPath = try await postJSON(
            url: base.appendingPathComponent("mcp"),
            headers: spoofedHeaders,
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-public",
                "method": "ping"
            ]
        )
        XCTAssertEqual(legacyPublicPath.statusCode, 404)
    }

    func testForwardedIssuerBindsBearerTokenToOrigin() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
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
        XCTAssertEqual(authorized.statusCode, 200)

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
        XCTAssertEqual(replayed.statusCode, 401)
    }

    func testMCPRunsInstalledPocketCTLReadOnlyCommand() async throws {
        guard let pocketCTLPath = DefaultToolPresetCatalog.pocketCTLExecutablePath else {
            throw XCTSkip("PocketCTL is not installed on this Mac.")
        }

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
        try await Task.sleep(nanoseconds: 100_000_000)
        let health = try await getJSON(url: base.appendingPathComponent("health"))
        XCTAssertEqual(health.json["tool_profile"] as? String, "pocketctl-cli")
        XCTAssertEqual(health.json["tool_count"] as? Int, 1)

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
        XCTAssertEqual(toolCall.statusCode, 200)

        let callResult = try XCTUnwrap(toolCall.json["result"] as? [String: Any])
        let structuredContent = try XCTUnwrap(callResult["structuredContent"] as? [String: Any])
        XCTAssertEqual(structuredContent["succeeded"] as? Bool, true)
        XCTAssertEqual(structuredContent["exitCode"] as? Int, 0)
        let stdout = try XCTUnwrap(structuredContent["stdout"] as? String)
        XCTAssertTrue(stdout.contains("\"email\""))
        XCTAssertTrue(stdout.contains("\"user_uuid\""))
    }

    func testGenericCLIAdapterDescriptionExplainsDirectArgvSemantics() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try XCTUnwrap(tools.first)
        let description = try XCTUnwrap(listedTool["description"] as? String)
        XCTAssertTrue(description.contains("without a shell"))
        XCTAssertTrue(description.contains("do not use `~`"))
        XCTAssertTrue(description.contains("global options such as `--ask-for-approval` and `--sandbox` must appear before `exec`"))
        XCTAssertTrue(description.contains("May require macOS privacy permission for Screen Recording, Accessibility"))

        let inputSchema = try XCTUnwrap(listedTool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let argsSchema = try XCTUnwrap(properties["args"] as? [String: Any])
        XCTAssertTrue((argsSchema["description"] as? String)?.contains("No shell is used") == true)

        let annotations = try XCTUnwrap(listedTool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, true)
        XCTAssertEqual(annotations["idempotentHint"] as? Bool, false)
    }

    func testClaudeCLIAdapterDescriptionExplainsMCPFriendlyInvocation() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try XCTUnwrap(tools.first)
        let description = try XCTUnwrap(listedTool["description"] as? String)
        XCTAssertTrue(description.contains("non-interactive MCP-safe calls"))
        XCTAssertTrue(description.contains("`--print`"))
        XCTAssertTrue(description.contains("`--output-format text`, `json`, or `stream-json`"))
        XCTAssertTrue(description.contains("`--mcp-config`"))
        XCTAssertTrue(description.contains("Avoid bare interactive sessions"))
    }

    func testRemCTLCLIAdapterDescriptionExplainsNumericIDsAndPrivateFlag() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try XCTUnwrap(tools.first)
        let description = try XCTUnwrap(listedTool["description"] as? String)
        XCTAssertTrue(description.contains("numeric `id` field"))
        XCTAssertTrue(description.contains("do not pass the UUID embedded in `deepLink`"))
        XCTAssertTrue(description.contains("synced rich URL attachments"))
        XCTAssertTrue(description.contains("tag add/replace/remove"))
        XCTAssertTrue(description.contains("list groups, smart lists, and templates"))
        XCTAssertTrue(description.contains("Do not use `--private` for normal due dates, recurrence, or EventKit alarms"))

        let inputSchema = try XCTUnwrap(listedTool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let argsSchema = try XCTUnwrap(properties["args"] as? [String: Any])
        let argsDescription = try XCTUnwrap(argsSchema["description"] as? String)
        XCTAssertTrue(argsDescription.contains("Use numeric reminder IDs"))
        XCTAssertTrue(argsDescription.contains("Use `--private --url`"))
        XCTAssertTrue(argsDescription.contains("edit --private --set-tags"))
        XCTAssertTrue(argsDescription.contains("add --private -f"))
        XCTAssertTrue(argsDescription.contains("section, list, group, smart-list, and template commands"))
        XCTAssertTrue(argsDescription.contains("ordinary due dates, recurrence, and EventKit alarms do not"))
    }

    func testPocketCTLCLIAdapterDescriptionExplainsJSONAndDryRun() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try XCTUnwrap(tools.first)
        let description = try XCTUnwrap(listedTool["description"] as? String)
        XCTAssertTrue(description.contains("For PocketCTL, prefer `--json`"))
        XCTAssertTrue(description.contains("`--dry-run --json`"))

        let inputSchema = try XCTUnwrap(listedTool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let argsSchema = try XCTUnwrap(properties["args"] as? [String: Any])
        let argsDescription = try XCTUnwrap(argsSchema["description"] as? String)
        XCTAssertTrue(argsDescription.contains("Exact PocketCTL argv items"))
        XCTAssertTrue(argsDescription.contains("played-state writes"))
    }

    func testHabitCTLCLIAdapterDescriptionExplainsJSONAndDryRun() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let tools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try XCTUnwrap(tools.first)
        let description = try XCTUnwrap(listedTool["description"] as? String)
        XCTAssertTrue(description.contains("For HabitCTL, prefer `--json`"))
        XCTAssertTrue(description.contains("checking, logging, archiving"))

        let inputSchema = try XCTUnwrap(listedTool["inputSchema"] as? [String: Any])
        let properties = try XCTUnwrap(inputSchema["properties"] as? [String: Any])
        let argsSchema = try XCTUnwrap(properties["args"] as? [String: Any])
        let argsDescription = try XCTUnwrap(argsSchema["description"] as? String)
        XCTAssertTrue(argsDescription.contains("Exact HabitCTL argv items"))
        XCTAssertTrue(argsDescription.contains("note writes"))
    }

    func testDestructiveMCPToolCallRequiresHostApproval() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
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
        XCTAssertEqual(approval.toolID, "test.remctl.run")
        XCTAssertEqual(approval.clientName, "HTTP Test")
        XCTAssertTrue(approval.argumentsPreview.contains("args=add Test -l Work"))
        XCTAssertTrue(toolApprovals.deny(requestID: approval.id))

        let deniedCall = try await callTask.value
        XCTAssertEqual(deniedCall.statusCode, 200)
        XCTAssertEqual(deniedCall.isError, true)
        XCTAssertEqual(deniedCall.stderr, "Tool call was not approved on the host Mac.")
    }

    func testClientToolPermissionSkipsHostApprovalForDestructiveTool() async throws {
        let defaultsSuite = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuite))
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let client = try XCTUnwrap(coordinator.connectedClientSnapshot().first)
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
        XCTAssertEqual(toolCall.statusCode, 200)
        let result = try XCTUnwrap(toolCall.json["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, false)
        XCTAssertTrue(toolApprovals.approvalSnapshot().isEmpty)
    }

    func testToolsListReflectsRuntimeUpdatesWithoutRestart() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let initialList = try await toolsList(base: base, accessToken: accessToken)
        XCTAssertEqual(initialList.map { $0["name"] as? String }, ["test_first"])

        runtime.update(tools: [firstTool, secondTool])
        let updatedList = try await toolsList(base: base, accessToken: accessToken)
        XCTAssertEqual(
            Set(updatedList.compactMap { $0["name"] as? String }),
            Set(["test_first", "test_second"])
        )
    }

    func testMCPToolNamesAreClaudeCompatible() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)
        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)

        let listedTools = try await toolsList(base: base, accessToken: accessToken)
        let names = listedTools.compactMap { $0["name"] as? String }
        XCTAssertEqual(names.count, tools.count)
        XCTAssertTrue(names.contains("preset_filesystem_list_directory"))
        XCTAssertTrue(names.contains("custom_31a0edd6b19a5788"))
        XCTAssertTrue(names.contains("same_name"))
        XCTAssertEqual(Set(names).count, names.count)

        for name in names {
            XCTAssertLessThanOrEqual(name.count, 64)
            XCTAssertNotNil(name.range(of: #"^[a-zA-Z0-9_-]{1,64}$"#, options: .regularExpression))
        }
    }

    func testMCPBridgeToolExposesUpstreamSchemaAndForwardsJSONArguments() async throws {
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
        try await Task.sleep(nanoseconds: 100_000_000)

        let health = try await getJSON(url: base.appendingPathComponent("health"))
        XCTAssertEqual(health.json["tool_profile"] as? String, "mcp-bridge")

        let accessToken = try await authorizedAccessToken(base: base, coordinator: coordinator, server: server)
        let listedTools = try await toolsList(base: base, accessToken: accessToken)
        let listedTool = try XCTUnwrap(listedTools.first)
        let toolName = try XCTUnwrap(listedTool["name"] as? String)
        XCTAssertEqual(listedTool["title"] as? String, "Paste Search")

        let schema = try XCTUnwrap(listedTool["inputSchema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["payload"] as? [String: Any])

        let annotations = try XCTUnwrap(listedTool["annotations"] as? [String: Any])
        XCTAssertEqual(annotations["title"] as? String, "Paste Search")
        XCTAssertEqual(annotations["readOnlyHint"] as? Bool, true)
        XCTAssertEqual(annotations["destructiveHint"] as? Bool, false)
        XCTAssertEqual(annotations["openWorldHint"] as? Bool, false)

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
        XCTAssertEqual(toolCall.statusCode, 200)
        let result = try XCTUnwrap(toolCall.json["result"] as? [String: Any])
        let structuredContent = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        let stdout = try XCTUnwrap(structuredContent["stdout"] as? String)
        let echoedPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any])

        XCTAssertEqual(echoedPayload["query"] as? String, "clip")
        XCTAssertEqual(echoedPayload["count"] as? Int, 2)
        XCTAssertEqual((echoedPayload["nested"] as? [String: Any])?["enabled"] as? Bool, true)
    }
}

private struct FakeToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        let stdout: String
        if let payload = parameters["payload"] {
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
    XCTAssertEqual(response.statusCode, 200)
    let result = try XCTUnwrap(response.json["result"] as? [String: Any])
    return try XCTUnwrap(result["tools"] as? [[String: Any]])
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
    XCTAssertEqual(registered.statusCode, 201)
    let clientID = try XCTUnwrap(registered.json["client_id"] as? String)

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
    let authorizationPage = try await get(url: try XCTUnwrap(authorize.url), headers: headers)
    XCTAssertEqual(authorizationPage.statusCode, 200)

    let requestID = try XCTUnwrap(coordinator.approvalSnapshot().first?.id)
    XCTAssertTrue(server.approveAuthorizationRequest(id: requestID))

    var statusURL = URLComponents(url: base.appendingPathComponent("authorize/status"), resolvingAgainstBaseURL: false)!
    statusURL.queryItems = [URLQueryItem(name: "request_id", value: requestID.uuidString)]
    let status = try await getJSON(url: try XCTUnwrap(statusURL.url), headers: headers)
    let redirectURI = try XCTUnwrap(status.json["redirect_uri"] as? String)
    let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

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
    XCTAssertEqual(token.statusCode, 200)
    return try XCTUnwrap(token.json["access_token"] as? String)
}

private func waitForPendingToolApproval(
    in coordinator: ToolCallApprovalCoordinator,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> ToolCallApprovalRequest {
    for _ in 0..<50 {
        if let request = coordinator.approvalSnapshot().first(where: { $0.state == .pending }) {
            return request
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    XCTFail("Timed out waiting for pending tool approval.", file: file, line: line)
    throw NSError(domain: "MacRemoteTests", code: 1)
}

private func get(url: URL, headers: [String: String] = [:]) async throws -> (statusCode: Int, data: Data) {
    let response = try await getWithHeaders(url: url, headers: headers)
    return (response.statusCode, response.data)
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
    let http = try XCTUnwrap(response as? HTTPURLResponse)
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
    let http = try XCTUnwrap(response as? HTTPURLResponse)
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
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return (http.statusCode, try decodeJSON(data))
}

private func decodeJSON(_ data: Data) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
}

private func percentEncode(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value
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
        return "\(scheme)://\(forwardedHost)/mcp/\(instanceID)"
    }
    return "\(base.absoluteString)/mcp/\(instanceID)"
}
