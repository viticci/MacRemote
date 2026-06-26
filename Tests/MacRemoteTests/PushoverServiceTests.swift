import XCTest
@testable import MacRemote

final class PushoverServiceTests: XCTestCase {
    func testFormBodyEscapesFields() throws {
        let body = PushoverService.formBody([
            "token": "api token",
            "user": "user+key",
            "title": "MacRemote",
            "message": "Tunnel down & needs restart"
        ])
        let text = try XCTUnwrap(String(data: body, encoding: .utf8))

        XCTAssertEqual(
            text,
            "message=Tunnel%20down%20%26%20needs%20restart&title=MacRemote&token=api%20token&user=user%2Bkey"
        )
    }

    func testSendPostsToPushoverAPI() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PushoverURLProtocolMock.self]
        let session = URLSession(configuration: config)
        PushoverURLProtocolMock.install(
            statusCode: 200,
            body: #"{"status":1,"request":"request-id"}"#.data(using: .utf8)!
        )

        let service = PushoverService(session: session)
        try await service.send(
            PushoverMessage(title: "MacRemote", message: "Approval needed"),
            using: PushoverSettings(isEnabled: true, userKey: " user-key ", apiToken: " api-token ")
        )

        XCTAssertEqual(PushoverURLProtocolMock.requestPath(), "/1/messages.json")
        XCTAssertEqual(PushoverURLProtocolMock.requestMethod(), "POST")
        XCTAssertEqual(
            PushoverURLProtocolMock.requestHeader("Content-Type"),
            "application/x-www-form-urlencoded; charset=utf-8"
        )
        XCTAssertEqual(
            PushoverURLProtocolMock.requestBody(),
            "message=Approval%20needed&title=MacRemote&token=api-token&user=user-key"
        )
    }

    func testSendRequiresConfiguredSettings() async {
        let service = PushoverService()

        await XCTAssertThrowsErrorAsync(
            try await service.send(
                PushoverMessage(title: "MacRemote", message: "Approval needed"),
                using: PushoverSettings(isEnabled: true, userKey: "", apiToken: "api-token")
            )
        ) { error in
            XCTAssertEqual(error as? PushoverServiceError, .missingCredentials)
        }
    }

    @MainActor
    func testAppModelPersistsPushoverSettings() throws {
        let defaults = try makePushoverIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: pushoverDefaultsSuiteName(defaults)) }

        let model = try makePushoverAppModel(userDefaults: defaults)
        model.pushoverSettings = PushoverSettings(
            isEnabled: true,
            userKey: " user-key ",
            apiToken: " api-token "
        )

        let reloaded = try makePushoverAppModel(userDefaults: defaults)
        XCTAssertEqual(
            reloaded.pushoverSettings,
            PushoverSettings(isEnabled: true, userKey: "user-key", apiToken: "api-token")
        )
    }
}

private struct NoopPushoverSender: PushoverSending {
    func send(_ message: PushoverMessage, using settings: PushoverSettings) async throws {}
}

private func makePushoverIsolatedDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> UserDefaults {
    let suiteName = "MacRemotePushoverTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        XCTFail("Could not create isolated UserDefaults suite.", file: file, line: line)
        throw NSError(domain: "MacRemotePushoverTests", code: 1)
    }
    defaults.set(suiteName, forKey: "MacRemotePushoverTests.suiteName")
    return defaults
}

@MainActor
private func makePushoverAppModel(userDefaults: UserDefaults) throws -> AppModel {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
    return AppModel(
        userDefaults: userDefaults,
        toolStore: store,
        pushoverSender: NoopPushoverSender()
    )
}

private func pushoverDefaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemotePushoverTests.suiteName") ?? ""
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected async expression to throw.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

private final class PushoverURLProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statusCode = 200
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
        request.url?.host == "api.pushover.net"
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
