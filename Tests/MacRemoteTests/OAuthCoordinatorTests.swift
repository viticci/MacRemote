import XCTest
@testable import MacRemote

final class OAuthCoordinatorTests: XCTestCase {
    func testRegisteredClientsAreCapped() throws {
        let coordinator = OAuthCoordinator()

        for index in 0..<OAuthCoordinator.maxRegisteredClients {
            let client = try coordinator.registerClient(from: [
                "client_name": "Client \(index)",
                "redirect_uris": ["http://127.0.0.1/callback/\(index)"],
                "scope": "mcp:tools"
            ])
            XCTAssertNotNil(client["client_id"] as? String)
        }

        XCTAssertThrowsError(
            try coordinator.registerClient(from: [
                "client_name": "Overflow",
                "redirect_uris": ["http://127.0.0.1/callback/overflow"],
                "scope": "mcp:tools"
            ])
        ) { error in
            XCTAssertEqual(
                error as? OAuthError,
                .invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
            )
        }
    }

    func testHostApprovalRequiredBeforeTokenExchange() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "test-verifier-\(UUID().uuidString)"
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
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
            issuer: issuer,
            resource: resource
        )

        let pendingApproval = try XCTUnwrap(coordinator.approvalSnapshot().first)
        XCTAssertEqual(pendingApproval.state, .pending)
        XCTAssertEqual(pendingApproval.issuer, issuer)
        XCTAssertEqual(pendingApproval.resource, resource)
        XCTAssertEqual(pendingApproval.redirectURI, "http://127.0.0.1/callback")
        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "code": "not-issued",
                "code_verifier": verifier
            ], issuer: issuer, resource: resource)
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
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)

        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
    }

    func testPKCEMismatchRejectsTokenExchange() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
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
            issuer: issuer,
            resource: resource
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
                "code_verifier": "wrong-verifier",
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("PKCE verification failed."))
        }
    }

    func testAuthorizationCodeAndAccessTokenAreIssuerBound() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "issuer-bound-verifier"
        let issuer = "https://macremote-one.example"
        let otherIssuer = "https://macremote-two.example"
        let resource = "\(issuer)/mcp/test-instance"
        let otherResource = "\(otherIssuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Issuer Test",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)
        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )

        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
                "code": code,
                "code_verifier": verifier,
                "resource": otherResource
            ], issuer: otherIssuer, resource: otherResource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Issuer mismatch."))
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        XCTAssertFalse(coordinator.validateAccessToken(accessToken, issuer: otherIssuer, resource: otherResource))
        XCTAssertFalse(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: "\(issuer)/mcp/other"))
    }

    func testAuthorizationCodeAndAccessTokenAreResourceBound() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "resource-bound-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let otherResource = "\(issuer)/mcp/other-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Resource Test",
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
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )

        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "code": code,
                "code_verifier": verifier,
                "resource": otherResource
            ], issuer: issuer, resource: otherResource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Resource mismatch."))
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        XCTAssertEqual(token["resource"] as? String, resource)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        XCTAssertFalse(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: otherResource))
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
                issuer: "http://127.0.0.1:1234",
                resource: "http://127.0.0.1:1234/mcp/test-instance"
            )
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidRequest("Unregistered redirect_uri."))
        }
    }

    func testRefreshTokenRotates() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "refresh-verifier"
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
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
            issuer: issuer,
            resource: resource
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let refreshToken = try XCTUnwrap(token["refresh_token"] as? String)
        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(rotated["access_token"] as? String)
        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        )
    }

    func testRefreshTokenIsIssuerBound() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "refresh-issuer-verifier"
        let issuer = "https://macremote-one.example"
        let otherIssuer = "https://macremote-two.example"
        let resource = "\(issuer)/mcp/test-instance"
        let otherResource = "\(otherIssuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Refresh Issuer Test",
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
            issuer: issuer,
            resource: resource
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let refreshToken = try XCTUnwrap(token["refresh_token"] as? String)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": otherResource
            ], issuer: otherIssuer, resource: otherResource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Issuer mismatch."))
        }

        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(rotated["access_token"] as? String)
    }

    func testRefreshTokenIsResourceBoundWithoutConsumingOnMismatch() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "refresh-resource-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let otherResource = "\(issuer)/mcp/other-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Refresh Resource Test",
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
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let refreshToken = try XCTUnwrap(token["refresh_token"] as? String)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": otherResource
            ], issuer: issuer, resource: otherResource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Resource mismatch."))
        }

        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(rotated["access_token"] as? String)
    }

    func testRevokeAllGrantsInvalidatesTokensAndRegisteredClients() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "revoke-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Revoke Test",
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
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        let refreshToken = try XCTUnwrap(token["refresh_token"] as? String)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))

        let summary = coordinator.revokeAllGrants()

        XCTAssertEqual(summary.clients, 1)
        XCTAssertEqual(summary.authorizations, 1)
        XCTAssertEqual(summary.accessTokens, 1)
        XCTAssertEqual(summary.refreshTokens, 1)
        XCTAssertEqual(summary.total, 4)
        XCTAssertTrue(coordinator.approvalSnapshot().isEmpty)
        XCTAssertFalse(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Invalid refresh token."))
        }
        XCTAssertThrowsError(
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": "http://127.0.0.1/callback",
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "new-verifier"),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidRequest("Unknown client_id."))
        }
    }
}
