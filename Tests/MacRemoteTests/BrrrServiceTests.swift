import Foundation
import Testing
@testable import MacRemote

struct BrrrServiceTests {
    @Test func jsonBodyUsesBrrrPayloadFields() throws {
        let body = try BrrrService.jsonBody(
            for: BrrrMessage(
                title: "MacRemote",
                message: "Tunnel stopped",
                threadID: "macremote-tunnel"
            )
        )
        let text = try #require(String(data: body, encoding: .utf8))

        #expect(
            text ==
            #"{"message":"Tunnel stopped","thread_id":"macremote-tunnel","title":"MacRemote"}"#
        )
    }

    @Test func sendPostsToBrrrAPIWithAuthorizationHeader() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BrrrURLProtocolMock.self]
        let session = URLSession(configuration: config)
        BrrrURLProtocolMock.install(statusCode: 204, body: Data())

        let service = BrrrService(session: session)
        try await service.send(
            BrrrMessage(title: "MacRemote", message: "Approval needed", threadID: "macremote-approval"),
            using: BrrrSettings(isEnabled: true, webhookSecret: " br_usr_secret ")
        )

        #expect(BrrrURLProtocolMock.requestPath() == "/v1/send")
        #expect(BrrrURLProtocolMock.requestMethod() == "POST")
        #expect(BrrrURLProtocolMock.requestHeader("Authorization") == "Bearer br_usr_secret")
        #expect(BrrrURLProtocolMock.requestHeader("Content-Type") == "application/json; charset=utf-8")
        #expect(BrrrURLProtocolMock.requestHeader("User-Agent") == "MacRemote/1.0")
        #expect(
            BrrrURLProtocolMock.requestBody() ==
            #"{"message":"Approval needed","thread_id":"macremote-approval","title":"MacRemote"}"#
        )
    }

    @Test func sendRequiresConfiguredSettings() async {
        let service = BrrrService()

        await #expect(throws: BrrrServiceError.missingCredentials) {
            try await service.send(
                BrrrMessage(title: "MacRemote", message: "Approval needed"),
                using: BrrrSettings(isEnabled: true, webhookSecret: "")
            )
        }
    }

    @MainActor
    @Test func appModelPersistsBrrrSettings() throws {
        let defaults = try makeBrrrIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: brrrDefaultsSuiteName(defaults)) }

        let model = try makeBrrrAppModel(userDefaults: defaults)
        model.brrrSettings = BrrrSettings(
            isEnabled: true,
            webhookSecret: " br_usr_secret "
        )

        let reloaded = try makeBrrrAppModel(userDefaults: defaults)
        #expect(
            reloaded.brrrSettings ==
            BrrrSettings(isEnabled: true, webhookSecret: "br_usr_secret")
        )
    }
}

private struct NoopBrrrSender: BrrrSending {
    func send(_ message: BrrrMessage, using settings: BrrrSettings) async throws {}
}

private func makeBrrrIsolatedDefaults(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> UserDefaults {
    let suiteName = "MacRemoteBrrrTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated UserDefaults suite.", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteBrrrTests", code: 1)
    }
    defaults.set(suiteName, forKey: "MacRemoteBrrrTests.suiteName")
    return defaults
}

@MainActor
private func makeBrrrAppModel(userDefaults: UserDefaults) throws -> AppModel {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
    return AppModel(
        userDefaults: userDefaults,
        toolStore: store,
        brrrSender: NoopBrrrSender()
    )
}

private func brrrDefaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteBrrrTests.suiteName") ?? ""
}

private final class BrrrURLProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCode = 204
    nonisolated(unsafe) private static var responseBody = Data()
    nonisolated(unsafe) private static var capturedRequest: URLRequest?
    nonisolated(unsafe) private static var capturedBody: String?

    static func install(statusCode: Int, body: Data) {
        lock.lock()
        self.statusCode = statusCode
        responseBody = body
        capturedRequest = nil
        capturedBody = nil
        lock.unlock()
    }

    static func requestPath() -> String? {
        lock.lock()
        let path = capturedRequest?.url?.path
        lock.unlock()
        return path
    }

    static func requestMethod() -> String? {
        lock.lock()
        let method = capturedRequest?.httpMethod
        lock.unlock()
        return method
    }

    static func requestHeader(_ name: String) -> String? {
        lock.lock()
        let value = capturedRequest?.value(forHTTPHeaderField: name)
        lock.unlock()
        return value
    }

    static func requestBody() -> String? {
        lock.lock()
        let body = capturedBody
        lock.unlock()
        return body
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.brrr.now"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyData(from: request)
        Self.lock.lock()
        Self.capturedRequest = request
        Self.capturedBody = body.flatMap { String(data: $0, encoding: .utf8) }
        let statusCode = Self.statusCode
        let responseBody = Self.responseBody
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
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
