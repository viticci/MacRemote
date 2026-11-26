import Foundation
import Testing
@testable import MacRemote

/// Choke-point coverage for how MacRemote, acting as an MCP *client*, decides
/// between the modern discover flow and the legacy initialize fallback.
///
/// The bridge now renegotiates when an upstream server rejects `2026-07-28` but
/// names a version our legacy flow implements, mirroring the renegotiation
/// MacRemote's own server offers. Reserved rejections that say nothing about
/// versions (-32020, -32021) must still fail closed, and so must any -32022
/// that leaves us with nothing to downgrade to.
@Suite struct MCPUpstreamProtocolTests {
    @Test func clientInfoUsesTheReleaseIdentity() {
        #expect(MacRemoteProductInfo.name == "MacRemote")
        #expect(MacRemoteProductInfo.version == "1.0")
        #expect(MCPUpstreamProtocol.clientInfo["name"] as? String == MacRemoteProductInfo.name)
        #expect(MCPUpstreamProtocol.clientInfo["version"] as? String == MacRemoteProductInfo.version)
    }

    @Test func reservedModernDiscoverErrorsNeverAllowLegacyFallback() {
        for code in [-32020, -32021] {
            expectDiscoverFailsClosed(
                discoverErrorResponse(code: code),
                mentioning: ["\(code)"]
            )
            // Even when such an error carries a version list, these codes
            // describe a malformed request, not a version disagreement, so the
            // list must not be read as a downgrade invitation.
            expectDiscoverFailsClosed(
                discoverErrorResponse(
                    code: code,
                    data: ["supported": ["2025-11-25", "2025-06-18", "2025-03-26"]]
                ),
                mentioning: ["\(code)"]
            )
        }
    }

    @Test func unrecognizedDiscoverResponsesFallBackWithTheConfiguredVersion() throws {
        // Unchanged: a server that simply does not know server/discover is a
        // legacy server, and it named no version, so the bridge keeps using the
        // version its configuration already carries.
        for response in [
            discoverErrorResponse(code: -32601),
            discoverErrorResponse(code: -32600),
            ["jsonrpc": "2.0", "id": "discover"] as [String: Any]
        ] {
            let verdict = try MCPUpstreamProtocol.classifyDiscoverResponse(response)
            #expect(!verdict.isModern)
            #expect(verdict.renegotiatedLegacyVersion == nil)
        }
    }

    @Test func discoverResultAdvertisingTheModernVersionStaysModern() throws {
        let verdict = try MCPUpstreamProtocol.classifyDiscoverResponse(
            discoverResultResponse(supportedVersions: ["2026-07-28", "2025-11-25"])
        )
        #expect(verdict.isModern)
        #expect(verdict.renegotiatedLegacyVersion == nil)
        let result = try #require(verdict.modernResult)
        #expect(result["supportedVersions"] as? [String] == ["2026-07-28", "2025-11-25"])
    }

    @Test func unsupportedVersionErrorNamingAnImplementedVersionRenegotiatesToTheNewest() throws {
        let expectations: [(advertised: [String], requested: String)] = [
            (["2025-03-26", "2025-06-18"], "2025-06-18"),
            (["2025-11-25"], "2025-11-25"),
            (["2025-06-18", "2099-01-01"], "2025-06-18"),
            (["2026-09-15", "2025-03-26"], "2025-03-26"),
            (["2025-03-26", "2025-11-25", "2025-06-18"], "2025-11-25")
        ]
        for expectation in expectations {
            let verdict = try MCPUpstreamProtocol.classifyDiscoverResponse(
                discoverErrorResponse(
                    code: -32022,
                    data: [
                        "supported": expectation.advertised,
                        "requested": "2026-07-28"
                    ]
                )
            )
            #expect(!verdict.isModern)
            #expect(
                verdict.renegotiatedLegacyVersion == expectation.requested,
                "\(expectation.advertised) should renegotiate to \(expectation.requested)."
            )
        }

        // One junk entry must not discard an otherwise usable list.
        let mixed = try MCPUpstreamProtocol.classifyDiscoverResponse(
            discoverErrorResponse(
                code: -32022,
                data: ["supported": ["2025-06-18", 2025, NSNull()] as [Any]]
            )
        )
        #expect(mixed.renegotiatedLegacyVersion == "2025-06-18")
    }

    @Test func unsupportedVersionErrorWithoutAnImplementedVersionFailsClosed() {
        // No data at all.
        expectDiscoverFailsClosed(
            discoverErrorResponse(code: -32022),
            mentioning: ["-32022"]
        )
        // Data present, but no supported key.
        expectDiscoverFailsClosed(
            discoverErrorResponse(code: -32022, data: ["requested": "2026-07-28"]),
            mentioning: ["-32022"]
        )
        // supported is not an array of version strings.
        for malformed: Any in [
            "2025-06-18",
            ["versions": ["2025-06-18"]],
            [2025],
            NSNull()
        ] {
            expectDiscoverFailsClosed(
                discoverErrorResponse(code: -32022, data: ["supported": malformed]),
                mentioning: ["-32022"]
            )
        }
        // Well formed, but shares nothing with the legacy flow.
        for disjoint in [[String](), ["2099-01-01"], ["2026-09-15", "2027-01-01"]] {
            expectDiscoverFailsClosed(
                discoverErrorResponse(code: -32022, data: ["supported": disjoint]),
                mentioning: ["-32022"]
            )
        }
    }

    @Test func discoverResultAdvertisingOnlyLegacyVersionsRenegotiatesToTheNewest() throws {
        let expectations: [(advertised: [String], requested: String)] = [
            (["2025-11-25", "2025-06-18"], "2025-11-25"),
            (["2025-03-26"], "2025-03-26"),
            (["2025-06-18", "2099-01-01"], "2025-06-18")
        ]
        for expectation in expectations {
            let verdict = try MCPUpstreamProtocol.classifyDiscoverResponse(
                discoverResultResponse(supportedVersions: expectation.advertised)
            )
            #expect(!verdict.isModern)
            #expect(
                verdict.renegotiatedLegacyVersion == expectation.requested,
                "\(expectation.advertised) should renegotiate to \(expectation.requested)."
            )
        }
    }

    @Test func discoverResultAdvertisingNoImplementedVersionFailsClosed() {
        for supportedVersions in [[String](), ["2099-01-01"], ["2026-09-15"]] {
            expectDiscoverFailsClosed(
                discoverResultResponse(supportedVersions: supportedVersions),
                mentioning: supportedVersions
            )
        }
    }

    @Test func discoverResultWithoutASupportedVersionsArrayStillFailsClosed() {
        // Unchanged: a modern-shaped result that will not say what it speaks is
        // malformed, not a downgrade invitation.
        expectDiscoverFailsClosed(
            discoverResultResponse(supportedVersions: nil),
            mentioning: ["supportedVersions"]
        )
        expectDiscoverFailsClosed(
            discoverResultResponse(supportedVersions: "2025-06-18"),
            mentioning: ["supportedVersions"]
        )
    }

    @Test func negotiatedVersionPrefersOurNewestRegardlessOfServerOrdering() {
        #expect(MCPUpstreamProtocol.legacyVersions == ["2025-11-25", "2025-06-18", "2025-03-26"])
        #expect(
            MCPUpstreamProtocol.negotiableLegacyVersion(
                from: ["2025-03-26", "2025-06-18"]
            ) == "2025-06-18"
        )
        #expect(
            MCPUpstreamProtocol.negotiableLegacyVersion(
                from: ["2025-03-26", "2025-11-25", "2025-06-18"]
            ) == "2025-11-25"
        )
        #expect(
            MCPUpstreamProtocol.negotiableLegacyVersion(
                from: ["2025-11-25", "2025-03-26"]
            ) == "2025-11-25"
        )
        #expect(MCPUpstreamProtocol.negotiableLegacyVersion(from: ["2099-01-01"]) == nil)
        #expect(MCPUpstreamProtocol.negotiableLegacyVersion(from: []) == nil)
        #expect(MCPUpstreamProtocol.negotiableLegacyVersion(from: nil) == nil)
        #expect(
            MCPUpstreamProtocol.negotiableLegacyVersion(
                from: [MCPUpstreamProtocol.modernVersion]
            ) == nil,
            "The modern version is not something the legacy initialize flow can request."
        )
    }
}

private func discoverErrorResponse(code: Int, data: [String: Any]? = nil) -> [String: Any] {
    var error: [String: Any] = [
        "code": code,
        "message": "Upstream rejection"
    ]
    if let data {
        error["data"] = data
    }
    return [
        "jsonrpc": "2.0",
        "id": "discover",
        "error": error
    ]
}

private func discoverResultResponse(supportedVersions: Any?) -> [String: Any] {
    var result: [String: Any] = [
        "resultType": "complete",
        "capabilities": [:],
        "_meta": [
            "io.modelcontextprotocol/serverInfo": [
                "name": "fixture",
                "version": "1.0.0"
            ]
        ]
    ]
    if let supportedVersions {
        result["supportedVersions"] = supportedVersions
    }
    return [
        "jsonrpc": "2.0",
        "id": "discover",
        "result": result
    ]
}

private func expectDiscoverFailsClosed(
    _ response: [String: Any],
    mentioning fragments: [String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        let verdict = try MCPUpstreamProtocol.classifyDiscoverResponse(response)
        Issue.record(
            """
            classifyDiscoverResponse should have failed closed, got \
            modern=\(verdict.isModern) version=\
            \(verdict.renegotiatedLegacyVersion ?? "nil").
            """,
            sourceLocation: sourceLocation
        )
    } catch {
        let description = error.localizedDescription
        for fragment in fragments {
            #expect(
                description.contains(fragment),
                "Failure should explain itself with \(fragment): \(description)",
                sourceLocation: sourceLocation
            )
        }
    }
}
