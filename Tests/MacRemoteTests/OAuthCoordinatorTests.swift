import XCTest
@testable import MacRemote

final class OAuthCoordinatorTests: XCTestCase {
    func testHostApprovalRequiredBeforeTokenExchange() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "test-verifier-\(UUID().uuidString)"
        let client = try coordinator.registerClient(from: [
            "client_name": "Claude Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "scope": "mcp:tools",
                "state": "abc",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256"
            ],
            issuer: "http://127.0.0.1:1234"
        )

        XCTAssertEqual(coordinator.approvalSnapshot().first?.state, .pending)
        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "code": "not-issued",
                "code_verifier": verifier
            ])
        )

        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let status = coordinator.authorizationStatus(requestID: requestID)
        let redirectURI = try XCTUnwrap(status["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier
        ])

        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken))
    }

    func testPKCEMismatchRejectsTokenExchange() throws {
        let coordinator = OAuthCoordinator()
        let client = try coordinator.registerClient(from: [
            "client_name": "Bad PKCE",
            "redirect_uris": ["http://localhost/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": "http://localhost/callback",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: "right-verifier"),
                "code_challenge_method": "S256"
            ],
            issuer: "http://127.0.0.1:1234"
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let status = coordinator.authorizationStatus(requestID: requestID)
        let redirectURI = try XCTUnwrap(status["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://localhost/callback",
                "code": code,
                "code_verifier": "wrong-verifier"
            ])
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("PKCE verification failed."))
        }
    }

    func testUnregisteredRedirectURIIsRejected() throws {
        let coordinator = OAuthCoordinator()
        let client = try coordinator.registerClient(from: [
            "client_name": "Redirect Test",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)

        XCTAssertThrowsError(
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": "https://attacker.example/callback",
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "verifier"),
                    "code_challenge_method": "S256"
                ],
                issuer: "http://127.0.0.1:1234"
            )
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidRequest("Unregistered redirect_uri."))
        }
    }

    func testRefreshTokenRotates() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "refresh-verifier"
        let client = try coordinator.registerClient(from: [
            "client_name": "Refresh Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)
        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256"
            ],
            issuer: "http://127.0.0.1:1234"
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier
        ])
        let refreshToken = try XCTUnwrap(token["refresh_token"] as? String)
        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ])
        XCTAssertNotNil(rotated["access_token"] as? String)
        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ])
        )
    }
}
