import CryptoKit
import Foundation
import Network

// MARK: - Errors

/// Failures of MacRemote's own sign-in to an upstream MCP server. Every
/// description is a complete sentence that says what to do next, because these
/// strings reach the Tools page and the stderr of a bridged tool call.
enum MCPUpstreamOAuthError: LocalizedError, Equatable {
    case signInRequired(serverName: String)
    case notSupported(serverName: String)
    case insecureEndpoint(String)
    case invalidMetadata(String)
    case registrationFailed(String)
    case authorizationDenied(String)
    case stateMismatch
    case tokenExchangeFailed(String)
    case serverUnavailable(String)
    case timedOut(serverName: String)
    case cancelled
    case listenerFailed(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired(let name):
            "Sign in to \(name) in MacRemote › Tools to use its tools."
        case .notSupported(let name):
            "\(name) doesn't offer a sign-in MacRemote can complete: it published no OAuth metadata."
        case .insecureEndpoint(let endpoint):
            "Sign-in refused: \(endpoint) is neither HTTPS nor an address on this Mac."
        case .invalidMetadata(let detail):
            "The server's sign-in metadata is incomplete: \(detail)"
        case .registrationFailed(let detail):
            "The server refused MacRemote's registration: \(detail)"
        case .authorizationDenied(let detail):
            "The sign-in was not approved: \(detail)"
        case .stateMismatch:
            "The sign-in reply didn't match MacRemote's request, so it was ignored."
        case .tokenExchangeFailed(let detail):
            "The server didn't issue a token: \(detail)"
        case .serverUnavailable(let detail):
            "The server couldn't answer the sign-in right now: \(detail) Try again later."
        case .timedOut(let name):
            "The sign-in timed out. Try again and approve the request in \(name)."
        case .cancelled:
            "The sign-in was cancelled."
        case .listenerFailed(let detail):
            "MacRemote couldn't open its sign-in reply address: \(detail)"
        }
    }
}

// MARK: - Credential and store

/// What MacRemote keeps after signing in to one upstream server: the client it
/// registered and the tokens that client was issued. Stored as one Keychain
/// item per server URL; never persisted in the tool registry.
struct MCPUpstreamOAuthCredential: Codable, Equatable, Sendable {
    var issuer: String
    var tokenEndpoint: String
    var revocationEndpoint: String?
    var clientID: String
    var resource: String?
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    var signedInAt: Date

    func isExpired(at now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// Keychain-backed credential store for upstream sign-ins, keyed by the
/// normalized MCP server URL. Reads are cached in memory so a bridged tool
/// call never touches the Keychain twice for the same server.
final class MCPUpstreamOAuthStore: @unchecked Sendable {
    static let keychainService = "MacRemote.upstream-mcp-oauth"
    static let shared = MCPUpstreamOAuthStore(
        keychain: KeychainSecretStore(service: MCPUpstreamOAuthStore.keychainService)
    )

    private let keychain: any KeychainSecretStoring
    private let lock = NSLock()
    private var cache: [String: MCPUpstreamOAuthCredential] = [:]
    private var knownAbsent: Set<String> = []
    private var refreshes: [String: Task<MCPUpstreamOAuthCredential?, any Error>] = [:]

    init(keychain: any KeychainSecretStoring) {
        self.keychain = keychain
    }

    /// Scheme and host are case-insensitive; a trailing slash, query, or
    /// fragment never changes which server a token belongs to.
    static func account(for serverURL: String) -> String {
        let trimmed = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            return trimmed
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.query = nil
        components.fragment = nil
        var path = components.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path
        return components.string ?? trimmed
    }

    func credential(for serverURL: String) -> MCPUpstreamOAuthCredential? {
        let account = Self.account(for: serverURL)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[account] {
            return cached
        }
        if knownAbsent.contains(account) {
            return nil
        }
        guard let raw = try? keychain.read(account: account, interactive: false),
              let data = raw.data(using: .utf8),
              let credential = try? JSONDecoder().decode(MCPUpstreamOAuthCredential.self, from: data) else {
            knownAbsent.insert(account)
            return nil
        }
        cache[account] = credential
        return credential
    }

    func isSignedIn(_ serverURL: String) -> Bool {
        credential(for: serverURL) != nil
    }

    func save(_ credential: MCPUpstreamOAuthCredential, for serverURL: String) throws {
        let account = Self.account(for: serverURL)
        let data = try JSONEncoder().encode(credential)
        try keychain.write(String(decoding: data, as: UTF8.self), account: account)
        lock.lock()
        cache[account] = credential
        knownAbsent.remove(account)
        lock.unlock()
    }

    func remove(for serverURL: String) {
        let account = Self.account(for: serverURL)
        keychain.delete(account: account)
        lock.lock()
        cache[account] = nil
        knownAbsent.insert(account)
        lock.unlock()
    }

    /// Saves a refreshed credential only if `previous` is still the stored
    /// one. A refresh that finishes after the owner signed out, or signed in
    /// again, must not put its token back.
    func replace(
        _ previous: MCPUpstreamOAuthCredential,
        with credential: MCPUpstreamOAuthCredential,
        for serverURL: String
    ) throws -> Bool {
        let account = Self.account(for: serverURL)
        let data = try JSONEncoder().encode(credential)
        return try lock.withLock {
            guard cache[account] == previous else { return false }
            try keychain.write(String(decoding: data, as: UTF8.self), account: account)
            cache[account] = credential
            return true
        }
    }

    /// Runs `refresh` for a server, or joins the one already running for it.
    ///
    /// Many servers replace the refresh token each time it is used. Two tool
    /// calls that both find an expired token would otherwise both present the
    /// same one, and the server would refuse the second and may end the
    /// sign-in. Every client shares one store, so the refresh in progress is
    /// kept here. It is not tied to the caller that started it: a caller that
    /// gives up must not stop a refresh whose new token still has to be saved.
    func refreshOnce(
        for serverURL: String,
        _ refresh: @escaping @Sendable () async throws -> MCPUpstreamOAuthCredential?
    ) async throws -> MCPUpstreamOAuthCredential? {
        let account = Self.account(for: serverURL)
        let running = lock.withLock {
            if let running = refreshes[account] {
                return running
            }
            let started = Task {
                defer { self.lock.withLock { self.refreshes[account] = nil } }
                return try await refresh()
            }
            refreshes[account] = started
            return started
        }
        return try await running.value
    }
}

/// In-memory Keychain stand-in for tests.
final class InMemoryKeychainSecretStore: KeychainSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    init() {}

    func read(account: String, interactive: Bool) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let secret = secrets[account] else {
            throw KeychainSecretStoreError.keychain(errSecItemNotFound)
        }
        return secret
    }

    func write(_ secret: String, account: String) throws {
        lock.lock()
        secrets[account] = secret
        lock.unlock()
    }

    func delete(account: String) {
        lock.lock()
        secrets[account] = nil
        lock.unlock()
    }
}

// MARK: - Server metadata

/// The subset of RFC 9728 (protected resource) and RFC 8414 (authorization
/// server) metadata MacRemote needs to sign in.
struct MCPUpstreamOAuthServerMetadata: Equatable, Sendable {
    var resource: String
    var issuer: String
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var registrationEndpoint: String?
    var revocationEndpoint: String?
    var scopesSupported: [String]
    var grantTypesSupported: [String]
    var codeChallengeMethodsSupported: [String]

    var supportsRefreshTokens: Bool {
        grantTypesSupported.contains("refresh_token")
    }
}

// MARK: - Client

/// MacRemote as an OAuth client of an upstream MCP server: discovery, dynamic
/// client registration, the authorization-code flow with PKCE through the
/// user's browser and a one-shot reply address on this Mac, refresh, and
/// revocation. Codex and Claude Code sign in to servers like Paste the same way.
struct MCPUpstreamOAuthClient: Sendable {
    typealias URLOpener = @Sendable (URL) async -> Void

    static let clientName = MacRemoteProductInfo.name
    static let defaultSignInTimeout: TimeInterval = 300
    /// One sign-in request, start to finish. The request's own timeout only
    /// limits the gap between bytes.
    static let requestDeadlineSeconds: TimeInterval = 30
    /// Metadata, registration, and token replies are small JSON documents.
    static let maximumResponseBytes = 1024 * 1024

    private let urlSession: URLSession
    private let store: MCPUpstreamOAuthStore
    private let openURL: URLOpener
    private let signInTimeout: TimeInterval

    init(
        urlSession: URLSession = .shared,
        store: MCPUpstreamOAuthStore = .shared,
        openURL: @escaping URLOpener,
        signInTimeout: TimeInterval = MCPUpstreamOAuthClient.defaultSignInTimeout
    ) {
        self.urlSession = urlSession
        self.store = store
        self.openURL = openURL
        self.signInTimeout = signInTimeout
    }

    // MARK: Discovery

    /// Finds the server's OAuth metadata, or nil when it publishes none.
    /// `resourceMetadataURL` comes from a `WWW-Authenticate` challenge when the
    /// server sent one (RFC 9728 §5.1); otherwise the well-known paths are tried
    /// with and without the MCP endpoint's path component.
    func discover(
        serverURL: String,
        resourceMetadataURL: String? = nil
    ) async throws -> MCPUpstreamOAuthServerMetadata? {
        guard let server = URL(string: serverURL), let origin = Self.origin(of: server) else {
            return nil
        }

        var resourceCandidates = [String]()
        if let resourceMetadataURL {
            resourceCandidates.append(resourceMetadataURL)
        }
        let path = server.path.hasPrefix("/") ? server.path : "/" + server.path
        if path != "/", !path.isEmpty {
            resourceCandidates.append("\(origin)/.well-known/oauth-protected-resource\(path)")
        }
        resourceCandidates.append("\(origin)/.well-known/oauth-protected-resource")

        var authorizationServers = [origin]
        // False while the list above is only this app's guess: an older server
        // publishes its sign-in metadata at its own address without saying
        // which authorization server it uses.
        var serverNamedItsIssuers = false
        var resource = serverURL
        var scopes = [String]()
        for candidate in resourceCandidates {
            guard let object = try await fetchJSON(candidate) else { continue }
            if let declared = object["resource"] as? String, !declared.isEmpty {
                // RFC 9728 §3.3: a document that describes some other
                // resource must not be used. Otherwise a server could have
                // MacRemote ask for a token meant for a different service.
                guard Self.resource(declared, covers: serverURL) else { continue }
                resource = declared
            }
            if let servers = object["authorization_servers"] as? [String], !servers.isEmpty {
                authorizationServers = servers
                serverNamedItsIssuers = true
            }
            scopes = object["scopes_supported"] as? [String] ?? []
            break
        }

        for issuer in authorizationServers {
            guard let metadata = try await authorizationServerMetadata(
                issuer: issuer,
                mustNameThisIssuer: serverNamedItsIssuers
            ) else { continue }
            return MCPUpstreamOAuthServerMetadata(
                resource: resource,
                issuer: metadata.issuer,
                authorizationEndpoint: metadata.authorizationEndpoint,
                tokenEndpoint: metadata.tokenEndpoint,
                registrationEndpoint: metadata.registrationEndpoint,
                revocationEndpoint: metadata.revocationEndpoint,
                scopesSupported: scopes.isEmpty ? metadata.scopesSupported : scopes,
                grantTypesSupported: metadata.grantTypesSupported,
                codeChallengeMethodsSupported: metadata.codeChallengeMethodsSupported
            )
        }
        return nil
    }

    /// True when a 401 from this server can be fixed by signing in.
    func supportsSignIn(serverURL: String, resourceMetadataURL: String? = nil) async -> Bool {
        (try? await discover(serverURL: serverURL, resourceMetadataURL: resourceMetadataURL)) != nil
    }

    /// Fetches the metadata of one authorization server. Nothing it returns
    /// needs checking again: the document names the issuer that was asked
    /// for, and every endpoint that will receive a code, a token, or the
    /// registration is HTTPS or on this Mac.
    private func authorizationServerMetadata(
        issuer: String,
        mustNameThisIssuer: Bool
    ) async throws -> MCPUpstreamOAuthServerMetadata? {
        guard let issuerURL = URL(string: issuer), let origin = Self.origin(of: issuerURL) else {
            return nil
        }
        let path = issuerURL.path
        var candidates = [String]()
        if !path.isEmpty, path != "/" {
            candidates.append("\(origin)/.well-known/oauth-authorization-server\(path)")
            candidates.append("\(origin)\(path)/.well-known/openid-configuration")
        }
        candidates.append("\(origin)/.well-known/oauth-authorization-server")
        candidates.append("\(origin)/.well-known/openid-configuration")

        var otherIssuer: String?
        for candidate in candidates {
            guard let object = try await fetchJSON(candidate) else { continue }
            // RFC 8414 §3.3: the document must name the issuer it was fetched
            // for. One that names another describes a different authorization
            // server, for example another tenant on the same host. The rule
            // applies when the server named its issuer. When the issuer is
            // only this app's guess, the document found at the server's own
            // address is the server's answer, whatever issuer it names.
            let declared = object["issuer"] as? String ?? ""
            let namesThisIssuer = MCPUpstreamOAuthStore.account(for: declared)
                == MCPUpstreamOAuthStore.account(for: issuer)
            guard namesThisIssuer || (!mustNameThisIssuer && !declared.isEmpty) else {
                otherIssuer = declared
                continue
            }
            guard let authorizationEndpoint = object["authorization_endpoint"] as? String,
                  let tokenEndpoint = object["token_endpoint"] as? String else {
                throw MCPUpstreamOAuthError.invalidMetadata("authorization_endpoint and token_endpoint are required.")
            }
            let registrationEndpoint = object["registration_endpoint"] as? String
            for endpoint in [authorizationEndpoint, tokenEndpoint, registrationEndpoint].compactMap({ $0 }) {
                try Self.requireTrustworthy(endpoint)
            }
            return MCPUpstreamOAuthServerMetadata(
                resource: "",
                issuer: declared,
                authorizationEndpoint: authorizationEndpoint,
                tokenEndpoint: tokenEndpoint,
                registrationEndpoint: registrationEndpoint,
                revocationEndpoint: object["revocation_endpoint"] as? String,
                scopesSupported: object["scopes_supported"] as? [String] ?? [],
                grantTypesSupported: object["grant_types_supported"] as? [String] ?? ["authorization_code"],
                codeChallengeMethodsSupported: object["code_challenge_methods_supported"] as? [String] ?? []
            )
        }
        if let otherIssuer {
            throw MCPUpstreamOAuthError.invalidMetadata(
                "it describes \(otherIssuer.isEmpty ? "no issuer" : otherIssuer), not \(issuer)."
            )
        }
        return nil
    }

    // MARK: Sign-in

    /// Runs the whole sign-in and stores the result. The browser opens the
    /// server's approval page; the server sends the user back to a one-shot
    /// address on 127.0.0.1 that MacRemote opened just for this attempt.
    func signIn(serverURL: String, serverName: String) async throws -> MCPUpstreamOAuthCredential {
        guard let metadata = try await discover(serverURL: serverURL) else {
            throw MCPUpstreamOAuthError.notSupported(serverName: serverName)
        }
        guard metadata.codeChallengeMethodsSupported.contains("S256") else {
            throw MCPUpstreamOAuthError.invalidMetadata("the server does not support PKCE S256.")
        }

        let listener = try MCPUpstreamOAuthRedirectListener(serverName: serverName)
        defer { listener.cancel() }
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        let clientID = try await registerClient(
            metadata: metadata,
            redirectURI: redirectURI
        )

        let verifier = Self.randomToken(byteCount: 32)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = Self.randomToken(byteCount: 16)

        var authorize = URLComponents(string: metadata.authorizationEndpoint)
        var items = authorize?.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: metadata.resource)
        ]
        if !metadata.scopesSupported.isEmpty {
            items.append(URLQueryItem(name: "scope", value: metadata.scopesSupported.joined(separator: " ")))
        }
        authorize?.queryItems = items
        guard let authorizeURL = authorize?.url else {
            throw MCPUpstreamOAuthError.invalidMetadata("the authorization endpoint is not a valid URL.")
        }

        await openURL(authorizeURL)

        let reply = try await listener.awaitReply(timeout: signInTimeout)
        guard reply.state == state else {
            throw MCPUpstreamOAuthError.stateMismatch
        }
        if let error = reply.error {
            throw MCPUpstreamOAuthError.authorizationDenied(
                [error, reply.errorDescription].compactMap { $0 }.joined(separator: ": ")
            )
        }
        guard let code = reply.code, !code.isEmpty else {
            throw MCPUpstreamOAuthError.authorizationDenied("no authorization code was returned.")
        }

        let token = try await postForm(
            metadata.tokenEndpoint,
            fields: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "client_id": clientID,
                "code_verifier": verifier,
                "resource": metadata.resource
            ]
        )
        let credential = try Self.credential(
            from: token,
            metadata: metadata,
            clientID: clientID,
            previous: nil
        )
        try store.save(credential, for: serverURL)
        return credential
    }

    /// Exchanges the refresh token when the server issued one. Returns nil when
    /// there is nothing to refresh with; throws when the server refused.
    /// Callers that overlap for one server share a single exchange.
    func refresh(serverURL: String) async throws -> MCPUpstreamOAuthCredential? {
        try await store.refreshOnce(for: serverURL) {
            try await exchangeRefreshToken(serverURL: serverURL)
        }
    }

    private func exchangeRefreshToken(serverURL: String) async throws -> MCPUpstreamOAuthCredential? {
        guard let current = store.credential(for: serverURL),
              let refreshToken = current.refreshToken, !refreshToken.isEmpty else {
            return nil
        }
        var fields = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": current.clientID
        ]
        if let resource = current.resource {
            fields["resource"] = resource
        }
        let token = try await postForm(current.tokenEndpoint, fields: fields)
        let metadata = MCPUpstreamOAuthServerMetadata(
            resource: current.resource ?? serverURL,
            issuer: current.issuer,
            authorizationEndpoint: "",
            tokenEndpoint: current.tokenEndpoint,
            registrationEndpoint: nil,
            revocationEndpoint: current.revocationEndpoint,
            scopesSupported: [],
            grantTypesSupported: ["refresh_token"],
            codeChallengeMethodsSupported: ["S256"]
        )
        let refreshed = try Self.credential(
            from: token,
            metadata: metadata,
            clientID: current.clientID,
            previous: current
        )
        guard try store.replace(current, with: refreshed, for: serverURL) else {
            // The owner signed out, or signed in again, while the server was
            // answering. Whatever is stored now is the sign-in to use.
            return store.credential(for: serverURL)
        }
        return refreshed
    }

    /// A usable access token for this server, refreshing an expired one when
    /// the server allows it. Nil means the user has to sign in.
    func accessToken(for serverURL: String) async -> String? {
        guard let credential = store.credential(for: serverURL) else { return nil }
        guard credential.isExpired() else { return credential.accessToken }
        guard let refreshed = try? await refresh(serverURL: serverURL) else {
            return nil
        }
        return refreshed.accessToken
    }

    /// Drops a stored sign-in without contacting the server (a 401 already
    /// proved it is dead). The Tools page then offers Sign In again.
    func forget(serverURL: String) {
        store.remove(for: serverURL)
    }

    /// Revokes the token when the server offers revocation, then forgets it.
    func signOut(serverURL: String) async {
        if let credential = store.credential(for: serverURL),
           let revocation = credential.revocationEndpoint {
            _ = try? await postForm(revocation, fields: [
                "token": credential.accessToken,
                "token_type_hint": "access_token",
                "client_id": credential.clientID
            ])
        }
        store.remove(for: serverURL)
    }

    // MARK: Registration and tokens

    private func registerClient(
        metadata: MCPUpstreamOAuthServerMetadata,
        redirectURI: String
    ) async throws -> String {
        guard let registration = metadata.registrationEndpoint, let url = URL(string: registration) else {
            throw MCPUpstreamOAuthError.registrationFailed(
                "the server does not offer dynamic client registration, and MacRemote has no client ID for it."
            )
        }
        var grantTypes = ["authorization_code"]
        if metadata.supportsRefreshTokens {
            grantTypes.append("refresh_token")
        }
        let body: [String: Any] = [
            "client_name": Self.clientName,
            "redirect_uris": [redirectURI],
            "grant_types": grantTypes,
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "application_type": "native"
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.checkedData(withJSONObject: body)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = object["client_id"] as? String, !clientID.isEmpty else {
            throw MCPUpstreamOAuthError.registrationFailed(
                "HTTP \(status)\(Self.detail(from: data))"
            )
        }
        return clientID
    }

    /// Posts a code or a token. The endpoint is checked here as well as at
    /// discovery, because a refresh or a sign-out uses an address that was
    /// stored with the sign-in, possibly by an earlier version of the app.
    private func postForm(_ endpoint: String, fields: [String: String]) async throws -> [String: Any] {
        try Self.requireTrustworthy(endpoint)
        guard let url = URL(string: endpoint) else {
            throw MCPUpstreamOAuthError.invalidMetadata("\(endpoint) is not a valid URL.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncoded(fields).utf8)
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // The server is in trouble or asks to slow down. That says nothing
        // about the token, so it must not read as the server refusing it.
        guard status < 500, status != 429 else {
            throw MCPUpstreamOAuthError.serverUnavailable("HTTP \(status).")
        }
        guard (200..<300).contains(status) else {
            let error = object["error"] as? String
            let description = object["error_description"] as? String
            throw MCPUpstreamOAuthError.tokenExchangeFailed(
                [error, description].compactMap { $0 }.joined(separator: ": ").isEmpty
                    ? "HTTP \(status)\(Self.detail(from: data))"
                    : [error, description].compactMap { $0 }.joined(separator: ": ")
            )
        }
        return object
    }

    private static func credential(
        from token: [String: Any],
        metadata: MCPUpstreamOAuthServerMetadata,
        clientID: String,
        previous: MCPUpstreamOAuthCredential?
    ) throws -> MCPUpstreamOAuthCredential {
        guard let accessToken = token["access_token"] as? String, !accessToken.isEmpty else {
            throw MCPUpstreamOAuthError.tokenExchangeFailed("the response carried no access_token.")
        }
        if let type = token["token_type"] as? String, type.caseInsensitiveCompare("Bearer") != .orderedSame {
            throw MCPUpstreamOAuthError.tokenExchangeFailed("unsupported token type \(type).")
        }
        let expiresIn = (token["expires_in"] as? NSNumber)?.doubleValue
            ?? (token["expires_in"] as? String).flatMap(Double.init)
        let now = Date()
        return MCPUpstreamOAuthCredential(
            issuer: metadata.issuer,
            tokenEndpoint: metadata.tokenEndpoint,
            revocationEndpoint: metadata.revocationEndpoint ?? previous?.revocationEndpoint,
            clientID: clientID,
            resource: metadata.resource.isEmpty ? previous?.resource : metadata.resource,
            accessToken: accessToken,
            refreshToken: (token["refresh_token"] as? String) ?? previous?.refreshToken,
            expiresAt: expiresIn.map { now.addingTimeInterval(max(0, $0)) },
            signedInAt: previous?.signedInAt ?? now
        )
    }

    // MARK: Helpers

    private func fetchJSON(_ urlString: String) async throws -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        try Self.requireTrustworthy(urlString)
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Sends one sign-in request under a deadline and a size limit. A server
    /// that answers slowly without end would otherwise keep a sign-in, or the
    /// one shared token refresh, waiting for ever.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let session = urlSession
        do {
            return try await withDeadline(seconds: Self.requestDeadlineSeconds) {
                try await MCPHTTPResponseBody.data(
                    for: request,
                    session: session,
                    maximumBytes: Self.maximumResponseBytes
                )
            }
        } catch is DeadlineExceeded {
            throw URLError(.timedOut)
        }
    }

    /// Sign-in endpoints must be HTTPS, or plain HTTP only on this Mac. Tokens
    /// never travel in the clear to another machine.
    static func requireTrustworthy(_ endpoint: String) throws {
        guard let url = URL(string: endpoint), let host = url.host?.lowercased() else {
            throw MCPUpstreamOAuthError.insecureEndpoint(endpoint)
        }
        switch url.scheme?.lowercased() {
        case "https":
            return
        case "http" where isLoopbackHost(host):
            return
        default:
            throw MCPUpstreamOAuthError.insecureEndpoint(endpoint)
        }
    }

    /// "localhost" or a loopback address. An address has to parse as one: a
    /// prefix test would also accept a hostname such as "127.example.com".
    static func isLoopbackHost(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host == "[::1]" || IPv4Address(host)?.isLoopback == true
    }

    /// True when a declared resource is this server or a parent path on the
    /// same origin, which is how servers commonly name themselves.
    static func resource(_ declared: String, covers serverURL: String) -> Bool {
        guard let resource = URL(string: MCPUpstreamOAuthStore.account(for: declared)),
              let server = URL(string: MCPUpstreamOAuthStore.account(for: serverURL)),
              let resourceOrigin = origin(of: resource),
              resourceOrigin == origin(of: server) else {
            return false
        }
        let resourcePath = resource.path.hasSuffix("/") ? resource.path : resource.path + "/"
        let serverPath = server.path.hasSuffix("/") ? server.path : server.path + "/"
        return serverPath.hasPrefix(resourcePath)
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var origin = "\(scheme)://\(host)"
        if let port = url.port {
            origin += ":\(port)"
        }
        return origin
    }

    static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    private static func detail(from data: Data) -> String {
        let text = String(decoding: data.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "." : ": \(text)"
    }
}

// MARK: - Loopback reply listener

/// A one-shot HTTP listener on 127.0.0.1 with a system-chosen port (RFC 8252
/// §7.3). It answers exactly one request, hands the query back, and closes.
final class MCPUpstreamOAuthRedirectListener: @unchecked Sendable {
    struct Reply: Equatable, Sendable {
        var code: String?
        var state: String?
        var error: String?
        var errorDescription: String?
    }

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MacRemote.upstream-oauth-redirect")
    private let lock = NSLock()
    private var reply: Reply?
    private var waiters: [CheckedContinuation<Reply, Error>] = []
    private let serverName: String

    init(serverName: String) throws {
        self.serverName = serverName
        // Network.framework rejects a required local endpoint on port 0, so
        // ask the kernel for a free port first and retry if another process
        // grabs it in between.
        var lastError: MCPUpstreamOAuthError = .listenerFailed("no free port on 127.0.0.1.")
        var started: (NWListener, UInt16)?
        for _ in 0..<8 {
            let port = try Self.freeLoopbackPort()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            guard let listener = try? NWListener(using: parameters) else { continue }
            let relay = self.relay
            listener.newConnectionHandler = { connection in
                relay.handler?(connection)
            }
            do {
                let readyPort = try Self.start(listener, on: queue)
                started = (listener, readyPort)
                break
            } catch let error as MCPUpstreamOAuthError {
                lastError = error
            }
        }
        guard let (listener, port) = started else {
            throw lastError
        }
        self.listener = listener
        self.port = port
        relay.handler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    /// NWListener refuses to start without a connection handler, and `self`
    /// is not available until every stored property exists, so the handler
    /// installed before `start` forwards to the one set at the end of `init`.
    private let relay = ConnectionRelay()

    private final class ConnectionRelay: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ((NWConnection) -> Void)?

        var handler: ((NWConnection) -> Void)? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Binds a throwaway socket to 127.0.0.1:0 and reports the port the kernel
    /// chose. The socket closes before the real listener binds.
    private static func freeLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw MCPUpstreamOAuthError.listenerFailed("socket() failed.")
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bound else {
            throw MCPUpstreamOAuthError.listenerFailed("bind() to 127.0.0.1 failed.")
        }
        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length) == 0
            }
        }
        guard named, assigned.sin_port != 0 else {
            throw MCPUpstreamOAuthError.listenerFailed("getsockname() failed.")
        }
        return UInt16(bigEndian: assigned.sin_port)
    }

    /// Starts the listener and blocks until the system assigned a port, so a
    /// caller never registers a reply address nobody is listening on.
    private static func start(_ listener: NWListener, on queue: DispatchQueue) throws -> UInt16 {
        let gate = DispatchSemaphore(value: 0)
        let outcome = OutcomeBox()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                outcome.resolve(.success(listener.port?.rawValue ?? 0))
                gate.signal()
            case .failed(let error):
                outcome.resolve(.failure(error))
                gate.signal()
            case .cancelled:
                outcome.resolve(.failure(NWError.posix(.ECANCELED)))
                gate.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        guard gate.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw MCPUpstreamOAuthError.listenerFailed("the listener never became ready.")
        }
        switch outcome.value {
        case .success(let port) where port != 0:
            return port
        case .success:
            listener.cancel()
            throw MCPUpstreamOAuthError.listenerFailed("no port was assigned.")
        case .failure(let error):
            listener.cancel()
            throw MCPUpstreamOAuthError.listenerFailed(error.localizedDescription)
        case nil:
            listener.cancel()
            throw MCPUpstreamOAuthError.listenerFailed("the listener reported no state.")
        }
    }

    func cancel() {
        listener.cancel()
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending {
            waiter.resume(throwing: MCPUpstreamOAuthError.cancelled)
        }
    }

    /// Waits for the browser's reply, for at most `timeout`, and stops
    /// waiting at once when the sign-in is cancelled. The wait itself cannot
    /// be interrupted, so it is raced rather than awaited directly; the
    /// caller's `cancel()` then releases it.
    func awaitReply(timeout: TimeInterval) async throws -> Reply {
        do {
            return try await withDeadline(seconds: timeout) {
                try await self.nextReply()
            }
        } catch is DeadlineExceeded {
            throw MCPUpstreamOAuthError.timedOut(serverName: serverName)
        } catch is CancellationError {
            throw MCPUpstreamOAuthError.cancelled
        }
    }

    private func nextReply() async throws -> Reply {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let reply {
                lock.unlock()
                continuation.resume(returning: reply)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            let reply = Self.parseReply(fromRequest: request)
            let body = Self.responsePage(serverName: self.serverName, reply: reply)
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            guard let reply else { return }
            self.lock.lock()
            let isFirst = self.reply == nil
            if isFirst { self.reply = reply }
            let pending = self.waiters
            self.waiters.removeAll()
            self.lock.unlock()
            for waiter in pending {
                waiter.resume(returning: reply)
            }
        }
    }

    /// Only `GET /callback?…` counts as a reply; anything else (a favicon
    /// request, a probe) gets the page but never resolves the sign-in.
    static func parseReply(fromRequest request: String) -> Reply? {
        guard let requestLine = request.split(separator: "\r\n", maxSplits: 1).first
            .map(String.init) ?? request.split(separator: "\n", maxSplits: 1).first.map(String.init) else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1\(parts[1])"),
              components.path == "/callback" else {
            return nil
        }
        var reply = Reply()
        for item in components.queryItems ?? [] {
            switch item.name {
            case "code": reply.code = item.value
            case "state": reply.state = item.value
            case "error": reply.error = item.value
            case "error_description": reply.errorDescription = item.value
            default: break
            }
        }
        guard reply.code != nil || reply.error != nil else { return nil }
        return reply
    }

    private static func responsePage(serverName: String, reply: Reply?) -> String {
        let name = escapeHTML(serverName)
        let headline: String
        let detail: String
        if let reply, reply.error == nil {
            headline = "MacRemote is signed in to \(name)."
            detail = "You can close this tab and go back to MacRemote."
        } else if let reply, let error = reply.error {
            headline = "The sign-in to \(name) didn't finish."
            detail = "The server answered: \(escapeHTML(error)). Go back to MacRemote and try again."
        } else {
            headline = "Waiting for \(name)."
            detail = "This address only exists while MacRemote is signing in. Go back to MacRemote."
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><title>MacRemote</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body{font-family:-apple-system,system-ui,sans-serif;margin:0;display:grid;place-items:center;min-height:100vh;background:#f5f5f7;color:#1d1d1f}
        main{max-width:32rem;padding:2rem;text-align:center}h1{font-size:1.4rem;font-weight:600;margin:0 0 .5rem}p{margin:0;color:#6e6e73}
        @media(prefers-color-scheme:dark){body{background:#1c1c1e;color:#f5f5f7}p{color:#98989d}}</style></head>
        <body><main><h1>\(headline)</h1><p>\(detail)</p></main></body></html>
        """
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class OutcomeBox: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value: Result<UInt16, Error>?

        func resolve(_ result: Result<UInt16, Error>) {
            lock.lock()
            if value == nil { value = result }
            lock.unlock()
        }
    }
}
