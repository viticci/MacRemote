import Foundation
import Testing
@testable import MacRemote

@Suite(.serialized)
struct LocalMCPProtocolConformanceTests {
    @Test func modernDiscoveryIsStatelessCacheableAndAdvertisesExtensions() async throws {
        let fixture = try await ProtocolServerFixture(tools: [protocolTool(id: "test_echo")])
        defer { fixture.server.stop() }

        let unauthenticated = try await protocolPost(
            fixture: fixture,
            authenticated: false,
            headers: modernHeaders(method: "server/discover"),
            body: modernRequest(method: "server/discover")
        )
        #expect(unauthenticated.statusCode == 401)

        let response = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "server/discover"),
            body: modernRequest(method: "server/discover")
        )
        #expect(response.statusCode == 200)
        #expect(protocolHeader(response.headers, named: "MCP-Protocol-Version") == "2026-07-28")

        let result = try #require(response.json["result"] as? [String: Any])
        #expect(result["supportedVersions"] as? [String] == ["2026-07-28"])
        #expect(result["resultType"] as? String == "complete")
        #expect(result["ttlMs"] as? Int == 0)
        #expect(result["cacheScope"] as? String == "private")
        #expect(result["serverInfo"] == nil)

        let meta = try #require(result["_meta"] as? [String: Any])
        let serverInfo = try #require(meta["io.modelcontextprotocol/serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "MacRemote")
        try protocolExpectCanonicalServerInfo(serverInfo, base: fixture.base)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)
        #expect(capabilities["resources"] != nil)
        let extensions = try #require(capabilities["extensions"] as? [String: Any])
        #expect(Set(extensions.keys) == ["io.modelcontextprotocol/ui"])
    }

    /// Both inputs used to end the whole app: Foundation reads `-1e999` as an
    /// infinity it cannot write back, and the overlapping base64 markers made
    /// an invalid range.
    @Test func hostileNumbersAndHeadersGetAnErrorNotACrash() async throws {
        let fixture = try await ProtocolServerFixture(tools: [])
        defer { fixture.server.stop() }

        let infiniteID = try await protocolPost(
            fixture: fixture,
            headers: [:],
            body: [:],
            rawBody: Data(#"{"jsonrpc":"2.0","id":-1e999,"method":"ping"}"#.utf8)
        )
        #expect(protocolErrorCode(infiniteID) == -32700)

        let overlappingMarkers = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/call", name: "=?base64?="),
            body: modernRequest(method: "tools/call", params: ["name": "anything", "arguments": [:]])
        )
        #expect(protocolErrorCode(overlappingMarkers) != nil)

        let stillServing = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "ping"),
            body: modernRequest(method: "ping")
        )
        #expect(stillServing.statusCode == 200)
    }

    @Test func modernValidationUsesFinalErrorCodesAndLegacyShapesStayLegacy() async throws {
        let fixture = try await ProtocolServerFixture(tools: [
            protocolTool(id: "legacy_widget", category: .reminders)
        ])
        defer { fixture.server.stop() }

        // An exact modern header is an explicit modern claim and never silently
        // downgrades, even when the request omits the modern envelope.
        let missingMeta = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "ping"),
            body: ["jsonrpc": "2.0", "id": 1, "method": "ping", "params": [:]]
        )
        #expect(missingMeta.statusCode == 400)
        #expect(protocolErrorCode(missingMeta) == -32602)

        let missingClientCapabilities = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "ping"),
            body: [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "ping",
                "params": [
                    "_meta": [
                        "io.modelcontextprotocol/protocolVersion": "2026-07-28"
                    ]
                ]
            ]
        )
        #expect(missingClientCapabilities.statusCode == 400)
        #expect(protocolErrorCode(missingClientCapabilities) == -32602)
        #expect(
            protocolErrorMessage(missingClientCapabilities)
                == "Modern MCP requests require protocolVersion and clientCapabilities metadata."
        )
        let missingClientCapabilitiesData = try #require(
            protocolErrorData(missingClientCapabilities)
        )
        #expect(
            Set(try #require(missingClientCapabilitiesData["supported"] as? [String]))
                == protocolModernVersions
        )

        let unsupported = try await protocolPost(
            fixture: fixture,
            headers: [
                "MCP-Protocol-Version": "2099-01-01",
                "Mcp-Method": "ping"
            ],
            body: modernRequest(method: "ping", protocolVersion: "2099-01-01")
        )
        #expect(unsupported.statusCode == 400)
        #expect(protocolErrorCode(unsupported) == -32022)
        #expect(protocolErrorMessage(unsupported) == "Unsupported protocol version.")
        let unsupportedData = try #require(
            (unsupported.json["error"] as? [String: Any])?["data"] as? [String: Any]
        )
        #expect(unsupportedData["requested"] as? String == "2099-01-01")
        #expect(
            Set(try #require(unsupportedData["supported"] as? [String]))
                == protocolModernVersions
        )

        let mismatch = try await protocolPost(
            fixture: fixture,
            headers: [
                "MCP-Protocol-Version": "2025-11-25",
                "Mcp-Method": "ping"
            ],
            body: modernRequest(method: "ping")
        )
        #expect(mismatch.statusCode == 400)
        #expect(protocolErrorCode(mismatch) == -32020)

        let missingMethodHeader = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2026-07-28"],
            body: modernRequest(method: "ping")
        )
        #expect(missingMethodHeader.statusCode == 400)
        #expect(protocolErrorCode(missingMethodHeader) == -32020)

        let unknown = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "unknown/method"),
            body: modernRequest(method: "unknown/method")
        )
        #expect(unknown.statusCode == 404)
        #expect(protocolErrorCode(unknown) == -32601)

        for version in ["2025-11-25", "2025-06-18", "2025-03-26"] {
            let initialize = try await protocolPost(
                fixture: fixture,
                headers: version == "2025-03-26" ? [:] : ["MCP-Protocol-Version": version],
                body: [
                    "jsonrpc": "2.0",
                    "id": version,
                    "method": "initialize",
                    "params": [
                        "protocolVersion": version,
                        "capabilities": [:],
                        "clientInfo": ["name": "Legacy Test", "version": "1"]
                    ]
                ]
            )
            #expect(initialize.statusCode == 200)
            let result = try #require(initialize.json["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == version)
            #expect(result["serverInfo"] != nil)
            #expect(result["resultType"] == nil)
            #expect(result["ttlMs"] == nil)
            #expect(result["cacheScope"] == nil)
            let legacyCapabilities = try #require(result["capabilities"] as? [String: Any])
            #expect(legacyCapabilities["extensions"] == nil)
        }

        let legacyCompatibilityList = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-list",
                "method": "tools/list"
            ]
        )
        let legacyCompatibilityResult = try #require(
            legacyCompatibilityList.json["result"] as? [String: Any]
        )
        let legacyCompatibilityTools = try #require(
            legacyCompatibilityResult["tools"] as? [[String: Any]]
        )
        let legacyCompatibilityMeta = try #require(
            legacyCompatibilityTools.first?["_meta"] as? [String: Any]
        )
        #expect(legacyCompatibilityMeta["ui"] == nil)
        #expect(legacyCompatibilityMeta["ui/resourceUri"] != nil)
        #expect(legacyCompatibilityMeta["openai/outputTemplate"] != nil)

        let legacyApps = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-apps",
                "method": "initialize",
                "params": [
                    "protocolVersion": "2025-11-25",
                    "capabilities": [
                        "extensions": [
                            "io.modelcontextprotocol/ui": [
                                "mimeTypes": ["text/html;profile=mcp-app"]
                            ]
                        ]
                    ],
                    "clientInfo": ["name": "Legacy Apps Test", "version": "1"]
                ]
            ]
        )
        let legacyAppsResult = try #require(legacyApps.json["result"] as? [String: Any])
        let legacyAppsCapabilities = try #require(
            legacyAppsResult["capabilities"] as? [String: Any]
        )
        let legacyExtensions = try #require(
            legacyAppsCapabilities["extensions"] as? [String: Any]
        )
        #expect(Set(legacyExtensions.keys) == ["io.modelcontextprotocol/ui"])

        let legacyAppsList = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-apps-list",
                "method": "tools/list"
            ]
        )
        let legacyAppsListResult = try #require(
            legacyAppsList.json["result"] as? [String: Any]
        )
        let legacyAppsTools = try #require(
            legacyAppsListResult["tools"] as? [[String: Any]]
        )
        let legacyAppsMeta = try #require(
            legacyAppsTools.first?["_meta"] as? [String: Any]
        )
        #expect(legacyAppsMeta["ui"] != nil)
        #expect(legacyAppsMeta["ui/resourceUri"] != nil)
        #expect(legacyAppsMeta["openai/outputTemplate"] != nil)
    }

    @Test func unsupportedProtocolVersionHeaderAloneRenegotiatesInsteadOfDemandingModernMetadata()
        async throws
    {
        let fixture = try await ProtocolServerFixture(tools: [protocolTool(id: "test_echo")])
        defer { fixture.server.stop() }

        // A header-only client (no modern `_meta`) that names a version we do not
        // speak must be told what we *do* speak. Regular ChatGPT sends exactly this
        // shape, and the pre-fix server answered with the modern-envelope -32602,
        // which gave the client nothing to renegotiate against.
        for requested in ["2024-11-05", "2027-01-01"] {
            for method in ["tools/list", "ping"] {
                let response = try await protocolPost(
                    fixture: fixture,
                    headers: ["MCP-Protocol-Version": requested],
                    body: [
                        "jsonrpc": "2.0",
                        "id": "unsupported-\(requested)-\(method)",
                        "method": method
                    ]
                )
                #expect(response.statusCode == 400)
                #expect(protocolErrorCode(response) == -32022)
                #expect(protocolErrorMessage(response) == "Unsupported protocol version.")
                #expect(
                    protocolErrorMessage(response)
                        != "Modern MCP requests require protocolVersion and clientCapabilities metadata.",
                    "An unsupported version must never dead-end in the modern envelope error."
                )
                let data = try #require(protocolErrorData(response))
                #expect(data["requested"] as? String == requested)
                let supported = try #require(data["supported"] as? [String])
                #expect(supported == ["2025-11-25", "2025-06-18", "2025-03-26"])
                #expect(
                    protocolHeader(response.headers, named: "MCP-Protocol-Version")
                        == "2025-11-25"
                )
            }
        }

        // The same unsupported header with params present but no modern `_meta`
        // keys stays on the renegotiation path.
        let withParams = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2024-11-05"],
            body: [
                "jsonrpc": "2.0",
                "id": "unsupported-with-params",
                "method": "tools/call",
                "params": [
                    "name": "test_echo",
                    "arguments": [:]
                ]
            ]
        )
        #expect(withParams.statusCode == 400)
        #expect(protocolErrorCode(withParams) == -32022)
        #expect(protocolErrorMessage(withParams) == "Unsupported protocol version.")
        #expect(
            (try #require(protocolErrorData(withParams)))["requested"] as? String == "2024-11-05"
        )
    }

    @Test func legacyRenegotiationHintStaysLegacyAndReachesAWorkingSession() async throws {
        let fixture = try await ProtocolServerFixture(tools: [protocolTool(id: "test_echo")])
        defer { fixture.server.stop() }

        // A legacy-shaped request gets a legacy-only counter-offer. It must
        // never be invited into the modern era without a modern envelope.
        let refused = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2025-01-08"],
            body: ["jsonrpc": "2.0", "id": "reneg-1", "method": "tools/list"]
        )
        #expect(protocolErrorCode(refused) == -32022)
        let refusedData = try #require(protocolErrorData(refused))
        let supported = try #require(refusedData["supported"] as? [String])
        let newestAdvertised = try #require(supported.first)
        #expect(newestAdvertised == "2025-11-25")
        #expect(Set(supported) == protocolLegacyVersions)

        // The client follows the offer through legacy initialize.
        let initialize = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": newestAdvertised],
            body: [
                "jsonrpc": "2.0",
                "id": "reneg-2",
                "method": "initialize",
                "params": [
                    "protocolVersion": newestAdvertised,
                    "capabilities": [:] as [String: Any],
                    "clientInfo": ["name": "loop-client", "version": "1.0"]
                ]
            ]
        )
        #expect(initialize.statusCode == 200)
        let initializeResult = try #require(initialize.json["result"] as? [String: Any])
        #expect(initializeResult["protocolVersion"] as? String == "2025-11-25")
        #expect(
            initializeResult["serverInfo"] != nil,
            "Legacy initialize keeps its top-level serverInfo shape."
        )

        // ChatGPT adds only the modern-shaped clientCapabilities field to the
        // subsequent legacy call. It is inert without a protocolVersion claim.
        let call = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": newestAdvertised],
            body: [
                "jsonrpc": "2.0",
                "id": "reneg-3",
                "method": "tools/call",
                "params": [
                    "name": "test_echo",
                    "arguments": [:] as [String: Any],
                    "_meta": [
                        "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]
                    ]
                ]
            ]
        )
        #expect(call.statusCode == 200)
        #expect(call.json["error"] == nil)
        #expect((call.json["result"] as? [String: Any]) != nil)
        #expect(
            protocolHeader(call.headers, named: "MCP-Protocol-Version") == "2025-11-25"
        )
    }

    @Test func protocolEraRoutingUsesDiscoverModernHeaderAndModernMetadataOnly() async throws {
        let fixture = try await ProtocolServerFixture(tools: [protocolTool(id: "test_echo")])
        defer { fixture.server.stop() }

        // (a) Claimless discovery stays legacy and returns Method not found so
        // a dual-era client can fall back to initialize.
        let discoverWithoutHeader = try await protocolPost(
            fixture: fixture,
            headers: [:],
            body: [
                "jsonrpc": "2.0",
                "id": "discover-no-header",
                "method": "server/discover",
                "params": [:]
            ]
        )
        #expect(discoverWithoutHeader.statusCode == 200)
        #expect(protocolErrorCode(discoverWithoutHeader) == -32601)
        #expect(
            protocolHeader(discoverWithoutHeader.headers, named: "MCP-Protocol-Version")
                == "2025-03-26"
        )

        // (b) The exact modern header is a modern claim and cannot downgrade.
        let modernHeaderWithoutMeta = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2026-07-28"],
            body: [
                "jsonrpc": "2.0",
                "id": "modern-header-no-meta",
                "method": "tools/list"
            ]
        )
        #expect(modernHeaderWithoutMeta.statusCode == 400)
        #expect(protocolErrorCode(modernHeaderWithoutMeta) == -32602)

        // (c) A full modern `_meta` envelope routes modern even with no header at
        // all, so it fails on the missing header rather than on the envelope.
        let envelopeWithoutHeader = try await protocolPost(
            fixture: fixture,
            headers: [:],
            body: modernRequest(method: "ping")
        )
        #expect(envelopeWithoutHeader.statusCode == 400)
        #expect(protocolErrorCode(envelopeWithoutHeader) == -32020)
        #expect(
            protocolErrorMessage(envelopeWithoutHeader) == "Missing MCP-Protocol-Version header."
        )

        // A protocolVersion key is a modern claim even without its companion.
        let versionOnly = try await protocolPost(
            fixture: fixture,
            headers: [:],
            body: [
                "jsonrpc": "2.0",
                "id": "version-only",
                "method": "tools/list",
                "params": [
                    "_meta": [
                        "io.modelcontextprotocol/protocolVersion": "2026-07-28"
                    ]
                ]
            ]
        )
        #expect(versionOnly.statusCode == 400)
        #expect(protocolErrorCode(versionOnly) == -32602)

        // A clientCapabilities object alone does not claim a version. This is
        // the exact hybrid field ChatGPT adds to otherwise legacy requests.
        for headers in [
            [String: String](),
            ["MCP-Protocol-Version": "2025-11-25"]
        ] {
            let capabilitiesOnly = try await protocolPost(
                fixture: fixture,
                headers: headers,
                body: [
                    "jsonrpc": "2.0",
                    "id": "capabilities-only",
                    "method": "tools/list",
                    "params": [
                        "_meta": [
                            "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]
                        ]
                    ]
                ]
            )
            #expect(capabilitiesOnly.statusCode == 200)
            #expect((capabilitiesOnly.json["result"] as? [String: Any])?["tools"] != nil)
            #expect((capabilitiesOnly.json["result"] as? [String: Any])?["resultType"] == nil)
        }

        // The same incomplete metadata under an exact modern header is still
        // malformed modern MCP and never executes as legacy.
        let modernCapabilitiesOnly = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2026-07-28"],
            body: [
                "jsonrpc": "2.0",
                "id": "modern-capabilities-only",
                "method": "tools/list",
                "params": [
                    "_meta": [
                        "io.modelcontextprotocol/clientCapabilities": [:] as [String: Any]
                    ]
                ]
            ]
        )
        #expect(modernCapabilitiesOnly.statusCode == 400)
        #expect(protocolErrorCode(modernCapabilitiesOnly) == -32602)

        // Legacy header plus a plain body is served, not classified as modern.
        for legacyVersion in ["2025-11-25", "2025-06-18", "2025-03-26"] {
            let legacy = try await protocolPost(
                fixture: fixture,
                headers: ["MCP-Protocol-Version": legacyVersion],
                body: [
                    "jsonrpc": "2.0",
                    "id": "legacy-\(legacyVersion)",
                    "method": "tools/list"
                ]
            )
            #expect(legacy.statusCode == 200)
            let result = try #require(legacy.json["result"] as? [String: Any])
            #expect(result["tools"] as? [[String: Any]] != nil)
            #expect(result["resultType"] == nil)
        }

        // No header and no modern `_meta` is the legacy path.
        let headerless = try await protocolPost(
            fixture: fixture,
            headers: [:],
            body: [
                "jsonrpc": "2.0",
                "id": "headerless",
                "method": "tools/list"
            ]
        )
        #expect(headerless.statusCode == 200)
        let headerlessResult = try #require(headerless.json["result"] as? [String: Any])
        #expect(headerlessResult["tools"] as? [[String: Any]] != nil)
        #expect(headerlessResult["resultType"] == nil)

        // A complete modern request still succeeds.
        let modern = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "ping"),
            body: modernRequest(method: "ping")
        )
        #expect(modern.statusCode == 200)
        #expect(modern.json["result"] as? [String: Any] != nil)
        #expect(protocolHeader(modern.headers, named: "MCP-Protocol-Version") == "2026-07-28")
    }

    @Test func legacyInitializeStillNegotiatesDownFromUnlistedProtocolVersions() async throws {
        let fixture = try await ProtocolServerFixture(tools: [protocolTool(id: "test_echo")])
        defer { fixture.server.stop() }

        // Renegotiation for header-only clients must not disturb the legacy
        // initialize handshake, which silently settles on the newest legacy
        // version when the client asks for something we do not list.
        let unlistedVersions: [String?] = ["2024-11-05", "2027-01-01", nil]
        for requested in unlistedVersions {
            var params: [String: Any] = [
                "capabilities": [:],
                "clientInfo": ["name": "Legacy Downgrade Test", "version": "1"]
            ]
            if let requested {
                params["protocolVersion"] = requested
            }

            let headerless = try await protocolPost(
                fixture: fixture,
                headers: [:],
                body: [
                    "jsonrpc": "2.0",
                    "id": "initialize-\(requested ?? "absent")",
                    "method": "initialize",
                    "params": params
                ]
            )
            #expect(headerless.statusCode == 200)
            let headerlessResult = try #require(headerless.json["result"] as? [String: Any])
            #expect(headerlessResult["protocolVersion"] as? String == "2025-11-25")
            #expect(headerlessResult["serverInfo"] != nil)

            let legacyHeader = try await protocolPost(
                fixture: fixture,
                headers: ["MCP-Protocol-Version": "2025-06-18"],
                body: [
                    "jsonrpc": "2.0",
                    "id": "initialize-legacy-header-\(requested ?? "absent")",
                    "method": "initialize",
                    "params": params
                ]
            )
            #expect(legacyHeader.statusCode == 200)
            let legacyHeaderResult = try #require(legacyHeader.json["result"] as? [String: Any])
            #expect(legacyHeaderResult["protocolVersion"] as? String == "2025-11-25")
        }
    }

    @Test func modernCatalogIsDeterministicCacheableAndCapabilityScoped() async throws {
        let fixture = try await ProtocolServerFixture(tools: [
            protocolTool(id: "z_tool", category: .reminders),
            protocolTool(id: "a_tool", category: .reminders)
        ])
        defer { fixture.server.stop() }

        let withoutUI = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/list"),
            body: modernRequest(method: "tools/list")
        )
        let withoutUIResult = try #require(withoutUI.json["result"] as? [String: Any])
        #expect(withoutUIResult["resultType"] as? String == "complete")
        #expect(withoutUIResult["ttlMs"] as? Int == 0)
        #expect(withoutUIResult["cacheScope"] as? String == "private")
        let listMeta = try #require(withoutUIResult["_meta"] as? [String: Any])
        let listServerInfo = try #require(
            listMeta["io.modelcontextprotocol/serverInfo"] as? [String: Any]
        )
        try protocolExpectCanonicalServerInfo(listServerInfo, base: fixture.base)
        let withoutUITools = try #require(withoutUIResult["tools"] as? [[String: Any]])
        #expect(withoutUITools.compactMap { $0["name"] as? String } == ["a_tool", "z_tool"])
        let plainMeta = try #require(withoutUITools.first?["_meta"] as? [String: Any])
        #expect(plainMeta["ui"] == nil)

        let extensionWithoutMIME = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/list"),
            body: modernRequest(
                method: "tools/list",
                capabilities: [
                    "extensions": [
                        "io.modelcontextprotocol/ui": [:]
                    ]
                ]
            )
        )
        let extensionWithoutMIMEResult = try #require(
            extensionWithoutMIME.json["result"] as? [String: Any]
        )
        let extensionWithoutMIMETools = try #require(
            extensionWithoutMIMEResult["tools"] as? [[String: Any]]
        )
        let extensionWithoutMIMEMeta = try #require(
            extensionWithoutMIMETools.first?["_meta"] as? [String: Any]
        )
        #expect(extensionWithoutMIMEMeta["ui"] == nil)

        let uiCapabilities: [String: Any] = [
            "extensions": [
                "io.modelcontextprotocol/ui": [
                    "mimeTypes": ["text/html;profile=mcp-app"]
                ]
            ]
        ]
        let withUI = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/list"),
            body: modernRequest(method: "tools/list", capabilities: uiCapabilities)
        )
        let withUIResult = try #require(withUI.json["result"] as? [String: Any])
        let withUITools = try #require(withUIResult["tools"] as? [[String: Any]])
        let enhancedMeta = try #require(withUITools.first?["_meta"] as? [String: Any])
        #expect(enhancedMeta["ui"] != nil)

        let resourcesWithoutUI = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "resources/list"),
            body: modernRequest(method: "resources/list")
        )
        let coreResources = try #require(
            (resourcesWithoutUI.json["result"] as? [String: Any])?["resources"] as? [[String: Any]]
        )
        #expect(coreResources.count == 1)

        let resourcesWithUI = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "resources/list"),
            body: modernRequest(method: "resources/list", capabilities: uiCapabilities)
        )
        let enhancedResources = try #require(
            (resourcesWithUI.json["result"] as? [String: Any])?["resources"] as? [[String: Any]]
        )
        #expect(enhancedResources.count == 2)

        // The widget's sandbox policy is not capability-scoped the way linkage
        // and the resource listing are. `_meta` is ignorable, so a client that
        // never declared Apps loses nothing by receiving `ui`; withholding it
        // drops `ui.csp`, and a host with no CSP falls back to a default that
        // blocks the widget's one external origin. Both modern paths — with
        // and without the capability — carry the allowlist for the current
        // resource and every compatibility URI.
        let widgetURI = "ui://macremote/output-v7.html"
        for readableURI in MCPAppsMetadata.readableResourceURIs {
            for capabilities in [[:], uiCapabilities] as [[String: Any]] {
                let read = try await protocolPost(
                    fixture: fixture,
                    headers: modernHeaders(method: "resources/read", name: readableURI),
                    body: modernRequest(
                        method: "resources/read",
                        params: ["uri": readableURI],
                        capabilities: capabilities
                    )
                )
                let contents = try #require(
                    (read.json["result"] as? [String: Any])?["contents"]
                        as? [[String: Any]]
                )
                #expect(contents.first?["uri"] as? String == readableURI)
                let contentMeta = try #require(
                    contents.first?["_meta"] as? [String: Any]
                )
                let contentUI = try #require(contentMeta["ui"] as? [String: Any])
                let contentCSP = try #require(contentUI["csp"] as? [String: Any])
                #expect(
                    contentCSP["resourceDomains"] as? [String]
                        == ["https://static.pocketcasts.com"]
                )
                #expect((contentCSP["connectDomains"] as? [String])?.isEmpty == true)
            }
        }

        // The listed descriptor declares the same policy the read result does.
        let listedWidget = try #require(
            enhancedResources.first { $0["uri"] as? String == widgetURI }
        )
        let listedWidgetMeta = try #require(listedWidget["_meta"] as? [String: Any])
        let listedWidgetUI = try #require(listedWidgetMeta["ui"] as? [String: Any])
        #expect(
            (listedWidgetUI["csp"] as? [String: Any])?["resourceDomains"] as? [String]
                == ["https://static.pocketcasts.com"]
        )

        let missingResourceURI = "ui://macremote/does-not-exist"
        let missingResource = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "resources/read", name: missingResourceURI),
            body: modernRequest(method: "resources/read", params: ["uri": missingResourceURI])
        )
        #expect(missingResource.statusCode == 200)
        #expect(protocolErrorCode(missingResource) == -32602)

        let legacyMissingResource = try await protocolPost(
            fixture: fixture,
            headers: ["MCP-Protocol-Version": "2025-11-25"],
            body: [
                "jsonrpc": "2.0",
                "id": "legacy-resource",
                "method": "resources/read",
                "params": ["uri": missingResourceURI]
            ]
        )
        #expect(legacyMissingResource.statusCode == 200)
        #expect(protocolErrorCode(legacyMissingResource) == -32002)
    }

    @Test func modernMirroredHeadersDecodeAndValidateToolParameters() async throws {
        let headerParameter = ToolParameter(
            name: "region",
            title: "Region",
            kind: .string,
            jsonSchema: .object(["x-mcp-header": .string("Region")])
        )
        let invalidHeaderParameter = ToolParameter(
            name: "ratio",
            title: "Ratio",
            kind: .number,
            jsonSchema: .object(["x-mcp-header": .string("Ratio")])
        )
        let integerHeaderParameter = ToolParameter(
            name: "count",
            title: "Count",
            kind: .integer,
            jsonSchema: .object(["x-mcp-header": .string("Count")])
        )
        let booleanHeaderParameter = ToolParameter(
            name: "enabled",
            title: "Enabled",
            kind: .boolean,
            jsonSchema: .object(["x-mcp-header": .string("Enabled")])
        )
        let refHeaderParameter = ToolParameter(
            name: "payload",
            title: "Payload",
            kind: .json,
            jsonSchema: .object([
                "type": .string("object"),
                "$ref": .string("#/$defs/headerValue"),
                "$defs": .object([
                    "headerValue": .object([
                        "type": .string("string"),
                        "x-mcp-header": .string("ViaRef")
                    ])
                ])
            ])
        )
        let composedHeaderParameter = ToolParameter(
            name: "payload",
            title: "Payload",
            kind: .json,
            jsonSchema: .object([
                "type": .string("object"),
                "allOf": .array([
                    .object([
                        "type": .string("string"),
                        "x-mcp-header": .string("AllOf")
                    ])
                ]),
                "anyOf": .array([
                    .object([
                        "type": .string("integer"),
                        "x-mcp-header": .string("AnyOf")
                    ])
                ]),
                "oneOf": .array([
                    .object([
                        "type": .string("boolean"),
                        "x-mcp-header": .string("OneOf")
                    ])
                ])
            ])
        )
        let fixture = try await ProtocolServerFixture(tools: [
            protocolTool(id: "header_tool", parameters: [headerParameter]),
            protocolTool(
                id: "typed_header_tool",
                parameters: [integerHeaderParameter, booleanHeaderParameter]
            ),
            protocolTool(id: "invalid_header_tool", parameters: [invalidHeaderParameter]),
            protocolTool(id: "ref_header_tool", parameters: [refHeaderParameter]),
            protocolTool(id: "composed_header_tool", parameters: [composedHeaderParameter])
        ])
        defer { fixture.server.stop() }

        let listed = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/list"),
            body: modernRequest(method: "tools/list")
        )
        let tools = try #require((listed.json["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let validSchema = try #require(
            tools.first { $0["name"] as? String == "header_tool" }?["inputSchema"] as? [String: Any]
        )
        let validProperties = try #require(validSchema["properties"] as? [String: Any])
        let regionSchema = try #require(validProperties["region"] as? [String: Any])
        #expect(regionSchema["x-mcp-header"] as? String == "Region")

        let invalidSchema = try #require(
            tools.first { $0["name"] as? String == "invalid_header_tool" }?["inputSchema"] as? [String: Any]
        )
        #expect(protocolContainsKey("x-mcp-header", in: invalidSchema) == false)
        let refSchema = try #require(
            tools.first { $0["name"] as? String == "ref_header_tool" }?["inputSchema"] as? [String: Any]
        )
        #expect(
            protocolContainsKey("x-mcp-header", in: refSchema) == false,
            "Mirrored headers cannot become statically reachable through $ref."
        )
        let composedSchema = try #require(
            tools.first { $0["name"] as? String == "composed_header_tool" }?["inputSchema"]
                as? [String: Any]
        )
        #expect(
            protocolContainsKey("x-mcp-header", in: composedSchema) == false,
            "Mirrored headers in composition branches are unreachable."
        )

        let missingHeader = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/call", name: "header_tool"),
            body: modernRequest(
                method: "tools/call",
                params: ["name": "header_tool", "arguments": ["region": " padded "]]
            )
        )
        #expect(missingHeader.statusCode == 400)
        #expect(protocolErrorCode(missingHeader) == -32020)

        let encodedValue = "=?base64?\(Data(" padded ".utf8).base64EncodedString())?="
        let validCall = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/call", name: "header_tool").merging([
                "Mcp-Param-Region": encodedValue
            ]) { _, new in new },
            body: modernRequest(
                method: "tools/call",
                params: ["name": "header_tool", "arguments": ["region": " padded "]]
            )
        )
        #expect(validCall.statusCode == 200)
        let validResult = try #require(validCall.json["result"] as? [String: Any])
        #expect(validResult["resultType"] as? String == "complete")
        #expect(validResult["isError"] as? Bool == false)

        let emptyValue = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/call", name: "header_tool").merging([
                "Mcp-Param-Region": ""
            ]) { _, new in new },
            body: modernRequest(
                method: "tools/call",
                params: ["name": "header_tool", "arguments": ["region": ""]]
            )
        )
        #expect(emptyValue.statusCode == 200)
        #expect((emptyValue.json["result"] as? [String: Any])?["isError"] as? Bool == false)

        let typedCases: [(header: String, value: String, arguments: [String: Any])] = [
            ("Mcp-Param-Count", "0", ["count": 0]),
            ("Mcp-Param-Count", "1", ["count": 1]),
            ("Mcp-Param-Enabled", "false", ["enabled": false]),
            ("Mcp-Param-Enabled", "true", ["enabled": true])
        ]
        for typedCase in typedCases {
            let response = try await protocolPost(
                fixture: fixture,
                headers: modernHeaders(
                    method: "tools/call",
                    name: "typed_header_tool"
                ).merging([
                    typedCase.header: typedCase.value
                ]) { _, new in new },
                body: modernRequest(
                    method: "tools/call",
                    params: [
                        "name": "typed_header_tool",
                        "arguments": typedCase.arguments
                    ]
                )
            )
            #expect(response.statusCode == 200)
            #expect((response.json["result"] as? [String: Any])?["isError"] as? Bool == false)
        }
        for mismatchedCase in [
            (header: "Mcp-Param-Count", value: "false", arguments: ["count": false]),
            (header: "Mcp-Param-Enabled", value: "0", arguments: ["enabled": 0])
        ] {
            let response = try await protocolPost(
                fixture: fixture,
                headers: modernHeaders(
                    method: "tools/call",
                    name: "typed_header_tool"
                ).merging([
                    mismatchedCase.header: mismatchedCase.value
                ]) { _, new in new },
                body: modernRequest(
                    method: "tools/call",
                    params: [
                        "name": "typed_header_tool",
                        "arguments": mismatchedCase.arguments
                    ]
                )
            )
            #expect(response.statusCode == 400)
            #expect(protocolErrorCode(response) == -32020)
        }

        let catalogURI = "macremote://catalog/v1"
        let encodedName = "=?base64?\(Data(catalogURI.utf8).base64EncodedString())?="
        let encodedResourceName = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "resources/read", name: encodedName),
            body: modernRequest(method: "resources/read", params: ["uri": catalogURI])
        )
        #expect(encodedResourceName.statusCode == 200)
        #expect(encodedResourceName.json["result"] != nil)
    }

    @Test func modernCatalogFailsClosedForOverBudgetBridgeSchemas() async throws {
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
        let wideProperties = Dictionary(
            uniqueKeysWithValues: (0..<4_100).map {
                ("value\($0)", JSONValue.object(["type": .string("string")]))
            }
        )
        let wideSchema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(wideProperties)
        ])
        let fixture = try await ProtocolServerFixture(tools: [
            protocolBridgeTool(id: "deep_bridge", inputSchema: deepSchema),
            protocolBridgeTool(id: "wide_bridge", inputSchema: wideSchema)
        ])
        defer { fixture.server.stop() }

        let listed = try await protocolPost(
            fixture: fixture,
            headers: modernHeaders(method: "tools/list"),
            body: modernRequest(method: "tools/list")
        )

        #expect(listed.statusCode == 200)
        let tools = try #require(
            (listed.json["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        )
        #expect(tools.count == 2)
        for tool in tools {
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
            #expect((schema["properties"] as? [String: Any])?.isEmpty == true)
            #expect(schema["additionalProperties"] as? Bool == false)
            #expect(protocolContainsKey("x-mcp-header", in: schema) == false)
        }
    }

    @Test func modernCORSAndAuthorizationMetadataAdvertiseRequiredHeadersAndIssuer() async throws {
        let fixture = try await ProtocolServerFixture(tools: [])
        defer { fixture.server.stop() }

        let preflight = try await protocolRequest(
            method: "OPTIONS",
            url: fixture.mcpURL,
            headers: [
                "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers":
                    "authorization, content-type, mcp-protocol-version, mcp-method, mcp-name, mcp-param-region"
            ]
        )
        #expect(preflight.statusCode == 204)
        let allowedHeaders = protocolHeader(preflight.headers, named: "Access-Control-Allow-Headers") ?? ""
        for name in ["mcp-protocol-version", "mcp-method", "mcp-name", "mcp-param-region"] {
            #expect(allowedHeaders.contains(name))
        }

        let metadata = try await protocolRequest(
            method: "GET",
            url: fixture.base.appendingPathComponent(".well-known/oauth-authorization-server")
        )
        let metadataJSON = try protocolDecodeJSON(metadata.data)
        #expect(metadataJSON["authorization_response_iss_parameter_supported"] as? Bool == true)
    }
}

private struct ProtocolServerFixture {
    let server: LocalMCPServer
    let base: URL
    let mcpURL: URL
    let token: String

    init(tools: [ToolDefinition]) async throws {
        let token = "protocol-conformance-token-\(UUID().uuidString)"
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(token, clientName: "Protocol Conformance")
        let server = LocalMCPServer(
            instanceID: "protocol-test",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: ProtocolToolExecutor()
        )
        let port = try server.start()
        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        self.server = server
        self.base = base
        self.mcpURL = base.appendingPathComponent("mcp/protocol-test")
        self.token = token
        try await protocolWaitForServer(base: base)
    }
}

private struct ProtocolToolExecutor: ToolExecuting {
    func execute(
        toolID: String,
        parameters: [String: ToolArgumentValue]
    ) async throws -> ToolExecutionOutcome {
        ToolExecutionOutcome(
            toolID: toolID,
            toolName: toolID,
            exitCode: 0,
            stdout: parameters["region"]?.stringValue ?? "ok",
            stderr: "",
            duration: 0.001,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private func protocolTool(
    id: String,
    parameters: [ToolParameter] = [],
    category: ToolCategory = .utilities,
    capability: ToolCapability = .readOnly
) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: id,
        summary: "Protocol conformance fixture.",
        executablePath: "/bin/echo",
        argumentPattern: parameters.map { "{\($0.name)}" },
        parameters: parameters,
        capability: capability,
        timeoutSeconds: 2,
        outputByteLimit: 1024,
        category: category
    )
}

private func protocolBridgeTool(
    id: String,
    inputSchema: JSONValue
) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: id,
        summary: "Protocol bridge conformance fixture.",
        executablePath: "",
        argumentPattern: [],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: 2,
        outputByteLimit: 1024,
        category: .developer,
        backend: .mcpHTTPBridge,
        mcpBridge: MCPBridgeConfiguration(
            serverName: "fixture",
            serverURL: "http://127.0.0.1:4999/mcp",
            toolName: id,
            inputSchema: inputSchema
        )
    )
}

private func modernRequest(
    method: String,
    protocolVersion: String = "2026-07-28",
    params: [String: Any] = [:],
    capabilities: [String: Any] = [:]
) -> [String: Any] {
    var params = params
    params["_meta"] = [
        "io.modelcontextprotocol/protocolVersion": protocolVersion,
        "io.modelcontextprotocol/clientCapabilities": capabilities,
        "io.modelcontextprotocol/clientInfo": [
            "name": "MacRemote Protocol Tests",
            "version": "1"
        ]
    ]
    return [
        "jsonrpc": "2.0",
        "id": UUID().uuidString,
        "method": method,
        "params": params
    ]
}

private func modernHeaders(method: String, name: String? = nil) -> [String: String] {
    var headers = [
        "MCP-Protocol-Version": "2026-07-28",
        "Mcp-Method": method
    ]
    if let name {
        headers["Mcp-Name"] = name
    }
    return headers
}

private func protocolExpectCanonicalServerInfo(
    _ serverInfo: [String: Any],
    base: URL,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    #expect(
        serverInfo["name"] as? String == MacRemoteProductInfo.name,
        sourceLocation: sourceLocation
    )
    #expect(
        serverInfo["version"] as? String == MacRemoteProductInfo.version,
        sourceLocation: sourceLocation
    )
    #expect(
        serverInfo["websiteUrl"] as? String == MacRemoteProductInfo.websiteURL,
        sourceLocation: sourceLocation
    )
    let icons = try #require(
        serverInfo["icons"] as? [[String: Any]],
        sourceLocation: sourceLocation
    )
    let remoteIconURLs = icons.compactMap { icon -> URL? in
        guard let source = icon["src"] as? String,
              !source.hasPrefix("data:") else {
            return nil
        }
        return URL(string: source)
    }
    #expect(remoteIconURLs.count == 2, sourceLocation: sourceLocation)
    #expect(
        Set(remoteIconURLs.map(\.path)) == [
            "/macremote-icon-128.png",
            "/macremote-icon.png"
        ],
        sourceLocation: sourceLocation
    )
    for iconURL in remoteIconURLs {
        #expect(iconURL.scheme == base.scheme, sourceLocation: sourceLocation)
        #expect(iconURL.host == base.host, sourceLocation: sourceLocation)
        #expect(iconURL.port == base.port, sourceLocation: sourceLocation)
    }
}

private func protocolPost(
    fixture: ProtocolServerFixture,
    authenticated: Bool = true,
    headers: [String: String],
    body: [String: Any],
    rawBody: Data? = nil
) async throws -> (
    statusCode: Int,
    json: [String: Any],
    headers: [AnyHashable: Any],
    data: Data
) {
    var headers = headers
    headers["Content-Type"] = "application/json"
    if authenticated {
        headers["Authorization"] = "Bearer \(fixture.token)"
    }
    var request = URLRequest(url: fixture.mcpURL)
    request.httpMethod = "POST"
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    request.httpBody = try rawBody ?? JSONSerialization.data(withJSONObject: body)
    let response = try await URLSession.shared.data(for: request)
    let http = try #require(response.1 as? HTTPURLResponse)
    return (
        http.statusCode,
        (try? protocolDecodeJSON(response.0)) ?? [:],
        http.allHeaderFields,
        response.0
    )
}

private func protocolRequest(
    method: String,
    url: URL,
    headers: [String: String] = [:]
) async throws -> (statusCode: Int, data: Data, headers: [AnyHashable: Any]) {
    var request = URLRequest(url: url)
    request.httpMethod = method
    for (name, value) in headers {
        request.setValue(value, forHTTPHeaderField: name)
    }
    let response = try await URLSession.shared.data(for: request)
    let http = try #require(response.1 as? HTTPURLResponse)
    return (http.statusCode, response.0, http.allHeaderFields)
}

private func protocolWaitForServer(base: URL) async throws {
    for _ in 0..<50 {
        if let response = try? await protocolRequest(
            method: "GET",
            url: base.appendingPathComponent("health")
        ), response.statusCode == 200 {
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("Timed out waiting for protocol conformance server.")
    throw CocoaError(.fileReadUnknown)
}

private func protocolDecodeJSON(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func protocolHeader(_ headers: [AnyHashable: Any], named name: String) -> String? {
    headers.first {
        ($0.key as? String)?.caseInsensitiveCompare(name) == .orderedSame
    }?.value as? String
}

private func protocolErrorCode(
    _ response: (statusCode: Int, json: [String: Any], headers: [AnyHashable: Any], data: Data)
) -> Int? {
    (response.json["error"] as? [String: Any])?["code"] as? Int
}

private func protocolErrorMessage(
    _ response: (statusCode: Int, json: [String: Any], headers: [AnyHashable: Any], data: Data)
) -> String? {
    (response.json["error"] as? [String: Any])?["message"] as? String
}

private func protocolErrorData(
    _ response: (statusCode: Int, json: [String: Any], headers: [AnyHashable: Any], data: Data)
) -> [String: Any]? {
    (response.json["error"] as? [String: Any])?["data"] as? [String: Any]
}

private let protocolModernVersions: Set<String> = ["2026-07-28"]

private let protocolLegacyVersions: Set<String> = [
    "2025-11-25",
    "2025-06-18",
    "2025-03-26"
]

private func protocolContainsKey(_ key: String, in value: Any) -> Bool {
    if let object = value as? [String: Any] {
        return object[key] != nil || object.values.contains { protocolContainsKey(key, in: $0) }
    }
    if let array = value as? [Any] {
        return array.contains { protocolContainsKey(key, in: $0) }
    }
    return false
}
