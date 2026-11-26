import Foundation
import Testing
@testable import MacRemote

struct MCPHTTPResponseBodyTests {
    /// Servers built on the common Python and Node SDKs frame events with CRLF.
    @Test func readsServerSentEventsWithEitherLineEnding() {
        let message = #"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#
        for body in [
            "event: message\ndata: \(message)\n\n",
            "event: message\r\ndata: \(message)\r\n\r\n",
            message
        ] {
            let parsed = MCPHTTPResponseBody.jsonRPCMessage(from: Data(body.utf8))
            #expect((parsed?["result"] as? [String: Any])?["ok"] as? Bool == true)
        }
        #expect(MCPHTTPResponseBody.jsonRPCMessage(from: Data("not json".utf8)) == nil)
    }
}

@Suite(.serialized)
struct MCPHTTPBridgeClientTests {
    @Test func callsStreamableHTTPServerWithSessionHeadersAndJSONArguments() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
            .legacyDiscoverFallback,
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": "session-1"
                ],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"mock","version":"1.0.0"},"capabilities":{}}}"#
            ),
            MCPBridgeMockResponse(statusCode: 202, headers: [:], body: ""),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: """
                event: message
                data: {"jsonrpc":"2.0","id":"call","result":{"content":[{"type":"text","text":"ok"}],"structuredContent":{"ok":true}}}

                """
            )
        ])

        let tool = ToolDefinition(
            id: "mcp.mock.echo",
            name: "Mock Echo",
            summary: "Echo through a local MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "mock",
                serverURL: "http://local-mcp.test/mcp",
                toolName: "echo",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "payload": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "query": .object([
                                    "type": .string("string"),
                                    "x-mcp-header": .string("Query")
                                ])
                            ])
                        ])
                    ])
                ]),
                headers: [MCPBridgeHeader(name: "Authorization", value: "Bearer test-token")]
            )
        )

        let client = MCPHTTPBridgeClient(urlSession: session)
        let outcome = try await client.call(tool: tool, parameters: [
            "payload": .json(.object([
                "query": .string("clip"),
                "count": .number(2)
            ]))
        ])

        #expect(outcome.succeeded)
        #expect(outcome.stdout == #"{"ok":true}"#)
        #expect(outcome.upstreamMCPResult?.content == [
            .object(["type": .string("text"), "text": .string("ok")])
        ])

        let requests = MCPBridgeURLProtocolMock.requests()
        #expect(requests.map { $0.method } == ["server/discover", "initialize", "notifications/initialized", "tools/call"])
        #expect(requests[0].headers["Authorization"] == "Bearer test-token")
        #expect(requests[0].headers["MCP-Protocol-Version"] == "2026-07-28")
        #expect(requests[0].headers["Mcp-Method"] == "server/discover")
        #expect(requests[1].headers["Mcp-Session-Id"] == nil)
        let initializeParams = try #require(requests[1].body["params"] as? [String: Any])
        let clientInfo = try #require(initializeParams["clientInfo"] as? [String: Any])
        #expect(clientInfo["name"] as? String == "MacRemote")
        #expect(clientInfo["version"] as? String == "1.0")
        #expect(requests[2].headers["Mcp-Session-Id"] == "session-1")
        #expect(requests[3].headers["Mcp-Session-Id"] == "session-1")
        #expect(requests[3].headers["MCP-Protocol-Version"] == "2025-06-18")
        #expect(requests[3].headers.keys.contains { $0.lowercased().hasPrefix("mcp-param-") } == false)

        let params = try #require(requests[3].body["params"] as? [String: Any])
        #expect(params["name"] as? String == "echo")
        let arguments = try #require(params["arguments"] as? [String: Any])
        let payload = try #require(arguments["payload"] as? [String: Any])
        #expect(payload["query"] as? String == "clip")
        #expect(payload["count"] as? Int == 2)
    }

    @Test func unwrapsSoleTextAndMapsUpstreamToolError() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
            .legacyDiscoverFallback,
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"mock","version":"1.0.0"},"capabilities":{}}}"#
            ),
            MCPBridgeMockResponse(statusCode: 202, headers: [:], body: ""),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"call","result":{"content":[{"type":"text","text":"upstream rejected the request"}],"isError":true}}"#
            )
        ])

        let tool = ToolDefinition(
            id: "mcp_mock_fail",
            name: "Mock Failure",
            summary: "Return an upstream tool error.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "mock",
                serverURL: "http://local-mcp.test/mcp",
                toolName: "fail"
            )
        )

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: tool,
            parameters: [:]
        )

        #expect(!outcome.succeeded)
        #expect(outcome.exitCode == 1)
        #expect(outcome.stdout == "upstream rejected the request")
        #expect(outcome.stderr.isEmpty)
        #expect(outcome.upstreamMCPResult == nil)
    }

    @Test func dropsOversizedPreservationContextAtomicallyAtToolOutputLimit() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let largeFallback = String(repeating: "rich upstream fallback ", count: 100)
        let callBody = try #require(String(data: JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "call",
            "result": [
                "content": [[
                    "type": "text",
                    "text": largeFallback,
                    "annotations": ["audience": ["assistant"]]
                ]],
                "structuredContent": ["ok": true]
            ]
        ]), encoding: .utf8))
        MCPBridgeURLProtocolMock.install([
            .legacyDiscoverFallback,
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"mock","version":"1.0.0"},"capabilities":{}}}"#
            ),
            MCPBridgeMockResponse(statusCode: 202, headers: [:], body: ""),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: callBody
            )
        ])

        let tool = ToolDefinition(
            id: "mcp_mock_capped",
            name: "Mock Capped",
            summary: "Exercise the bridge output cap.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "mock",
                serverURL: "http://local-mcp.test/mcp",
                toolName: "capped"
            )
        )

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: tool,
            parameters: [:]
        )

        #expect(outcome.succeeded)
        #expect(outcome.stdout == #"{"ok":true}"#)
        #expect(outcome.truncatedStdout)
        #expect(outcome.upstreamMCPResult == nil)
        #expect(outcome.stderr.contains("Normalized stdout is complete"))
        #expect(outcome.stderr.contains("omitted atomically"))
        #expect(outcome.stderr.contains("configured output limit"))
    }

    @Test func stdoutOnlyTruncationDoesNotClaimPreservationContextWasDropped() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let longText = String(repeating: "plain-output-", count: 200)
        let callBody = try #require(String(data: JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "call",
            "result": [
                "content": [["type": "text", "text": longText]],
                "isError": false
            ]
        ]), encoding: .utf8))
        MCPBridgeURLProtocolMock.install([
            .legacyDiscoverFallback,
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"mock","version":"1.0.0"},"capabilities":{}}}"#
            ),
            MCPBridgeMockResponse(statusCode: 202, headers: [:], body: ""),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: callBody
            )
        ])

        let tool = ToolDefinition(
            id: "mcp_mock_stdout_cap",
            name: "Mock Stdout Cap",
            summary: "Exercise stdout-only truncation.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "mock",
                serverURL: "http://local-mcp.test/mcp",
                toolName: "stdout-cap"
            )
        )

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: tool,
            parameters: [:]
        )

        #expect(outcome.succeeded)
        #expect(outcome.truncatedStdout)
        #expect(outcome.stdout.utf8.count <= tool.outputByteLimit)
        #expect(outcome.upstreamMCPResult == nil)
        #expect(outcome.stderr.isEmpty)
    }

    @Test func usesModernDiscoverAndPerRequestMetadataWithoutInitialize() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"modern","version":"2.0.0"}}}}"#
            ),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"call","result":{"resultType":"complete","content":[{"type":"text","text":"modern"}],"structuredContent":{"mode":"modern"},"isError":false}}"#
            )
        ])

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "echo"),
            parameters: ["query": .string("hello")]
        )

        #expect(outcome.succeeded)
        #expect(outcome.stdout == #"{"mode":"modern"}"#)
        let requests = MCPBridgeURLProtocolMock.requests()
        #expect(requests.map(\.method) == ["server/discover", "tools/call"])
        #expect(requests.allSatisfy { $0.headers["MCP-Protocol-Version"] == "2026-07-28" })
        #expect(requests[1].headers["Mcp-Method"] == "tools/call")
        #expect(requests[1].headers["Mcp-Name"] == "echo")
        let params = try #require(requests[1].body["params"] as? [String: Any])
        let meta = try #require(params["_meta"] as? [String: Any])
        #expect(meta["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
        #expect(meta["io.modelcontextprotocol/clientInfo"] as? [String: Any] != nil)
        #expect(meta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any] != nil)
    }

    @Test func modernToolCallMirrorsTypedNestedAndEncodedParameters() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"ttlMs":0,"cacheScope":"private"}}"#
            ),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"call","result":{"resultType":"complete","content":[{"type":"text","text":"ok"}],"isError":false}}"#
            )
        ])
        let schema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "region": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Region")
                ]),
                "options": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "zero": .object([
                            "type": .string("integer"),
                            "x-mcp-header": .string("Zero")
                        ]),
                        "one": .object([
                            "type": .string("integer"),
                            "x-mcp-header": .string("One")
                        ]),
                        "disabled": .object([
                            "type": .string("boolean"),
                            "x-mcp-header": .string("Disabled")
                        ]),
                        "enabled": .object([
                            "type": .string("boolean"),
                            "x-mcp-header": .string("Enabled")
                        ])
                    ])
                ]),
                "greeting": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Greeting")
                ]),
                "literal": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Literal")
                ]),
                "empty": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Empty")
                ]),
                "optional": .object([
                    "type": .string("string"),
                    "x-mcp-header": .string("Optional")
                ])
            ])
        ])

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "execute", inputSchema: schema),
            parameters: [
                "region": .string("us-west1"),
                "options": .json(.object([
                    "zero": .number(0),
                    "one": .number(1),
                    "disabled": .bool(false),
                    "enabled": .bool(true)
                ])),
                "greeting": .string("Hello, 世界"),
                "literal": .string("=?base64?literal?="),
                "empty": .string("")
            ]
        )

        #expect(outcome.succeeded)
        let request = try #require(
            MCPBridgeURLProtocolMock.requests().first { $0.method == "tools/call" }
        )
        #expect(request.headers["Mcp-Param-Region"] == "us-west1")
        #expect(request.headers["Mcp-Param-Zero"] == "0")
        #expect(request.headers["Mcp-Param-One"] == "1")
        #expect(request.headers["Mcp-Param-Disabled"] == "false")
        #expect(request.headers["Mcp-Param-Enabled"] == "true")
        #expect(
            request.headers["Mcp-Param-Greeting"] ==
                "=?base64?\(Data("Hello, 世界".utf8).base64EncodedString())?="
        )
        #expect(
            request.headers["Mcp-Param-Literal"] ==
                "=?base64?\(Data("=?base64?literal?=".utf8).base64EncodedString())?="
        )
        #expect(request.headers["Mcp-Param-Empty"] == "")
        #expect(request.headers["Mcp-Param-Optional"] == nil)
    }

    @Test func unsupportedVersionDiscoverErrorWithNoSharedVersionDoesNotDowngradeToInitialize()
        async throws
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        // 2026-09-15 is a future modern-era version, not one our legacy
        // initialize implements, so there is nothing to renegotiate down to.
        MCPBridgeURLProtocolMock.install([
            MCPBridgeMockResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","error":{"code":-32022,"message":"Unsupported protocol version","data":{"supported":["2026-09-15"],"requested":"2026-07-28"}}}"#
            )
        ])

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "echo"),
            parameters: [:]
        )

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("-32022"))
        #expect(outcome.stderr.contains("2026-09-15"))
        #expect(MCPBridgeURLProtocolMock.requests().map(\.method) == ["server/discover"])
    }

    @Test func reservedModernDiscoverErrorsDoNotDowngradeToInitialize() async throws {
        for code in [-32020, -32021] {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MCPBridgeURLProtocolMock.self]
            let session = URLSession(configuration: config)
            MCPBridgeURLProtocolMock.install([
                MCPBridgeMockResponse(
                    statusCode: 400,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"jsonrpc":"2.0","id":"discover","error":{"code":\#(code),"message":"Reserved modern rejection"}}"#
                )
            ])

            let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
                tool: Self.tool(name: "echo"),
                parameters: [:]
            )

            #expect(!outcome.succeeded)
            #expect(outcome.stderr.contains("\(code)"))
            #expect(
                MCPBridgeURLProtocolMock.requests().map(\.method) == ["server/discover"],
                "\(code) must block the legacy initialize fallback."
            )
        }
    }

    @Test func unsupportedVersionDiscoverErrorNamingALegacyVersionFallsBackToInitialize()
        async throws
    {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
            MCPBridgeMockResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","error":{"code":-32022,"message":"Unsupported protocol version.","data":{"supported":["2025-03-26","2025-11-25","2025-06-18"],"requested":"2026-07-28"}}}"#
            ),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": "renegotiated-session"
                ],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"legacy","version":"1.0.0"},"capabilities":{}}}"#
            ),
            MCPBridgeMockResponse(
                statusCode: 202,
                headers: [:],
                body: ""
            ),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"call","result":{"content":[{"type":"text","text":"ok"}]}}"#
            )
        ])

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "echo"),
            parameters: [:]
        )

        #expect(outcome.succeeded)
        let requests = MCPBridgeURLProtocolMock.requests()
        #expect(requests.map(\.method) == [
            "server/discover", "initialize", "notifications/initialized", "tools/call"
        ])
        let initialize = try #require(requests.first { $0.method == "initialize" })
        let initializeParams = try #require(initialize.body["params"] as? [String: Any])
        #expect(
            initializeParams["protocolVersion"] as? String == "2025-11-25",
            "The bridge must request the newest mutually supported version."
        )
        #expect(initialize.headers["MCP-Protocol-Version"] == "2025-11-25")
        let call = try #require(requests.first { $0.method == "tools/call" })
        #expect(
            (call.body["params"] as? [String: Any])?["_meta"] == nil,
            "The renegotiated session must speak legacy."
        )
    }

    @Test func toolCallUsesToolTimeoutWhileDiscoveryRemainsBounded() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{}}}"#
            ),
            MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"call","result":{"resultType":"complete","content":[{"type":"text","text":"ok"}]}}"#
            )
        ])

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "background", timeoutSeconds: 300),
            parameters: [:]
        )

        #expect(outcome.succeeded)
        let requests = MCPBridgeURLProtocolMock.requests()
        #expect(requests[0].timeoutInterval == 60)
        #expect(requests[1].timeoutInterval == 300)
    }

    /// A request's own timeout only limits the gap between bytes. A server
    /// that keeps sending a little, during the first probe or during the
    /// call itself, must still be cut off at the tool's timeout.
    @Test(arguments: ["server/discover", "tools/call"])
    func aResponseThatNeverFinishesEndsAtTheToolTimeout(stalledMethod: String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install { request in
            if request.method == stalledMethod {
                return MCPBridgeMockResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "text/event-stream"],
                    body: ": started\n\n",
                    keepsSendingForSeconds: 6
                )
            }
            return MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{}}}"#
            )
        }

        let started = Date()
        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "echo", timeoutSeconds: 1),
            parameters: [:]
        )

        #expect(outcome.timedOut)
        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("did not finish answering within the 1-second limit"))
        #expect(Date().timeIntervalSince(started) < 3)
        // The connection is dropped, not left to keep receiving.
        for _ in 0..<100 where MCPBridgeURLProtocolMock.interruptedStreamCount() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(MCPBridgeURLProtocolMock.interruptedStreamCount() == 1)
    }

    @Test func aResponseOverTheSizeLimitIsRefusedNotBuffered() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install { request in
            guard request.method == "tools/call" else {
                return MCPBridgeMockResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{}}}"#
                )
            }
            let text = String(repeating: "x", count: 4096)
            return MCPBridgeMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"call","result":{"resultType":"complete","content":[{"type":"text","text":"\#(text)"}]}}"#
            )
        }

        let outcome = try await MCPHTTPBridgeClient(urlSession: session, maximumResponseBytes: 1024).call(
            tool: Self.tool(name: "echo"),
            parameters: [:]
        )

        #expect(!outcome.succeeded)
        #expect(!outcome.timedOut)
        #expect(outcome.stdout.isEmpty)
        #expect(outcome.stderr.contains("sent more than 1 KB in one response"))
    }

    @Test func modernInputRequiredIsAnsweredAndTheCallSentAgain() async throws {
        let session = Self.mockSession()
        MCPBridgeURLProtocolMock.install { request in
            switch request.method {
            case "server/discover":
                return .modernDiscover
            case "tools/call" where (request.body["params"] as? [String: Any])?["requestState"] == nil:
                return .json(#"{"jsonrpc":"2.0","id":"call","result":{"resultType":"input_required","inputRequests":{"color":{"method":"elicitation/create","params":{"message":"Pick a color.","requestedSchema":{"type":"object","properties":{"color":{"type":"string"}}}}}},"requestState":"opaque/state=1"}}"#)
            default:
                return .json(#"{"jsonrpc":"2.0","id":"call","result":{"resultType":"complete","content":[{"type":"text","text":"done"}],"structuredContent":{"done":true}}}"#)
            }
        }
        let relay = RecordingRelay(modes: [.form])

        let outcome = try await MCPElicitationRelay.$current.withValue(relay) {
            try await MCPHTTPBridgeClient(urlSession: session).call(tool: Self.tool(name: "echo"), parameters: [:])
        }

        #expect(outcome.succeeded, "\(outcome.stderr)")
        #expect(outcome.stdout == #"{"done":true}"#)
        #expect(relay.asked.first?["color"]?.objectValue?["params"]?.objectValue?["message"] == .string("[mock] Pick a color."))
        let calls = MCPBridgeURLProtocolMock.requests().filter { $0.method == "tools/call" }
        #expect(calls.count == 2)
        let first = try #require(calls.first?.body["params"] as? [String: Any])
        let capabilities = ((first["_meta"] as? [String: Any])?["io.modelcontextprotocol/clientCapabilities"] as? [String: Any]) ?? [:]
        #expect((capabilities["extensions"] as? [String: Any])?["io.modelcontextprotocol/tasks"] != nil)
        #expect((capabilities["elicitation"] as? [String: Any]).map { Set($0.keys) } == ["form"])
        let retry = try #require(calls.last?.body["params"] as? [String: Any])
        #expect(retry["requestState"] as? String == "opaque/state=1")
        #expect(retry["name"] as? String == "echo")
        let answer = (retry["inputResponses"] as? [String: Any])?["color"] as? [String: Any]
        #expect(answer?["action"] as? String == "accept")
        #expect((answer?["content"] as? [String: Any])?["color"] as? String == "blue")
        #expect(calls[0].body["id"] as? String != calls[1].body["id"] as? String)
    }

    @Test func modernUpstreamTaskIsPolledToItsResult() async throws {
        let session = Self.mockSession()
        let polls = LockedCounter()
        MCPBridgeURLProtocolMock.install { request in
            switch request.method {
            case "server/discover":
                return .modernDiscover
            case "tools/call":
                return .json(#"{"jsonrpc":"2.0","id":"call","result":{"resultType":"task","taskId":"up-task-1","status":"working","pollIntervalMs":250}}"#)
            case "tasks/get" where polls.incrementCall() < 2:
                return .json(#"{"jsonrpc":"2.0","id":"get","result":{"resultType":"complete","taskId":"up-task-1","status":"working","pollIntervalMs":250}}"#)
            default:
                return .json(#"{"jsonrpc":"2.0","id":"get","result":{"resultType":"complete","taskId":"up-task-1","status":"completed","result":{"content":[{"type":"text","text":"done"}],"structuredContent":{"done":true}}}}"#)
            }
        }

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "echo"),
            parameters: [:]
        )

        #expect(outcome.succeeded, "\(outcome.stderr)")
        #expect(outcome.stdout == #"{"done":true}"#)
        let polled = MCPBridgeURLProtocolMock.requests().filter { $0.method == "tasks/get" }
        #expect(polled.count == 2)
        #expect(polled.first?.headers["Mcp-Name"] == "up-task-1")
        #expect((polled.first?.body["params"] as? [String: Any])?["taskId"] as? String == "up-task-1")
    }

    /// A task's first answer is only a handle, whatever its status says: the
    /// task, its result or error included, is read with `tasks/get` (SPEC D82).
    @Test(arguments: ["completed", "failed", "cancelled"])
    func anUpstreamTaskIsReadWithTasksGetWhateverItsFirstStatus(status: String) async throws {
        let session = Self.mockSession()
        let final = [
            "completed": #""status":"completed","result":{"content":[{"type":"text","text":"done"}],"structuredContent":{"done":true}}"#,
            "failed": #""status":"failed","statusMessage":"Tool execution failed","error":{"code":-32603,"message":"the upstream broke"}"#,
            "cancelled": #""status":"cancelled","statusMessage":"stopped upstream""#
        ][status] ?? ""
        MCPBridgeURLProtocolMock.install { request in
            switch request.method {
            case "server/discover":
                return .modernDiscover
            case "tools/call":
                return .json(#"{"jsonrpc":"2.0","id":"call","result":{"resultType":"task","taskId":"up-task-3","status":"\#(status)","pollIntervalMs":250}}"#)
            default:
                return .json(#"{"jsonrpc":"2.0","id":"get","result":{"resultType":"complete","taskId":"up-task-3",\#(final)}}"#)
            }
        }

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(tool: Self.tool(name: "echo"), parameters: [:])

        switch status {
        case "completed":
            #expect(outcome.succeeded, "\(outcome.stderr)")
            #expect(outcome.stdout == #"{"done":true}"#)
        case "failed":
            #expect(outcome.stderr.contains("the upstream broke"), "\(outcome.stderr)")
        default:
            #expect(outcome.stderr.contains("stopped upstream"), "\(outcome.stderr)")
        }
        let methods = MCPBridgeURLProtocolMock.requests().map(\.method)
        #expect(methods.filter { $0 == "tasks/get" }.count == 1)
        #expect(!methods.contains("tasks/cancel"))
    }

    @Test func cancellingTheCallCancelsTheUpstreamTask() async throws {
        let session = Self.mockSession()
        MCPBridgeURLProtocolMock.install { request in
            switch request.method {
            case "server/discover":
                return .modernDiscover
            case "tools/call":
                return .json(#"{"jsonrpc":"2.0","id":"call","result":{"resultType":"task","taskId":"up-task-2","status":"working","pollIntervalMs":250}}"#)
            case "tasks/cancel":
                return .json(#"{"jsonrpc":"2.0","id":"cancel","result":{"resultType":"complete"}}"#)
            default:
                return .json(#"{"jsonrpc":"2.0","id":"get","result":{"resultType":"complete","taskId":"up-task-2","status":"working","pollIntervalMs":250}}"#)
            }
        }
        func sent(_ method: String) -> MCPBridgeCapturedRequest? {
            MCPBridgeURLProtocolMock.requests().first { $0.method == method }
        }

        let call = Task {
            try await MCPHTTPBridgeClient(urlSession: session).call(tool: Self.tool(name: "echo"), parameters: [:])
        }
        for _ in 0..<500 where sent("tasks/get") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        call.cancel()
        _ = try? await call.value
        for _ in 0..<200 where sent("tasks/cancel") == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        let cancel = try #require(sent("tasks/cancel"))
        #expect((cancel.body["params"] as? [String: Any])?["taskId"] as? String == "up-task-2")
        #expect(cancel.headers["Mcp-Name"] == "up-task-2")
    }

    @Test func anUpstreamRequestOtherThanElicitationEndsTheCall() async throws {
        let session = Self.mockSession()
        MCPBridgeURLProtocolMock.install { request in
            request.method == "server/discover"
                ? .modernDiscover
                : .json(#"{"jsonrpc":"2.0","id":"call","result":{"resultType":"input_required","inputRequests":{"llm":{"method":"sampling/createMessage","params":{"messages":[],"maxTokens":10}}},"requestState":"s"}}"#)
        }
        let relay = RecordingRelay(modes: [.form, .url])

        let outcome = try await MCPElicitationRelay.$current.withValue(relay) {
            try await MCPHTTPBridgeClient(urlSession: session).call(tool: Self.tool(name: "echo"), parameters: [:])
        }

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("sampling/createMessage"))
        #expect(relay.asked.isEmpty)
        #expect(MCPBridgeURLProtocolMock.requests().filter { $0.method == "tools/call" }.count == 1)
    }

    @Test func expiredLegacySessionReinitializesAfterModernFallback() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        let state = LockedCounter()
        MCPBridgeURLProtocolMock.install { request in
            switch request.method {
            case "server/discover":
                return .legacyDiscoverFallback
            case "initialize":
                let index = state.incrementInitialize()
                return MCPBridgeMockResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "session-\(index)"
                    ],
                    body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"legacy","version":"1"},"capabilities":{}}}"#
                )
            case "notifications/initialized":
                return MCPBridgeMockResponse(statusCode: 202, headers: [:], body: "")
            case "tools/call":
                if state.incrementCall() == 1 {
                    return MCPBridgeMockResponse(statusCode: 404, headers: [:], body: "expired")
                }
                return MCPBridgeMockResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"jsonrpc":"2.0","id":"call","result":{"content":[{"type":"text","text":"recovered"}]}}"#
                )
            default:
                return MCPBridgeMockResponse(statusCode: 500, headers: [:], body: "unexpected")
            }
        }

        let outcome = try await MCPHTTPBridgeClient(urlSession: session).call(
            tool: Self.tool(name: "echo"),
            parameters: [:]
        )

        #expect(outcome.succeeded)
        #expect(outcome.stdout == "recovered")
        let requests = MCPBridgeURLProtocolMock.requests()
        #expect(requests.map(\.method) == [
            "server/discover", "initialize", "notifications/initialized", "tools/call",
            "server/discover", "initialize", "notifications/initialized", "tools/call"
        ])
        #expect(requests[3].headers["Mcp-Session-Id"] == "session-1")
        #expect(requests[7].headers["Mcp-Session-Id"] == "session-2")
    }

    @Test func legacySessionCacheIsIsolatedByResolvedAuthorizationValue() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install { request in
            let authorization = request.headers["Authorization"] ?? ""
            let suffix = authorization.hasSuffix("token-a") ? "a" : "b"
            switch request.method {
            case "server/discover":
                return .legacyDiscoverFallback
            case "initialize":
                return MCPBridgeMockResponse(
                    statusCode: 200,
                    headers: [
                        "Content-Type": "application/json",
                        "Mcp-Session-Id": "session-\(suffix)"
                    ],
                    body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"legacy","version":"1"},"capabilities":{}}}"#
                )
            case "notifications/initialized":
                return MCPBridgeMockResponse(statusCode: 202, headers: [:], body: "")
            case "tools/call":
                return MCPBridgeMockResponse(
                    statusCode: 200,
                    headers: ["Content-Type": "application/json"],
                    body: #"{"jsonrpc":"2.0","id":"call","result":{"content":[{"type":"text","text":"ok"}]}}"#
                )
            default:
                return MCPBridgeMockResponse(statusCode: 500, headers: [:], body: "unexpected")
            }
        }

        let client = MCPHTTPBridgeClient(urlSession: session)
        let first = try await client.call(
            tool: Self.tool(name: "echo", authorization: "Bearer token-a"),
            parameters: [:]
        )
        let second = try await client.call(
            tool: Self.tool(name: "echo", authorization: "Bearer token-b"),
            parameters: [:]
        )

        #expect(first.succeeded)
        #expect(second.succeeded)
        let calls = MCPBridgeURLProtocolMock.requests().filter { $0.method == "tools/call" }
        #expect(calls.count == 2)
        #expect(calls[0].headers["Mcp-Session-Id"] == "session-a")
        #expect(calls[1].headers["Mcp-Session-Id"] == "session-b")
        #expect(MCPBridgeURLProtocolMock.requests().filter { $0.method == "initialize" }.count == 2)
    }

    private static func mockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        return URLSession(configuration: config)
    }

    private static func tool(
        name: String,
        authorization: String? = nil,
        timeoutSeconds: TimeInterval = 5,
        inputSchema: JSONValue? = nil
    ) -> ToolDefinition {
        ToolDefinition(
            id: "mcp_mock_\(name)",
            name: "Mock \(name)",
            summary: "Mock MCP bridge tool.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: timeoutSeconds,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "mock",
                serverURL: "http://local-mcp.test/mcp",
                toolName: name,
                inputSchema: inputSchema,
                headers: authorization.map { [MCPBridgeHeader(name: "Authorization", value: $0)] } ?? []
            )
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var initializeCount = 0
    private var callCount = 0

    func incrementInitialize() -> Int {
        lock.withLock {
            initializeCount += 1
            return initializeCount
        }
    }

    func incrementCall() -> Int {
        lock.withLock {
            callCount += 1
            return callCount
        }
    }
}

/// Stands in for the app a call came from: records each round of questions
/// and accepts every one with `{"color": "blue"}`.
private final class RecordingRelay: MCPElicitationAnswering, @unchecked Sendable {
    let modes: Set<MCPElicitationMode>
    private let lock = NSLock()
    private var rounds = [[String: JSONValue]]()

    init(modes: Set<MCPElicitationMode>) {
        self.modes = modes
    }

    var asked: [[String: JSONValue]] {
        lock.withLock { rounds }
    }

    func answers(to questions: [String: JSONValue]) async -> [String: JSONValue]? {
        lock.withLock { rounds.append(questions) }
        return questions.mapValues { _ in
            .object(["action": .string("accept"), "content": .object(["color": .string("blue")])])
        }
    }
}

private struct MCPBridgeCapturedRequest: @unchecked Sendable {
    let method: String
    let headers: [String: String]
    let body: [String: Any]
    let timeoutInterval: TimeInterval
}

private struct MCPBridgeMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    /// After `body`, keep sending a few bytes every 20 ms for this long before
    /// ending the response: a server that streams without finishing.
    let keepsSendingForSeconds: TimeInterval

    init(statusCode: Int, headers: [String: String], body: String, keepsSendingForSeconds: TimeInterval = 0) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(body.utf8)
        self.keepsSendingForSeconds = keepsSendingForSeconds
    }

    static var modernDiscover: MCPBridgeMockResponse {
        .json(#"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{}}}"#)
    }

    static func json(_ body: String) -> MCPBridgeMockResponse {
        MCPBridgeMockResponse(statusCode: 200, headers: ["Content-Type": "application/json"], body: body)
    }

    static var legacyDiscoverFallback: MCPBridgeMockResponse {
        MCPBridgeMockResponse(
            statusCode: 404,
            headers: ["Content-Type": "application/json"],
            body: #"{"jsonrpc":"2.0","id":"discover","error":{"code":-32601,"message":"Method not found"}}"#
        )
    }
}

private final class MCPBridgeURLProtocolMock: URLProtocol, @unchecked Sendable {
    typealias Responder = (MCPBridgeCapturedRequest) -> MCPBridgeMockResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [MCPBridgeMockResponse] = []
    nonisolated(unsafe) private static var capturedRequests: [MCPBridgeCapturedRequest] = []
    nonisolated(unsafe) private static var responder: Responder?
    nonisolated(unsafe) private static var interruptedStreams = 0
    private static let streamQueue = DispatchQueue(label: "MCPBridgeURLProtocolMock.stream")
    /// Set while this response is still being sent in pieces.
    private var stream: DispatchSourceTimer?

    static func install(_ newResponses: [MCPBridgeMockResponse]) {
        lock.lock()
        responses = newResponses
        capturedRequests = []
        responder = nil
        interruptedStreams = 0
        lock.unlock()
    }

    static func install(responder newResponder: @escaping Responder) {
        lock.lock()
        responses = []
        capturedRequests = []
        responder = newResponder
        interruptedStreams = 0
        lock.unlock()
    }

    /// How many responses were cut off by the client while still streaming.
    static func interruptedStreamCount() -> Int {
        lock.withLock { interruptedStreams }
    }

    static func requests() -> [MCPBridgeCapturedRequest] {
        lock.lock()
        let snapshot = capturedRequests
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "local-mcp.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let method = json["method"] as? String ?? ""
        let headers = request.allHTTPHeaderFields ?? [:]

        let captured = MCPBridgeCapturedRequest(
            method: method,
            headers: headers,
            body: json,
            timeoutInterval: request.timeoutInterval
        )
        Self.lock.lock()
        Self.capturedRequests.append(captured)
        let responder = Self.responder
        let queuedResponse = Self.responses.isEmpty ? nil : Self.responses.removeFirst()
        Self.lock.unlock()
        let response = responder?(captured)
            ?? queuedResponse
            ?? MCPBridgeMockResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"unexpected request"}"#
            )

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        guard response.keepsSendingForSeconds > 0 else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        let ends = Date(timeIntervalSinceNow: response.keepsSendingForSeconds)
        let timer = DispatchSource.makeTimerSource(queue: Self.streamQueue)
        timer.schedule(deadline: .now() + .milliseconds(20), repeating: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, self.stream != nil else { return }
            if Date() < ends {
                self.client?.urlProtocol(self, didLoad: Data(": still here\n\n".utf8))
            } else {
                self.stream?.cancel()
                self.stream = nil
                self.client?.urlProtocolDidFinishLoading(self)
            }
        }
        Self.streamQueue.sync { stream = timer }
        timer.resume()
    }

    override func stopLoading() {
        Self.streamQueue.sync {
            guard let stream else { return }
            stream.cancel()
            self.stream = nil
            Self.lock.withLock { Self.interruptedStreams += 1 }
        }
    }

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
}
