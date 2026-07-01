import Foundation
import XCTest
@testable import MacRemote

final class LocalMCPScannerTests: XCTestCase {
    func testScansClaudeExtensionProbesToolsAndBuildsBridgeDefinitions() async throws {
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
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.id, "claude_extension.paste")
        XCTAssertEqual(candidate.displayName, "Paste")
        XCTAssertTrue(candidate.bridgeable)
        XCTAssertEqual(candidate.probe?.serverInfo.title, "Paste")
        XCTAssertEqual(candidate.probe?.tools.map(\.name), ["search", "create_item"])

        let requests = LocalMCPScannerURLProtocolMock.requests()
        XCTAssertEqual(requests.map(\.method), ["initialize", "notifications/initialized", "tools/list"])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer secret-token")
        XCTAssertEqual(requests[2].headers["Mcp-Session-Id"], "session-1")

        let tools = try scanner.bridgeTools(for: candidate)
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0].backend, .mcpHTTPBridge)
        XCTAssertEqual(tools[0].mcpBridge?.serverURL, "http://127.0.0.1:39725/mcp")
        XCTAssertEqual(tools[0].mcpBridge?.headers.first?.value, nil)
        XCTAssertEqual(tools[0].mcpBridge?.headers.first?.valueSource?.keyPath, ["server", "mcp_config", "env", "MCP_TOKEN"])
        XCTAssertEqual(tools[0].capability, .readOnly)
        XCTAssertEqual(tools[1].capability, .write)
    }

    func testScansCodexStdioServerProbesToolsAndBuildsBridgeDefinitions() async throws {
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
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.id, "codex.mock_stdio")
        XCTAssertEqual(candidate.transport, .stdio)
        XCTAssertTrue(candidate.bridgeable)
        XCTAssertNil(candidate.probeError)
        XCTAssertEqual(candidate.probe?.serverInfo.name, "mock-stdio")
        XCTAssertEqual(candidate.probe?.tools.map(\.name), ["echo"])

        let tools = try scanner.bridgeTools(for: candidate)
        let tool = try XCTUnwrap(tools.first)
        XCTAssertEqual(tool.backend, .mcpStdioBridge)
        XCTAssertEqual(tool.mcpStdioBridge?.command, serverURL.path)
        XCTAssertEqual(tool.mcpStdioBridge?.args, ["--fixture"])
        XCTAssertEqual(tool.mcpStdioBridge?.startupTimeoutSeconds, 30)
        XCTAssertEqual(tool.mcpStdioBridge?.environment.first?.value, nil)
        XCTAssertEqual(tool.mcpStdioBridge?.environment.first?.valueSource?.kind, .tomlFile)
        XCTAssertEqual(tool.mcpStdioBridge?.environment.first?.valueSource?.keyPath, ["mcp_servers", "mock_stdio", "env", "MOCK_SECRET"])

        let client = MCPStdioBridgeClient(environment: ExecutableLocator.toolEnvironment)
        let outcome = try await client.call(tool: tool, parameters: [
            "query": .string("hello")
        ])

        XCTAssertTrue(outcome.succeeded, outcome.stderr)
        XCTAssertTrue(outcome.stdout.contains(#""secret":"from-toml""#), outcome.stdout)
        XCTAssertTrue(outcome.stdout.contains(#""query":"hello""#), outcome.stdout)
    }

    func testScansCodexStdioAuthProfilesAsSeparateBridges() async throws {
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
        XCTAssertEqual(candidates.map(\.id).sorted(), ["codex.account_user", "codex.public_search"])

        let publicProfile = try XCTUnwrap(candidates.first { $0.displayName == "public-search" })
        XCTAssertEqual(publicProfile.transport, .stdio)
        XCTAssertEqual(publicProfile.probe?.tools.map(\.name), ["search_public_records"])

        let accountProfile = try XCTUnwrap(candidates.first { $0.displayName == "account-user" })
        XCTAssertEqual(accountProfile.transport, .stdio)
        XCTAssertEqual(accountProfile.startupTimeoutSeconds, 300)
        XCTAssertEqual(accountProfile.probe?.tools.map(\.name), ["get_account_bookmarks"])

        let accountTool = try XCTUnwrap(scanner.bridgeTools(for: accountProfile).first)
        XCTAssertEqual(accountTool.backend, .mcpStdioBridge)
        XCTAssertEqual(accountTool.mcpStdioBridge?.serverName, "account-user")
        XCTAssertEqual(accountTool.mcpStdioBridge?.command, accountURL.path)
        XCTAssertEqual(accountTool.mcpStdioBridge?.startupTimeoutSeconds, 300)
        XCTAssertEqual(accountTool.mcpStdioBridge?.toolName, "get_account_bookmarks")
        XCTAssertNoThrow(try ToolArgumentResolver.validate(accountTool))
    }

    func testJSONServersFallbackPreservesEnvironmentKeyPath() async throws {
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
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.id, "cursor.profile_one")
        XCTAssertEqual(candidate.environment.first?.value, nil)
        XCTAssertEqual(candidate.environment.first?.valueSource?.kind, .jsonFile)
        XCTAssertEqual(candidate.environment.first?.valueSource?.keyPath, ["servers", "profile-one", "env", "PROFILE_TOKEN"])
    }

    private static let mockStdioMCPServer = """
    #!/usr/bin/env python3
    import json
    import os
    import sys

    for line in sys.stdin:
        message = json.loads(line)
        method = message.get("method")
        if method == "initialize":
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
            print(json.dumps({
                "jsonrpc": "2.0",
                "id": message.get("id"),
                "result": {
                    "content": [{"type": "text", "text": "ok"}],
                    "structuredContent": {
                        "secret": os.environ.get("MOCK_SECRET"),
                        "arguments": params.get("arguments", {})
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
            if method == "initialize":
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
}

private struct LocalMCPScannerMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String], body: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(body.utf8)
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
        Self.capturedRequests.append(LocalMCPScannerCapturedRequest(method: method, headers: request.allHTTPHeaderFields ?? [:]))
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
}
