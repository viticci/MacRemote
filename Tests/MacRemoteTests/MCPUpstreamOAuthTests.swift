import CryptoKit
import Foundation
import Testing
@testable import MacRemote

/// MacRemote as an OAuth client of an upstream MCP server (D62). The mock
/// answers metadata, registration, and token requests for
/// `https://oauth-mcp.test`; the reply address is a real listener on this Mac.
@Suite(.serialized)
struct MCPUpstreamOAuthTests {
    private static let serverURL = "https://oauth-mcp.test/mcp"

    @Test func signsInThroughDiscoveryRegistrationPKCEAndTheLoopbackReply() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.signInResponder())
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        let authorizeURL = LockedBox<URL?>(nil)
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: store,
            openURL: { url in
                authorizeURL.value = url
                await Self.answerAuthorize(url, state: Self.query(url)["state"] ?? "")
            },
            signInTimeout: 10
        )

        let credential = try await client.signIn(serverURL: Self.serverURL, serverName: "Mock")

        #expect(credential.accessToken == "token-1")
        #expect(credential.clientID == "client-1")
        #expect(credential.resource == "https://oauth-mcp.test")
        #expect(store.credential(for: Self.serverURL)?.accessToken == "token-1")
        #expect(store.isSignedIn("https://OAUTH-MCP.test/mcp/"))

        let authorize = try #require(authorizeURL.value)
        let authorizeQuery = Self.query(authorize)
        #expect(authorize.path == "/authorize")
        #expect(authorizeQuery["response_type"] == "code")
        #expect(authorizeQuery["client_id"] == "client-1")
        #expect(authorizeQuery["code_challenge_method"] == "S256")
        #expect(authorizeQuery["resource"] == "https://oauth-mcp.test")
        let redirectURI = try #require(authorizeQuery["redirect_uri"])
        #expect(redirectURI.hasPrefix("http://127.0.0.1:"))
        #expect(redirectURI.hasSuffix("/callback"))

        let requests = OAuthMock.requests()
        let registration = try #require(requests.first { $0.path == "/register" })
        let registrationBody = try #require(try JSONSerialization.jsonObject(with: registration.body) as? [String: Any])
        #expect(registrationBody["redirect_uris"] as? [String] == [redirectURI])
        #expect(registrationBody["token_endpoint_auth_method"] as? String == "none")
        #expect(registrationBody["client_name"] as? String == "MacRemote")

        let token = try #require(requests.first { $0.path == "/token" })
        let form = Self.form(token.body)
        #expect(form["grant_type"] == "authorization_code")
        #expect(form["code"] == "code-1")
        #expect(form["client_id"] == "client-1")
        #expect(form["redirect_uri"] == redirectURI)
        #expect(form["resource"] == "https://oauth-mcp.test")
        let verifier = try #require(form["code_verifier"])
        let expectedChallenge = MCPUpstreamOAuthClient.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        #expect(authorizeQuery["code_challenge"] == expectedChallenge)
    }

    @Test func rejectsAReplyWhoseStateDoesNotMatch() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.signInResponder())
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: store,
            openURL: { url in await Self.answerAuthorize(url, state: "not-the-state") },
            signInTimeout: 10
        )

        await #expect(throws: MCPUpstreamOAuthError.stateMismatch) {
            try await client.signIn(serverURL: Self.serverURL, serverName: "Mock")
        }
        #expect(store.credential(for: Self.serverURL) == nil)
        #expect(!OAuthMock.requests().contains { $0.path == "/token" })
    }

    @Test func refusesPlainHTTPSignInEndpointsOffThisMac() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { request in
            switch request.path {
            case "/.well-known/oauth-authorization-server":
                return .json(#"{"issuer":"https://oauth-mcp.test","authorization_endpoint":"http://example.com/authorize","token_endpoint":"https://oauth-mcp.test/token","registration_endpoint":"https://oauth-mcp.test/register","code_challenge_methods_supported":["S256"]}"#)
            default:
                return .notFound
            }
        }
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { _ in Issue.record("the browser must never open for a refused endpoint") }
        )

        await #expect(throws: MCPUpstreamOAuthError.insecureEndpoint("http://example.com/authorize")) {
            try await client.signIn(serverURL: Self.serverURL, serverName: "Mock")
        }
    }

    /// Asked for one authorization server, MacRemote must not sign in with
    /// the endpoints of another, such as a different tenant on the same host.
    @Test func metadataForADifferentIssuerIsRefused() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { request in
            switch request.path {
            case "/.well-known/oauth-protected-resource":
                return .json(#"{"resource":"https://oauth-mcp.test","authorization_servers":["https://oauth-mcp.test/tenant-a"]}"#)
            case "/.well-known/oauth-authorization-server":
                return .json(#"{"issuer":"https://oauth-mcp.test","authorization_endpoint":"https://oauth-mcp.test/authorize","token_endpoint":"https://oauth-mcp.test/token","registration_endpoint":"https://oauth-mcp.test/register","code_challenge_methods_supported":["S256"]}"#)
            default:
                return .notFound
            }
        }
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { _ in Issue.record("the browser must never open for another issuer's endpoints") }
        )

        await #expect(throws: MCPUpstreamOAuthError.invalidMetadata(
            "it describes https://oauth-mcp.test, not https://oauth-mcp.test/tenant-a."
        )) {
            try await client.signIn(serverURL: Self.serverURL, serverName: "Mock")
        }
        #expect(!OAuthMock.requests().contains { $0.path == "/register" })
    }

    /// An older server names no authorization server and publishes sign-in
    /// metadata at its own address, often that of a sign-in service it uses.
    /// The issuer MacRemote asked for was then only its own guess.
    @Test func aServerThatNamesNoIssuerMayUseAnotherSignInService() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { request in
            request.path == "/.well-known/oauth-authorization-server"
                ? .json(#"{"issuer":"https://login.example","authorization_endpoint":"https://login.example/authorize","token_endpoint":"https://login.example/token"}"#)
                : .notFound
        }
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { _ in }
        )

        let metadata = try #require(try await client.discover(serverURL: Self.serverURL))
        #expect(metadata.issuer == "https://login.example")
        #expect(metadata.tokenEndpoint == "https://login.example/token")
    }

    /// The protected-resource document says which resource a token is for. A
    /// server must not be able to ask for a token meant for another origin.
    @Test func aDeclaredResourceOnAnotherOriginIsNotUsed() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { request in
            request.path == "/.well-known/oauth-protected-resource"
                ? .json(#"{"resource":"https://victim.example/api","authorization_servers":["https://oauth-mcp.test"]}"#)
                : Self.signInResponder()(request)
        }
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { _ in }
        )

        let metadata = try #require(try await client.discover(serverURL: Self.serverURL))

        #expect(metadata.resource == Self.serverURL)
    }

    @Test func aHostnameThatOnlyLooksLikeLoopbackIsNotTrusted() throws {
        #expect(throws: MCPUpstreamOAuthError.insecureEndpoint("http://127.example.com/token")) {
            try MCPUpstreamOAuthClient.requireTrustworthy("http://127.example.com/token")
        }
        try MCPUpstreamOAuthClient.requireTrustworthy("http://127.0.0.1:8080/token")
        try MCPUpstreamOAuthClient.requireTrustworthy("http://localhost:8080/token")
        try MCPUpstreamOAuthClient.requireTrustworthy("http://[::1]:8080/token")
    }

    /// Many servers replace the refresh token each time it is used. Two calls
    /// that find the same expired token must share one refresh, or the second
    /// would present a token that is already spent.
    @Test func concurrentRefreshesSpendTheRefreshTokenOnce() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.rotatingRefreshResponder())
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        try store.save(Self.credential(token: "token-1", refreshToken: "refresh-1", expiresAt: .distantPast), for: Self.serverURL)
        // Tool calls and scans each hold their own client over the one store.
        let first = MCPUpstreamOAuthClient(urlSession: session, store: store, openURL: { _ in })
        let second = MCPUpstreamOAuthClient(urlSession: session, store: store, openURL: { _ in })

        async let firstToken = first.accessToken(for: Self.serverURL)
        async let secondToken = second.accessToken(for: Self.serverURL)
        let tokens = await [firstToken, secondToken]

        #expect(tokens == ["token-2", "token-2"])
        #expect(OAuthMock.requests().filter { $0.path == "/token" }.count == 1)
        #expect(store.credential(for: Self.serverURL)?.refreshToken == "refresh-2")
    }

    @Test func aRefreshThatFinishesAfterSignOutDoesNotSignBackIn() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.rotatingRefreshResponder())
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        try store.save(Self.credential(token: "token-1", refreshToken: "refresh-1", expiresAt: .distantPast), for: Self.serverURL)
        let client = MCPUpstreamOAuthClient(urlSession: session, store: store, openURL: { _ in })

        async let token = client.accessToken(for: Self.serverURL)
        while OAuthMock.requests().isEmpty {
            try await Task.sleep(for: .milliseconds(5))
        }
        client.forget(serverURL: Self.serverURL)

        #expect(await token == nil)
        #expect(store.credential(for: Self.serverURL) == nil)
    }

    @Test func aStoredTokenEndpointThatIsNotTrustworthyNeverGetsTheRefreshToken() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { _ in .notFound }
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        var credential = Self.credential(token: "token-1", refreshToken: "refresh-1", expiresAt: .distantPast)
        credential.tokenEndpoint = "http://oauth-mcp.test/token"
        try store.save(credential, for: Self.serverURL)
        let client = MCPUpstreamOAuthClient(urlSession: session, store: store, openURL: { _ in })

        #expect(await client.accessToken(for: Self.serverURL) == nil)
        #expect(OAuthMock.requests().isEmpty)
    }

    /// Nobody answered in the browser. The sign-in has to end by itself, and
    /// the address it opened for the reply has to close.
    @Test func anUnansweredSignInTimesOutAndClosesItsReplyAddress() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.signInResponder())
        let authorizeURL = LockedBox<URL?>(nil)
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { authorizeURL.value = $0 },
            signInTimeout: 0.5
        )

        let started = Date()
        let signIn = Task { try await client.signIn(serverURL: Self.serverURL, serverName: "Mock") }
        let rescue = Self.answerLate(authorizeURL)
        await #expect(throws: MCPUpstreamOAuthError.timedOut(serverName: "Mock")) {
            _ = try await signIn.value
        }
        rescue.cancel()

        #expect(Date().timeIntervalSince(started) < 3)
        #expect(await Self.replyAddressIsClosed(authorizeURL.value))
    }

    @Test func aCancelledSignInEndsAndClosesItsReplyAddress() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.signInResponder())
        let authorizeURL = LockedBox<URL?>(nil)
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { authorizeURL.value = $0 },
            signInTimeout: 30
        )

        let signIn = Task { try await client.signIn(serverURL: Self.serverURL, serverName: "Mock") }
        while authorizeURL.value == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let cancelled = Date()
        signIn.cancel()
        let rescue = Self.answerLate(authorizeURL)
        await #expect(throws: MCPUpstreamOAuthError.cancelled) {
            _ = try await signIn.value
        }
        rescue.cancel()

        #expect(Date().timeIntervalSince(cancelled) < 3)
        #expect(await Self.replyAddressIsClosed(authorizeURL.value))
    }

    /// Each sign-in owns its reply address. One that is abandoned while a
    /// second one for the same server succeeds still cleans up after itself.
    @Test func aSecondSignInWhileOneWaitsLeavesNoReplyAddressOpen() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.signInResponder())
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        let abandonedURL = LockedBox<URL?>(nil)
        let abandoned = MCPUpstreamOAuthClient(
            urlSession: session,
            store: store,
            openURL: { abandonedURL.value = $0 },
            signInTimeout: 1
        )
        let answeredURL = LockedBox<URL?>(nil)
        let answered = MCPUpstreamOAuthClient(
            urlSession: session,
            store: store,
            openURL: { url in
                answeredURL.value = url
                await Self.answerAuthorize(url, state: Self.query(url)["state"] ?? "")
            },
            signInTimeout: 10
        )

        let started = Date()
        let first = Task { try await abandoned.signIn(serverURL: Self.serverURL, serverName: "Mock") }
        while abandonedURL.value == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        let credential = try await answered.signIn(serverURL: Self.serverURL, serverName: "Mock")
        let rescue = Self.answerLate(abandonedURL)
        await #expect(throws: MCPUpstreamOAuthError.timedOut(serverName: "Mock")) {
            _ = try await first.value
        }
        rescue.cancel()

        #expect(Date().timeIntervalSince(started) < 3)
        #expect(store.credential(for: Self.serverURL) == credential)
        #expect(await Self.replyAddressIsClosed(abandonedURL.value))
        #expect(await Self.replyAddressIsClosed(answeredURL.value))
    }

    @Test func aServerWithoutOAuthMetadataIsNotSignInCapable() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { _ in .notFound }
        let client = MCPUpstreamOAuthClient(
            urlSession: session,
            store: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore()),
            openURL: { _ in }
        )

        #expect(await client.supportsSignIn(serverURL: Self.serverURL) == false)
        await #expect(throws: MCPUpstreamOAuthError.notSupported(serverName: "Mock")) {
            try await client.signIn(serverURL: Self.serverURL, serverName: "Mock")
        }
    }

    @Test func bridgeCallSendsTheStoredSignInToken() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.mcpResponder(status: 200))
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        try store.save(Self.credential(token: "token-1"), for: Self.serverURL)

        let client = MCPHTTPBridgeClient(urlSession: session, oauthStore: store)
        let outcome = try await client.call(tool: Self.tool(), parameters: [:])

        #expect(outcome.succeeded, "\(outcome.stderr)")
        let call = try #require(OAuthMock.requests().first { $0.rpcMethod == "tools/call" })
        #expect(call.headers["Authorization"] == "Bearer token-1")
    }

    @Test func bridgeCallWithoutASignInSaysSoInsteadOfCalling() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.mcpResponder(status: 200))
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())

        let client = MCPHTTPBridgeClient(urlSession: session, oauthStore: store)
        let outcome = try await client.call(tool: Self.tool(), parameters: [:])

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("Sign in to Mock"))
        #expect(OAuthMock.requests().isEmpty)
    }

    @Test func aRejectedSignInTokenIsForgottenSoToolsAskForANewSignIn() async throws {
        let session = OAuthMock.session()
        OAuthMock.install(responder: Self.mcpResponder(status: 401))
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        try store.save(Self.credential(token: "stale"), for: Self.serverURL)

        let client = MCPHTTPBridgeClient(urlSession: session, oauthStore: store)
        let outcome = try await client.call(tool: Self.tool(), parameters: [:])

        #expect(!outcome.succeeded)
        #expect(outcome.stderr.contains("Sign in to Mock"))
        #expect(store.credential(for: Self.serverURL) == nil)
    }

    /// A refused refresh ends the sign-in. A server that is merely in trouble
    /// says nothing about the token, so the sign-in has to survive it.
    @Test(arguments: [(400, false), (503, true)])
    func aFailedRefreshForgetsTheSignInOnlyWhenTheServerRefusedIt(
        tokenStatus: Int,
        keepsSignIn: Bool
    ) async throws {
        let session = OAuthMock.session()
        OAuthMock.install { request in
            request.path == "/token"
                ? .json(#"{"error":"invalid_grant"}"#, statusCode: tokenStatus)
                : .init(statusCode: 401, body: "")
        }
        let store = MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        try store.save(Self.credential(token: "stale", refreshToken: "refresh-1"), for: Self.serverURL)

        let client = MCPHTTPBridgeClient(urlSession: session, oauthStore: store)
        let outcome = try await client.call(tool: Self.tool(), parameters: [:])

        #expect(!outcome.succeeded)
        #expect((store.credential(for: Self.serverURL) != nil) == keepsSignIn)
    }

    @Test func scannerTurnsA401FromASignInCapableServerIntoSignInRequired() async throws {
        let session = OAuthMock.session()
        OAuthMock.install { request in
            request.method == "POST" ? .init(statusCode: 401, body: "") : Self.signInResponder()(request)
        }
        let scanner = LocalMCPScanner(
            homeDirectory: FileManager.default.temporaryDirectory,
            urlSession: session,
            executablePath: { _ in nil },
            oauthStore: MCPUpstreamOAuthStore(keychain: InMemoryKeychainSecretStore())
        )
        let candidate = Self.candidate(headers: [])

        var failure: (any Error)?
        do {
            _ = try await scanner.probe(candidate: candidate)
        } catch {
            failure = error
        }

        #expect(LocalMCPScanner.isSignInRequired(failure))
        #expect(failure?.localizedDescription == "Sign in to Mock in MacRemote › Tools to use its tools.")

        let signedIn = candidate.signedInWithMacRemote()
        #expect(signedIn.usesUpstreamOAuth)
        #expect(signedIn.headers == [.upstreamOAuthAuthorization])
        #expect(signedIn.canonicalRuntimeIdentity != candidate.canonicalRuntimeIdentity)
        #expect(signedIn.bridgeIdentity == candidate.bridgeIdentity)
    }

    @Test func aStaleExtensionTokenIsReplacedNotStacked() {
        let stale = MCPBridgeHeader(
            name: "Authorization",
            valueSource: MCPBridgeHeaderValueSource(
                kind: .jsonFile,
                filePath: "/missing/manifest.json",
                keyPath: ["server", "mcp_config", "env", "MCP_TOKEN"],
                prefix: "Bearer "
            )
        )
        let other = MCPBridgeHeader(name: "X-Client", value: "macremote")
        let signedIn = Self.candidate(headers: [stale, other]).signedInWithMacRemote()
        #expect(signedIn.headers == [other, .upstreamOAuthAuthorization])
    }

    @Test func storeAccountsIgnoreCaseTrailingSlashAndQuery() {
        #expect(MCPUpstreamOAuthStore.account(for: "HTTP://127.0.0.1:39725/mcp/") == "http://127.0.0.1:39725/mcp")
        #expect(MCPUpstreamOAuthStore.account(for: "https://Example.com/MCP?x=1#f") == "https://example.com/MCP")
    }

    @Test func theReplyListenerAcceptsOnlyTheCallbackPath() {
        let reply = MCPUpstreamOAuthRedirectListener.parseReply(
            fromRequest: "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )
        #expect(reply == .init(code: "abc", state: "xyz", error: nil, errorDescription: nil))
        #expect(MCPUpstreamOAuthRedirectListener.parseReply(fromRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n") == nil)
        #expect(MCPUpstreamOAuthRedirectListener.parseReply(fromRequest: "POST /callback?code=abc HTTP/1.1\r\n\r\n") == nil)
        let denied = MCPUpstreamOAuthRedirectListener.parseReply(
            fromRequest: "GET /callback?error=access_denied&error_description=No&state=s HTTP/1.1\r\n\r\n"
        )
        #expect(denied?.error == "access_denied")
    }

    // MARK: - Fixtures

    private static func signInResponder() -> OAuthMock.Responder {
        { request in
            switch (request.method, request.path) {
            case ("GET", "/.well-known/oauth-protected-resource"):
                return .json(#"{"resource":"https://oauth-mcp.test","authorization_servers":["https://oauth-mcp.test"]}"#)
            case ("GET", "/.well-known/oauth-authorization-server"):
                return .json(#"{"issuer":"https://oauth-mcp.test","authorization_endpoint":"https://oauth-mcp.test/authorize","token_endpoint":"https://oauth-mcp.test/token","registration_endpoint":"https://oauth-mcp.test/register","revocation_endpoint":"https://oauth-mcp.test/revoke","code_challenge_methods_supported":["S256"],"grant_types_supported":["authorization_code"]}"#)
            case ("POST", "/register"):
                return .json(#"{"client_id":"client-1","token_endpoint_auth_method":"none"}"#, statusCode: 201)
            case ("POST", "/token"):
                let form = Self.form(request.body)
                guard form["code"] == "code-1", form["code_verifier"] != nil else {
                    return .json(#"{"error":"invalid_grant"}"#, statusCode: 400)
                }
                return .json(#"{"access_token":"token-1","token_type":"Bearer","expires_in":3600}"#)
            default:
                return .notFound
            }
        }
    }

    /// The MCP endpoint of a server that only speaks the legacy flow; every
    /// POST answers `status` so a 401 test can watch the token get forgotten.
    private static func mcpResponder(status: Int) -> OAuthMock.Responder {
        { request in
            guard request.method == "POST", request.path == "/mcp" else {
                return .notFound
            }
            guard status == 200 else {
                return .init(statusCode: status, body: "")
            }
            switch request.rpcMethod {
            case "server/discover":
                return .json(#"{"jsonrpc":"2.0","id":"discover","error":{"code":-32601,"message":"Method not found"}}"#, statusCode: 404)
            case "initialize":
                return .json(#"{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","serverInfo":{"name":"mock","version":"1.0.0"},"capabilities":{}}}"#)
            case "notifications/initialized":
                return .init(statusCode: 202, body: "")
            case "tools/call":
                return .json(#"{"jsonrpc":"2.0","id":"call","result":{"content":[{"type":"text","text":"ok"}],"structuredContent":{"ok":true}}}"#)
            default:
                return .notFound
            }
        }
    }

    /// A token endpoint that replaces the refresh token on every use and
    /// refuses one that was already spent. It answers slowly, so two callers
    /// overlap.
    private static func rotatingRefreshResponder() -> OAuthMock.Responder {
        let spent = LockedBox<Set<String>>([])
        return { request in
            guard request.method == "POST", request.path == "/token" else {
                return .notFound
            }
            Thread.sleep(forTimeInterval: 0.2)
            let refreshToken = Self.form(request.body)["refresh_token"] ?? ""
            let isFirstUse = spent.update { $0.insert(refreshToken).inserted }
            guard refreshToken == "refresh-1", isFirstUse else {
                return .json(#"{"error":"invalid_grant"}"#, statusCode: 400)
            }
            return .json(#"{"access_token":"token-2","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-2"}"#)
        }
    }

    /// Without a working timeout or cancellation, a sign-in waits for the
    /// browser for ever. Answering late lets such a test fail instead of hang.
    private static func answerLate(_ authorizeURL: LockedBox<URL?>) -> Task<Void, Never> {
        Task {
            guard (try? await Task.sleep(for: .seconds(4))) != nil, let url = authorizeURL.value else { return }
            await answerAuthorize(url, state: "late")
        }
    }

    /// True once nothing accepts connections on the sign-in's reply address.
    private static func replyAddressIsClosed(_ authorizeURL: URL?) async -> Bool {
        guard let authorizeURL,
              let redirect = query(authorizeURL)["redirect_uri"],
              let url = URL(string: redirect) else {
            return false
        }
        for _ in 0..<100 {
            do {
                _ = try await URLSession(configuration: .ephemeral).data(from: url)
            } catch {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// Plays the browser: the user approved, and the server sent them back.
    private static func answerAuthorize(_ url: URL, state: String) async {
        guard let redirect = Self.query(url)["redirect_uri"],
              var components = URLComponents(string: redirect) else {
            Issue.record("authorize URL carried no redirect_uri")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "code", value: "code-1"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let callback = components.url else { return }
        _ = try? await URLSession(configuration: .ephemeral).data(from: callback)
    }

    private static func credential(
        token: String,
        refreshToken: String? = nil,
        expiresAt: Date? = nil
    ) -> MCPUpstreamOAuthCredential {
        MCPUpstreamOAuthCredential(
            issuer: "https://oauth-mcp.test",
            tokenEndpoint: "https://oauth-mcp.test/token",
            revocationEndpoint: nil,
            clientID: "client-1",
            resource: "https://oauth-mcp.test",
            accessToken: token,
            refreshToken: refreshToken,
            expiresAt: expiresAt,
            signedInAt: Date()
        )
    }

    private static func tool() -> ToolDefinition {
        ToolDefinition(
            id: "mock_ping",
            name: "Mock: Ping",
            summary: "Ping through a signed-in MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "Mock",
                serverURL: serverURL,
                toolName: "ping",
                inputSchema: .object(["type": .string("object"), "properties": .object([:])]),
                headers: [.upstreamOAuthAuthorization]
            )
        )
    }

    private static func candidate(headers: [MCPBridgeHeader]) -> LocalMCPServerCandidate {
        LocalMCPServerCandidate(
            id: "test.mock",
            source: "test",
            sourcePath: "test",
            name: "mock",
            displayName: "Mock",
            transport: .http,
            url: serverURL,
            command: nil,
            args: [],
            startupTimeoutSeconds: nil,
            isLocal: true,
            bridgeable: true,
            reason: nil,
            headers: headers,
            environment: [],
            probe: nil,
            probeError: nil
        )
    }

    private static func query(_ url: URL) -> [String: String] {
        Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func form(_ body: Data) -> [String: String] {
        var result = [String: String]()
        for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            result[parts[0].removingPercentEncoding ?? parts[0]] = parts[1].removingPercentEncoding ?? parts[1]
        }
        return result
    }
}

// MARK: - Mock transport for https://oauth-mcp.test

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func update<Result>(_ change: (inout Value) -> Result) -> Result {
        lock.withLock { change(&stored) }
    }
}

private struct OAuthCapturedRequest: @unchecked Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    var rpcMethod: String {
        ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"] as? String) ?? ""
    }
}

private struct OAuthMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    init(statusCode: Int, headers: [String: String] = [:], body: String) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = Data(body.utf8)
    }

    static func json(_ body: String, statusCode: Int = 200) -> OAuthMockResponse {
        OAuthMockResponse(statusCode: statusCode, headers: ["Content-Type": "application/json"], body: body)
    }

    static var notFound: OAuthMockResponse { OAuthMockResponse(statusCode: 404, body: "") }
}

private final class OAuthMock: URLProtocol, @unchecked Sendable {
    typealias Responder = @Sendable (OAuthCapturedRequest) -> OAuthMockResponse

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: Responder = { _ in .notFound }
    nonisolated(unsafe) private static var captured: [OAuthCapturedRequest] = []

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OAuthMock.self]
        return URLSession(configuration: config)
    }

    static func install(responder newResponder: @escaping Responder) {
        lock.lock()
        responder = newResponder
        captured = []
        lock.unlock()
    }

    static func requests() -> [OAuthCapturedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "oauth-mcp.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = OAuthCapturedRequest(
            method: self.request.httpMethod ?? "GET",
            path: self.request.url?.path ?? "",
            headers: self.request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(from: self.request) ?? Data()
        )
        Self.lock.lock()
        Self.captured.append(request)
        let responder = Self.responder
        Self.lock.unlock()
        let response = responder(request)
        let http = HTTPURLResponse(
            url: self.request.url!,
            statusCode: response.statusCode,
            httpVersion: nil,
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
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
