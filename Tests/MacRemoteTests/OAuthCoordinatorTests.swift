import Foundation
import Testing
@testable import MacRemote

struct OAuthCoordinatorTests {
    @Test func registeredClientsAreCapped() throws {
        let coordinator = OAuthCoordinator()

        for index in 0..<OAuthCoordinator.maxRegisteredClients {
            let client = try coordinator.registerClient(from: [
                "client_name": "Client \(index)",
                "redirect_uris": ["http://127.0.0.1/callback/\(index)"],
                "scope": "mcp:tools"
            ])
            #expect((client["client_id"] as? String) != nil)
        }

        #expect(throws: OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")) {
            try coordinator.registerClient(from: [
                "client_name": "Overflow",
                "redirect_uris": ["http://127.0.0.1/callback/overflow"],
                "scope": "mcp:tools"
            ])
        }
    }

    @Test func dynamicRegistrationReusesExistingLogicalClient() throws {
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

        #expect(first["client_id"] as? String == second["client_id"] as? String)
        #expect(coordinator.connectedClientSnapshot().count == 0)
    }

    @Test func loopbackRegistrationReusesLogicalClientAcrossCallbackPorts() throws {
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

        let clientID = try #require(first["client_id"] as? String)
        #expect(second["client_id"] as? String == clientID)
        #expect(
            second["redirect_uris"] as? [String] ==
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
        let request = try #require(coordinator.approvalSnapshot().first { $0.id == requestID })
        #expect(request.clientID == clientID)
        #expect(request.clientTrustID.hasPrefix("macremote-trust-"))
    }

    @Test func nativeAppRedirectSchemeCanRegisterForDynamicClients() throws {
        let coordinator = OAuthCoordinator()
        let redirectURI = "raycast://extensions/raycast/raycast/mcp-oauth-callback"

        let client = try coordinator.registerClient(from: [
            "client_name": "Raycast",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])

        #expect((client["client_id"] as? String) != nil)
        #expect(client["redirect_uris"] as? [String] == [redirectURI])
    }

    @Test func registeredClientPersistsAcrossCoordinatorRestart() throws {
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
        let clientID = try #require(client["client_id"] as? String)

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

        let request = try #require(reloaded.approvalSnapshot().first { $0.id == requestID })
        #expect(request.clientName == "Notion")
        #expect(request.redirectURI == redirectURI)
    }

    @Test func refreshTokenPersistsAcrossCoordinatorRestart() throws {
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
        #expect(firstCoordinator.validateAccessToken(issued.accessToken, issuer: issuer, resource: resource))

        let reloaded = OAuthCoordinator(grantStore: store)
        #expect(reloaded.connectedClientSnapshot().first?.name == "Notion")
        let rotated = try reloaded.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": issued.refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)

        let accessToken = try #require(rotated["access_token"] as? String)
        #expect(reloaded.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try reloaded.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": issued.refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
    }

    @Test func authorizeCanRecoverNotionCachedDynamicClientID() throws {
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

        let request = try #require(coordinator.approvalSnapshot().first { $0.id == requestID })
        #expect(request.clientName == "Notion")
        #expect(request.redirectURI == redirectURI)
        #expect(coordinator.approve(requestID: requestID))
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((token["access_token"] as? String) != nil)

        let reloaded = OAuthCoordinator(grantStore: store)
        #expect(reloaded.connectedClientSnapshot().first?.id == clientID)
        #expect(reloaded.connectedClientSnapshot().first?.name == "Notion")
    }

    @Test func unsafeRedirectSchemesAreRejectedForDynamicClients() throws {
        let coordinator = OAuthCoordinator()

        for redirectURI in [
            "javascript:alert(1)",
            "file:///tmp/callback"
        ] {
            #expect(throws: OAuthError.invalidRequest("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")) {
                try coordinator.registerClient(from: [
                    "client_name": "Unsafe",
                    "redirect_uris": [redirectURI],
                    "scope": "mcp:tools"
                ])
            }
        }
    }

    @Test func pendingAuthorizationsAreCapped() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Pending Cap",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)

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

        #expect(throws: OAuthError.invalidRequest("Too many pending authorization requests. Approve, deny, or wait for expiration.")) {
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
        }
    }

    @Test func resolvedAuthorizationsArePruned() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Retention",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)

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
            #expect(coordinator.deny(requestID: requestID))
        }

        #expect(coordinator.approvalSnapshot().count <= OAuthCoordinator.maxStoredAuthorizations)
    }

    @Test func hostApprovalRequiredBeforeTokenExchange() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "test-verifier-\(UUID().uuidString)"
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Claude Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)

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

        let pendingApproval = try #require(coordinator.approvalSnapshot().first)
        #expect(pendingApproval.state == .pending)
        #expect(pendingApproval.issuer == issuer)
        #expect(pendingApproval.resource == resource)
        #expect(pendingApproval.redirectURI == "http://127.0.0.1/callback")
        #expect(throws: (any Error).self) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "code": "not-issued",
                "code_verifier": verifier
            ], issuer: issuer, resource: resource)
        }

        #expect(coordinator.approve(requestID: requestID))
        let status = coordinator.authorizationStatus(requestID: requestID)
        let redirectURI = try #require(status["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)

        let accessToken = try #require(token["access_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
    }

    @Test func pkceMismatchRejectsTokenExchange() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Bad PKCE",
            "redirect_uris": ["http://localhost/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)

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
        #expect(coordinator.approve(requestID: requestID))
        let status = coordinator.authorizationStatus(requestID: requestID)
        let redirectURI = try #require(status["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        #expect(throws: OAuthError.invalidGrant("PKCE verification failed.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://localhost/callback",
                "code": code,
                "code_verifier": "wrong-verifier",
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
    }

    @Test func authorizationCodeAndAccessTokenAreIssuerBound() throws {
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
        let clientID = try #require(client["client_id"] as? String)
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

        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let issuerMismatch = #expect(throws: (any Error).self) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
                "code": code,
                "code_verifier": verifier,
                "resource": otherResource
            ], issuer: otherIssuer, resource: otherResource)
        }
        if case .invalidGrant(let message) = issuerMismatch as? OAuthError {
            #expect(message.contains("Issuer mismatch."))
            #expect(message.contains("Restart login using one MacRemote URL consistently"))
        } else {
            Issue.record("Expected invalid_grant issuer mismatch, got \(String(describing: issuerMismatch))")
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "https://claude.ai/api/mcp/auth_callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try #require(token["access_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.validateAccessToken(accessToken, issuer: otherIssuer, resource: otherResource) == false)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: "\(issuer)/mcp/other") == false)
    }

    @Test func authorizationCodeAndAccessTokenAreResourceBound() throws {
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
        let clientID = try #require(client["client_id"] as? String)
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

        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        #expect(throws: OAuthError.invalidGrant("Resource mismatch.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": "http://127.0.0.1/callback",
                "code": code,
                "code_verifier": verifier,
                "resource": otherResource
            ], issuer: issuer, resource: otherResource)
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try #require(token["access_token"] as? String)
        #expect(token["resource"] as? String == resource)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: otherResource) == false)
    }

    @Test func authorizationCodeExchangeAcceptsPublicClientOmittingRepeatedFields() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "public-client-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Public PKCE Client",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
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

        let pendingApproval = try #require(coordinator.approvalSnapshot().first)
        #expect(pendingApproval.resource == resource)
        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "code": code,
            "code_verifier": verifier,
            "resource": "\(resource)/"
        ], issuer: issuer, resource: resource)

        let accessToken = try #require(token["access_token"] as? String)
        #expect(token["resource"] as? String == resource)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: "\(resource)/"))
    }

    @Test func authorizationCodeExchangeRejectsMismatchedRepeatedClientMetadata() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "metadata-mismatch-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Mismatch Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
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

        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)

        #expect(throws: OAuthError.invalidGrant("Client or redirect URI mismatch.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": "macremote-client-wrong",
                "redirect_uri": "http://127.0.0.1/callback",
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((token["access_token"] as? String) != nil)
    }

    @Test func confidentialClientModeDisablesDynamicRegistration() throws {
        let credentials = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-confidential",
            clientSecret: "client-secret"
        )
        let coordinator = OAuthCoordinator(
            clientAuthentication: .confidentialClientRequired(credentials)
        )

        #expect(coordinator.supportsDynamicClientRegistration() == false)
        #expect(
            coordinator.tokenEndpointAuthMethodsSupported() ==
            ["client_secret_basic", "client_secret_post"]
        )
        #expect(throws: OAuthError.invalidRequest("Dynamic client registration is disabled while OAuth client credentials are required.")) {
            try coordinator.registerClient(from: [
                "client_name": "Dynamic Client",
                "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
                "scope": "mcp:tools"
            ])
        }
    }

    @Test func confidentialAuthorizationCodeAndRefreshRequireClientSecretPost() throws {
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
        let pending = try #require(coordinator.approvalSnapshot().first { $0.id == requestID })
        #expect(pending.clientID == credentials.clientID)
        #expect(pending.clientTrustID.hasPrefix("macremote-confidential-"))
        #expect(coordinator.approve(requestID: requestID))
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)

        #expect(throws: OAuthError.invalidClient("Client authentication required.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": credentials.clientID,
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }

        #expect(throws: OAuthError.invalidClient("Client authentication failed.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": credentials.clientID,
                "client_secret": "wrong-secret",
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
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
        let accessToken = try #require(token["access_token"] as? String)
        let refreshToken = try #require(token["refresh_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.connectedClientSnapshot().first?.redirectURIs == [redirectURI])

        #expect(throws: OAuthError.invalidClient("Client authentication failed.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }

        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "client_id": credentials.clientID,
            "client_secret": credentials.clientSecret,
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((rotated["access_token"] as? String) != nil)
    }

    @Test func multipleConfidentialCredentialsAppearAsSeparateConnectedClients() throws {
        let claude = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-claude",
            clientSecret: "claude-secret"
        )
        let raycast = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-raycast",
            clientSecret: "raycast-secret"
        )
        let coordinator = OAuthCoordinator(
            clientAuthentication: .confidentialClientsRequired([claude, raycast])
        )
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"

        let claudeToken = try issueApprovedConfidentialToken(
            coordinator: coordinator,
            credentials: claude,
            redirectURI: "https://claude.ai/api/mcp/auth_callback",
            issuer: issuer,
            resource: resource
        )
        let raycastToken = try issueApprovedConfidentialToken(
            coordinator: coordinator,
            credentials: raycast,
            redirectURI: "raycast://oauth",
            issuer: issuer,
            resource: resource
        )

        #expect(coordinator.validateAccessToken(claudeToken.accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.validateAccessToken(raycastToken.accessToken, issuer: issuer, resource: resource))

        let clients = coordinator.connectedClientSnapshot()
        #expect(Set(clients.map(\.id)) == [claude.clientID, raycast.clientID])
        #expect(Set(clients.map(\.name)) == ["Claude", "Raycast"])
        #expect(clients.first { $0.id == claude.clientID }?.redirectURIs == ["https://claude.ai/api/mcp/auth_callback"])
        #expect(clients.first { $0.id == raycast.clientID }?.redirectURIs == ["raycast://oauth"])
    }

    @Test func publicClientRejectsUnexpectedClientSecret() throws {
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
        let clientID = try #require(client["client_id"] as? String)
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
        #expect(coordinator.approve(requestID: requestID))
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)

        #expect(throws: OAuthError.invalidRequest("Public clients must not send client_secret.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "client_secret": "unexpected",
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
    }

    @Test func accessTokenCanValidateAgainstExplicitEquivalentResourceSet() throws {
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

        #expect(coordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            acceptedResources: [aliasResource, resource]
        ) != nil)
        #expect(coordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            acceptedResources: [aliasResource]
        ) == nil)
        #expect(coordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            acceptedResources: [otherResource]
        ) == nil)
    }

    @Test func unregisteredRedirectURIIsRejected() throws {
        let coordinator = OAuthCoordinator()
        let client = try coordinator.registerClient(from: [
            "client_name": "Redirect Test",
            "redirect_uris": ["https://claude.ai/api/mcp/auth_callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)

        #expect(throws: OAuthError.invalidRequest("Unregistered redirect_uri.")) {
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
        }
    }

    @Test func refreshTokenRotates() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "refresh-verifier"
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Refresh Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
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
        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let refreshToken = try #require(token["refresh_token"] as? String)
        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": "\(resource)/"
        ], issuer: issuer, resource: resource)
        #expect((rotated["access_token"] as? String) != nil)
        #expect(rotated["resource"] as? String == resource)
        #expect(throws: (any Error).self) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
    }

    @Test func refreshTokenIsIssuerBound() throws {
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
        let clientID = try #require(client["client_id"] as? String)
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
        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let refreshToken = try #require(token["refresh_token"] as? String)

        let issuerMismatch = #expect(throws: (any Error).self) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": otherResource
            ], issuer: otherIssuer, resource: otherResource)
        }
        if case .invalidGrant(let message) = issuerMismatch as? OAuthError {
            #expect(message.contains("Issuer mismatch."))
            #expect(message.contains("Restart login using one MacRemote URL consistently"))
        } else {
            Issue.record("Expected invalid_grant issuer mismatch, got \(String(describing: issuerMismatch))")
        }

        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((rotated["access_token"] as? String) != nil)
    }

    @Test func refreshTokenIsResourceBoundWithoutConsumingOnMismatch() throws {
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
        let clientID = try #require(client["client_id"] as? String)
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
        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let refreshToken = try #require(token["refresh_token"] as? String)

        #expect(throws: OAuthError.invalidGrant("Resource mismatch.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": otherResource
            ], issuer: issuer, resource: otherResource)
        }

        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((rotated["access_token"] as? String) != nil)
    }

    @Test func revokeAllGrantsInvalidatesTokensAndRegisteredClients() throws {
        let coordinator = OAuthCoordinator()
        let verifier = "revoke-verifier"
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Revoke Test",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
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
        #expect(coordinator.approve(requestID: requestID))
        let redirectURI = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirectURI)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let accessToken = try #require(token["access_token"] as? String)
        let refreshToken = try #require(token["refresh_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))

        let summary = coordinator.revokeAllGrants()

        #expect(summary.clients == 1)
        #expect(summary.authorizations == 1)
        #expect(summary.accessTokens == 1)
        #expect(summary.refreshTokens == 1)
        #expect(summary.total == 4)
        #expect(coordinator.approvalSnapshot().isEmpty)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource) == false)
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
        #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
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
        }
    }

    @Test func revokeClientInvalidatesOnlyThatClientAndForcesReregistration() throws {
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
        #expect(coordinator.connectedClientSnapshot().count == 2)
        #expect(coordinator.validateAccessToken(first.accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.validateAccessToken(second.accessToken, issuer: issuer, resource: resource))

        let summary = try #require(coordinator.revokeClient(id: first.clientID))

        #expect(summary.clients == 1)
        #expect(summary.authorizations == 1)
        #expect(summary.accessTokens == 1)
        #expect(summary.refreshTokens == 1)
        #expect(coordinator.validateAccessToken(first.accessToken, issuer: issuer, resource: resource) == false)
        #expect(coordinator.validateAccessToken(second.accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.connectedClientSnapshot().map(\.id) == [second.clientID])
        #expect(coordinator.revokeClient(id: first.clientID) == nil)

        let reregistered = try coordinator.registerClient(from: [
            "client_name": "First Client",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let reregisteredClientID = try #require(reregistered["client_id"] as? String)
        #expect(reregisteredClientID != first.clientID)
    }

    @Test func generatedCredentialAuthorizesInNonSecretMode() throws {
        // Raycast bug reproduction: a generated macremote-oauth-* credential
        // used while the connector runs a non-secret (service-token-headers)
        // access mode must authorize. Before the fix the policy dropped these
        // credentials, so /authorize threw "Unknown client_id."
        let defaults = try isolatedOAuthDefaults()
        let coordinator = OAuthCoordinator(grantStore: OAuthGrantStore(userDefaults: defaults))
        let issuer = "https://macremote.viticci.net"
        let resource = "\(issuer)/mcp/abc123"
        let clientID = "macremote-oauth-Zt7k2p9WqfLmN3xR8sVb"
        let clientSecret = "generated-secret-abcdefghijklmnopqrstuvwxyz0123456789"
        let redirectURI = "https://raycast.com/redirect/extension"
        let verifier = "raycast-verifier-0123456789abcdef"

        coordinator.updateClientAuthentication(
            .dynamicPublicClients(honoring: [
                OAuthConfidentialClientCredentials(clientID: clientID, clientSecret: clientSecret)
            ])
        )

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "state": "raycast-state",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.approve(requestID: requestID))
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((token["access_token"] as? String) != nil)
    }

    @Test func nonSecretPolicyHonorsCredentialsAndAdvertisesBothAuthMethods() {
        let creds = [OAuthConfidentialClientCredentials(clientID: "macremote-oauth-x", clientSecret: "y")]
        let hybrid = OAuthClientAuthenticationPolicy.dynamicPublicClients(honoring: creds)
        #expect(hybrid.supportsDynamicClientRegistration)   // DCR still works
        #expect(hybrid.confidentialClients.count == 1)      // generated creds honored
        #expect(hybrid.tokenEndpointAuthMethodsSupported.contains("none"))
        #expect(hybrid.tokenEndpointAuthMethodsSupported.contains("client_secret_post"))

        let bare = OAuthClientAuthenticationPolicy.dynamicPublicClients(honoring: [])
        #expect(bare.tokenEndpointAuthMethodsSupported == ["none"])
    }

    // MARK: - Static header token (Single Header sign-in)

    @Test func staticHeaderTokenAuthenticatesAcrossIssuersAndResources() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken("header-secret", clientName: "Single Header Client")

        let context = try #require(coordinator.clientContext(
            forAccessToken: "header-secret",
            issuer: "https://macremote.viticci.net",
            resource: "https://macremote.viticci.net/mcp"
        ))
        #expect(context.clientID == OAuthCoordinator.staticHeaderClientID)
        #expect(context.clientName == "Single Header Client")
        #expect(context.scopes == ["mcp:tools"])

        // Unlike OAuth access tokens, the static token is not bound to the
        // issuer it was minted under — quick-tunnel hostnames rotate.
        let otherHost = coordinator.clientContext(
            forAccessToken: "header-secret",
            issuer: "https://other.trycloudflare.com",
            resource: "https://other.trycloudflare.com/mcp"
        )
        #expect(otherHost != nil)
    }

    @Test func staticHeaderTokenRejectsWrongAndClearedTokens() {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken("header-secret")

        #expect(coordinator.clientContext(
            forAccessToken: "wrong-token",
            issuer: "https://macremote.viticci.net",
            resource: "https://macremote.viticci.net/mcp"
        ) == nil)

        coordinator.updateStaticHeaderToken(nil)
        #expect(coordinator.clientContext(
            forAccessToken: "header-secret",
            issuer: "https://macremote.viticci.net",
            resource: "https://macremote.viticci.net/mcp"
        ) == nil)
    }

    @Test func staticHeaderTokenDoesNotShadowOAuthTokens() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken("header-secret")
        let issuer = "https://macremote.viticci.net"
        let resource = "https://macremote.viticci.net/mcp"
        let tokens = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Client",
            redirectURI: "http://127.0.0.1:7777/callback",
            issuer: issuer,
            resource: resource
        )

        let oauthContext = try #require(coordinator.clientContext(
            forAccessToken: tokens.accessToken,
            issuer: issuer,
            resource: resource
        ))
        #expect(oauthContext.clientID != OAuthCoordinator.staticHeaderClientID)
    }
}

private func isolatedOAuthDefaults(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> UserDefaults {
    let suiteName = "MacRemoteOAuthTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated UserDefaults suite.", sourceLocation: sourceLocation)
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
    let clientID = try #require(client["client_id"] as? String)
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
    #expect(coordinator.approve(requestID: requestID))
    let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
    let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
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
        try #require(token["access_token"] as? String),
        try #require(token["refresh_token"] as? String)
    )
}

private func issueApprovedConfidentialToken(
    coordinator: OAuthCoordinator,
    credentials: OAuthConfidentialClientCredentials,
    redirectURI: String,
    issuer: String,
    resource: String
) throws -> (accessToken: String, refreshToken: String) {
    let verifier = "confidential-verifier-\(UUID().uuidString)"
    let requestID = try coordinator.beginAuthorization(
        queryItems: [
            "response_type": "code",
            "client_id": credentials.clientID,
            "redirect_uri": redirectURI,
            "scope": "mcp:tools",
            "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
            "code_challenge_method": "S256",
            "resource": resource
        ],
        issuer: issuer,
        resource: resource
    )
    #expect(coordinator.approve(requestID: requestID))
    let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
    let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
    let token = try coordinator.exchangeToken(form: [
        "grant_type": "authorization_code",
        "client_id": credentials.clientID,
        "client_secret": credentials.clientSecret,
        "redirect_uri": redirectURI,
        "code": code,
        "code_verifier": verifier,
        "resource": resource
    ], issuer: issuer, resource: resource)
    return (
        try #require(token["access_token"] as? String),
        try #require(token["refresh_token"] as? String)
    )
}
