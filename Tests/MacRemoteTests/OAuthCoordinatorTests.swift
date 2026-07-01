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

    func testDynamicRegistrationReusesExistingLogicalClient() throws {
        let coordinator = OAuthCoordinator()
        let first = try coordinator.registerClient(from: [
            "client_name": "Codex CLI",
            "redirect_uris": ["https://codex.example/oauth/callback"],
            "scope": "mcp:tools"
        ])
        let second = try coordinator.registerClient(from: [
            "client_name": "Codex CLI",
            "redirect_uris": ["https://codex.example/oauth/callback"],
            "scope": "mcp:tools"
        ])

        XCTAssertEqual(first["client_id"] as? String, second["client_id"] as? String)
        XCTAssertEqual(coordinator.connectedClientSnapshot().count, 0)
    }

    func testLoopbackRegistrationReusesLogicalClientAcrossCallbackPorts() throws {
        let coordinator = OAuthCoordinator()
        let first = try coordinator.registerClient(from: [
            "client_name": "Codex CLI",
            "redirect_uris": ["http://127.0.0.1:49152/callback"],
            "scope": "mcp:tools"
        ])
        let second = try coordinator.registerClient(from: [
            "client_name": "Codex CLI",
            "redirect_uris": ["http://127.0.0.1:49153/callback"],
            "scope": "mcp:tools"
        ])

        let clientID = try XCTUnwrap(first["client_id"] as? String)
        XCTAssertEqual(second["client_id"] as? String, clientID)
        XCTAssertEqual(
            second["redirect_uris"] as? [String],
            ["http://127.0.0.1:49152/callback", "http://127.0.0.1:49153/callback"]
        )

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1:49153/callback",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: "codex-port-verifier"),
                "code_challenge_method": "S256"
            ],
            issuer: "http://127.0.0.1:1234",
            resource: "http://127.0.0.1:1234/mcp/test-instance"
        )
        let request = try XCTUnwrap(coordinator.approvalSnapshot().first { $0.id == requestID })
        XCTAssertEqual(request.clientID, clientID)
        XCTAssertTrue(request.clientTrustID.hasPrefix("macremote-trust-"))
    }

    func testNativeAppRedirectSchemeCanRegisterForDynamicClients() throws {
        let coordinator = OAuthCoordinator()
        let redirectURI = "raycast://extensions/raycast/raycast/mcp-oauth-callback"

        let client = try coordinator.registerClient(from: [
            "client_name": "Raycast",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])

        XCTAssertNotNil(client["client_id"] as? String)
        XCTAssertEqual(client["redirect_uris"] as? [String], [redirectURI])
    }

    func testRegisteredClientPersistsAcrossCoordinatorRestart() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let redirectURI = "https://www.notion.so/oauth/callback"

        let coordinator = OAuthCoordinator(grantStore: store)
        let client = try coordinator.registerClient(from: [
            "client_name": "Notion",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)

        let reloaded = OAuthCoordinator(grantStore: store)
        let requestID = try reloaded.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "state": "notion-state",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: "notion-verifier"),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )

        let request = try XCTUnwrap(reloaded.approvalSnapshot().first { $0.id == requestID })
        XCTAssertEqual(request.clientName, "Notion")
        XCTAssertEqual(request.redirectURI, redirectURI)
    }

    func testRefreshTokenPersistsAcrossCoordinatorRestart() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"

        let firstCoordinator = OAuthCoordinator(grantStore: store)
        let issued = try issueApprovedTokens(
            coordinator: firstCoordinator,
            clientName: "Notion",
            redirectURI: "https://www.notion.so/oauth/callback",
            issuer: issuer,
            resource: resource
        )
        XCTAssertTrue(firstCoordinator.validateAccessToken(issued.accessToken, issuer: issuer, resource: resource))

        let reloaded = OAuthCoordinator(grantStore: store)
        XCTAssertEqual(reloaded.connectedClientSnapshot().first?.name, "Notion")
        let rotated = try reloaded.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": issued.refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)

        let accessToken = try XCTUnwrap(rotated["access_token"] as? String)
        XCTAssertTrue(reloaded.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        XCTAssertThrowsError(
            try reloaded.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": issued.refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Invalid refresh token."))
        }
    }

    func testAuthorizeCanRecoverNotionCachedDynamicClientID() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let coordinator = OAuthCoordinator(grantStore: store)
        let issuer = "https://macremote.viticci.net"
        let resource = "\(issuer)/mcp/b06386fec5a37604c776b341e89f53aa"
        let redirectURI = "https://app.notion.com/workflows/mcp/oauth/callback"
        let clientID = "macremote-client-CsRCW9bcxFfllcH6Uqlsog"
        let verifier = "notion-recovered-verifier"

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "state": "notion-state",
                "nonce": "notion-nonce",
                "notion_user_id": "abdd4b07-b867-4f46-a4ec-c6a39e351e3f",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "prompt": "consent",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )

        let request = try XCTUnwrap(coordinator.approvalSnapshot().first { $0.id == requestID })
        XCTAssertEqual(request.clientName, "Notion")
        XCTAssertEqual(request.redirectURI, redirectURI)
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirect = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(token["access_token"] as? String)

        let reloaded = OAuthCoordinator(grantStore: store)
        XCTAssertEqual(reloaded.connectedClientSnapshot().first?.id, clientID)
        XCTAssertEqual(reloaded.connectedClientSnapshot().first?.name, "Notion")
    }

    func testUnsafeRedirectSchemesAreRejectedForDynamicClients() throws {
        let coordinator = OAuthCoordinator()

        for redirectURI in [
            "javascript:alert(1)",
            "file:///tmp/callback"
        ] {
            XCTAssertThrowsError(
                try coordinator.registerClient(from: [
                    "client_name": "Unsafe",
                    "redirect_uris": [redirectURI],
                    "scope": "mcp:tools"
                ])
            ) { error in
                XCTAssertEqual(
                    error as? OAuthError,
                    .invalidRequest("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")
                )
            }
        }
    }

    func testPendingAuthorizationsAreCapped() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Pending Cap",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)

        for index in 0..<OAuthCoordinator.maxPendingAuthorizations {
            _ = try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": "http://127.0.0.1/callback",
                    "scope": "mcp:tools",
                    "state": "state-\(index)",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "verifier-\(index)"),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }

        XCTAssertThrowsError(
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": "http://127.0.0.1/callback",
                    "scope": "mcp:tools",
                    "state": "overflow",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "overflow-verifier"),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        ) { error in
            XCTAssertEqual(
                error as? OAuthError,
                .invalidRequest("Too many pending authorization requests. Approve, deny, or wait for expiration.")
            )
        }
    }

    func testResolvedAuthorizationsArePruned() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Retention",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)

        for index in 0..<(OAuthCoordinator.maxStoredAuthorizations + 20) {
            let requestID = try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": "http://127.0.0.1/callback",
                    "scope": "mcp:tools",
                    "state": "state-\(index)",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "verifier-\(index)"),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
            XCTAssertTrue(coordinator.deny(requestID: requestID))
        }

        XCTAssertLessThanOrEqual(coordinator.approvalSnapshot().count, OAuthCoordinator.maxStoredAuthorizations)
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
            guard case .invalidGrant(let message) = error as? OAuthError else {
                return XCTFail("Expected invalid_grant issuer mismatch, got \(error)")
            }
            XCTAssertTrue(message.contains("Issuer mismatch."))
            XCTAssertTrue(message.contains("Restart login using one MacRemote URL consistently"))
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

    func testAuthorizationCodeExchangeAcceptsPublicClientOmittingRepeatedFields() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "public-client-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Public PKCE Client",
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
                "resource": "\(resource)/"
            ],
            issuer: issuer,
            resource: resource
        )

        let pendingApproval = try XCTUnwrap(coordinator.approvalSnapshot().first)
        XCTAssertEqual(pendingApproval.resource, resource)
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirectURI = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "resource": "\(resource)/"
        ], issuer: issuer, resource: resource)

        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        XCTAssertEqual(token["resource"] as? String, resource)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: "\(resource)/"))
    }

    func testAuthorizationCodeExchangeRejectsMismatchedRepeatedClientMetadata() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "metadata-mismatch-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Mismatch Test",
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
                "client_id": "macremote-client-wrong",
                "redirect_uri": "http://127.0.0.1/callback",
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidGrant("Client or redirect URI mismatch."))
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(token["access_token"] as? String)
    }

    func testConfidentialClientModeDisablesDynamicRegistration() throws {
        let credentials = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-confidential",
            clientSecret: "client-secret"
        )
        let coordinator = OAuthCoordinator(
            clientAuthentication: .confidentialClientRequired(credentials)
        )

        XCTAssertFalse(coordinator.supportsDynamicClientRegistration())
        XCTAssertEqual(
            coordinator.tokenEndpointAuthMethodsSupported(),
            ["client_secret_basic", "client_secret_post"]
        )
        XCTAssertThrowsError(
            try coordinator.registerClient(from: [
                "client_name": "Dynamic Client",
                "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
                "scope": "mcp:tools"
            ])
        ) { error in
            XCTAssertEqual(
                error as? OAuthError,
                .invalidRequest("Dynamic client registration is disabled while OAuth client credentials are required.")
            )
        }
    }

    func testConfidentialAuthorizationCodeAndRefreshRequireClientSecretPost() throws {
        let credentials = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-confidential",
            clientSecret: "correct-secret"
        )
        let coordinator = OAuthCoordinator(
            clientAuthentication: .confidentialClientRequired(credentials)
        )
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"
        let verifier = "confidential-verifier"

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": credentials.clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "state": "state",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        let pending = try XCTUnwrap(coordinator.approvalSnapshot().first { $0.id == requestID })
        XCTAssertEqual(pending.clientID, credentials.clientID)
        XCTAssertTrue(pending.clientTrustID.hasPrefix("macremote-confidential-"))
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirect = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": credentials.clientID,
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidClient("Client authentication required."))
        }

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": credentials.clientID,
                "client_secret": "wrong-secret",
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidClient("Client authentication failed."))
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try XCTUnwrap(token["access_token"] as? String)
        let refreshToken = try XCTUnwrap(token["refresh_token"] as? String)
        XCTAssertTrue(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        XCTAssertEqual(coordinator.connectedClientSnapshot().first?.redirectURIs, [redirectURI])

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidClient("Client authentication failed."))
        }

        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(rotated["access_token"] as? String)
    }

    func testPublicClientRejectsUnexpectedClientSecret() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "public-secret-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "Public Client",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try XCTUnwrap(client["client_id"] as? String)
        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        XCTAssertTrue(coordinator.approve(requestID: requestID))
        let redirect = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)

        XCTAssertThrowsError(
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "client_secret": "unexpected",
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        ) { error in
            XCTAssertEqual(error as? OAuthError, .invalidRequest("Public clients must not send client_secret."))
        }
    }

    func testAccessTokenCanValidateAgainstExplicitEquivalentResourceSet() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let aliasResource = "\(issuer)/mcp"
        let otherResource = "\(issuer)/mcp/other-instance"
        let issued = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Alias Test",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )

        XCTAssertNotNil(coordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            acceptedResources: [aliasResource, resource]
        ))
        XCTAssertNil(coordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            acceptedResources: [aliasResource]
        ))
        XCTAssertNil(coordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            acceptedResources: [otherResource]
        ))
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
            "resource": "\(resource)/"
        ], issuer: issuer, resource: resource)
        XCTAssertNotNil(rotated["access_token"] as? String)
        XCTAssertEqual(rotated["resource"] as? String, resource)
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
            guard case .invalidGrant(let message) = error as? OAuthError else {
                return XCTFail("Expected invalid_grant issuer mismatch, got \(error)")
            }
            XCTAssertTrue(message.contains("Issuer mismatch."))
            XCTAssertTrue(message.contains("Restart login using one MacRemote URL consistently"))
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

    func testRevokeClientInvalidatesOnlyThatClientAndForcesReregistration() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "http://127.0.0.1/callback"
        let first = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "First Client",
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        let second = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Second Client",
            redirectURI: "http://127.0.0.1/second-callback",
            issuer: issuer,
            resource: resource
        )
        XCTAssertEqual(coordinator.connectedClientSnapshot().count, 2)
        XCTAssertTrue(coordinator.validateAccessToken(first.accessToken, issuer: issuer, resource: resource))
        XCTAssertTrue(coordinator.validateAccessToken(second.accessToken, issuer: issuer, resource: resource))

        let summary = try XCTUnwrap(coordinator.revokeClient(id: first.clientID))

        XCTAssertEqual(summary.clients, 1)
        XCTAssertEqual(summary.authorizations, 1)
        XCTAssertEqual(summary.accessTokens, 1)
        XCTAssertEqual(summary.refreshTokens, 1)
        XCTAssertFalse(coordinator.validateAccessToken(first.accessToken, issuer: issuer, resource: resource))
        XCTAssertTrue(coordinator.validateAccessToken(second.accessToken, issuer: issuer, resource: resource))
        XCTAssertEqual(coordinator.connectedClientSnapshot().map(\.id), [second.clientID])
        XCTAssertNil(coordinator.revokeClient(id: first.clientID))

        let reregistered = try coordinator.registerClient(from: [
            "client_name": "First Client",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let reregisteredClientID = try XCTUnwrap(reregistered["client_id"] as? String)
        XCTAssertNotEqual(reregisteredClientID, first.clientID)
    }
}

private func isolatedOAuthDefaults(
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> UserDefaults {
    let suiteName = "MacRemoteOAuthTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        XCTFail("Could not create isolated UserDefaults suite.", file: file, line: line)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func issueApprovedTokens(
    coordinator: OAuthCoordinator,
    clientName: String,
    redirectURI: String,
    issuer: String,
    resource: String
) throws -> (clientID: String, accessToken: String, refreshToken: String) {
    let verifier = "verifier-\(UUID().uuidString)"
    let client = try coordinator.registerClient(from: [
        "client_name": clientName,
        "redirect_uris": [redirectURI],
        "scope": "mcp:tools"
    ])
    let clientID = try XCTUnwrap(client["client_id"] as? String)
    let requestID = try coordinator.beginAuthorization(
        queryItems: [
            "response_type": "code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "scope": "mcp:tools",
            "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
            "code_challenge_method": "S256",
            "resource": resource
        ],
        issuer: issuer,
        resource: resource
    )
    XCTAssertTrue(coordinator.approve(requestID: requestID))
    let redirect = try XCTUnwrap(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
    let code = try XCTUnwrap(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
    let token = try coordinator.exchangeToken(form: [
        "grant_type": "authorization_code",
        "client_id": clientID,
        "redirect_uri": redirectURI,
        "code": code,
        "code_verifier": verifier,
        "resource": resource
    ], issuer: issuer, resource: resource)
    return (
        clientID,
        try XCTUnwrap(token["access_token"] as? String),
        try XCTUnwrap(token["refresh_token"] as? String)
    )
}
