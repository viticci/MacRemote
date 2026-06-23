import XCTest
@testable import MacRemote

final class TunnelServiceTests: XCTestCase {
    func testParsesTryCloudflareURLFromOutput() {
        let output = "INFO Your quick Tunnel has been created! Visit it at https://quiet-river-123.trycloudflare.com"
        XCTAssertEqual(
            TunnelService.firstPublicURL(in: output)?.absoluteString,
            "https://quiet-river-123.trycloudflare.com"
        )
    }

    func testIgnoresNonTryCloudflareURL() {
        let output = "Forwarding to http://127.0.0.1:60735"
        XCTAssertNil(TunnelService.firstPublicURL(in: output))
    }

    @MainActor
    func testAppModelCurrentPublicMCPURLAddsInstancePath() {
        let model = AppModel()
        model.instanceID = "abc123"
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)

        XCTAssertEqual(
            model.currentPublicMCPURL?.absoluteString,
            "https://quiet-river-123.trycloudflare.com/mcp/abc123"
        )
    }
}
