import CryptoKit
import Foundation
import Testing
@testable import MacRemote

struct OAuthCoordinatorTests {
    @Test func registrationCapEvictsOnlyAnOldNeverAuthorizedClient() throws {
        let coordinator = OAuthCoordinator()
        let protected = try coordinator.registerClient(from: [
            "client_name": "Protected",
            "redirect_uris": ["http://127.0.0.1/protected"],
            "scope": "mcp:tools"
        ])
        let protectedID = try #require(protected["client_id"] as? String)
        let protectedRequestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": protectedID,
                "redirect_uri": "http://127.0.0.1/protected",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("protected")),
                "code_challenge_method": "S256"
            ],
            issuer: "http://127.0.0.1:1234",
            resource: "http://127.0.0.1:1234/mcp/test-instance"
        )

        var oldestEvictableID = ""
        for index in 1..<OAuthCoordinator.maxRegisteredClients {
            let client = try coordinator.registerClient(from: [
                "client_name": "Client \(index)",
                "redirect_uris": ["http://127.0.0.1/callback/\(index)"],
                "scope": "mcp:tools"
            ])
            if index == 1 {
                oldestEvictableID = try #require(client["client_id"] as? String)
            }
        }

        let replacement = try coordinator.registerClient(from: [
            "client_name": "Replacement",
            "redirect_uris": ["http://127.0.0.1/callback/replacement"],
            "scope": "mcp:tools"
        ])
        #expect((replacement["client_id"] as? String) != nil)
        #expect(coordinator.approvalSnapshot().contains { $0.id == protectedRequestID })
        #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": oldestEvictableID,
                    "redirect_uri": "http://127.0.0.1/callback/1",
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("evicted")),
                    "code_challenge_method": "S256"
                ],
                issuer: "http://127.0.0.1:1234",
                resource: "http://127.0.0.1:1234/mcp/test-instance"
            )
        }
    }

    @Test func deniedAuthorizationCannotPinRegistrationCapacity() throws {
        let coordinator = OAuthCoordinator()
        var oldestDeniedClientID = ""

        for index in 0..<OAuthCoordinator.maxRegisteredClients {
            let redirectURI = "http://127.0.0.1/denied/\(index)"
            let registration = try coordinator.registerClient(from: [
                "client_name": "Denied \(index)",
                "redirect_uris": [redirectURI],
                "scope": "mcp:tools"
            ])
            let clientID = try #require(registration["client_id"] as? String)
            if index == 0 {
                oldestDeniedClientID = clientID
            }
            let requestID = try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": redirectURI,
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("denied-\(index)")),
                    "code_challenge_method": "S256"
                ],
                issuer: "http://127.0.0.1:1234",
                resource: "http://127.0.0.1:1234/mcp/test-instance"
            )
            #expect(coordinator.deny(requestID: requestID))
        }

        let replacement = try coordinator.registerClient(from: [
            "client_name": "Replacement",
            "redirect_uris": ["http://127.0.0.1/replacement"],
            "scope": "mcp:tools"
        ])
        #expect((replacement["client_id"] as? String) != nil)
        #expect(!coordinator.approvalSnapshot().contains { $0.clientID == oldestDeniedClientID })
        #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": oldestDeniedClientID,
                    "redirect_uri": "http://127.0.0.1/denied/0",
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("evicted-denied")),
                    "code_challenge_method": "S256"
                ],
                issuer: "http://127.0.0.1:1234",
                resource: "http://127.0.0.1:1234/mcp/test-instance"
            )
        }
    }

    @Test func identicalDynamicRegistrationCreatesIndependentClient() throws {
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

        #expect(first["client_id"] as? String != second["client_id"] as? String)
        #expect(coordinator.connectedClientSnapshot().count == 0)
    }

    @Test func dynamicRegistrationValidatesClientMetadata() throws {
        let coordinator = OAuthCoordinator()
        let valid: [String: Any] = [
            "client_name": "ChatGPT",
            "redirect_uris": ["https://chatgpt.com/connector/oauth/test-callback"],
            "application_type": "web",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": "mcp:tools"
        ]

        let registration = try coordinator.registerClient(from: valid)
        #expect(registration["grant_types"] as? [String] == ["authorization_code", "refresh_token"])
        #expect(registration["response_types"] as? [String] == ["code"])
        #expect(registration["token_endpoint_auth_method"] as? String == "none")
        #expect(registration["application_type"] as? String == "web")
        #expect((registration["client_id_issued_at"] as? Int ?? 0) > 0)

        var unsupportedGrant = valid
        unsupportedGrant["grant_types"] = ["client_credentials"]
        #expect(throws: OAuthError.invalidClientMetadata("Only authorization_code with optional refresh_token is supported.")) {
            try coordinator.registerClient(from: unsupportedGrant)
        }

        var unusableGrantCombination = valid
        unusableGrantCombination["grant_types"] = ["refresh_token"]
        #expect(throws: OAuthError.invalidClientMetadata("Only authorization_code with optional refresh_token is supported.")) {
            try coordinator.registerClient(from: unusableGrantCombination)
        }

        var unsupportedResponse = valid
        unsupportedResponse["response_types"] = ["token"]
        #expect(throws: OAuthError.invalidClientMetadata("Only the code response type is supported.")) {
            try coordinator.registerClient(from: unsupportedResponse)
        }

        var unknownMethod = valid
        unknownMethod["token_endpoint_auth_method"] = "tls_client_auth"
        #expect(throws: OAuthError.invalidClientMetadata("Unsupported token_endpoint_auth_method.")) {
            try coordinator.registerClient(from: unknownMethod)
        }

        var malformedGrantTypes = valid
        malformedGrantTypes["grant_types"] = "authorization_code"
        #expect(throws: OAuthError.invalidClientMetadata("grant_types must be a non-empty string array.")) {
            try coordinator.registerClient(from: malformedGrantTypes)
        }

        var invalidRedirect = valid
        invalidRedirect["redirect_uris"] = ["javascript:alert(1)"]
        #expect(throws: OAuthError.invalidRedirectURI("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")) {
            try coordinator.registerClient(from: invalidRedirect)
        }

        var invalidClientURI = valid
        invalidClientURI["client_uri"] = "not an absolute URI"
        #expect(throws: OAuthError.invalidClientMetadata("client_uri must be an absolute URI.")) {
            try coordinator.registerClient(from: invalidClientURI)
        }

        var conflictingJWKMetadata = valid
        conflictingJWKMetadata["jwks_uri"] = "https://chatgpt.com/.well-known/jwks.json"
        conflictingJWKMetadata["jwks"] = ["keys": []]
        #expect(throws: OAuthError.invalidClientMetadata("jwks and jwks_uri must not both be present.")) {
            try coordinator.registerClient(from: conflictingJWKMetadata)
        }
    }

    @Test func dynamicRegistrationValidatesApplicationTypeWithoutBreakingLegacyClients() throws {
        let coordinator = OAuthCoordinator()

        let legacy = try coordinator.registerClient(from: [
            "client_name": "Legacy CLI",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "scope": "mcp:tools"
        ])
        #expect(legacy["application_type"] == nil)

        let native = try coordinator.registerClient(from: [
            "client_name": "Current CLI",
            "redirect_uris": ["http://127.0.0.1/callback"],
            "application_type": "native",
            "scope": "mcp:tools"
        ])
        #expect(native["application_type"] as? String == "native")

        #expect(throws: OAuthError.invalidClientMetadata("application_type must be native or web.")) {
            try coordinator.registerClient(from: [
                "client_name": "Invalid Type",
                "redirect_uris": ["https://client.example/callback"],
                "application_type": "desktop",
                "scope": "mcp:tools"
            ])
        }

        #expect(throws: OAuthError.invalidClientMetadata("application_type must be native or web.")) {
            try coordinator.registerClient(from: [
                "client_name": "Malformed Type",
                "redirect_uris": ["https://client.example/callback"],
                "application_type": true,
                "scope": "mcp:tools"
            ])
        }

        #expect(throws: OAuthError.invalidRedirectURI("web application_type requires HTTPS redirect_uris.")) {
            try coordinator.registerClient(from: [
                "client_name": "Mismatched Web App",
                "redirect_uris": ["http://localhost/callback"],
                "application_type": "web",
                "scope": "mcp:tools"
            ])
        }
    }

    /// An app gets a secret only when it asks for one. Leaving the method out
    /// means a public app.
    @Test func registrationWithoutAnAuthMethodIssuesNoSecret() throws {
        let registration = try OAuthCoordinator().registerClient(from: [
            "client_name": "ChatGPT",
            "redirect_uris": ["https://chatgpt.com/connector/oauth/test-callback"],
            "scope": "mcp:tools"
        ])

        #expect(registration["token_endpoint_auth_method"] as? String == "none")
        #expect(registration["client_secret"] == nil)
    }

    /// Claude registers itself and asks for a secret of its own when one is
    /// offered. That must work from registration to renewal, and only with
    /// the secret: the client ID alone is known to anyone who saw the sign-in.
    @Test func anAppThatAsksForItsOwnSecretSignsInAndRenewsWithIt() throws {
        let coordinator = OAuthCoordinator()
        let verifier = validPKCEVerifier("own-secret-verifier")
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirect = "https://claude.ai/api/mcp/auth_callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "Claude",
            "redirect_uris": [redirect],
            "token_endpoint_auth_method": "client_secret_post",
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        let clientSecret = try #require(client["client_secret"] as? String)
        #expect(client["token_endpoint_auth_method"] as? String == "client_secret_post")

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirect,
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
        let token = try coordinator.exchangeToken(
            form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "client_secret": clientSecret,
                "redirect_uri": redirect,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ],
            clientAuthenticationSource: .clientSecretPost,
            issuer: issuer,
            resource: resource
        )
        let refreshToken = try #require(token["refresh_token"] as? String)

        // Without the secret the refresh token is worth nothing.
        #expect(throws: OAuthError.self) {
            try coordinator.exchangeToken(
                form: ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken, "resource": resource],
                issuer: issuer,
                resource: resource
            )
        }
        let renewed = try coordinator.exchangeToken(
            form: [
                "grant_type": "refresh_token",
                "client_id": clientID,
                "client_secret": clientSecret,
                "refresh_token": refreshToken,
                "resource": resource
            ],
            clientAuthenticationSource: .clientSecretPost,
            issuer: issuer,
            resource: resource
        )
        let accessToken = try #require(renewed["access_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
    }

    /// An app saved by an earlier build with a secret of its own must keep
    /// renewing, and only with the secret sent the way it registered.
    @Test func savedSelfRegisteredAppWithItsOwnSecretStillRenews() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let clientID = "macremote-client-SavedBasicClient01"
        let clientSecret = "saved-secret-0123456789"
        let refreshToken = "saved-refresh-token"
        let now = Date()
        try store.saveSnapshot(OAuthGrantSnapshot(
            clients: [OAuthStoredClient(
                id: clientID,
                trustID: nil,
                name: "ChatGPT",
                redirectURIs: ["https://chatgpt.com/connector/oauth/saved-callback"],
                scopes: ["mcp:tools"],
                createdAt: now,
                authenticationMethod: "clientSecretBasic",
                secretHash: sha256Hex(clientSecret)
            )],
            accessTokens: [],
            refreshTokens: [OAuthStoredToken(
                tokenHash: sha256Hex(refreshToken),
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: ["mcp:tools"],
                issuedAt: now,
                expiresAt: now.addingTimeInterval(3_600)
            )]
        ))

        let coordinator = OAuthCoordinator(grantStore: store)
        let form = [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "client_secret": clientSecret,
            "refresh_token": refreshToken,
            "resource": resource
        ]
        #expect(throws: OAuthError.invalidClient("Client authentication method does not match registration.")) {
            try coordinator.exchangeToken(
                form: form,
                clientAuthenticationSource: .clientSecretPost,
                issuer: issuer,
                resource: resource
            )
        }
        let renewed = try coordinator.exchangeToken(
            form: form,
            clientAuthenticationSource: .clientSecretBasic,
            issuer: issuer,
            resource: resource
        )
        let accessToken = try #require(renewed["access_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
    }

    @Test func dynamicRegistrationAcceptsIPv6LoopbackAndRejectsHostlessHTTPS() throws {
        let coordinator = OAuthCoordinator()
        let ipv6Redirect = "http://[::1]:49152/callback"

        let registration = try coordinator.registerClient(from: [
            "client_name": "IPv6 Native Client",
            "redirect_uris": [ipv6Redirect],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": "mcp:tools"
        ])
        #expect(registration["redirect_uris"] as? [String] == [ipv6Redirect])

        #expect(throws: OAuthError.invalidRedirectURI("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")) {
            try coordinator.registerClient(from: [
                "client_name": "Hostless HTTPS Client",
                "redirect_uris": ["https:/callback"],
                "scope": "mcp:tools"
            ])
        }
    }

    @Test func unsupportedScopesReturnStandardErrorsWithoutConsumingRefreshGrant() throws {
        let coordinator = OAuthCoordinator()

        #expect(throws: OAuthError.invalidClientMetadata("Unsupported scope.")) {
            try coordinator.registerClient(from: [
                "client_name": "Bad Scope",
                "redirect_uris": ["https://chatgpt.com/connector/oauth/test-callback"],
                "scope": "mcp:tools profile"
            ])
        }

        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://chatgpt.com/connector/oauth/test-callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "ChatGPT",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        #expect(throws: OAuthError.invalidScope("Unsupported scope.")) {
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": redirectURI,
                    "scope": "mcp:tools profile",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("invalid-scope")),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }

        let issued = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Refresh Scope",
            redirectURI: "https://refresh.example/callback",
            issuer: issuer,
            resource: resource
        )
        #expect(throws: OAuthError.invalidScope("Unsupported scope.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": issued.refreshToken,
                "scope": "profile",
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
        let validRotation = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": issued.refreshToken,
            "scope": "mcp:tools",
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect(validRotation["scope"] as? String == "mcp:tools")
    }

    @Test func loopbackRegistrationsReceiveIndependentAuthorizationIdentities() throws {
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
        let secondClientID = try #require(second["client_id"] as? String)
        #expect(secondClientID != clientID)
        #expect(second["redirect_uris"] as? [String] == ["http://127.0.0.1:49153/callback"])

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": secondClientID,
                "redirect_uri": "http://127.0.0.1:49153/callback",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: "codex-port-verifier"),
                "code_challenge_method": "S256"
            ],
            issuer: "http://127.0.0.1:1234",
            resource: "http://127.0.0.1:1234/mcp/test-instance"
        )
        let request = try #require(coordinator.approvalSnapshot().first { $0.id == requestID })
        #expect(request.clientID == secondClientID)
        #expect(request.clientTrustID.hasPrefix("macremote-dcr-v2-"))
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

    @Test func approvedClientPersistsAcrossCoordinatorRestart() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let redirectURI = "http://127.0.0.1/notion-callback"

        let coordinator = OAuthCoordinator(grantStore: store)
        let client = try coordinator.registerClient(from: [
            "client_name": "Notion",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        let firstRequestID = try beginSignIn(
            coordinator: coordinator,
            clientID: clientID,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.approve(requestID: firstRequestID))

        let reloaded = OAuthCoordinator(grantStore: store)
        let requestID = try beginSignIn(
            coordinator: reloaded,
            clientID: clientID,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )

        let request = try #require(reloaded.approvalSnapshot().first { $0.id == requestID })
        #expect(request.clientName == "Notion")
        #expect(request.redirectURI == redirectURI)
    }

    // MARK: - Clients the owner never approved

    /// Registering and asking to sign in need no credentials. Until the owner
    /// approves, nothing about the client may reach the disk, not even when
    /// another app's sign-in causes the file to be written.
    @Test func clientIsSavedOnlyOnceTheOwnerApprovesIt() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let coordinator = OAuthCoordinator(grantStore: store)
        let redirectURI = "http://127.0.0.1/callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "Unanswered",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        let requestID = try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)
        let approved = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Approved",
            redirectURI: "http://127.0.0.1/approved",
            issuer: "https://macremote.example",
            resource: "https://macremote.example/mcp"
        )
        #expect(try store.loadSnapshot().clients.map(\.id) == [approved.clientID])

        #expect(coordinator.approve(requestID: requestID))

        #expect(Set(try store.loadSnapshot().clients.map(\.id)) == [approved.clientID, clientID])
    }

    @Test func deniedClientIsForgottenWithItsLastWaitingSignIn() throws {
        let coordinator = OAuthCoordinator()
        let redirectURI = "http://127.0.0.1/callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "Denied",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        let first = try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)
        let second = try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)

        #expect(coordinator.deny(requestID: first))
        #expect(coordinator.clientIdentities().map(\.clientID) == [clientID])

        #expect(coordinator.deny(requestID: second))
        #expect(coordinator.clientIdentities().isEmpty)
        #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
            try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)
        }
    }

    @Test func unansweredClientIsForgottenWhenItsSignInExpires() throws {
        let coordinator = OAuthCoordinator()
        let redirectURI = "http://127.0.0.1/callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "Unanswered",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        let requestID = try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)

        // Any later request notices the expiry; this one carries the clock.
        let later = Date().addingTimeInterval(OAuthCoordinator.pendingAuthorizationLifetime + 1)
        #expect(throws: OAuthError.invalidGrant("Unknown authorization code.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "authorization_code",
                "code": "not-a-code",
                "code_verifier": validPKCEVerifier("expiry-clock")
            ], issuer: "http://127.0.0.1:1234", resource: "http://127.0.0.1:1234/mcp", now: later)
        }

        #expect(coordinator.approvalSnapshot().first { $0.id == requestID }?.state == .expired)
        #expect(coordinator.clientIdentities().isEmpty)
    }

    @Test func approvedClientSurvivesALaterDenial() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "http://127.0.0.1/callback"
        let issued = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Approved",
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        let again = try beginSignIn(
            coordinator: coordinator,
            clientID: issued.clientID,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )

        #expect(coordinator.deny(requestID: again))

        #expect(coordinator.validateAccessToken(issued.accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.clientIdentities().map(\.clientID) == [issued.clientID])
    }

    /// Why an unknown client ID that this Mac issued is still given a record:
    /// the app kept the ID, and the refusal happens in a browser where the app
    /// cannot see it. A denied app with a web return address can ask again.
    @Test func deniedAppCanAskAgainWithTheClientIDItKept() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let coordinator = OAuthCoordinator(grantStore: store)
        let redirectURI = "https://app.notion.com/workflows/mcp/oauth/callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "Notion",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)
        let denied = try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)
        #expect(coordinator.deny(requestID: denied))
        #expect(coordinator.clientIdentities().isEmpty)

        let again = try beginSignIn(coordinator: coordinator, clientID: clientID, redirectURI: redirectURI)

        #expect(coordinator.approvalSnapshot().first { $0.id == again }?.state == .pending)
        #expect(try store.loadSnapshot().clients.isEmpty)
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
            ], issuer: issuer, resource: resource, now: afterRetryGrace())
        }
    }

    @Test func oauthReconnectAndTokenRotationPreserveToolGrantIdentity() throws {
        let defaults = try isolatedOAuthDefaults()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let redirectURI = "https://chatgpt.com/connector/oauth/test-callback"
        let clientName = "ChatGPT"
        let tool = ToolDefinition(
            id: "reminders_today",
            permissionEpoch: "installed-reminders-generation",
            name: "Today",
            summary: "List today's reminders.",
            executablePath: "/usr/bin/true",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 4_096,
            origin: .userDefined,
            category: .reminders
        )
        let originalFingerprint = tool.securityFingerprint

        let firstCoordinator = OAuthCoordinator(
            grantStore: OAuthGrantStore(userDefaults: defaults)
        )
        let issued = try issueApprovedTokens(
            coordinator: firstCoordinator,
            clientName: clientName,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        let initialContext = try #require(firstCoordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            resource: resource
        ))
        let permissionStore = ClientToolPermissionStore(userDefaults: defaults)
        permissionStore.setAllowed(true, clientTrustID: initialContext.clientTrustID, tool: tool)

        // Reloading preserves the existing registration and its grants. A new
        // unauthenticated DCR request with identical metadata is a different
        // registration and must not inherit them.
        let reconnectedCoordinator = OAuthCoordinator(
            grantStore: OAuthGrantStore(userDefaults: defaults)
        )
        let registration = try reconnectedCoordinator.registerClient(from: [
            "client_name": clientName,
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        #expect(registration["client_id"] as? String != issued.clientID)
        let lookalikeID = try #require(registration["client_id"] as? String)
        let lookalikeRequestID = try reconnectedCoordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": lookalikeID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("lookalike")),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        let lookalikeRequest = try #require(
            reconnectedCoordinator.approvalSnapshot().first { $0.id == lookalikeRequestID }
        )
        #expect(lookalikeRequest.clientTrustID != initialContext.clientTrustID)
        #expect(!ClientToolPermissionStore(userDefaults: defaults).isAllowed(
            clientTrustID: lookalikeRequest.clientTrustID,
            tool: tool
        ))
        let reconnectedContext = try #require(reconnectedCoordinator.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            resource: resource
        ))
        #expect(reconnectedContext.clientTrustID == initialContext.clientTrustID)
        #expect(reconnectedContext.clientID == initialContext.clientID)
        #expect(ClientToolPermissionStore(userDefaults: defaults).isAllowed(
            clientTrustID: reconnectedContext.clientTrustID,
            tool: tool
        ))

        // Refreshing the access token also rotates the refresh token. Neither
        // token is part of the client trust identity or tool fingerprint.
        let rotated = try reconnectedCoordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": issued.refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        let rotatedAccessToken = try #require(rotated["access_token"] as? String)
        let rotatedRefreshToken = try #require(rotated["refresh_token"] as? String)
        #expect(rotatedAccessToken != issued.accessToken)
        #expect(rotatedRefreshToken != issued.refreshToken)
        let refreshedContext = try #require(reconnectedCoordinator.clientContext(
            forAccessToken: rotatedAccessToken,
            issuer: issuer,
            resource: resource
        ))
        #expect(refreshedContext.clientTrustID == initialContext.clientTrustID)
        #expect(tool.securityFingerprint == originalFingerprint)
        #expect(ClientToolPermissionStore(userDefaults: defaults).isAllowed(
            clientTrustID: refreshedContext.clientTrustID,
            tool: tool
        ))

        // Prove both sides survive another process reload rather than relying
        // on the in-memory coordinator or the original ToolDefinition value.
        let restartedCoordinator = OAuthCoordinator(
            grantStore: OAuthGrantStore(userDefaults: defaults)
        )
        let restartedContext = try #require(restartedCoordinator.clientContext(
            forAccessToken: rotatedAccessToken,
            issuer: issuer,
            resource: resource
        ))
        let reloadedTool = try JSONDecoder().decode(
            ToolDefinition.self,
            from: JSONEncoder().encode(tool)
        )
        #expect(restartedContext.clientTrustID == initialContext.clientTrustID)
        #expect(reloadedTool.securityFingerprint == originalFingerprint)
        #expect(ClientToolPermissionStore(userDefaults: defaults).isAllowed(
            clientTrustID: restartedContext.clientTrustID,
            tool: reloadedTool
        ))
    }

    @Test func legacyMetadataTrustGrantIsNotCarriedIntoReloadedRegistration() throws {
        let defaults = try isolatedOAuthDefaults()
        let grantStore = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"
        let issued = try issueApprovedTokens(
            coordinator: OAuthCoordinator(grantStore: grantStore),
            clientName: "Codex CLI",
            redirectURI: "http://127.0.0.1:49152/callback",
            issuer: issuer,
            resource: resource
        )
        var snapshot = try grantStore.loadSnapshot()
        let stored = try #require(snapshot.clients.first { $0.id == issued.clientID })
        let legacyTrustID = "macremote-trust-legacy-metadata"
        snapshot.clients = snapshot.clients.map { client in
            guard client.id == issued.clientID else { return client }
            return OAuthStoredClient(
                id: client.id,
                trustID: legacyTrustID,
                name: client.name,
                redirectURIs: client.redirectURIs,
                scopes: client.scopes,
                createdAt: client.createdAt,
                authenticationMethod: client.authenticationMethod,
                secretHash: client.secretHash
            )
        }
        try grantStore.saveSnapshot(snapshot)

        let tool = ToolDefinition(
            id: "legacy_write",
            permissionEpoch: "legacy-write-generation",
            name: "Legacy Write",
            summary: "Test migration isolation.",
            executablePath: "/usr/bin/true",
            argumentPattern: [],
            parameters: [],
            capability: .write,
            timeoutSeconds: 10,
            outputByteLimit: 4_096,
            origin: .userDefined,
            category: .utilities
        )
        let permissions = ClientToolPermissionStore(userDefaults: defaults)
        permissions.setAllowed(true, clientTrustID: legacyTrustID, tool: tool)

        let reloaded = OAuthCoordinator(grantStore: grantStore)
        let context = try #require(reloaded.clientContext(
            forAccessToken: issued.accessToken,
            issuer: issuer,
            resource: resource
        ))
        #expect(context.clientTrustID.hasPrefix("macremote-dcr-v2-"))
        #expect(context.clientTrustID != legacyTrustID)
        #expect(!permissions.isAllowed(clientTrustID: context.clientTrustID, tool: tool))
        #expect(permissions.isAllowed(clientTrustID: legacyTrustID, tool: tool))
        let migratedStored = try #require(
            grantStore.loadSnapshot().clients.first { $0.id == stored.id }
        )
        #expect(migratedStored.trustID == context.clientTrustID)
    }

    @Test func authorizeCanRecoverNotionCachedDynamicClientID() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let coordinator = OAuthCoordinator(grantStore: store)
        let issuer = "https://macremote.example.com"
        let resource = "\(issuer)/mcp/b06386fec5a37604c776b341e89f53aa"
        let redirectURI = "https://app.notion.com/workflows/mcp/oauth/callback"
        let clientID = "macremote-client-CsRCW9bcxFfllcH6Uqlsog"
        let verifier = validPKCEVerifier("notion-recovered-verifier")

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

    /// Claude's "Use Claude's published identity" option: the client ID is a
    /// web address, and nothing was registered first.
    @Test func claudeSignsInWithItsPublishedIdentity() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let coordinator = OAuthCoordinator(grantStore: store)
        let issuer = "https://macremote.example.com"
        let resource = "\(issuer)/mcp/b06386fec5a37604c776b341e89f53aa"
        let clientID = "https://claude.ai/oauth/mcp-oauth-client-metadata"
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"
        let verifier = validPKCEVerifier("claude-published-verifier")

        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "state": "claude-state",
                // The name comes from the built-in list, not from the request.
                "client_name": "Not Claude",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )

        let request = try #require(coordinator.approvalSnapshot().first { $0.id == requestID })
        #expect(request.clientName == "Claude")
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
        let refreshToken = try #require(token["refresh_token"] as? String)

        let reloaded = OAuthCoordinator(grantStore: store)
        #expect(reloaded.connectedClientSnapshot().first?.id == clientID)
        #expect(reloaded.connectedClientSnapshot().first?.name == "Claude")
        let renewed = try reloaded.exchangeToken(form: [
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((renewed["access_token"] as? String) != nil)
    }

    /// A published identity is accepted only as published: its own return
    /// address, and only an address on the built-in list.
    @Test func publishedIdentitiesAreNotAWayAroundRegistration() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example.com"
        let resource = "\(issuer)/mcp/test-instance"

        func begin(clientID: String, redirectURI: String) throws {
            _ = try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": redirectURI,
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("published-refused")),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }

        #expect(throws: OAuthError.invalidRequest("Unregistered redirect_uri.")) {
            try begin(
                clientID: "https://claude.ai/oauth/mcp-oauth-client-metadata",
                redirectURI: "https://claude.ai.example.net/api/mcp/auth_callback"
            )
        }
        for unknown in [
            "https://example.net/oauth/client-metadata.json",
            "https://claude.ai/oauth/mcp-oauth-client-metadata/",
            "https://claude.ai.example.net/oauth/mcp-oauth-client-metadata"
        ] {
            #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
                try begin(clientID: unknown, redirectURI: "https://claude.ai/api/mcp/auth_callback")
            }
        }
        #expect(coordinator.approvalSnapshot().isEmpty)
        #expect(coordinator.connectedClientSnapshot().isEmpty)
    }

    @Test func unsafeRedirectSchemesAreRejectedForDynamicClients() throws {
        let coordinator = OAuthCoordinator()

        for redirectURI in [
            "javascript:alert(1)",
            "file:///tmp/callback"
        ] {
            #expect(throws: OAuthError.invalidRedirectURI("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")) {
                try coordinator.registerClient(from: [
                    "client_name": "Unsafe",
                    "redirect_uris": [redirectURI],
                    "scope": "mcp:tools"
                ])
            }
        }
    }

    /// Starting a sign-in needs no credentials, so both limits matter: one
    /// client cannot hold many requests, and all clients together cannot fill
    /// the owner's queue without bound.
    @Test func pendingAuthorizationsAreCappedPerClientAndInTotal() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp/test-instance"

        func begin(clientID: String, state: String) throws {
            _ = try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": "http://127.0.0.1/callback",
                    "scope": "mcp:tools",
                    "state": state,
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "verifier-\(state)"),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }
        func register(_ name: String) throws -> String {
            let client = try coordinator.registerClient(from: [
                "client_name": name,
                "redirect_uris": ["http://127.0.0.1/callback"],
                "scope": "mcp:tools"
            ])
            return try #require(client["client_id"] as? String)
        }
        let tooMany = OAuthError.invalidRequest(
            "Too many pending authorization requests. Approve, deny, or wait for expiration."
        )

        let first = try register("First")
        for index in 0..<OAuthCoordinator.maxPendingAuthorizationsPerClient {
            try begin(clientID: first, state: "first-\(index)")
        }
        #expect(throws: tooMany) { try begin(clientID: first, state: "first-overflow") }

        var pending = OAuthCoordinator.maxPendingAuthorizationsPerClient
        var clientNumber = 0
        while pending < OAuthCoordinator.maxPendingAuthorizations {
            clientNumber += 1
            try begin(clientID: try register("Client \(clientNumber)"), state: "fill-\(clientNumber)")
            pending += 1
        }
        #expect(throws: tooMany) { try begin(clientID: try register("One More"), state: "overflow") }
    }

    /// A Client Secret app has no registered redirect, and the sign-in page
    /// navigates to whatever address the request names.
    @Test func confidentialClientRedirectIsValidatedAndStaysBound() throws {
        let credentials = OAuthConfidentialClientCredentials(
            clientID: "macremote-oauth-test",
            clientSecret: "test-secret"
        )
        let coordinator = OAuthCoordinator(clientAuthentication: .confidentialClientsRequired([credentials]))
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"

        func begin(redirectURI: String) throws -> UUID {
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": credentials.clientID,
                    "redirect_uri": redirectURI,
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: "verifier"),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }

        #expect(throws: OAuthError.self) { try begin(redirectURI: "javascript:alert(document.domain)//") }

        // The first completed sign-in binds the redirect...
        _ = try issueApprovedConfidentialToken(
            coordinator: coordinator,
            credentials: credentials,
            redirectURI: "https://app.example/callback",
            issuer: issuer,
            resource: resource
        )
        // ...and from then on a different one is refused, while the bound one works.
        #expect(throws: OAuthError.invalidRequest("Unregistered redirect_uri.")) {
            try begin(redirectURI: "https://evil.example/callback")
        }
        _ = try begin(redirectURI: "https://app.example/callback")
    }

    @Test func clientNamesAreReducedToPlainText() throws {
        let coordinator = OAuthCoordinator()
        let client = try coordinator.registerClient(from: [
            "client_name": "Claude \u{2705}\u{202E}\n  wants   more",
            "redirect_uris": ["https://app.example/callback"],
            "scope": "mcp:tools"
        ])
        _ = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": try #require(client["client_id"] as? String),
                "redirect_uri": "https://app.example/callback",
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: "verifier"),
                "code_challenge_method": "S256"
            ],
            issuer: "https://macremote.example",
            resource: "https://macremote.example/mcp"
        )
        #expect(coordinator.approvalSnapshot().first?.clientName == "Claude wants more")
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
        // Approved once, so the denials below do not make it unknown.
        _ = try signInRegisteredClient(
            coordinator: coordinator,
            clientID: clientID,
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )

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

    @Test func authorizationResponsesIncludeIssuerOnSuccessAndError() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://client.example/callback"
        let client = try coordinator.registerClient(from: [
            "client_name": "RFC 9207 Client",
            "redirect_uris": [redirectURI],
            "application_type": "web",
            "scope": "mcp:tools"
        ])
        let clientID = try #require(client["client_id"] as? String)

        func begin(state: String, verifier: String) throws -> UUID {
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": clientID,
                    "redirect_uri": redirectURI,
                    "scope": "mcp:tools",
                    "state": state,
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }

        let approvedID = try begin(
            state: "approved-state",
            verifier: validPKCEVerifier("approved-issuer-response")
        )
        #expect(coordinator.approve(requestID: approvedID))
        let approvedRedirect = try #require(
            coordinator.authorizationStatus(requestID: approvedID)["redirect_uri"] as? String
        )
        let approvedItems = URLComponents(string: approvedRedirect)?.queryItems ?? []
        #expect(approvedItems.first { $0.name == "code" }?.value != nil)
        #expect(approvedItems.first { $0.name == "iss" }?.value == issuer)
        #expect(approvedItems.first { $0.name == "state" }?.value == "approved-state")

        let deniedID = try begin(
            state: "denied-state",
            verifier: validPKCEVerifier("denied-issuer-response")
        )
        #expect(coordinator.deny(requestID: deniedID))
        let deniedRedirect = try #require(
            coordinator.authorizationStatus(requestID: deniedID)["redirect_uri"] as? String
        )
        let deniedItems = URLComponents(string: deniedRedirect)?.queryItems ?? []
        #expect(deniedItems.first { $0.name == "error" }?.value == "access_denied")
        #expect(deniedItems.first { $0.name == "iss" }?.value == issuer)
        #expect(deniedItems.first { $0.name == "state" }?.value == "denied-state")
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
                "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("right-verifier")),
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
                "code_verifier": validPKCEVerifier("wrong-verifier"),
                "resource": resource
            ], issuer: issuer, resource: resource)
        }
    }

    @Test func malformedPKCEVerifierIsRejectedBeforeS256Comparison() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://chatgpt.com/connector/oauth/test-callback"
        let validVerifier = validPKCEVerifier("valid-boundary-verifier")
        let client = try coordinator.registerClient(from: [
            "client_name": "ChatGPT",
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
                "code_challenge": OAuthCoordinator.pkceChallenge(for: validVerifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.approve(requestID: requestID))
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first { $0.name == "code" }?.value)

        let invalidVerifiers = [
            String(repeating: "a", count: 42),
            String(repeating: "a", count: 129),
            String(repeating: "a", count: 42) + "!",
            String(repeating: "a", count: 42) + "é"
        ]
        for verifier in invalidVerifiers {
            #expect(throws: OAuthError.invalidRequest("Invalid code_verifier.")) {
                try coordinator.exchangeToken(form: [
                    "grant_type": "authorization_code",
                    "client_id": clientID,
                    "redirect_uri": redirectURI,
                    "code": code,
                    "code_verifier": verifier,
                    "resource": resource
                ], issuer: issuer, resource: resource)
            }
        }

        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": validVerifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((token["access_token"] as? String) != nil)
    }

    @Test func authorizationCodeAndAccessTokenAreIssuerBound() throws {
        let coordinator = OAuthCoordinator()
        let verifier = validPKCEVerifier("issuer-bound-verifier")
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
        let verifier = validPKCEVerifier("resource-bound-verifier")
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
        let verifier = validPKCEVerifier("public-client-verifier")
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
        let verifier = validPKCEVerifier("metadata-mismatch-verifier")
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
        let verifier = validPKCEVerifier("confidential-verifier")

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

    // MARK: - Connected-app snapshot (D45)

    @Test func firstAndLastConnectedComeFromRegistrationAndLatestActivity() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"

        let registration = try coordinator.registerClient(from: [
            "client_name": "Claude",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(registration["client_id"] as? String)
        let registeredAt = Date()

        _ = try signInRegisteredClient(
            coordinator: coordinator,
            clientID: clientID,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )

        let client = try #require(coordinator.connectedClientSnapshot().first)
        #expect(abs(client.createdAt.timeIntervalSince(registeredAt)) < 5)
        #expect(client.lastAuthorizedAt >= client.createdAt)

        // An identical re-registration is a new, still-unapproved app. It must
        // not alter the existing connected app's dates or identity.
        let firstConnected = client.createdAt
        let newRegistration = try coordinator.registerClient(from: [
            "client_name": "Claude",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        #expect(newRegistration["client_id"] as? String != clientID)
        let reregistered = try #require(coordinator.connectedClientSnapshot().first)
        #expect(reregistered.createdAt == firstConnected)
        #expect(reregistered.id == clientID)
    }

    @Test func sessionStateIsActiveWhileTokensAreLive() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        _ = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Active App",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )

        let client = try #require(coordinator.connectedClientSnapshot().first)
        #expect(client.sessionState == .active)
        #expect(client.activeAccessTokens == 1)
        #expect(client.authenticationMethod == .none)
    }

    @Test func approvingWithoutTokenExchangeReadsAsWaitingToFinishSigningIn() throws {
        // The shipped bug: an app approved a second ago, with its code still
        // unredeemed, was labeled "Sign-in expired".
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"
        let registration = try coordinator.registerClient(from: [
            "client_name": "Mid Sign-In",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(registration["client_id"] as? String)
        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("waiting-verifier")),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.approve(requestID: requestID))

        let client = try #require(coordinator.connectedClientSnapshot().first)
        #expect(client.sessionState == .awaitingSignIn)
        #expect(client.activeAccessTokens == 0)
        #expect(client.activeRefreshTokens == 0)
    }

    @Test func lapsedTokensReadAsExpiredAndStayListed() async throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        coordinator.updateTokenLifetimes(access: 0.05, refresh: 0.05)
        _ = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Lapsed App",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        let client = try #require(coordinator.connectedClientSnapshot().first)
        #expect(client.sessionState == .expired)
        #expect(client.activeAccessTokens == 0)
        #expect(client.activeRefreshTokens == 0)
        #expect(client.name == "Lapsed App")
    }

    @Test func snapshotOrdersActiveThenWaitingThenExpired() async throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"

        _ = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Active App",
            redirectURI: "http://127.0.0.1/active",
            issuer: issuer,
            resource: resource
        )

        // The expired app signs in *after* the active one, so its
        // lastAuthorizedAt is newer — state still has to win the sort.
        coordinator.updateTokenLifetimes(access: 0.05, refresh: 0.05)
        _ = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Expired App",
            redirectURI: "http://127.0.0.1/expired",
            issuer: issuer,
            resource: resource
        )
        try await Task.sleep(nanoseconds: 200_000_000)

        let waitingRedirect = "http://127.0.0.1/waiting"
        let registration = try coordinator.registerClient(from: [
            "client_name": "Waiting App",
            "redirect_uris": [waitingRedirect],
            "scope": "mcp:tools"
        ])
        let waitingID = try #require(registration["client_id"] as? String)
        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": waitingID,
                "redirect_uri": waitingRedirect,
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("ordering-verifier")),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.approve(requestID: requestID))

        let snapshot = coordinator.connectedClientSnapshot()
        #expect(snapshot.map(\.name) == ["Active App", "Waiting App", "Expired App"])
        #expect(snapshot.map(\.sessionState) == [.active, .awaitingSignIn, .expired])
        #expect(try #require(snapshot.last).lastAuthorizedAt > snapshot[0].lastAuthorizedAt)
    }

    @Test func registrationsSharingADisplayNameStayDistinctInTheSnapshot() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let real = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Claude",
            redirectURI: "https://claude.ai/api/mcp/auth_callback",
            issuer: issuer,
            resource: resource
        )
        let impostor = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Claude",
            redirectURI: "https://impostor.example/callback",
            issuer: issuer,
            resource: resource
        )

        let snapshot = coordinator.connectedClientSnapshot()
        #expect(snapshot.count == 2)
        #expect(Set(snapshot.map(\.name)) == ["Claude"])
        #expect(Set(snapshot.map(\.id)) == [real.clientID, impostor.clientID])
        #expect(Set(snapshot.map(\.trustID)).count == 2)
    }

    @Test func confidentialClientsReportTheirRealSignInMethod() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let clientID = "macremote-oauth-Zt7k2p9WqfLmN3xR8sVb"
        let clientSecret = "generated-secret-abcdefghijklmnopqrstuvwxyz0123456789"
        let redirectURI = "https://raycast.com/redirect/extension"
        coordinator.updateClientAuthentication(
            .confidentialClientsRequired([
                OAuthConfidentialClientCredentials(clientID: clientID, clientSecret: clientSecret)
            ])
        )
        let verifier = validPKCEVerifier("confidential-method-verifier")
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
        _ = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)

        let client = try #require(coordinator.connectedClientSnapshot().first { $0.id == clientID })
        #expect(client.authenticationMethod.isConfidential)
        #expect(client.sessionState == .active)
    }

    @Test func publicClientRejectsUnexpectedClientSecret() throws {
        let coordinator = OAuthCoordinator()
        let verifier = validPKCEVerifier("public-secret-verifier")
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
        let verifier = validPKCEVerifier("refresh-verifier")
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
        #expect((rotated["refresh_token"] as? String) != refreshToken)
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "resource": resource
            ], issuer: issuer, resource: resource, now: afterRetryGrace())
        }
    }

    // MARK: - A refresh token that comes back after it was used

    @Test func usedRefreshTokenRevokesEveryTokenOfThatSignIn() throws {
        let reused = ReuseLog()
        let coordinator = OAuthCoordinator(refreshTokenReuseHandler: { reused.record($0) })
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "http://127.0.0.1/callback"
        let stolen = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Copied App",
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        // The same app, approved a second time: a separate sign-in.
        let otherSignIn = try signInRegisteredClient(
            coordinator: coordinator,
            clientID: stolen.clientID,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": stolen.refreshToken
        ], issuer: issuer, resource: resource)
        let rotatedAccessToken = try #require(rotated["access_token"] as? String)
        let rotatedRefreshToken = try #require(rotated["refresh_token"] as? String)

        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": stolen.refreshToken
            ], issuer: issuer, resource: resource, now: afterRetryGrace())
        }

        #expect(!coordinator.validateAccessToken(stolen.accessToken, issuer: issuer, resource: resource))
        #expect(!coordinator.validateAccessToken(rotatedAccessToken, issuer: issuer, resource: resource))
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": rotatedRefreshToken
            ], issuer: issuer, resource: resource)
        }
        #expect(coordinator.validateAccessToken(otherSignIn.accessToken, issuer: issuer, resource: resource))
        #expect(reused.names == ["Copied App"])
    }

    /// An app whose reply was lost sends the same refresh token again. It must
    /// get the tokens it missed, not a second pair and not a sign-out.
    @Test func retriedRefreshReturnsTheSameTokens() throws {
        let reused = ReuseLog()
        let coordinator = OAuthCoordinator(refreshTokenReuseHandler: { reused.record($0) })
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let issued = try issueApprovedTokens(
            coordinator: coordinator,
            clientName: "Retrying App",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )
        let form = ["grant_type": "refresh_token", "refresh_token": issued.refreshToken]
        let now = Date()
        let first = try coordinator.exchangeToken(form: form, issuer: issuer, resource: resource, now: now)

        let retry = try coordinator.exchangeToken(
            form: form,
            issuer: issuer,
            resource: resource,
            now: now.addingTimeInterval(OAuthCoordinator.refreshRetryGrace - 1)
        )

        #expect(retry["access_token"] as? String == first["access_token"] as? String)
        #expect(retry["refresh_token"] as? String == first["refresh_token"] as? String)
        let accessToken = try #require(first["access_token"] as? String)
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(reused.names.isEmpty)
    }

    /// The record of which tokens were used lives in the saved file, so a
    /// copy presented after a relaunch, generations later, still ends the
    /// sign-in.
    @Test func usedRefreshTokenIsRecognizedAfterRelaunch() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let first = OAuthCoordinator(grantStore: store)
        let issued = try issueApprovedTokens(
            coordinator: first,
            clientName: "Copied App",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )
        var current = issued.refreshToken
        var currentAccessToken = issued.accessToken
        for _ in 0..<2 {
            let rotated = try first.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": current
            ], issuer: issuer, resource: resource)
            current = try #require(rotated["refresh_token"] as? String)
            currentAccessToken = try #require(rotated["access_token"] as? String)
        }

        let reused = ReuseLog()
        let relaunched = OAuthCoordinator(refreshTokenReuseHandler: { reused.record($0) }, grantStore: store)
        #expect(relaunched.validateAccessToken(currentAccessToken, issuer: issuer, resource: resource))
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try relaunched.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": issued.refreshToken
            ], issuer: issuer, resource: resource, now: afterRetryGrace())
        }

        #expect(!relaunched.validateAccessToken(currentAccessToken, issuer: issuer, resource: resource))
        #expect(reused.names == ["Copied App"])
        #expect(try store.loadSnapshot().refreshTokens.isEmpty)
    }

    /// The reply to a refresh is kept in memory only. Right after a relaunch
    /// a retry cannot be answered, but it is still a retry: nothing is revoked.
    @Test func retryRightAfterRelaunchIsRefusedWithoutSigningOut() throws {
        let defaults = try isolatedOAuthDefaults()
        let store = OAuthGrantStore(userDefaults: defaults)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let first = OAuthCoordinator(grantStore: store)
        let issued = try issueApprovedTokens(
            coordinator: first,
            clientName: "Retrying App",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource
        )
        let form = ["grant_type": "refresh_token", "refresh_token": issued.refreshToken]
        let rotated = try first.exchangeToken(form: form, issuer: issuer, resource: resource)
        let accessToken = try #require(rotated["access_token"] as? String)

        let reused = ReuseLog()
        let relaunched = OAuthCoordinator(refreshTokenReuseHandler: { reused.record($0) }, grantStore: store)
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try relaunched.exchangeToken(form: form, issuer: issuer, resource: resource)
        }

        #expect(relaunched.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(reused.names.isEmpty)
    }

    /// A file written before sign-ins were tracked: no sign-in ID on any
    /// token, and a refresh token with no ID inside it. The app must stay
    /// connected, and its old token must still be caught when it comes back.
    @Test func grantsSavedByTheCurrentBuildLoadAndJoinReuseDetection() throws {
        let defaults = try isolatedOAuthDefaults()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let clientID = "macremote-client-SavedPublicClient01"
        let accessToken = "saved-access-token"
        let refreshToken = "saved-refresh-token"
        let issuedAt = Date().timeIntervalSinceReferenceDate
        func savedToken(_ token: String, lifetime: TimeInterval) -> String {
            """
            {"tokenHash":"\(sha256Hex(token))","clientID":"\(clientID)","issuer":"\(issuer)",\
            "resource":"\(resource)","scopes":["mcp:tools"],"issuedAt":\(issuedAt),"expiresAt":\(issuedAt + lifetime)}
            """
        }
        let savedFile = """
        {"clients":[{"id":"\(clientID)","trustID":"macremote-dcr-v2-saved","name":"Saved App",\
        "redirectURIs":["http://127.0.0.1/callback"],"scopes":["mcp:tools"],"createdAt":\(issuedAt)}],\
        "accessTokens":[\(savedToken(accessToken, lifetime: 900))],\
        "refreshTokens":[\(savedToken(refreshToken, lifetime: 86_400))]}
        """
        defaults.set(Data(savedFile.utf8), forKey: "MacRemote.oauthGrants")

        let reused = ReuseLog()
        let coordinator = OAuthCoordinator(
            refreshTokenReuseHandler: { reused.record($0) },
            grantStore: OAuthGrantStore(userDefaults: defaults)
        )
        #expect(coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(coordinator.connectedClientSnapshot().map(\.name) == ["Saved App"])
        let renewed = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ], issuer: issuer, resource: resource)
        let renewedAccessToken = try #require(renewed["access_token"] as? String)
        #expect(coordinator.validateAccessToken(renewedAccessToken, issuer: issuer, resource: resource))

        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try coordinator.exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ], issuer: issuer, resource: resource, now: afterRetryGrace())
        }
        #expect(!coordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource))
        #expect(!coordinator.validateAccessToken(renewedAccessToken, issuer: issuer, resource: resource))
        #expect(reused.names == ["Saved App"])
    }

    @Test func refreshTokenIsIssuerBound() throws {
        let coordinator = OAuthCoordinator()
        let verifier = validPKCEVerifier("refresh-issuer-verifier")
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
        let verifier = validPKCEVerifier("refresh-resource-verifier")
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
        let verifier = validPKCEVerifier("revoke-verifier")
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

        // The survivor keeps every kind of state, not just its access token.
        let survivor = try #require(coordinator.connectedClientSnapshot().first)
        #expect(survivor.sessionState == .active)
        #expect(survivor.activeAccessTokens == 1)
        #expect(survivor.activeRefreshTokens == 1)
        let refreshed = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": second.refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect((refreshed["access_token"] as? String) != nil)
        #expect(coordinator.approvalSnapshot().contains { $0.clientID == second.clientID })
        #expect(coordinator.approvalSnapshot().contains { $0.clientID == first.clientID } == false)

        let reregistered = try coordinator.registerClient(from: [
            "client_name": "First Client",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let reregisteredClientID = try #require(reregistered["client_id"] as? String)
        #expect(reregisteredClientID != first.clientID)
    }

    /// The owner's client IDs and secrets belong to OAuth Client Secret.
    /// Under Dynamic OAuth they are not a way in, even when they exist.
    @Test func ownerCredentialsAreRefusedWhileAppsRegisterThemselves() throws {
        let coordinator = OAuthCoordinator(clientAuthentication: .dynamicPublicClients)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"

        #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
            try coordinator.beginAuthorization(
                queryItems: [
                    "response_type": "code",
                    "client_id": "macremote-oauth-Zt7k2p9WqfLmN3xR8sVb",
                    "redirect_uri": "https://raycast.com/redirect/extension",
                    "scope": "mcp:tools",
                    "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier("owner-credentials")),
                    "code_challenge_method": "S256",
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource
            )
        }
    }

    @Test func eachPolicyAdmitsOneKindOfApp() {
        let credentials = [OAuthConfidentialClientCredentials(clientID: "macremote-oauth-x", clientSecret: "y")]

        let dynamic = OAuthClientAuthenticationPolicy.dynamicPublicClients
        #expect(dynamic.supportsDynamicClientRegistration)
        #expect(dynamic.confidentialClients.isEmpty)
        // A self-registering app may ask for a secret of its own. That is
        // not the owner's client ID and secret, which this policy refuses.
        #expect(dynamic.tokenEndpointAuthMethodsSupported == ["none", "client_secret_basic", "client_secret_post"])

        let secret = OAuthClientAuthenticationPolicy.confidentialClientsRequired(credentials)
        #expect(!secret.supportsDynamicClientRegistration)
        #expect(secret.confidentialClients == credentials)
        #expect(!secret.tokenEndpointAuthMethodsSupported.contains("none"))

        let header = OAuthClientAuthenticationPolicy.noOAuthClients
        #expect(!header.supportsDynamicClientRegistration)
        #expect(header.confidentialClients.isEmpty)
    }

    // MARK: - Token lifetimes

    @Test func defaultTokenLifetimeIssuance() throws {
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let verifier = validPKCEVerifier("lifetime-default-verifier")
        let client = try coordinator.registerClient(from: [
            "client_name": "Lifetime Default",
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
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value)
        let token = try coordinator.exchangeToken(form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": "http://127.0.0.1/callback",
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect(token["expires_in"] as? Int == 900)
        #expect(token["refresh_expires_in"] as? Int == 86_400)
    }

    @Test func customAccessTokenLifetimeHonored() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateTokenLifetimes(access: 3_600, refresh: OAuthCoordinator.defaultRefreshTokenLifetime)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let issued = try issueApprovedTokensAt(
            coordinator: coordinator,
            clientName: "Access Lifetime",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource,
            now: issuedAt
        )
        #expect(issued.expiresIn == 3_600)
        #expect(issued.refreshExpiresIn == 86_400)
        #expect(
            coordinator.validateAccessToken(
                issued.accessToken,
                issuer: issuer,
                resource: resource,
                now: issuedAt.addingTimeInterval(1_800)
            )
        )
        #expect(
            coordinator.validateAccessToken(
                issued.accessToken,
                issuer: issuer,
                resource: resource,
                now: issuedAt.addingTimeInterval(3_700)
            ) == false
        )
    }

    @Test func customRefreshTokenLifetimeEnforced() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateTokenLifetimes(access: OAuthCoordinator.defaultAccessTokenLifetime, refresh: 604_800)
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let issuedAt = Date(timeIntervalSince1970: 1_700_100_000)
        let issued = try issueApprovedTokensAt(
            coordinator: coordinator,
            clientName: "Refresh Lifetime",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource,
            now: issuedAt
        )
        #expect(issued.refreshExpiresIn == 604_800)

        let stillValid = try coordinator.exchangeToken(
            form: [
                "grant_type": "refresh_token",
                "refresh_token": issued.refreshToken,
                "resource": resource
            ],
            issuer: issuer,
            resource: resource,
            now: issuedAt.addingTimeInterval(604_799)
        )
        #expect((stillValid["access_token"] as? String) != nil)

        let expiredCoordinator = OAuthCoordinator()
        expiredCoordinator.updateTokenLifetimes(
            access: OAuthCoordinator.defaultAccessTokenLifetime,
            refresh: 604_800
        )
        let expiredIssued = try issueApprovedTokensAt(
            coordinator: expiredCoordinator,
            clientName: "Refresh Lifetime Expired",
            redirectURI: "http://127.0.0.1/callback",
            issuer: issuer,
            resource: resource,
            now: issuedAt
        )
        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try expiredCoordinator.exchangeToken(
                form: [
                    "grant_type": "refresh_token",
                    "refresh_token": expiredIssued.refreshToken,
                    "resource": resource
                ],
                issuer: issuer,
                resource: resource,
                now: issuedAt.addingTimeInterval(604_800)
            )
        }
    }

    @Test func refreshTokenRotationWithCustomLifetimes() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateTokenLifetimes(access: 3_600, refresh: 604_800)
        let verifier = validPKCEVerifier("custom-rotation-verifier")
        let issuer = "http://127.0.0.1:1234"
        let resource = "\(issuer)/mcp/test-instance"
        let client = try coordinator.registerClient(from: [
            "client_name": "Custom Rotation",
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
        #expect(token["expires_in"] as? Int == 3_600)
        #expect(token["refresh_expires_in"] as? Int == 604_800)
        let refreshToken = try #require(token["refresh_token"] as? String)
        let rotated = try coordinator.exchangeToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "resource": resource
        ], issuer: issuer, resource: resource)
        #expect(rotated["expires_in"] as? Int == 3_600)
        #expect(rotated["refresh_expires_in"] as? Int == 604_800)
        #expect((rotated["refresh_token"] as? String) != refreshToken)
    }

    // MARK: - Static header token (Single Header sign-in)

    @Test func staticHeaderTokenAuthenticatesAcrossIssuersAndResources() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken("header-secret", clientName: "Single Header Client")

        let context = try #require(coordinator.clientContext(
            forAccessToken: "header-secret",
            issuer: "https://macremote.example.com",
            resource: "https://macremote.example.com/mcp"
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
            issuer: "https://macremote.example.com",
            resource: "https://macremote.example.com/mcp"
        ) == nil)

        coordinator.updateStaticHeaderToken(nil)
        #expect(coordinator.clientContext(
            forAccessToken: "header-secret",
            issuer: "https://macremote.example.com",
            resource: "https://macremote.example.com/mcp"
        ) == nil)
    }

    @Test func staticHeaderTokenDoesNotShadowOAuthTokens() throws {
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken("header-secret")
        let issuer = "https://macremote.example.com"
        let resource = "https://macremote.example.com/mcp"
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

/// A moment at which a refresh token used just now is no longer a retry.
private func afterRetryGrace() -> Date {
    Date().addingTimeInterval(OAuthCoordinator.refreshRetryGrace + 1)
}

/// Collects the app names the coordinator reports for reused refresh tokens.
private final class ReuseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(name)
    }
}

/// Starts a sign-in for a client that is already known and returns the
/// request the owner would see.
@discardableResult
private func beginSignIn(
    coordinator: OAuthCoordinator,
    clientID: String,
    redirectURI: String,
    issuer: String = "https://macremote.example",
    resource: String = "https://macremote.example/mcp"
) throws -> UUID {
    try coordinator.beginAuthorization(
        queryItems: [
            "response_type": "code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "scope": "mcp:tools",
            "code_challenge": OAuthCoordinator.pkceChallenge(for: validPKCEVerifier(UUID().uuidString)),
            "code_challenge_method": "S256",
            "resource": resource
        ],
        issuer: issuer,
        resource: resource
    )
}

/// The form a token takes on disk, for tests that seed a saved file.
private func sha256Hex(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func validPKCEVerifier(_ seed: String) -> String {
    if seed.utf8.count >= 43 {
        return String(seed.prefix(128))
    }
    return seed + String(repeating: "~", count: 43 - seed.utf8.count)
}

private func issueApprovedTokensAt(
    coordinator: OAuthCoordinator,
    clientName: String,
    redirectURI: String,
    issuer: String,
    resource: String,
    now: Date
) throws -> (
    clientID: String,
    accessToken: String,
    refreshToken: String,
    expiresIn: Int,
    refreshExpiresIn: Int
) {
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
    ], issuer: issuer, resource: resource, now: now)
    return (
        clientID,
        try #require(token["access_token"] as? String),
        try #require(token["refresh_token"] as? String),
        try #require(token["expires_in"] as? Int),
        try #require(token["refresh_expires_in"] as? Int)
    )
}

/// Signs in a client that is already registered, so a test can observe the
/// registration timestamp separately from the sign-in.
private func signInRegisteredClient(
    coordinator: OAuthCoordinator,
    clientID: String,
    redirectURI: String,
    issuer: String,
    resource: String
) throws -> (accessToken: String, refreshToken: String) {
    let verifier = "verifier-\(UUID().uuidString)"
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
        try #require(token["access_token"] as? String),
        try #require(token["refresh_token"] as? String)
    )
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
