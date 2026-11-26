import Foundation
import Testing
@testable import MacRemote

@Suite(.serialized)
struct LocalMCPScannerTests {
    @Test func scansClaudeExtensionProbesToolsAndBuildsBridgeDefinitions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let manifestURL = home
            .appendingPathComponent("Library/Application Support/Claude/Claude Extensions/local.mcpb.paste/manifest.json")
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "name": "paste",
          "display_name": "Paste",
          "server": {
            "mcp_config": {
              "env": {
                "MCP_URL": "http://127.0.0.1:39725/mcp",
                "MCP_TOKEN": "secret-token"
              }
            }
          }
        }
        """.utf8).write(to: manifestURL)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMCPScannerURLProtocolMock.self]
        let session = URLSession(configuration: config)
        LocalMCPScannerURLProtocolMock.install([
            LocalMCPScannerMockResponse(
                statusCode: 404,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","error":{"code":-32601,"message":"Method not found"}}"#
            ),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": "session-1"
                ],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"paste","title":"Paste","version":"1.0.0","description":"Clipboard history."},"capabilities":{}}}"#
            ),
            LocalMCPScannerMockResponse(statusCode: 202, headers: [:], body: ""),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: """
                event: message
                data: {"jsonrpc":"2.0","id":"tools","result":{"tools":[{"name":"search","title":"Search","description":"Search saved clips.","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}},"annotations":{"readOnlyHint":true}},{"name":"create_item","title":"Create Item","description":"Create a clip.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}}},"annotations":{}}]}}

                """
            )
        ])

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            urlSession: session,
            executablePath: { _ in nil }
        )
        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let candidate = try #require(candidates.first)

        #expect(candidate.id == "claude_extension.paste")
        #expect(candidate.displayName == "Paste")
        #expect(candidate.bridgeable)
        #expect(candidate.probe?.serverInfo.title == "Paste")
        #expect(candidate.probe?.tools.map(\.name) == ["search", "create_item"])

        let requests = LocalMCPScannerURLProtocolMock.requests()
        #expect(requests.map(\.method) == ["server/discover", "initialize", "notifications/initialized", "tools/list"])
        #expect(requests[0].headers["Authorization"] == "Bearer secret-token")
        #expect(requests[0].header("MCP-Protocol-Version") == "2026-07-28")
        #expect(requests[3].headers["Mcp-Session-Id"] == "session-1")

        let tools = try scanner.bridgeTools(for: candidate)
        #expect(tools.count == 2)
        #expect(tools.map(\.id) == ["paste_search", "paste_create_item"])
        #expect(tools[0].backend == .mcpHTTPBridge)
        #expect(tools[0].mcpBridge?.serverURL == "http://127.0.0.1:39725/mcp")
        #expect(tools[0].mcpBridge?.headers.first?.value == nil)
        #expect(tools[0].mcpBridge?.headers.first?.valueSource?.keyPath == ["server", "mcp_config", "env", "MCP_TOKEN"])
        #expect(tools[0].capability == .readOnly)
        #expect(tools[1].capability == .write)
    }

    @Test func probesModernHTTPServerWithoutLegacyInitialize() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMCPScannerURLProtocolMock.self]
        let session = URLSession(configuration: config)
        LocalMCPScannerURLProtocolMock.install([
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{},"_meta":{"io.modelcontextprotocol/serverInfo":{"name":"modern","title":"Modern Server","version":"2.0.0","description":"Current protocol."}}}}"#
            ),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: """
                {
                  "jsonrpc": "2.0",
                  "id": "tools",
                  "result": {
                    "resultType": "complete",
                    "ttlMs": 0,
                    "cacheScope": "private",
                    "tools": [
                      {
                        "name": "search",
                        "title": "Search",
                        "description": "Search.",
                        "inputSchema": {
                          "type": "object",
                          "properties": {
                            "filters": {
                              "type": "object",
                              "properties": {
                                "region": {
                                  "type": "string",
                                  "x-mcp-header": "Region"
                                }
                              }
                            }
                          }
                        },
                        "annotations": {"readOnlyHint": true}
                      },
                      {
                        "name": "complex_schema",
                        "inputSchema": {
                          "$schema": "https://json-schema.org/draft/2020-12/schema",
                          "type": "object",
                          "$defs": {
                            "node": {
                              "type": "object",
                              "properties": {
                                "name": {"type": "string"},
                                "child": {"$ref": "#/$defs/node"}
                              }
                            }
                          },
                          "properties": {
                            "node": {"$ref": "#/$defs/node"},
                            "remote": {"$ref": "https://schemas.example/value.json"}
                          },
                          "oneOf": [
                            {"required": ["node"]},
                            {"required": ["remote"]}
                          ],
                          "unevaluatedProperties": false
                        }
                      },
                      {
                        "name": "invalid_name",
                        "inputSchema": {
                          "type": "object",
                          "properties": {
                            "value": {"type": "string", "x-mcp-header": "Bad Name"}
                          }
                        }
                      },
                      {
                        "name": "invalid_number",
                        "inputSchema": {
                          "type": "object",
                          "properties": {
                            "value": {"type": "number", "x-mcp-header": "Value"}
                          }
                        }
                      },
                      {
                        "name": "invalid_duplicate",
                        "inputSchema": {
                          "type": "object",
                          "properties": {
                            "first": {"type": "string", "x-mcp-header": "Region"},
                            "second": {"type": "boolean", "x-mcp-header": "region"}
                          }
                        }
                      },
                      {
                        "name": "invalid_unreachable",
                        "inputSchema": {
                          "type": "object",
                          "$defs": {
                            "hidden": {"type": "string", "x-mcp-header": "Hidden"}
                          }
                        }
                      },
                      {
                        "name": "invalid_ref_header",
                        "inputSchema": {
                          "type": "object",
                          "$defs": {
                            "header": {
                              "type": "string",
                              "x-mcp-header": "Header"
                            }
                          },
                          "properties": {
                            "value": {"$ref": "#/$defs/header"}
                          }
                        }
                      },
                      {
                        "name": "invalid_composed_header",
                        "inputSchema": {
                          "type": "object",
                          "oneOf": [
                            {
                              "properties": {
                                "value": {
                                  "type": "string",
                                  "x-mcp-header": "Composed"
                                }
                              }
                            }
                          ]
                        }
                      }
                    ]
                  }
                }
                """
            )
        ])
        let scanner = LocalMCPScanner(
            homeDirectory: FileManager.default.temporaryDirectory,
            urlSession: session,
            executablePath: { _ in nil }
        )
        let candidate = LocalMCPServerCandidate(
            id: "test.modern",
            source: "test",
            sourcePath: "test",
            name: "modern",
            displayName: "Modern",
            transport: .http,
            url: "http://127.0.0.1:39725/mcp",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil
        )

        let result = try await scanner.probe(candidate: candidate)

        #expect(result.serverInfo.title == "Modern Server")
        #expect(result.tools.map(\.name) == ["search", "complex_schema"])
        var importedCandidate = candidate
        importedCandidate.probe = result
        let importedTools = try scanner.bridgeTools(for: importedCandidate)
        #expect(importedTools.map(\.mcpBridge?.toolName) == ["search", "complex_schema"])
        #expect(
            importedTools.first?.mcpBridge?.inputSchema?.objectValue?["properties"]?
                .objectValue?["filters"]?.objectValue?["properties"]?
                .objectValue?["region"]?.objectValue?["x-mcp-header"] == .string("Region")
        )
        let complexSchema = try #require(importedTools.last?.mcpBridge?.inputSchema?.objectValue)
        #expect(complexSchema["$schema"] == .string("https://json-schema.org/draft/2020-12/schema"))
        #expect(complexSchema["oneOf"]?.objectValue == nil)
        #expect(complexSchema["oneOf"] == .array([
            .object(["required": .array([.string("node")])]),
            .object(["required": .array([.string("remote")])])
        ]))
        #expect(
            complexSchema["$defs"]?.objectValue?["node"]?.objectValue?["properties"]?
                .objectValue?["child"]?.objectValue?["$ref"] == .string("#/$defs/node")
        )
        #expect(
            complexSchema["properties"]?.objectValue?["remote"]?.objectValue?["$ref"] ==
                .string("https://schemas.example/value.json")
        )
        let requests = LocalMCPScannerURLProtocolMock.requests()
        #expect(requests.map(\.method) == ["server/discover", "tools/list"])
        #expect(requests.allSatisfy { $0.headers["MCP-Protocol-Version"] == "2026-07-28" })
        let toolsParams = try #require(requests[1].body["params"] as? [String: Any])
        let toolsMeta = try #require(toolsParams["_meta"] as? [String: Any])
        #expect(toolsMeta["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
    }

    /// A request's own timeout is 10 seconds between bytes. The whole probe
    /// has a deadline too, so one server cannot keep a scan running.
    @Test func probeOfAServerThatNeverFinishesAnsweringEndsAtItsDeadline() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMCPScannerURLProtocolMock.self]
        let session = URLSession(configuration: config)
        LocalMCPScannerURLProtocolMock.install([
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: ": started\n\n",
                neverFinishes: true
            )
        ])
        let scanner = LocalMCPScanner(
            homeDirectory: FileManager.default.temporaryDirectory,
            urlSession: session,
            executablePath: { _ in nil }
        )
        let candidate = LocalMCPServerCandidate(
            id: "test.stalled",
            source: "test",
            sourcePath: "test",
            name: "stalled",
            displayName: "Stalled",
            transport: .http,
            url: "http://127.0.0.1:39725/mcp",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil
        )

        let started = Date()
        var failure: (any Error)?
        do {
            _ = try await scanner.probe(candidate: candidate, timeoutCapSeconds: 1)
        } catch {
            failure = error
        }

        #expect(failure?.localizedDescription == "The MCP server did not finish answering within the 1-second limit.")
        #expect(Date().timeIntervalSince(started) < 5)
    }

    /// Skills are optional (SPEC D84): a server whose skills read stalls
    /// still imports with its tools, and records no skills.
    @Test func aStalledSkillsReadKeepsTheProbesTools() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMCPScannerURLProtocolMock.self]
        let session = URLSession(configuration: config)
        LocalMCPScannerURLProtocolMock.install([
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","result":{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{},"resources":{},"extensions":{"io.modelcontextprotocol/skills":{}}}}}"#
            ),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"tools","result":{"resultType":"complete","ttlMs":0,"cacheScope":"private","tools":[{"name":"search","inputSchema":{"type":"object"}}]}}"#
            ),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream"],
                body: ": started\n\n",
                neverFinishes: true
            )
        ])
        let scanner = LocalMCPScanner(
            homeDirectory: FileManager.default.temporaryDirectory,
            urlSession: session,
            executablePath: { _ in nil }
        )
        let candidate = LocalMCPServerCandidate(
            id: "test.slow-skills",
            source: "test",
            sourcePath: "test",
            name: "slow-skills",
            displayName: "Slow Skills",
            transport: .http,
            url: "http://127.0.0.1:39725/mcp",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil
        )

        let started = Date()
        let result = try await scanner.probe(candidate: candidate, timeoutCapSeconds: 1)

        #expect(result.tools.map(\.name) == ["search"])
        #expect(result.skills.isEmpty)
        #expect(LocalMCPScannerURLProtocolMock.requests().map(\.method) == ["server/discover", "tools/list", "skills/list"])
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func probeRenegotiatesToTheNewestVersionAnUnsupportedVersionErrorNames() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LocalMCPScannerURLProtocolMock.self]
        let session = URLSession(configuration: config)
        // The scan's default legacy ask is 2025-06-18; a -32022 naming a newer
        // revision we implement has to override it for this probe.
        LocalMCPScannerURLProtocolMock.install([
            LocalMCPScannerMockResponse(
                statusCode: 400,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"discover","error":{"code":-32022,"message":"Unsupported protocol version.","data":{"supported":["2025-03-26","2025-11-25"],"requested":"2026-07-28"}}}"#
            ),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "application/json",
                    "Mcp-Session-Id": "renegotiated"
                ],
                body: #"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-11-25","serverInfo":{"name":"legacy","title":"Legacy Server","version":"1.0.0"},"capabilities":{}}}"#
            ),
            LocalMCPScannerMockResponse(statusCode: 202, headers: [:], body: ""),
            LocalMCPScannerMockResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: #"{"jsonrpc":"2.0","id":"tools","result":{"tools":[{"name":"search","inputSchema":{"type":"object","properties":{"query":{"type":"string"}}},"annotations":{"readOnlyHint":true}}]}}"#
            )
        ])
        let scanner = LocalMCPScanner(
            homeDirectory: FileManager.default.temporaryDirectory,
            urlSession: session,
            executablePath: { _ in nil }
        )
        let candidate = LocalMCPServerCandidate(
            id: "test.renegotiated",
            source: "test",
            sourcePath: "test",
            name: "renegotiated",
            displayName: "Renegotiated",
            transport: .http,
            url: "http://127.0.0.1:39725/mcp",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [],
            environment: [],
            probe: nil,
            probeError: nil
        )

        let result = try await scanner.probe(candidate: candidate)

        #expect(result.serverInfo.title == "Legacy Server")
        #expect(result.tools.map(\.name) == ["search"])
        let requests = LocalMCPScannerURLProtocolMock.requests()
        #expect(requests.map(\.method) == [
            "server/discover", "initialize", "notifications/initialized", "tools/list"
        ])
        let initializeParams = try #require(requests[1].body["params"] as? [String: Any])
        #expect(initializeParams["protocolVersion"] as? String == "2025-11-25")
        #expect(requests[1].headers["MCP-Protocol-Version"] == "2025-11-25")
        #expect(requests[3].headers["Mcp-Session-Id"] == "renegotiated")
    }

    @Test func modernHTTPHeaderSchemaInspectionIsExplicitlyBounded() throws {
        var nested: [String: Any] = [
            "type": "string",
            "x-mcp-header": "Deep"
        ]
        for index in 0..<70 {
            nested = [
                "type": "object",
                "properties": ["level\(index)": nested]
            ]
        }
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["root": nested]
        ]
        let wideProperties = Dictionary(
            uniqueKeysWithValues: (0..<4_100).map {
                ("value\($0)", ["type": "string"])
            }
        )
        let wideSchema: [String: Any] = [
            "type": "object",
            "properties": wideProperties
        ]
        var acceptedDepthPayload: Any = "leaf"
        for _ in 0..<64 {
            acceptedDepthPayload = [acceptedDepthPayload]
        }
        var rejectedDepthPayload: Any = "leaf"
        for _ in 0..<65 {
            rejectedDepthPayload = [rejectedDepthPayload]
        }
        let exactDepthSchema: [String: Any] = [
            "type": "object",
            "padding": acceptedDepthPayload
        ]
        let overDepthSchema: [String: Any] = [
            "type": "object",
            "padding": rejectedDepthPayload
        ]
        let exactNodeSchema: [String: Any] = [
            "type": "object",
            "padding": (0..<4_094).map { _ in [String: Any]() }
        ]
        let overNodeSchema: [String: Any] = [
            "type": "object",
            "padding": (0..<4_095).map { _ in [String: Any]() }
        ]

        #expect(!MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(schema))
        #expect(!MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(wideSchema))
        #expect(MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(exactDepthSchema))
        #expect(!MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(overDepthSchema))
        #expect(MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(exactNodeSchema))
        #expect(!MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(overNodeSchema))

        let exactJSON = try #require(JSONValue.fromJSONObject(exactNodeSchema))
        let overJSON = try #require(JSONValue.fromJSONObject(overNodeSchema))
        #expect(MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(exactJSON))
        #expect(!MCPUpstreamProtocol.isValidModernHTTPToolInputSchema(overJSON))
    }

    @Test func bridgeImportFiltersInvalidSchemasForHTTPAndStdio() throws {
        var deepSchema: JSONValue = .object([
            "type": .string("string"),
            "x-mcp-header": .string("Deep")
        ])
        for index in 0..<70 {
            deepSchema = .object([
                "type": .string("object"),
                "properties": .object(["level\(index)": deepSchema])
            ])
        }
        let validTool = LocalMCPToolSummary(
            name: "valid",
            title: nil,
            description: nil,
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([:])
            ]),
            annotations: nil
        )
        let invalidTool = LocalMCPToolSummary(
            name: "hostile",
            title: nil,
            description: nil,
            inputSchema: deepSchema,
            annotations: nil
        )
        let scanner = LocalMCPScanner(
            homeDirectory: FileManager.default.temporaryDirectory,
            executablePath: { command in command == "echo" ? "/bin/echo" : nil }
        )

        for transport in [LocalMCPServerCandidate.Transport.http, .stdio] {
            let candidate = LocalMCPServerCandidate(
                id: "test.\(transport.rawValue)",
                source: "test",
                sourcePath: "test",
                name: "test",
                displayName: "Test",
                transport: transport,
                url: transport == .http ? "http://127.0.0.1:4999/mcp" : nil,
                command: transport == .stdio ? "/bin/echo" : nil,
                args: [],
                startupTimeoutSeconds: nil,
                isLocal: true,
                bridgeable: true,
                reason: nil,
                headers: [],
                environment: [],
                probe: LocalMCPProbeResult(
                    serverInfo: LocalMCPServerInfo(
                        name: "test",
                        title: nil,
                        version: nil,
                        description: nil
                    ),
                    tools: [validTool, invalidTool]
                ),
                probeError: nil
            )

            let tools = try scanner.bridgeTools(for: candidate)
            #expect(tools.map(\.mcpBridgeToolName) == ["valid"])
        }
    }

    @Test func bridgeToolIDsIgnoreEndpointHeadersSessionsAndOAuthTokenChanges() throws {
        let probe = LocalMCPProbeResult(
            serverInfo: LocalMCPServerInfo(name: "server", title: nil, version: nil, description: nil),
            tools: [
                LocalMCPToolSummary(
                    name: "find-item",
                    title: "Find Item",
                    description: nil,
                    inputSchema: nil,
                    annotations: nil
                )
            ]
        )
        var first = LocalMCPServerCandidate(
            id: "source.server",
            source: "source",
            sourcePath: "/tmp/one.json",
            name: "stable-server",
            displayName: "Stable Server",
            transport: .http,
            url: "http://127.0.0.1:9000/mcp?session=first",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [MCPBridgeHeader(name: "Authorization", value: "Bearer first")],
            environment: []
        )
        first.probe = probe

        var second = LocalMCPServerCandidate(
            id: "source.server",
            source: "source",
            sourcePath: "/tmp/one.json",
            name: "stable-server",
            displayName: "Stable Server",
            transport: .http,
            url: "http://127.0.0.1:9999/other?session=second",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [MCPBridgeHeader(name: "Authorization", value: "Bearer second")],
            environment: []
        )
        second.probe = probe

        let scanner = LocalMCPScanner()
        let firstID = try #require(scanner.bridgeTools(for: first).first?.id)
        let secondID = try #require(scanner.bridgeTools(for: second).first?.id)
        #expect(firstID == "stable_server_find_item")
        #expect(secondID == firstID)
        #expect(first.persistedServerIdentity != second.persistedServerIdentity)
        #expect(try scanner.bridgeTools(for: first).first?.mcpBridgeServerIdentity == first.persistedServerIdentity)
        #expect(try scanner.bridgeTools(for: second).first?.mcpBridgeServerIdentity == second.persistedServerIdentity)

        let collidingSecond = try #require(
            scanner.bridgeTools(for: second, existingIDs: [firstID]).first
        )
        #expect(collidingSecond.id != firstID)
        #expect(collidingSecond.id.hasPrefix("stable_server_find_item_"))

        let refreshedAfterCollisionRemoved = try #require(
            scanner.bridgeTools(
                for: second,
                preferredIDsByUpstreamToolName: ["find-item": collidingSecond.id]
            ).first
        )
        #expect(refreshedAfterCollisionRemoved.id == collidingSecond.id)

        let differentConfig = LocalMCPServerCandidate(
            id: "other.server",
            source: "other",
            sourcePath: "/tmp/two.json",
            name: second.name,
            displayName: second.displayName,
            transport: second.transport,
            url: second.url,
            command: second.command,
            args: second.args,
            startupTimeoutSeconds: second.startupTimeoutSeconds,
            isLocal: second.isLocal,
            bridgeable: second.bridgeable,
            reason: second.reason,
            headers: second.headers,
            environment: second.environment
        )
        #expect(differentConfig.persistedServerIdentity == second.persistedServerIdentity)
        #expect(differentConfig.configurationOwners.first?.serverIdentity != second.configurationOwners.first?.serverIdentity)
    }

    @Test func equivalentCodexAndClaudeConfigsDeduplicateWithoutLosingOwners() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        let claudeConfig = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.browser]
        command = "/usr/bin/false"
        args = ["--stdio"]
        """.utf8).write(to: codexConfig)
        try Data("""
        {"mcpServers":{"browser":{"command":"/usr/bin/false","args":["--stdio"]}}}
        """.utf8).write(to: claudeConfig)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let visible = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        let owned = await scanner.configuredCandidatesForReconciliation()
        let candidate = try #require(visible.first { $0.displayName == "browser" })

        #expect(visible.count { $0.displayName == "browser" } == 1)
        #expect(owned.count { $0.displayName == "browser" } == 1)
        #expect(Set(candidate.configurationOwners.map(\.source)) == ["codex", "claude_desktop"])
        #expect(Set(candidate.configurationOwners.map(\.sourcePath)) == [codexConfig.path, claudeConfig.path])
        #expect(candidate.persistedServerIdentity.hasPrefix("runtime."))
    }

    @Test func canonicalRuntimeIdentityMatchesCrossLanguageFixtures() {
        let stdio = LocalMCPServerCandidate(
            id: "fixture.openbrowser",
            source: "fixture",
            sourcePath: "/fixtures/config.json",
            name: "openbrowser",
            displayName: "OpenBrowser",
            transport: .stdio,
            url: nil,
            command: "/opt/homebrew/bin/node",
            args: [
                "/Users/example/Projects/OpenBrowser/systems/chrome/dist/index.js",
                "--profile",
                "default"
            ],
            startupTimeoutSeconds: 12.5,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [],
            environment: [
                MCPStdioEnvironmentVariable(
                    name: "OPENBROWSER_PROFILE",
                    valueSource: MCPBridgeHeaderValueSource(
                        kind: .environment,
                        environmentKey: "OPENBROWSER_PROFILE"
                    )
                )
            ]
        )
        let http = LocalMCPServerCandidate(
            id: "fixture.remote",
            source: "fixture",
            sourcePath: "/fixtures/config.json",
            name: "remote",
            displayName: "Remote",
            transport: .http,
            url: "https://mcp.example.test/v1/connect",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: false,
            bridgeable: true,
            reason: nil,
            headers: [
                MCPBridgeHeader(
                    name: "Authorization",
                    valueSource: MCPBridgeHeaderValueSource(
                        kind: .environment,
                        environmentKey: "MCP_AUTH_TOKEN",
                        prefix: "Bearer "
                    )
                )
            ],
            environment: []
        )

        #expect(stdio.canonicalRuntimeIdentity == "runtime.e98357ac40de67f94b1a3e6b8a08b81c")
        #expect(http.canonicalRuntimeIdentity == "runtime.c65914bdaf5576eba346bb3ba27d8d25")
    }

    @Test func sameCommandWithDifferentEnvironmentBindingsDoesNotDeduplicate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        let claudeConfig = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.browser]
        command = "/usr/bin/false"
        [mcp_servers.browser.env]
        PROFILE = "codex"
        """.utf8).write(to: codexConfig)
        try Data("""
        {"mcpServers":{"browser":{"command":"/usr/bin/false","env":{"PROFILE":"claude"}}}}
        """.utf8).write(to: claudeConfig)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
            .filter { $0.displayName == "browser" }

        #expect(candidates.count == 2)
        #expect(Set(candidates.compactMap(\.canonicalRuntimeIdentity)).count == 2)
    }

    @Test func sameCommandWithDifferentArgumentsDoesNotDeduplicate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        let claudeConfig = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.browser]
        command = "/usr/bin/false"
        args = ["one.js"]
        """.utf8).write(to: codexConfig)
        try Data("""
        {"mcpServers":{"browser":{"command":"/usr/bin/false","args":["two.js"]}}}
        """.utf8).write(to: claudeConfig)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
            .filter { $0.displayName == "browser" }
        #expect(candidates.count == 2)
        #expect(Set(candidates.compactMap(\.canonicalRuntimeIdentity)).count == 2)
    }

    @Test func sameHTTPURLWithDifferentAuthBindingsDoesNotDeduplicate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let codexConfig = home.appendingPathComponent(".codex/config.toml")
        let claudeConfig = home.appendingPathComponent(
            "Library/Application Support/Claude/claude_desktop_config.json"
        )
        try FileManager.default.createDirectory(
            at: codexConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: claudeConfig.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        [mcp_servers.browser]
        url = "http://127.0.0.1:9000/mcp"
        bearer_token_env_var = "CODEX_TOKEN"
        """.utf8).write(to: codexConfig)
        try Data("""
        {"mcpServers":{"browser":{"url":"http://127.0.0.1:9000/mcp","headers":{"Authorization":"Bearer public-test"}}}}
        """.utf8).write(to: claudeConfig)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
            .filter { $0.displayName == "browser" }
        #expect(candidates.count == 2)
        #expect(Set(candidates.compactMap(\.canonicalRuntimeIdentity)).count == 2)
    }

    @Test func bridgeToolsReserveExactCuratedIDsWithoutHashingTheWholeNamespace() throws {
        var candidate = LocalMCPServerCandidate(
            id: "test.utilities",
            source: "test",
            sourcePath: "/tmp/utilities.json",
            name: "utilities",
            displayName: "Utilities",
            transport: .http,
            url: "http://127.0.0.1:9000/mcp",
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: [],
            environment: []
        )
        candidate.probe = LocalMCPProbeResult(
            serverInfo: LocalMCPServerInfo(name: "utilities", title: nil, version: nil, description: nil),
            tools: [
                LocalMCPToolSummary(
                    name: "current_date",
                    title: "Current Date",
                    description: nil,
                    inputSchema: nil,
                    annotations: nil
                ),
                LocalMCPToolSummary(
                    name: "experimental_export",
                    title: "Experimental Export",
                    description: nil,
                    inputSchema: nil,
                    annotations: nil
                )
            ]
        )

        let ids = try LocalMCPScanner().bridgeTools(for: candidate).map(\.id)
        #expect(ids[0].hasPrefix("utilities_current_date_"))
        #expect(ids[1] == "utilities_experimental_export")
    }

    @Test func scansUserScopedClaudeStdioServerFromClaudeJSON() async throws {
        // `claude mcp add --scope user` writes a stdio
        // server at the top level of ~/.claude.json — not ~/.mcp.json — and it
        // never shows in `claude mcp list`'s HTTP-only output. The scanner must
        // read ~/.claude.json to surface it.
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let serverURL = home.appendingPathComponent("mock-stdio-mcp")
        try Data(Self.mockStdioMCPServer.utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let claudeJSON: [String: Any] = [
            "mcpServers": [
                "example-stdio": [
                    "type": "stdio",
                    "command": serverURL.path,
                    "args": ["--fixture"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: home.appendingPathComponent(".claude.json"))

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let candidate = try #require(candidates.first { $0.displayName == "example-stdio" })
        #expect(candidate.transport == .stdio)
        #expect(candidate.bridgeable)
        #expect(candidate.command == serverURL.path)
        #expect(candidate.args == ["--fixture"])
        #expect(try await scanner.probe(candidate: candidate).tools.map(\.name) == ["echo"])
    }

    @Test func scansCodexStdioServerProbesToolsAndBuildsBridgeDefinitions() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let serverURL = home.appendingPathComponent("mock-stdio-mcp")
        try Data(Self.mockStdioMCPServer.utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.mock_stdio]
        command = "\(serverURL.path)"
        args = ["--fixture"]
        startup_timeout_sec = 30.0

        [mcp_servers.mock_stdio.env]
        MOCK_SECRET = "from-toml"
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        var candidate = try #require(candidates.first)

        #expect(candidate.id == "codex.mock_stdio")
        #expect(candidate.transport == .stdio)
        #expect(candidate.bridgeable)
        #expect(candidate.probeError == nil)
        // A scan never launches a stdio server; importing or checking one does.
        #expect(candidate.probe == nil)
        candidate.probe = try await scanner.probe(candidate: candidate)
        #expect(candidate.probe?.serverInfo.name == "mock-stdio")
        #expect(candidate.probe?.tools.map(\.name) == ["echo"])

        let tools = try scanner.bridgeTools(for: candidate)
        let tool = try #require(tools.first)
        #expect(tool.backend == .mcpStdioBridge)
        #expect(tool.mcpStdioBridge?.command == serverURL.path)
        #expect(tool.mcpStdioBridge?.args == ["--fixture"])
        #expect(tool.mcpStdioBridge?.startupTimeoutSeconds == 30)
        #expect(tool.mcpStdioBridge?.environment.first?.value == nil)
        #expect(tool.mcpStdioBridge?.environment.first?.valueSource?.kind == .tomlFile)
        #expect(tool.mcpStdioBridge?.environment.first?.valueSource?.keyPath == ["mcp_servers", "mock_stdio", "env", "MOCK_SECRET"])

        let client = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        let outcome = try await client.call(tool: tool, parameters: [
            "query": .string("hello")
        ])

        #expect(outcome.succeeded, Comment(rawValue: outcome.stderr))
        #expect(
            outcome.stdout == #"{"arguments":{"query":"hello"},"secret":"from-toml"}"#,
            Comment(rawValue: outcome.stdout)
        )
        #expect(outcome.upstreamMCPResult?.content == [
            .object(["type": .string("text"), "text": .string("ok")])
        ])

        let failed = try await client.call(tool: tool, parameters: [
            "query": .string("fail")
        ])
        #expect(!failed.succeeded)
        #expect(failed.exitCode == 1)
        #expect(failed.stdout == "upstream rejected the request")
        #expect(failed.upstreamMCPResult == nil)

        let cappedTool = ToolDefinition(
            id: "mcp_stdio_capped",
            name: tool.name,
            summary: tool.summary,
            executablePath: tool.executablePath,
            argumentPattern: tool.argumentPattern,
            parameters: tool.parameters,
            capability: tool.capability,
            timeoutSeconds: tool.timeoutSeconds,
            outputByteLimit: 1024,
            origin: tool.origin,
            category: tool.category,
            permissionRequirements: tool.permissionRequirements,
            backend: .mcpStdioBridge,
            mcpStdioBridge: tool.mcpStdioBridge
        )
        let capped = try await client.call(tool: cappedTool, parameters: [
            "query": .string("large")
        ])
        #expect(capped.succeeded)
        #expect(capped.stdout == #"{"ok":true}"#)
        #expect(capped.truncatedStdout)
        #expect(capped.upstreamMCPResult == nil)
        #expect(capped.stderr.contains("Normalized stdout is complete"))
        #expect(capped.stderr.contains("omitted atomically"))
    }

    @Test func scansCodexStdioAuthProfilesAsSeparateBridges() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let publicURL = home.appendingPathComponent("public-mcp-wrapper")
        let accountURL = home.appendingPathComponent("account-mcp-wrapper")
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "public-search",
            toolName: "search_public_records",
            toolTitle: "Search Public Records"
        ).utf8).write(to: publicURL)
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "account-user",
            toolName: "get_account_bookmarks",
            toolTitle: "Get Account Bookmarks"
        ).utf8).write(to: accountURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: publicURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: accountURL.path)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.public-search]
        command = "\(publicURL.path)"

        [mcp_servers.account-user]
        command = "\(accountURL.path)"
        startup_timeout_sec = 300.0

        [mcp_servers.public-docs]
        url = "https://docs.example.com/mcp"
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        #expect(candidates.map(\.id).sorted() == ["codex.account_user", "codex.public_search"])

        // A scan never launches a stdio server; importing or checking one does.
        var publicProfile = try #require(candidates.first { $0.displayName == "public-search" })
        #expect(publicProfile.transport == .stdio)
        #expect(publicProfile.probe == nil)
        publicProfile.probe = try await scanner.probe(candidate: publicProfile)
        #expect(publicProfile.probe?.tools.map(\.name) == ["search_public_records"])

        var accountProfile = try #require(candidates.first { $0.displayName == "account-user" })
        #expect(accountProfile.transport == .stdio)
        #expect(accountProfile.startupTimeoutSeconds == 300)
        accountProfile.probe = try await scanner.probe(candidate: accountProfile)
        #expect(accountProfile.probe?.tools.map(\.name) == ["get_account_bookmarks"])

        let accountTool = try #require(scanner.bridgeTools(for: accountProfile).first)
        #expect(accountTool.backend == .mcpStdioBridge)
        #expect(accountTool.mcpStdioBridge?.serverName == "account-user")
        #expect(accountTool.mcpStdioBridge?.command == accountURL.path)
        #expect(accountTool.mcpStdioBridge?.startupTimeoutSeconds == 300)
        #expect(accountTool.mcpStdioBridge?.toolName == "get_account_bookmarks")
        #expect(throws: Never.self) { try ToolArgumentResolver.validate(accountTool) }
    }

    /// Reproduces the real ~/.codex/config.toml shape around `imessage_search`:
    /// multiple stdio/http MCP entries, a command-only server with no `args`,
    /// then trailing `[plugins."name@vendor"]` sections whose `enabled = true`
    /// lines follow immediately after the last MCP block.
    @Test func scansCodexConfigWithTrailingPluginsAndCommandOnlyServer() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let imessageScript = home.appendingPathComponent("run-codex-search-only.sh")
        let nodeRepl = home.appendingPathComponent("node_repl")
        let xSearch = home.appendingPathComponent("x-mcp-app-only")
        for url in [imessageScript, nodeRepl, xSearch] {
            try Data(Self.mockNamedStdioMCPServer(
                serverName: url.lastPathComponent,
                toolName: "search_messages",
                toolTitle: "Search Messages"
            ).utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.firecrawl]
        command = "npx"
        args = ["-y", "firecrawl-mcp"]

        [mcp_servers.firecrawl.env]
        FIRECRAWL_API_KEY = "fc-test-key"

        [mcp_servers.chrome-devtools]
        command = "npx"
        args = ["-y", "chrome-devtools-mcp@latest"]
        startup_timeout_sec = 30.0

        [mcp_servers.chrome-devtools.env]
        CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS = "1"

        [mcp_servers.notion]
        url = "https://mcp.notion.com/mcp"

        [mcp_servers.monologue.tools.list_recent_notes]
        approval_mode = "approve"

        [mcp_servers.node_repl]
        args = []
        command = "\(nodeRepl.path)"
        startup_timeout_sec = 120

        [mcp_servers.node_repl.env]
        CODEX_HOME = "\(home.path)/.codex"

        [mcp_servers.x-search]
        command = "\(xSearch.path)"
        startup_timeout_sec = 60.0

        [mcp_servers.x-docs]
        url = "https://docs.x.com/mcp"

        [mcp_servers.unavailable_example]
        command = "/usr/local/bin/unavailable-mcp-server"
        args = ["--mcp"]

        [mcp_servers.imessage_search]
        command = "\(imessageScript.path)"

        [plugins."build-ios-apps@openai-curated"]
        enabled = true

        [plugins."build-macos-apps@openai-curated"]
        enabled = true

        [plugins."github@openai-curated"]
        enabled = true

        [plugins."pdf@openai-primary-runtime"]
        enabled = true
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { command in
                if command == "npx" { return "/usr/bin/npx" }
                return nil
            },
            stdioBridgeClient: MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        )

        let candidates = await scanner.scan(includeRemote: false, probe: true)
        let imessage = try #require(candidates.first { $0.id == "codex.imessage_search" })

        #expect(imessage.displayName == "imessage_search")
        #expect(imessage.transport == .stdio)
        #expect(imessage.command == imessageScript.path)
        #expect(imessage.args.isEmpty)
        #expect(imessage.environment.isEmpty)
        #expect(imessage.bridgeable)
        #expect(imessage.reason == nil)
        #expect(imessage.probeError == nil)
        #expect(try await scanner.probe(candidate: imessage).tools.map(\.name) == ["search_messages"])

        // Nested tool approval tables must not become importable MCP servers.
        #expect(!candidates.contains { $0.displayName == "monologue.tools.list_recent_notes" })

        // Remote HTTP entries are excluded unless includeRemote is set.
        #expect(!candidates.contains { $0.id == "codex.notion" })
        #expect(!candidates.contains { $0.id == "codex.x_docs" })
    }

    /// The line-based Codex TOML parser keeps `currentName` set to the last
    /// `[mcp_servers.*]` header until another MCP header appears. Trailing
    /// `[plugins.*]` sections therefore mis-attribute `enabled = true` onto the
    /// last MCP block, but those keys are ignored when building candidates.
    @Test func trailingPluginEnabledLineDoesNotBreakCommandOnlyServerBridgeability() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let imessageScript = home.appendingPathComponent("run-codex-search-only.sh")
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "imessage_search",
            toolName: "search_messages",
            toolTitle: "Search Messages"
        ).utf8).write(to: imessageScript)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: imessageScript.path)

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.imessage_search]
        command = "\(imessageScript.path)"

        [plugins."build-ios-apps@openai-curated"]
        enabled = true

        [plugins."github@openai-curated"]
        enabled = true
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)
        let imessage = try #require(candidates.first { $0.id == "codex.imessage_search" })

        #expect(imessage.bridgeable)
        #expect(imessage.args.isEmpty)
        #expect(imessage.environment.isEmpty)
        #expect(imessage.reason == nil)
    }

    @Test func jsonServersFallbackPreservesEnvironmentKeyPath() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let commandURL = home.appendingPathComponent("mock-mcp")
        try Data(Self.mockNamedStdioMCPServer(
            serverName: "fallback",
            toolName: "echo",
            toolTitle: "Echo"
        ).utf8).write(to: commandURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: commandURL.path)

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "servers": {
            "profile-one": {
              "command": "\(commandURL.path)",
              "env": {
                "PROFILE_TOKEN": "from-json"
              }
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)
        let candidate = try #require(candidates.first)

        #expect(candidate.id == "cursor.profile_one")
        #expect(candidate.environment.first?.value == nil)
        #expect(candidate.environment.first?.valueSource?.kind == .jsonFile)
        #expect(candidate.environment.first?.valueSource?.keyPath == ["servers", "profile-one", "env", "PROFILE_TOKEN"])
    }

    @Test func scansVSCodeStdioServerWithEnv() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "vscode-mcp")
        let configURL = home.appendingPathComponent("Library/Application Support/Code/User/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "servers": {
            "notes": {
              "type": "stdio",
              "command": "\(commandURL.path)",
              "args": ["--vscode"],
              "env": { "VSCODE_TOKEN": "secret" }
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "vscode" })

        #expect(candidate.id == "vscode.notes")
        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
        #expect(candidate.args == ["--vscode"])
        #expect(candidate.environment.first?.valueSource?.keyPath == ["servers", "notes", "env", "VSCODE_TOKEN"])
    }

    @Test func scansWindsurfHTTPServerWithServerURL() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".codeium/windsurf/mcp_config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "remote-docs": {
              "serverUrl": "http://127.0.0.1:8080/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "windsurf" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:8080/mcp")
        #expect(candidate.bridgeable)
    }

    @Test func scansZedContextServerFromJSONCSettings() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "zed-mcp")
        let configURL = home.appendingPathComponent(".config/zed/settings.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          // Zed MCP block
          "context_servers": {
            "custom-tools": {
              "source": "custom",
              "command": "\(commandURL.path)",
              "args": ["--zed"]
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "zed" })

        #expect(candidate.id == "zed.custom_tools")
        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
        #expect(candidate.args == ["--zed"])
    }

    @Test func scansGeminiHTTPServerWithHttpURL() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".gemini/settings.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "gemini-remote": {
              "httpUrl": "http://127.0.0.1:9090/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "gemini" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:9090/mcp")
    }

    @Test func scansAntigravityHTTPServerWithServerURL() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".gemini/antigravity/mcp_config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "antigravity-remote": {
              "type": "remote",
              "serverUrl": "http://127.0.0.1:7070/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "antigravity" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:7070/mcp")
    }

    @Test func scansCopilotCLILocalStdioServer() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "copilot-mcp")
        let configURL = home.appendingPathComponent(".copilot/mcp-config.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "local-tools": {
              "type": "local",
              "command": "\(commandURL.path)"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "copilot_cli" })

        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
    }

    @Test func scansClineStreamableHTTPServer() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cline/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "cline-remote": {
              "type": "streamableHttp",
              "url": "http://127.0.0.1:5555/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "cline" })

        #expect(candidate.transport == .http)
        #expect(candidate.url == "http://127.0.0.1:5555/mcp")
    }

    @Test func jsoncStrippingPreservesCommentsInStringsAndRemovesTrailingCommas() {
        let input = """
        {
          "url": "https://example.com/path//not-a-comment",
          "items": [1, /* block */ 2,],
        }
        """
        let prepared = LocalMCPScanner.prepareJSONC(input)
        #expect(prepared.contains("https://example.com/path//not-a-comment"))
        #expect(!prepared.contains("/* block */"))

        let data = Data(prepared.utf8)
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["url"] as? String == "https://example.com/path//not-a-comment")
        #expect((object?["items"] as? [Int]) == [1, 2])
    }

    @Test func corruptJSONConfigSurfacesPseudoCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "cursor" })

        #expect(candidate.displayName == "mcp.json")
        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Could not read this file as JSON.")
    }

    @Test func corruptClaudeExtensionManifestSurfacesUnreadableOwnershipCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let manifest = home.appendingPathComponent(
            "Library/Application Support/Claude/Claude Extensions/Broken/manifest.json"
        )
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{not-json".utf8).write(to: manifest)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require(
            (await scanner.configuredCandidatesForReconciliation()).first {
                $0.source == "claude_extension" &&
                    URL(fileURLWithPath: $0.sourcePath).resolvingSymlinksInPath() ==
                    manifest.resolvingSymlinksInPath()
            }
        )
        #expect(!candidate.bridgeable)
        #expect(candidate.reason == "Could not read this file as JSON.")
    }

    @Test func existingClaudeExtensionRootEnumerationFailureEmitsPreservationSentinel() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(
            "Library/Application Support/Claude/Claude Extensions",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            claudeExtensionEnumerator: { _ in nil }
        )
        let candidate = try #require(
            (await scanner.configuredCandidatesForReconciliation()).first {
                $0.source == "claude_extension"
            }
        )
        #expect(candidate.sourceReadFailureScopePath == root.standardizedFileURL.path)
    }

    @Test func claudeExtensionSubtreeEnumerationFailureEmitsScopedSentinel() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(
            "Library/Application Support/Claude/Claude Extensions",
            isDirectory: true
        )
        let failedSubtree = root.appendingPathComponent("Unavailable", isDirectory: true)
        try FileManager.default.createDirectory(at: failedSubtree, withIntermediateDirectories: true)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { _ in nil },
            claudeExtensionEnumerator: { _ in ([], [failedSubtree]) }
        )
        let candidate = try #require(
            (await scanner.configuredCandidatesForReconciliation()).first {
                $0.sourceReadFailureScopePath != nil
            }
        )
        #expect(candidate.sourceReadFailureScopePath == failedSubtree.standardizedFileURL.path)
    }

    @Test func disabledFlagSurfacesNonBridgeableCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "disabled-mcp")
        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "disabled-server": {
              "disabled": true,
              "command": "\(commandURL.path)"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "disabled-server" })

        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Disabled in the source app's settings.")
    }

    @Test func missingAbsoluteInterpreterEntrypointIsNotBridgeable() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        let missing = home.appendingPathComponent("renamed/server/dist/index.js").path
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("""
        {"mcpServers":{"browser":{"command":"/usr/bin/false","args":["\(missing)"]}}}
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { name in name == "node" ? "/usr/bin/false" : nil }
        )
        // Use a node-shaped symlink so the scanner recognizes the interpreter
        // while validation remains fully local to this test.
        let node = home.appendingPathComponent("node")
        try FileManager.default.createSymbolicLink(at: node, withDestinationURL: URL(fileURLWithPath: "/usr/bin/false"))
        try Data("""
        {"mcpServers":{"browser":{"command":"\(node.path)","args":["\(missing)"]}}}
        """.utf8).write(to: configURL)

        let candidate = try #require(
            (await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "browser" }
        )
        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Entrypoint not found: \(missing).")
    }

    @Test func enabledFalseSurfacesNonBridgeableCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "off-server": {
              "enabled": false,
              "url": "http://127.0.0.1:1234/mcp"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "off-server" })

        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "Disabled in the source app's settings.")
    }

    @Test func scansOpenCodeLocalServerWithCommandArrayAndEnvironmentKey() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandURL = try Self.installMockStdioServer(in: home, name: "opencode-mcp")
        let configURL = home.appendingPathComponent(".config/opencode/opencode.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcp": {
            "opencode-local": {
              "type": "local",
              "command": ["\(commandURL.path)", "--leading"],
              "args": ["--trailing"],
              "environment": {
                "OPEN_CODE_TOKEN": "secret"
              }
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.source == "opencode" })

        #expect(candidate.transport == .stdio)
        #expect(candidate.command == commandURL.path)
        #expect(candidate.args == ["--leading", "--trailing"])
        #expect(candidate.environment.first?.valueSource?.keyPath == ["mcp", "opencode-local", "environment", "OPEN_CODE_TOKEN"])
    }

    @Test func claudeCodeProjectServersGetUniqueIDsAndDedupIdenticalCommands() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let commandA = try Self.installMockStdioServer(in: home, name: "project-a-mcp")
        let commandB = try Self.installMockStdioServer(in: home, name: "project-b-mcp")
        let sharedCommand = try Self.installMockStdioServer(in: home, name: "shared-mcp")

        let claudeJSON: [String: Any] = [
            "projects": [
                "/Users/test/project-a": [
                    "mcpServers": [
                        "shared-name": [
                            "command": commandA.path
                        ]
                    ]
                ],
                "/Users/test/project-b": [
                    "mcpServers": [
                        "shared-name": [
                            "command": commandB.path
                        ]
                    ]
                ],
                "/Users/test/project-c": [
                    "mcpServers": [
                        "dedup-me": [
                            "command": sharedCommand.path
                        ]
                    ]
                ],
                "/Users/test/project-d": [
                    "mcpServers": [
                        "dedup-me": [
                            "command": sharedCommand.path
                        ]
                    ]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: claudeJSON)
        try data.write(to: home.appendingPathComponent(".claude.json"))

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)
        let projectCandidates = candidates.filter { $0.source == "claude_code" && $0.displayName == "shared-name" }

        #expect(projectCandidates.count == 2)
        #expect(Set(projectCandidates.map(\.id)).count == 2)
        #expect(projectCandidates.allSatisfy { $0.displayName == "shared-name" })
        #expect(Set(projectCandidates.map(\.command)) == Set([commandA.path, commandB.path]))

        let dedupCandidates = candidates.filter { $0.source == "claude_code" && $0.displayName == "dedup-me" }
        #expect(dedupCandidates.count == 1)
    }

    @Test func envFileSurfacesNonBridgeableCandidate() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "env-file-server": {
              "command": "npx",
              "envFile": ".env.local"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.displayName == "env-file-server" })

        #expect(candidate.bridgeable == false)
        #expect(candidate.reason == "This server loads secrets from an env file; add the values in the source app before importing.")
    }

    @Test func typeNormalizationMapsStreamableHttpAndMissingURLReason() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let configURL = home.appendingPathComponent(".cursor/mcp.json")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {
          "mcpServers": {
            "streamable-server": {
              "type": "streamableHttp",
              "url": "http://127.0.0.1:4444/mcp"
            },
            "missing-url-server": {
              "type": "http"
            }
          }
        }
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidates = await scanner.scan(includeRemote: false, probe: false)

        let streamable = try #require(candidates.first { $0.displayName == "streamable-server" })
        #expect(streamable.transport == .http)
        #expect(streamable.url == "http://127.0.0.1:4444/mcp")
        #expect(streamable.bridgeable)

        let missingURL = try #require(candidates.first { $0.displayName == "missing-url-server" })
        #expect(missingURL.transport == .http)
        #expect(missingURL.bridgeable == false)
        #expect(missingURL.reason == "No server URL is configured.")
    }

    @Test func tomlForeignSectionKeysDoNotPolluteLastMCPServer() async throws {
        let home = try Self.makeTempHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let imessageScript = try Self.installMockStdioServer(
            in: home,
            name: "run-codex-search-only.sh",
            serverName: "imessage_search",
            toolName: "search_messages",
            toolTitle: "Search Messages"
        )

        let configURL = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        [mcp_servers.imessage_search]
        command = "\(imessageScript.path)"

        [plugins."build-ios-apps@openai-curated"]
        enabled = true
        secret_key = "must-not-appear"
        """.utf8).write(to: configURL)

        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        let candidate = try #require((await scanner.scan(includeRemote: false, probe: false)).first { $0.id == "codex.imessage_search" })

        #expect(candidate.bridgeable)
        #expect(candidate.environment.isEmpty)
        #expect(!candidate.args.contains("must-not-appear"))
    }

    private static func makeTempHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private static func installMockStdioServer(
        in home: URL,
        name: String,
        serverName: String = "mock-stdio",
        toolName: String = "echo",
        toolTitle: String = "Echo"
    ) throws -> URL {
        let serverURL = home.appendingPathComponent(name)
        try Data(mockNamedStdioMCPServer(
            serverName: serverName,
            toolName: toolName,
            toolTitle: toolTitle
        ).utf8).write(to: serverURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverURL.path)
        return serverURL
    }

    private static let mockStdioMCPServer = """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "server/discover":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "error": {"code": -32601, "message": "Method not found"}
            }), flush=True)
        elif method == "initialize":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "protocolVersion": "2025-06-18",
                    "serverInfo": {"name": "mock-stdio", "version": "1.0.0"},
                    "capabilities": {}
                }
            }), flush=True)
        elif method == "tools/list":
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "tools": [{
                        "name": "echo",
                        "title": "Echo",
                        "description": "Echo a value.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"query": {"type": "string"}},
                            "required": ["query"]
                        },
                        "annotations": {"readOnlyHint": True}
                    }]
                }
            }), flush=True)
        elif method == "tools/call":
            params = message.get("params", {})
            arguments = params.get("arguments", {})
            if arguments.get("query") == "fail":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "content": [{"type": "text", "text": "upstream rejected the request"}],
                        "isError": True
                    }
                }, sort_keys=True), flush=True)
                continue
            if arguments.get("query") == "large":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "content": [{
                            "type": "text",
                            "text": "rich upstream fallback " * 100,
                            "annotations": {"audience": ["assistant"]}
                        }],
                        "structuredContent": {"ok": True}
                    }
                }, sort_keys=True), flush=True)
                continue
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "content": [{"type": "text", "text": "ok"}],
                    "structuredContent": {
                        "secret": os.environ.get("MOCK_SECRET"),
                        "arguments": arguments
                    }
                }
            }, sort_keys=True), flush=True)
    """

    private static func mockNamedStdioMCPServer(serverName: String, toolName: String, toolTitle: String) -> String {
        """
        #!/usr/bin/env python3
        import json
        import sys

        SERVER_NAME = "\(serverName)"
        TOOL_NAME = "\(toolName)"
        TOOL_TITLE = "\(toolTitle)"

        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            if method == "server/discover":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "error": {"code": -32601, "message": "Method not found"}
                }), flush=True)
            elif method == "initialize":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "protocolVersion": "2025-06-18",
                        "serverInfo": {"name": SERVER_NAME, "version": "1.0.0"},
                        "capabilities": {}
                    }
                }), flush=True)
            elif method == "tools/list":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "tools": [{
                            "name": TOOL_NAME,
                            "title": TOOL_TITLE,
                            "description": "Mock X MCP tool.",
                            "inputSchema": {
                                "type": "object",
                                "properties": {}
                            },
                            "annotations": {"readOnlyHint": True}
                        }]
                    }
                }), flush=True)
            elif method == "tools/call":
                print(json.dumps({
                    "jsonrpc": "2.0",
                    "id": message.get("id"),
                    "result": {
                        "content": [{"type": "text", "text": "ok"}],
                        "structuredContent": {"server": SERVER_NAME}
                    }
                }, sort_keys=True), flush=True)
        """
    }
}

private struct LocalMCPScannerCapturedRequest: @unchecked Sendable {
    let method: String
    let headers: [String: String]
    let body: [String: Any]

    func header(_ name: String) -> String? {
        headers.first {
            $0.key.caseInsensitiveCompare(name) == .orderedSame
        }?.value
    }
}

private struct LocalMCPScannerMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    /// Send `body` and then leave the response open: a server that stalls.
    let neverFinishes: Bool

    init(statusCode: Int, headers: [String: String], body: String, neverFinishes: Bool = false) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(body.utf8)
        self.neverFinishes = neverFinishes
    }
}

private final class LocalMCPScannerURLProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [LocalMCPScannerMockResponse] = []
    nonisolated(unsafe) private static var capturedRequests: [LocalMCPScannerCapturedRequest] = []

    static func install(_ newResponses: [LocalMCPScannerMockResponse]) {
        lock.lock()
        responses = newResponses
        capturedRequests = []
        lock.unlock()
    }

    static func requests() -> [LocalMCPScannerCapturedRequest] {
        lock.lock()
        let snapshot = capturedRequests
        lock.unlock()
        return snapshot
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "127.0.0.1"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let method = json["method"] as? String ?? ""

        Self.lock.lock()
        Self.capturedRequests.append(LocalMCPScannerCapturedRequest(
            method: method,
            headers: request.allHTTPHeaderFields ?? [:],
            body: json
        ))
        let response = Self.responses.isEmpty
            ? LocalMCPScannerMockResponse(statusCode: 500, headers: [:], body: #"{"error":"unexpected request"}"#)
            : Self.responses.removeFirst()
        Self.lock.unlock()

        let httpResponse = HTTPURLResponse(
            url: request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        if !response.neverFinishes {
            client?.urlProtocolDidFinishLoading(self)
        }
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
}

@Suite("First-party MCP discovery", .serialized)
struct FirstPartyMCPScannerTests {
    /// A temp home with a fake `remctl` executable and a Claude Code config
    /// that launches that same file through an interpreter, the way
    /// `remctl mcp install --client claude-code` writes it.
    private func makeHome() throws -> (home: URL, executable: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("remctl")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let config = """
        {"mcpServers":{"remctl":{"type":"stdio","command":"/usr/bin/python3","args":["\(executable.path)","mcp"]},
                       "other":{"type":"stdio","command":"/usr/bin/true","args":[]}}}
        """
        try Data(config.utf8).write(to: home.appendingPathComponent(".claude.json"))
        return (home, executable)
    }

    private func makeScanner(home: URL, executable: URL) -> LocalMCPScanner {
        LocalMCPScanner(
            homeDirectory: home,
            executablePath: { name in name == "remctl" ? executable.path : nil }
        )
    }

    @Test func installedCLIProducesOneCandidateThatAbsorbsConfiguredLaunches() async throws {
        let (home, executable) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = makeScanner(home: home, executable: executable)

        let candidates = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        let remctl = candidates.filter { $0.name == "remctl" }
        #expect(remctl.count == 1)
        let candidate = try #require(remctl.first)
        #expect(candidate.source == FirstPartyMCPProviderCatalog.discoverySource)
        #expect(candidate.id == "first_party.remctl")
        #expect(candidate.displayName == "RemCTL")
        #expect(candidate.command == executable.path)
        #expect(candidate.args == ["mcp"])
        #expect(candidate.bridgeable)
        #expect(Set(candidate.configurationOwners.map(\.source)) == ["first_party", "claude_code"])
        #expect(candidates.contains { $0.name == "other" && $0.source == "claude_code" })
        #expect(scanner.firstPartyCandidate(for: FirstPartyMCPProviderCatalog.remCTL)?.id == candidate.id)
        #expect(scanner.firstPartyCandidate(for: FirstPartyMCPProviderCatalog.notesCTL) == nil)
        #expect(scanner.configSnapshot().contains(executable.path))
    }

    @Test func installedMailCTLIsOneServerEvenWhenClaudeDesktopAlsoLaunchesIt() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("mailctl")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        // The entry `mailctl mcp install claude-desktop` writes.
        let desktop = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        try Data(#"{"mcpServers":{"mailctl":{"command":"\#(executable.path)","args":["mcp","serve"]}}}"#.utf8)
            .write(to: desktop.appendingPathComponent("claude_desktop_config.json"))
        let scanner = LocalMCPScanner(
            homeDirectory: home,
            executablePath: { name in name == "mailctl" ? executable.path : nil }
        )

        let candidates = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        let mail = candidates.filter { $0.name == "mailctl" }
        #expect(mail.count == 1)
        let candidate = try #require(mail.first)
        #expect(candidate.id == "first_party.mailctl")
        #expect(candidate.displayName == "MailCTL")
        #expect(candidate.command == executable.path)
        #expect(candidate.args == ["mcp", "serve"])
        #expect(Set(candidate.configurationOwners.map(\.source)) == ["first_party", "claude_desktop"])
    }

    @Test func uninstalledCLIProducesNoCandidateAndTheConfigRowStaysGeneric() async throws {
        let (home, executable) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = LocalMCPScanner(homeDirectory: home, executablePath: { _ in nil })
        _ = executable

        let candidates = await scanner.scan(includeRemote: false, probe: false, includeRuntimeSources: false)
        #expect(candidates.contains { $0.source == FirstPartyMCPProviderCatalog.discoverySource } == false)
        #expect(candidates.contains { $0.name == "remctl" && $0.source == "claude_code" })
    }

    @Test func bridgedFirstPartyToolsCarryTheProviderPolicy() async throws {
        let (home, executable) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = makeScanner(home: home, executable: executable)
        var candidate = try #require(scanner.firstPartyCandidate(for: FirstPartyMCPProviderCatalog.remCTL))
        candidate.probe = LocalMCPProbeResult(
            serverInfo: LocalMCPServerInfo(name: "remctl", title: "RemCTL Reminders", version: "2.0.0", description: nil),
            tools: [
                LocalMCPToolSummary(
                    name: "today",
                    title: "Today's Reminders",
                    description: "Reminders due today.",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                    annotations: .object(["readOnlyHint": .bool(true)])
                ),
                LocalMCPToolSummary(
                    name: "run",
                    title: "Run RemCTL Command",
                    description: "Exact argv.",
                    inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                    annotations: .object(["destructiveHint": .bool(true)])
                )
            ]
        )

        let tools = try scanner.bridgeTools(for: candidate)
        #expect(tools.map(\.id) == ["remctl_today", "remctl_run"])
        let today = try #require(tools.first)
        #expect(today.name == "Today's Reminders")
        #expect(today.summary == "Reminders due today.")
        #expect(today.category == .reminders)
        #expect(today.capability == .readOnly)
        #expect(today.widgetPresentation?.profile == .reminderRows)
        // This fixture omits every action target; do not bind to another
        // installed family just because it owns the canonical name.
        #expect(today.uiActions?.isEmpty == true)
        #expect(today.mcpStdioBridge?.discoverySource == "first_party")
        #expect(today.mcpStdioBridge?.serverName == "RemCTL")
        let run = try #require(tools.last)
        #expect(run.approvalPolicy == .everyCall)
        #expect(run.capability == .destructive)
        #expect(run.widgetPresentation?.profile == .semanticResult)
    }
}
