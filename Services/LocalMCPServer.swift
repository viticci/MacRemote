import Foundation
import Darwin
import Network

final class LocalMCPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.macremote.local-server")
    private var listener: NWListener?
    private var activePort: UInt16?
    private let instanceID: String
    private let tools: [ToolDefinition]

    init(instanceID: String, tools: [ToolDefinition]) {
        self.instanceID = instanceID
        self.tools = tools
    }

    func start() throws -> UInt16 {
        let selectedPort = try Self.availablePort()
        guard let nwPort = NWEndpoint.Port(rawValue: selectedPort) else {
            throw LocalMCPServerError.portUnavailable
        }

        let listener = try NWListener(using: .tcp, on: nwPort)
        listener.service = nil
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        self.listener = listener
        self.activePort = selectedPort
        return selectedPort
    }

    func stop() {
        listener?.cancel()
        listener = nil
        activePort = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = HTTPRequest(data: data ?? Data())
            let response = self.response(for: request)
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func response(for request: HTTPRequest) -> Data {
        guard let activePort else {
            return HTTPResponse(status: .internalServerError, body: "Server not ready").data
        }

        let base = "http://127.0.0.1:\(activePort)"

        switch (request.method, request.path) {
        case ("GET", "/health"):
            return jsonResponse([
                "ok": true,
                "service": "MacRemote",
                "instance_id": instanceID,
                "tool_profile": "remctl-readonly",
                "tool_count": tools.count
            ])
        case ("GET", "/.well-known/oauth-protected-resource"):
            return jsonResponse([
                "resource": "\(base)/mcp",
                "authorization_servers": [base],
                "scopes_supported": ["mcp:tools"]
            ])
        case ("GET", "/.well-known/oauth-authorization-server"):
            return jsonResponse([
                "issuer": base,
                "authorization_endpoint": "\(base)/authorize",
                "token_endpoint": "\(base)/token",
                "registration_endpoint": "\(base)/register",
                "response_types_supported": ["code"],
                "code_challenge_methods_supported": ["S256"]
            ])
        case ("GET", "/authorize"):
            let body = """
            <!doctype html>
            <html>
            <head><meta charset="utf-8"><title>MacRemote Approval</title></head>
            <body>
            <h1>Host approval required</h1>
            <p>Open MacRemote on this Mac to approve or deny this client.</p>
            </body>
            </html>
            """
            return HTTPResponse(
                status: .ok,
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: body
            ).data
        case ("POST", "/mcp"):
            return HTTPResponse(
                status: .unauthorized,
                headers: [
                    "WWW-Authenticate": "Bearer realm=\"mcp\", resource_metadata=\"\(base)/.well-known/oauth-protected-resource\""
                ],
                body: "{\"ok\":false,\"error\":\"authorization_required\"}"
            ).data
        default:
            return HTTPResponse(status: .notFound, body: "{\"ok\":false,\"error\":\"not_found\"}").data
        }
    }

    private func jsonResponse(_ object: [String: Any]) -> Data {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return HTTPResponse(
            status: .ok,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            bodyData: data
        ).data
    }

    private static func availablePort() throws -> UInt16 {
        let range: ClosedRange<UInt16> = 49_152...65_000
        let randomCandidates = (0..<128).map { _ in UInt16.random(in: range) }
        let deterministicCandidates = stride(from: UInt16(49_152), through: UInt16(49_300), by: 1)
        for port in randomCandidates + deterministicCandidates {
            if canBind(port: port) {
                return port
            }
        }
        throw LocalMCPServerError.portUnavailable
    }

    private static func canBind(port: UInt16) -> Bool {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { return false }
        defer { close(socketDescriptor) }

        var value: Int32 = 1
        setsockopt(socketDescriptor, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

enum LocalMCPServerError: LocalizedError {
    case portUnavailable

    var errorDescription: String? {
        switch self {
        case .portUnavailable: "Could not allocate a local server port."
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String

    init(data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        let firstLine = text.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = firstLine.split(separator: " ")
        method = parts.indices.contains(0) ? String(parts[0]) : ""
        path = parts.indices.contains(1) ? String(parts[1]) : ""
    }
}

private struct HTTPResponse {
    enum Status {
        case ok
        case unauthorized
        case notFound
        case internalServerError

        var line: String {
            switch self {
            case .ok: "200 OK"
            case .unauthorized: "401 Unauthorized"
            case .notFound: "404 Not Found"
            case .internalServerError: "500 Internal Server Error"
            }
        }
    }

    let status: Status
    let headers: [String: String]
    let bodyData: Data

    init(status: Status, headers: [String: String] = [:], body: String) {
        self.status = status
        self.headers = headers
        self.bodyData = Data(body.utf8)
    }

    init(status: Status, headers: [String: String] = [:], bodyData: Data) {
        self.status = status
        self.headers = headers
        self.bodyData = bodyData
    }

    var data: Data {
        var responseHeaders = headers
        responseHeaders["Content-Length"] = String(bodyData.count)
        responseHeaders["Connection"] = "close"
        if responseHeaders["Content-Type"] == nil {
            responseHeaders["Content-Type"] = "application/json; charset=utf-8"
        }

        var head = "HTTP/1.1 \(status.line)\r\n"
        for key in responseHeaders.keys.sorted() {
            if let value = responseHeaders[key] {
                head += "\(key): \(value)\r\n"
            }
        }
        head += "\r\n"

        var data = Data(head.utf8)
        data.append(bodyData)
        return data
    }
}
