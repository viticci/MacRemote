import Foundation
import XCTest
@testable import MacRemote

final class LocalMCPServerTests: XCTestCase {
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

        let authorizationServer = try await getJSON(
            url: base.appendingPathComponent(".well-known/oauth-authorization-server"),
            headers: forwardedHeaders
        )
        XCTAssertEqual(authorizationServer.json["issuer"] as? String, "https://macremote-test.trycloudflare.com")
        XCTAssertEqual(authorizationServer.json["registration_endpoint"] as? String, "https://macremote-test.trycloudflare.com/register")
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
        XCTAssertEqual(tools.first?["name"] as? String, "test.echo")
        XCTAssertNotNil(tools.first?["outputSchema"] as? [String: Any])
        let annotations = try XCTUnwrap(tools.first?["annotations"] as? [String: Any])
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
                    "name": "test.echo",
                    "arguments": [
                        "value": "hello"
                    ]
                ]
            ]
        )
        XCTAssertEqual(toolCall.statusCode, 200)
        let callResult = try XCTUnwrap(toolCall.json["result"] as? [String: Any])
        let structuredContent = try XCTUnwrap(callResult["structuredContent"] as? [String: Any])
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

        let callTask = Task { () throws -> ToolCallErrorResponse in
            let response = try await postJSON(
                url: base.appendingPathComponent("mcp/test-instance"),
                bearerToken: accessToken,
                headers: ["MCP-Protocol-Version": "2025-11-25"],
                body: [
                    "jsonrpc": "2.0",
                    "id": "call",
                    "method": "tools/call",
                    "params": [
                        "name": "test.remctl.run",
                        "arguments": [
                            "args": ["add", "Test", "-l", "Work"]
                        ]
                    ]
                ]
            )
            let error = response.json["error"] as? [String: Any]
            return ToolCallErrorResponse(
                statusCode: response.statusCode,
                errorCode: error?["code"] as? Int
            )
        }

        let approval = try await waitForPendingToolApproval(in: toolApprovals)
        XCTAssertEqual(approval.toolID, "test.remctl.run")
        XCTAssertTrue(approval.argumentsPreview.contains("args=add Test -l Work"))
        XCTAssertTrue(toolApprovals.deny(requestID: approval.id))

        let deniedCall = try await callTask.value
        XCTAssertEqual(deniedCall.statusCode, 200)
        XCTAssertEqual(deniedCall.errorCode, -32004)
    }
}

private struct FakeToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolID: toolID,
            toolName: "Echo",
            exitCode: 0,
            stdout: "echo:\(parameters["value"]?.stringValue ?? "")",
            stderr: "",
            duration: 0.01,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct ToolCallErrorResponse: Sendable {
    let statusCode: Int
    let errorCode: Int?
}

private func authorizedAccessToken(
    base: URL,
    coordinator: OAuthCoordinator,
    server: LocalMCPServer
) async throws -> String {
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
    var request = URLRequest(url: url)
    for (key, value) in headers {
        request.setValue(value, forHTTPHeaderField: key)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let http = try XCTUnwrap(response as? HTTPURLResponse)
    return (http.statusCode, data)
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
) async throws -> (statusCode: Int, json: [String: Any]) {
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
    return (http.statusCode, (try? decodeJSON(data)) ?? [:])
}

private func postForm(
    url: URL,
    form: [String: String]
) async throws -> (statusCode: Int, json: [String: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
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
