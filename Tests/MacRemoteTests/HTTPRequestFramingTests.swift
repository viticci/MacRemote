import Darwin
import Foundation
import Testing
@testable import MacRemote

@Suite(.serialized)
struct HTTPRequestFramingTests {
    @Test func framingRequiresOneBoundedDecimalContentLengthAndRejectsTransferEncoding() {
        #expect(state("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n") == .complete)
        #expect(state("POST /mcp HTTP/1.1\r\nContent-Length: 4\r\n\r\nabc") == .incomplete)
        #expect(state("POST /mcp HTTP/1.1\r\nContent-Length: 4\r\n\r\nabcd") == .complete)

        let boundaryPrefix = "POST /mcp HTTP/1.1\r\nContent-Length: "
        var boundaryBodyLength = HTTPRequestFraming.maximumByteCount
        while true {
            let header = "\(boundaryPrefix)\(boundaryBodyLength)\r\n\r\n"
            let resolvedLength = HTTPRequestFraming.maximumByteCount - header.utf8.count
            if resolvedLength == boundaryBodyLength {
                let boundaryRequest = header + String(repeating: "a", count: boundaryBodyLength)
                #expect(state(boundaryRequest) == .complete)
                break
            }
            boundaryBodyLength = resolvedLength
        }

        let invalidHeaders = [
            "Content-Length: 1\r\nContent-Length: 1",
            "Content-Length: -1",
            "Content-Length: +1",
            "Content-Length: 1x",
            "Content-Length: 9223372036854775808",
            "Content-Length: 131072",
            "Transfer-Encoding: chunked",
            "Transfer-Encoding: identity\r\nContent-Length: 0"
        ]
        for headers in invalidHeaders {
            #expect(state("POST /mcp HTTP/1.1\r\n\(headers)\r\n\r\n") == .invalid)
        }
    }

    @Test func malformedUnauthenticatedFramingDoesNotStopTheServer() async throws {
        let server = LocalMCPServer(
            instanceID: "framing-test",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FramingTestToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        try await waitUntilHealthy(port: port)
        let malformedRequests = [
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 9223372036854775807\r\n\r\n", false),
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n", false),
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n", false),
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\n\r\nab", true),
            ("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Len", true)
        ]

        for (request, closesWriteSide) in malformedRequests {
            let response = try sendRawRequest(request, port: port, closesWriteSide: closesWriteSide)
            #expect(response.hasPrefix("HTTP/1.1 400"))
        }

        try await waitUntilHealthy(port: port)
    }

    @Test func requestWithoutAHostHeaderIsRefused() async throws {
        let server = LocalMCPServer(
            instanceID: "framing-test",
            tools: [],
            authCoordinator: OAuthCoordinator(),
            toolExecutor: FramingTestToolExecutor()
        )
        let port = try server.start()
        defer { server.stop() }

        try await waitUntilHealthy(port: port)
        let response = try sendRawRequest("GET /health HTTP/1.1\r\n\r\n", port: port, closesWriteSide: false)
        #expect(response.hasPrefix("HTTP/1.1 421"))
        #expect(response.contains("misdirected_request"))
    }

    private func state(_ request: String) -> HTTPRequestFraming.State {
        HTTPRequestFraming.state(data: Data(request.utf8))
    }

    private func sendRawRequest(_ request: String, port: UInt16, closesWriteSide: Bool) throws -> String {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        defer { close(descriptor) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connectionResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectionResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED) }

        let requestData = Data(request.utf8)
        let sent = requestData.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == requestData.count else { throw POSIXError(.EIO) }
        if closesWriteSide {
            guard shutdown(descriptor, SHUT_WR) == 0 else { throw POSIXError(.EIO) }
        }

        var bytes = [UInt8](repeating: 0, count: 4096)
        let received = Darwin.recv(descriptor, &bytes, bytes.count, 0)
        guard received > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return String(decoding: bytes.prefix(received), as: UTF8.self)
    }

    private func waitUntilHealthy(port: UInt16) async throws {
        let url = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<50 {
            do {
                let (_, response) = try await URLSession.shared.data(from: url)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return }
            } catch {
                // The listener starts asynchronously.
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Timed out waiting for the framing test server.")
        throw POSIXError(.ETIMEDOUT)
    }
}

private struct FramingTestToolExecutor: ToolExecuting {
    func execute(toolID: String, parameters: [String: ToolArgumentValue]) async throws -> ToolExecutionOutcome {
        throw POSIXError(.ENOSYS)
    }
}
