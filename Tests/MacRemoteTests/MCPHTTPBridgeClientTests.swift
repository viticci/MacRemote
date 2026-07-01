import Foundation
import XCTest
@testable import MacRemote

final class MCPHTTPBridgeClientTests: XCTestCase {
    func testCallsStreamableHTTPServerWithSessionHeadersAndJSONArguments() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MCPBridgeURLProtocolMock.self]
        let session = URLSession(configuration: config)
        MCPBridgeURLProtocolMock.install([
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
                inputSchema: .object(["type": .string("object")]),
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

        XCTAssertTrue(outcome.succeeded)
        XCTAssertTrue(outcome.stdout.contains(#""ok":true"#))

        let requests = MCPBridgeURLProtocolMock.requests()
        XCTAssertEqual(requests.map { $0.method }, ["initialize", "notifications/initialized", "tools/call"])
        XCTAssertEqual(requests[0].headers["Authorization"], "Bearer test-token")
        XCTAssertNil(requests[0].headers["Mcp-Session-Id"])
        XCTAssertEqual(requests[1].headers["Mcp-Session-Id"], "session-1")
        XCTAssertEqual(requests[2].headers["Mcp-Session-Id"], "session-1")
        XCTAssertEqual(requests[2].headers["MCP-Protocol-Version"], "2025-06-18")

        let params = try XCTUnwrap(requests[2].body["params"] as? [String: Any])
        XCTAssertEqual(params["name"] as? String, "echo")
        let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
        let payload = try XCTUnwrap(arguments["payload"] as? [String: Any])
        XCTAssertEqual(payload["query"] as? String, "clip")
        XCTAssertEqual(payload["count"] as? Int, 2)
    }
}

private struct MCPBridgeCapturedRequest: @unchecked Sendable {
    let method: String
    let headers: [String: String]
    let body: [String: Any]
}

private struct MCPBridgeMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String], body: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(body.utf8)
    }
}

private final class MCPBridgeURLProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var responses: [MCPBridgeMockResponse] = []
    nonisolated(unsafe) private static var capturedRequests: [MCPBridgeCapturedRequest] = []

    static func install(_ newResponses: [MCPBridgeMockResponse]) {
        lock.lock()
        responses = newResponses
        capturedRequests = []
        lock.unlock()
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

        Self.lock.lock()
        Self.capturedRequests.append(MCPBridgeCapturedRequest(method: method, headers: headers, body: json))
        let response = Self.responses.isEmpty
            ? MCPBridgeMockResponse(
                statusCode: 500,
                headers: ["Content-Type": "application/json"],
                body: #"{"error":"unexpected request"}"#
            )
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
