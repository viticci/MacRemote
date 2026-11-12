import CryptoKit
import Foundation
import Security

struct OAuthRevocationSummary: Equatable, Sendable {
    let clients: Int
    let authorizations: Int
    let accessTokens: Int
    let refreshTokens: Int

    var total: Int {
        clients + authorizations + accessTokens + refreshTokens
    }
}

struct OAuthConfidentialClientCredentials: Equatable, Sendable {
    let clientID: String
    let clientSecret: String
}

/// Which apps may start an OAuth sign-in. The owner picks one sign-in method,
/// and each method admits one kind of app: apps that register themselves, or
/// apps holding a client ID and secret the owner created. Never both.
struct OAuthClientAuthenticationPolicy: Equatable, Sendable {
    let requiresConfidentialClient: Bool
    let confidentialClients: [OAuthConfidentialClientCredentials]

    static let dynamicPublicClients = OAuthClientAuthenticationPolicy(
        requiresConfidentialClient: false,
        confidentialClients: []
    )

    static func confidentialClientRequired(_ credentials: OAuthConfidentialClientCredentials?) -> OAuthClientAuthenticationPolicy {
        confidentialClientsRequired(credentials.map { [$0] } ?? [])
    }

    static func confidentialClientsRequired(_ credentials: [OAuthConfidentialClientCredentials]) -> OAuthClientAuthenticationPolicy {
        OAuthClientAuthenticationPolicy(
            requiresConfidentialClient: true,
            confidentialClients: credentials
        )
    }

    /// Single Header: the fixed token is the only way in, so no app can
    /// register itself and no client ID is known.
    static let noOAuthClients = confidentialClientsRequired([])

    var supportsDynamicClientRegistration: Bool {
        !requiresConfidentialClient
    }

    /// An app that registers itself may ask for a secret of its own, and
    /// Claude does when one is offered. That is still an app that registered
    /// itself: its secret proves it is the app that registered, nothing more.
    var tokenEndpointAuthMethodsSupported: [String] {
        requiresConfidentialClient
            ? ["client_secret_basic", "client_secret_post"]
            : ["none", "client_secret_basic", "client_secret_post"]
    }
}

enum OAuthTokenClientAuthenticationSource: Equatable, Sendable {
    case none
    case clientSecretBasic
    case clientSecretPost
}

final class OAuthCoordinator: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([ApprovalRequest]) -> Void
    /// Called with the app's name when a refresh token that was already used
    /// comes back and the sign-in it belongs to is ended.
    typealias RefreshTokenReuseHandler = @Sendable (String) -> Void

    static let maxRegisteredClients = 64
    static let maxPendingAuthorizations = 16
    /// One app has no reason to hold several sign-ins open at once.
    static let maxPendingAuthorizationsPerClient = 2
    /// How long a sign-in request waits for the owner.
    static let pendingAuthorizationLifetime: TimeInterval = 300
    static let maxStoredAuthorizations = 64
    static let defaultAccessTokenLifetime: TimeInterval = 900
    static let defaultRefreshTokenLifetime: TimeInterval = 86_400

    private enum ClientAuthenticationMethod: String, Sendable {
        /// An app that registered itself.
        case none
        /// An app holding a client ID and secret the owner created. It may
        /// send the secret either way OAuth allows.
        case clientSecret
        /// Apps that registered themselves and asked for a secret of their
        /// own, sent in the header or in the form.
        case clientSecretBasic
        case clientSecretPost

        /// UI projection. The snapshot carries the real method so the Apps
        /// list can stop inferring it from a trust-ID prefix.
        var connectedAppAuthMethod: ConnectedAppAuthMethod {
            switch self {
            case .none: .none
            case .clientSecret: .clientSecret
            case .clientSecretBasic: .clientSecretBasic
            case .clientSecretPost: .clientSecretPost
            }
        }
    }

    private struct Client {
        let id: String
        let trustID: String
        let name: String
        let redirectURIs: [String]
        let scopes: Set<String>
        let createdAt: Date
        let authenticationMethod: ClientAuthenticationMethod
        let secretHash: String?

        init(
            id: String,
            trustID: String,
            name: String,
            redirectURIs: [String],
            scopes: Set<String>,
            createdAt: Date,
            authenticationMethod: ClientAuthenticationMethod = .none,
            secretHash: String? = nil
        ) {
            self.id = id
            self.trustID = trustID
            self.name = name
            self.redirectURIs = redirectURIs
            self.scopes = scopes
            self.createdAt = createdAt
            self.authenticationMethod = authenticationMethod
            self.secretHash = secretHash
        }

        init(stored: OAuthStoredClient) {
            self.id = stored.id
            self.name = stored.name
            self.redirectURIs = stored.redirectURIs
            self.scopes = Set(stored.scopes)
            self.createdAt = stored.createdAt
            if let storedMethod = stored.authenticationMethod {
                // Unknown persisted methods fail closed as confidential rather
                // than silently turning a client into a public client.
                self.authenticationMethod = ClientAuthenticationMethod(rawValue: storedMethod) ?? .clientSecret
            } else {
                self.authenticationMethod = .none
            }
            self.secretHash = stored.secretHash
            // DCR metadata is attacker supplied and is not proof of app
            // identity. Migrate every old metadata-derived dynamic trust ID to
            // a client-registration identity. This deliberately makes legacy
            // Always Allow grants unreachable instead of carrying them onto a
            // lookalike registration.
            if OAuthCoordinator.isRecoverableDynamicClientID(stored.id) {
                self.trustID = OAuthCoordinator.dynamicClientTrustID(clientID: stored.id)
            } else if PublishedOAuthClient.named(stored.id) != nil {
                self.trustID = OAuthCoordinator.publishedClientTrustID(clientID: stored.id)
            } else {
                self.trustID = stored.trustID ?? OAuthCoordinator.confidentialClientTrustID(clientID: stored.id)
            }
        }

        var stored: OAuthStoredClient {
            OAuthStoredClient(
                id: id,
                trustID: trustID,
                name: name,
                redirectURIs: redirectURIs,
                scopes: scopes.sorted(),
                createdAt: createdAt,
                authenticationMethod: authenticationMethod == .none ? nil : authenticationMethod.rawValue,
                secretHash: secretHash
            )
        }

        func updating(secretHash: String?) -> Client {
            Client(
                id: id,
                trustID: trustID,
                name: name,
                redirectURIs: redirectURIs,
                scopes: scopes,
                createdAt: createdAt,
                authenticationMethod: authenticationMethod,
                secretHash: secretHash
            )
        }

        func binding(redirectURI: String, scopes newScopes: Set<String>) -> Client {
            Client(
                id: id,
                trustID: trustID,
                name: name,
                redirectURIs: Array(Set(redirectURIs + [redirectURI])).sorted(),
                scopes: scopes.union(newScopes),
                createdAt: createdAt,
                authenticationMethod: authenticationMethod,
                secretHash: secretHash
            )
        }
    }

    private struct PendingAuthorization {
        let id: UUID
        let clientID: String
        let clientTrustID: String
        let clientName: String
        let redirectURI: String
        let scopes: Set<String>
        let state: String?
        let codeChallenge: String
        let createdAt: Date
        let issuer: String
        let resource: String
        var status: ApprovalRequest.State
        var codeHash: String?
        var codeExpiresAt: Date?
        var codeUsedAt: Date?
        var issuedCode: String?

        var approvalRequest: ApprovalRequest {
            ApprovalRequest(
                id: id,
                clientID: clientID,
                clientTrustID: clientTrustID,
                clientName: clientName,
                redirectURI: redirectURI,
                issuer: issuer,
                resource: resource,
                requestedScopes: scopes.sorted(),
                createdAt: createdAt,
                state: status
            )
        }
    }

    /// One issued access or refresh token. Both kinds carry the sign-in they
    /// came from, so a refresh token that comes back after it was used can
    /// take every token of that sign-in with it.
    private struct TokenRecord {
        let clientID: String
        let issuer: String
        let resource: String
        let scopes: Set<String>
        let issuedAt: Date
        let expiresAt: Date
        let signInID: String
        /// Refresh tokens only: the hash of the token this one replaced.
        var replacedTokenHash: String?

        func stored(tokenHash: String) -> OAuthStoredToken {
            OAuthStoredToken(
                tokenHash: tokenHash,
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes.sorted(),
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                signInID: signInID,
                replacedTokenHash: replacedTokenHash
            )
        }
    }

    /// The Single Header sign-in mode: one MacRemote-generated bearer token,
    /// valid for any issuer/resource this server answers for. Only the SHA-256
    /// of the token is held here.
    static let staticHeaderClientID = "macremote-header-token"

    /// How long the refresh token an app just used is still answered, with
    /// the same new tokens it was given the first time. An app whose reply was
    /// lost on the way sends the same token again after its own timeout, and
    /// some apps refresh from two places at once; treating those as theft
    /// would sign out an app that did nothing wrong. One minute covers a
    /// 30-second timeout plus a retry. The cost is small: a copied token works
    /// only if replayed within a minute of the real app's own refresh, and
    /// then yields the tokens the real app already holds, never a second set.
    /// The first time the two refresh more than a minute apart, the slower
    /// one presents a used token and the sign-in ends.
    static let refreshRetryGrace: TimeInterval = 60

    private let lock = NSLock()
    private let changeHandler: ChangeHandler?
    private let refreshTokenReuseHandler: RefreshTokenReuseHandler?
    private let grantStore: OAuthGrantStore?
    private var clientAuthentication: OAuthClientAuthenticationPolicy
    private var clients: [String: Client] = [:]
    /// Clients the owner approved at least once. Registering and asking to
    /// sign in need no credentials, so only these are written to disk, and
    /// any other client is dropped once no sign-in of its own is waiting.
    private var approvedClientIDs: Set<String> = []
    private var authorizations: [UUID: PendingAuthorization] = [:]
    private var accessTokensByHash: [String: TokenRecord] = [:]
    private var refreshTokensByHash: [String: TokenRecord] = [:]
    /// The reply to each recent refresh, by the hash of the token that was
    /// used, so a retry can be given the same tokens. Memory only, and dropped
    /// once the retry window is over: these are tokens in the clear, so a
    /// retry after a relaunch is refused instead of answered.
    private var refreshReplies: [String: (reply: [String: Any], until: Date)] = [:]
    private var staticHeaderTokenHash: String?
    private var staticHeaderClientName = "Single Header Client"
    private var accessTokenLifetime: TimeInterval = 900
    private var refreshTokenLifetime: TimeInterval = 86_400

    init(
        clientAuthentication: OAuthClientAuthenticationPolicy = .dynamicPublicClients,
        changeHandler: ChangeHandler? = nil,
        refreshTokenReuseHandler: RefreshTokenReuseHandler? = nil,
        grantStore: OAuthGrantStore? = nil
    ) {
        self.clientAuthentication = clientAuthentication
        self.changeHandler = changeHandler
        self.refreshTokenReuseHandler = refreshTokenReuseHandler
        self.grantStore = grantStore
        loadPersistedGrants()
    }

    func updateTokenLifetimes(access: TimeInterval, refresh: TimeInterval) {
        lock.withLock {
            accessTokenLifetime = access
            refreshTokenLifetime = refresh
        }
    }

    func updateClientAuthentication(_ policy: OAuthClientAuthenticationPolicy) {
        try? lock.withLock {
            clientAuthentication = policy
            var changed = false
            for credentials in policy.confidentialClients {
                if var client = clients[credentials.clientID],
                   client.authenticationMethod == .clientSecret {
                    client = client.updating(secretHash: Self.sha256Hex(credentials.clientSecret))
                    clients[credentials.clientID] = client
                    changed = true
                }
            }
            if changed {
                try persistGrantSnapshotLocked()
            }
        }
    }

    func tokenEndpointAuthMethodsSupported() -> [String] {
        lock.withLock {
            clientAuthentication.tokenEndpointAuthMethodsSupported
        }
    }

    func supportsDynamicClientRegistration() -> Bool {
        lock.withLock {
            clientAuthentication.supportsDynamicClientRegistration
        }
    }

    func registerClient(from jsonObject: Any) throws -> [String: Any] {
        guard supportsDynamicClientRegistration() else {
            throw OAuthError.invalidRequest("Dynamic client registration is disabled while OAuth client credentials are required.")
        }

        guard let object = jsonObject as? [String: Any] else {
            throw OAuthError.invalidRequest("Expected JSON object.")
        }

        if let clientName = object["client_name"], !(clientName is String) {
            throw OAuthError.invalidClientMetadata("client_name must be a string.")
        }
        if let scope = object["scope"], !(scope is String) {
            throw OAuthError.invalidClientMetadata("scope must be a string.")
        }

        let grantTypes = try registrationStringArray(
            object["grant_types"],
            field: "grant_types",
            defaultValue: ["authorization_code", "refresh_token"]
        )
        let grantTypeSet = Set(grantTypes)
        guard grantTypeSet.isSubset(of: ["authorization_code", "refresh_token"]),
              grantTypeSet.contains("authorization_code") else {
            throw OAuthError.invalidClientMetadata("Only authorization_code with optional refresh_token is supported.")
        }

        let responseTypes = try registrationStringArray(
            object["response_types"],
            field: "response_types",
            defaultValue: ["code"]
        )
        guard Set(responseTypes) == ["code"] else {
            throw OAuthError.invalidClientMetadata("Only the code response type is supported.")
        }

        // An app gets a secret of its own only when it asks for one. RFC 7591
        // makes client_secret_basic the default when the field is left out,
        // but the apps that leave it out are public ones, so a missing value
        // means "none" and the reply says so.
        var authenticationMethod = ClientAuthenticationMethod.none
        if let rawMethod = object["token_endpoint_auth_method"] {
            guard let method = rawMethod as? String, !method.isEmpty else {
                throw OAuthError.invalidClientMetadata("token_endpoint_auth_method must be a string.")
            }
            switch method {
            case "none": authenticationMethod = .none
            case "client_secret_basic": authenticationMethod = .clientSecretBasic
            case "client_secret_post": authenticationMethod = .clientSecretPost
            default: throw OAuthError.invalidClientMetadata("Unsupported token_endpoint_auth_method.")
            }
        }
        let clientSecret = authenticationMethod == .none ? nil : Self.randomToken(byteCount: 32)

        let clientName = sanitizeClientName(object["client_name"] as? String)
        let redirectURIs = try parseRedirectURIs(object["redirect_uris"], registration: true)
        let applicationType = try registrationApplicationType(
            object["application_type"],
            redirectURIs: redirectURIs
        )
        let additionalRegistrationMetadata = try registrationResponseMetadata(from: object)
        let scopes: Set<String>
        do {
            scopes = try parseScopes(object["scope"] as? String)
        } catch OAuthError.invalidScope {
            throw OAuthError.invalidClientMetadata("Unsupported scope.")
        }
        let clientID = "macremote-client-\(Self.randomToken(byteCount: 16))"
        let trustID = Self.dynamicClientTrustID(clientID: clientID)
        let client = Client(
            id: clientID,
            trustID: trustID,
            name: clientName,
            redirectURIs: redirectURIs,
            scopes: scopes,
            createdAt: Date(),
            authenticationMethod: authenticationMethod,
            secretHash: clientSecret.map(Self.sha256Hex)
        )

        let registeredClient: Client = try lock.withLock {
            if clients.count >= Self.maxRegisteredClients {
                let now = Date()
                // Precedence is deliberate: an active approval request, a
                // retained approved record, or a live token protects the registration.
                // Denied and expired never-approved attempts do not, otherwise
                // an unauthenticated caller could pin all 64 slots forever.
                expirePendingAuthorizations(now: now)
                let protectedClientIDs = Set(authorizations.values.compactMap { authorization in
                    switch authorization.status {
                    case .pending, .approved:
                        authorization.clientID
                    case .denied, .expired:
                        nil
                    }
                })
                let liveTokenClientIDs = Set(
                    accessTokensByHash.values.filter { $0.expiresAt > now }.map(\.clientID)
                        + refreshTokensByHash.values.filter { $0.expiresAt > now }.map(\.clientID)
                )
                let evictedClient = clients.values
                    .filter {
                        !protectedClientIDs.contains($0.id)
                            && !liveTokenClientIDs.contains($0.id)
                    }
                    .min { $0.createdAt < $1.createdAt }
                if let evictedClient {
                    clients.removeValue(forKey: evictedClient.id)
                    authorizations = authorizations.filter { $0.value.clientID != evictedClient.id }
                    // Only an approved client is on disk, so only its
                    // eviction changes the saved file.
                    if approvedClientIDs.remove(evictedClient.id) != nil {
                        try? persistGrantSnapshotLocked()
                    }
                }
            }

            guard clients.count < Self.maxRegisteredClients else {
                throw OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
            }
            // Kept in memory only until the owner approves its sign-in.
            clients[clientID] = client
            return client
        }

        var response: [String: Any] = [
            "client_id": registeredClient.id,
            "client_id_issued_at": Int(registeredClient.createdAt.timeIntervalSince1970),
            "client_name": registeredClient.name,
            "redirect_uris": registeredClient.redirectURIs,
            "grant_types": grantTypes,
            "response_types": responseTypes,
            "token_endpoint_auth_method": tokenEndpointAuthMethodName(authenticationMethod),
            "scope": registeredClient.scopes.sorted().joined(separator: " ")
        ]
        if let clientSecret {
            // Shown this once; only its hash is kept.
            response["client_secret"] = clientSecret
            response["client_secret_expires_at"] = 0
        }
        if let applicationType {
            response["application_type"] = applicationType
        }
        for (key, value) in additionalRegistrationMetadata {
            response[key] = value
        }
        return response
    }

    private func tokenEndpointAuthMethodName(_ method: ClientAuthenticationMethod) -> String {
        switch method {
        case .none: "none"
        case .clientSecretBasic: "client_secret_basic"
        case .clientSecret, .clientSecretPost: "client_secret_post"
        }
    }

    func beginAuthorization(queryItems: [String: String], issuer: String, resource: String) throws -> UUID {
        guard queryItems["response_type"] == "code" else {
            throw OAuthError.invalidRequest("Only authorization code flow is supported.")
        }
        guard let clientID = queryItems["client_id"], !clientID.isEmpty else {
            throw OAuthError.invalidRequest("Missing client_id.")
        }
        guard let redirectURI = queryItems["redirect_uri"], !redirectURI.isEmpty else {
            throw OAuthError.invalidRequest("Missing redirect_uri.")
        }
        guard let codeChallenge = queryItems["code_challenge"], !codeChallenge.isEmpty else {
            throw OAuthError.invalidRequest("Missing code_challenge.")
        }
        guard queryItems["code_challenge_method"] == "S256" else {
            throw OAuthError.invalidRequest("PKCE S256 is required.")
        }

        let requestedScopes = try parseScopes(queryItems["scope"])
        let resolvedResource = try resolveRequestedResource(queryItems["resource"], expectedResource: resource)
        let recoveryName = recoveredClientName(queryItems: queryItems, redirectURI: redirectURI)
        let id = UUID()

        // One step under the lock, with the client looked up last: this
        // endpoint needs no sign-in, so a refused request must not leave a
        // client record behind.
        let snapshot: [ApprovalRequest] = try lock.withLock {
            let now = Date()
            expirePendingAuthorizations(now: now)
            // Finished requests are history only; keeping few of them leaves
            // room for every pending one under the total cap.
            pruneResolvedAuthorizations(keeping: Self.maxStoredAuthorizations - Self.maxPendingAuthorizations)
            try requirePendingCapacityLocked(clientID: clientID)
            let client = try clientForAuthorizationLocked(
                clientID: clientID,
                redirectURI: redirectURI,
                requestedScopes: requestedScopes,
                recoveryName: recoveryName
            )
            authorizations[id] = PendingAuthorization(
                id: id,
                clientID: clientID,
                clientTrustID: client.trustID,
                clientName: client.name,
                redirectURI: redirectURI,
                scopes: requestedScopes,
                state: queryItems["state"],
                codeChallenge: codeChallenge,
                createdAt: now,
                issuer: issuer,
                resource: resolvedResource,
                status: .pending
            )
            return approvalSnapshotLocked()
        }
        notify(snapshot)
        scheduleExpiration(of: id)
        return id
    }

    /// Expiry is otherwise noticed only when another request arrives. Without
    /// this, a request nobody answered stayed on screen, in the Dock badge,
    /// and in the menu bar count after it could no longer be approved.
    private func scheduleExpiration(of id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pendingAuthorizationLifetime + 1))
            guard let self else { return }
            let snapshot: [ApprovalRequest]? = self.lock.withLock {
                guard self.authorizations[id]?.status == .pending else { return nil }
                self.expirePendingAuthorizations(now: Date())
                return self.approvalSnapshotLocked()
            }
            if let snapshot {
                self.notify(snapshot)
            }
        }
    }

    /// Drops a client the owner never approved once none of its sign-ins is
    /// waiting. Anyone can register or ask to sign in, so a denied or ignored
    /// request must not leave its client on record.
    private func forgetClientIfNeverApprovedLocked(_ clientID: String) {
        guard !approvedClientIDs.contains(clientID),
              !authorizations.values.contains(where: { $0.clientID == clientID && $0.status == .pending }) else {
            return
        }
        clients.removeValue(forKey: clientID)
    }

    private func requirePendingCapacityLocked(clientID: String) throws {
        let pending = authorizations.values.filter { $0.status == .pending }
        guard pending.count < Self.maxPendingAuthorizations,
              pending.count(where: { $0.clientID == clientID }) < Self.maxPendingAuthorizationsPerClient else {
            throw OAuthError.invalidRequest("Too many pending authorization requests. Approve, deny, or wait for expiration.")
        }
    }

    func authorizationStatus(requestID: UUID) -> [String: Any] {
        let now = Date()
        let result: (response: [String: Any], snapshot: [ApprovalRequest]) = lock.withLock {
            expirePendingAuthorizations(now: now)
            guard let authorization = authorizations[requestID] else {
                return (["status": "not_found"], approvalSnapshotLocked())
            }

            let response: [String: Any]
            switch authorization.status {
            case .pending:
                response = ["status": "pending"]
            case .approved:
                if let issuedCode = authorization.issuedCode {
                    response = [
                        "status": "approved",
                        "redirect_uri": redirectURI(for: authorization, code: issuedCode)
                    ]
                } else {
                    response = ["status": "pending"]
                }
            case .denied:
                response = [
                    "status": "denied",
                    "redirect_uri": errorRedirectURI(for: authorization, error: "access_denied")
                ]
            case .expired:
                response = [
                    "status": "expired",
                    "redirect_uri": errorRedirectURI(for: authorization, error: "expired")
                ]
            }
            return (response, approvalSnapshotLocked())
        }
        notify(result.snapshot)
        return result.response
    }

    func approve(requestID: UUID) -> Bool {
        let code = Self.randomToken(byteCount: 32)
        let now = Date()
        let result: (changed: Bool, snapshot: [ApprovalRequest]) = lock.withLock {
            expirePendingAuthorizations(now: now)
            guard var authorization = authorizations[requestID], authorization.status == .pending else {
                return (false, approvalSnapshotLocked())
            }
            authorization.status = .approved
            authorization.codeHash = Self.sha256Hex(code)
            authorization.codeExpiresAt = now.addingTimeInterval(120)
            authorization.issuedCode = code
            authorizations[requestID] = authorization
            // The owner's approval is what earns the client a saved record.
            if approvedClientIDs.insert(authorization.clientID).inserted {
                try? persistGrantSnapshotLocked()
            }
            return (true, approvalSnapshotLocked())
        }
        notify(result.snapshot)
        return result.changed
    }

    func deny(requestID: UUID) -> Bool {
        let result: (changed: Bool, snapshot: [ApprovalRequest]) = lock.withLock {
            guard var authorization = authorizations[requestID], authorization.status == .pending else {
                return (false, approvalSnapshotLocked())
            }
            authorization.status = .denied
            authorizations[requestID] = authorization
            forgetClientIfNeverApprovedLocked(authorization.clientID)
            return (true, approvalSnapshotLocked())
        }
        notify(result.snapshot)
        return result.changed
    }

    func exchangeToken(
        form: [String: String],
        clientAuthenticationSource: OAuthTokenClientAuthenticationSource? = nil,
        issuer: String,
        resource: String,
        now: Date = Date()
    ) throws -> [String: Any] {
        let authenticationSource = clientAuthenticationSource ?? Self.inferredClientAuthenticationSource(form: form)
        switch form["grant_type"] {
        case "authorization_code":
            return try exchangeAuthorizationCode(
                form: form,
                clientAuthenticationSource: authenticationSource,
                issuer: issuer,
                resource: resource,
                now: now
            )
        case "refresh_token":
            return try exchangeRefreshToken(
                form: form,
                clientAuthenticationSource: authenticationSource,
                issuer: issuer,
                resource: resource,
                now: now
            )
        default:
            throw OAuthError.invalidRequest("Unsupported grant_type.")
        }
    }

    /// Installs (or clears, with `nil`) the Single Header bearer token. The
    /// cleartext never persists here — only its hash, compared against the
    /// same SHA-256 digest used for OAuth access tokens.
    func updateStaticHeaderToken(_ token: String?, clientName: String = "Single Header Client") {
        lock.withLock {
            staticHeaderTokenHash = token.map(Self.sha256Hex)
            staticHeaderClientName = clientName
        }
    }

    func validateAccessToken(
        _ token: String,
        issuer: String,
        resource: String,
        requiredScope: String = "mcp:tools",
        now: Date = Date()
    ) -> Bool {
        clientContext(
            forAccessToken: token,
            issuer: issuer,
            resource: resource,
            requiredScope: requiredScope,
            now: now
        ) != nil
    }

    func clientContext(
        forAccessToken token: String,
        issuer: String,
        resource: String,
        requiredScope: String = "mcp:tools",
        now: Date = Date()
    ) -> AuthenticatedClientContext? {
        clientContext(
            forAccessToken: token,
            issuer: issuer,
            acceptedResources: [resource],
            requiredScope: requiredScope,
            now: now
        )
    }

    func clientContext(
        forAccessToken token: String,
        issuer: String,
        acceptedResources: [String],
        requiredScope: String = "mcp:tools",
        now: Date = Date()
    ) -> AuthenticatedClientContext? {
        let tokenHash = Self.sha256Hex(token)
        let canonicalAcceptedResources = Set(acceptedResources.compactMap { try? Self.canonicalResourceURI($0) })
        guard !canonicalAcceptedResources.isEmpty else { return nil }

        return lock.withLock {
            pruneExpiredTokens(now: now)
            guard let record = accessTokensByHash[tokenHash] else {
                if let staticHeaderTokenHash, staticHeaderTokenHash == tokenHash {
                    return AuthenticatedClientContext(
                        clientID: Self.staticHeaderClientID,
                        clientTrustID: Self.staticHeaderClientID,
                        clientName: staticHeaderClientName,
                        issuer: issuer,
                        resource: canonicalAcceptedResources.sorted()[0],
                        scopes: [requiredScope],
                        accessTokenExpiresAt: .distantFuture
                    )
                }
                return nil
            }
            guard record.expiresAt > now,
                  record.issuer == issuer,
                  canonicalAcceptedResources.contains(record.resource),
                  record.scopes.contains(requiredScope) else {
                return nil
            }

            let client = clients[record.clientID]
            return AuthenticatedClientContext(
                clientID: record.clientID,
                clientTrustID: client?.trustID ?? record.clientID,
                clientName: client?.name ?? "Remote MCP Client",
                issuer: record.issuer,
                resource: record.resource,
                scopes: record.scopes.sorted(),
                accessTokenExpiresAt: record.expiresAt
            )
        }
    }

    func approvalSnapshot() -> [ApprovalRequest] {
        lock.withLock {
            expirePendingAuthorizations(now: Date())
            return approvalSnapshotLocked()
        }
    }

    func connectedClientSnapshot() -> [ConnectedClient] {
        lock.withLock {
            pruneExpiredTokens(now: Date())
            return connectedClientSnapshotLocked()
        }
    }

    func revokeAllGrants() -> OAuthRevocationSummary {
        let summary: OAuthRevocationSummary = lock.withLock {
            let summary = OAuthRevocationSummary(
                clients: clients.count,
                authorizations: authorizations.count,
                accessTokens: accessTokensByHash.count,
                refreshTokens: refreshTokensByHash.count
            )
            clients.removeAll()
            approvedClientIDs.removeAll()
            authorizations.removeAll()
            accessTokensByHash.removeAll()
            refreshTokensByHash.removeAll()
            refreshReplies.removeAll()
            grantStore?.clear()
            return summary
        }
        notify([])
        return summary
    }

    /// Every client on record, signed in or not, and which kind it is: one
    /// holding a client ID and secret the owner created, or one that
    /// registered itself. When the owner switches sign-in method, the caller
    /// signs out the kind the new method does not admit.
    func clientIdentities() -> [(clientID: String, trustID: String, usesOwnerCredentials: Bool)] {
        lock.withLock {
            clients.values.map { ($0.id, $0.trustID, $0.authenticationMethod == .clientSecret) }
        }
    }

    func revokeClient(id clientID: String) -> OAuthRevocationSummary? {
        let result: (summary: OAuthRevocationSummary?, snapshot: [ApprovalRequest]) = lock.withLock {
            guard clients[clientID] != nil else {
                return (nil, approvalSnapshotLocked())
            }

            let authorizationIDs = authorizations
                .filter { $0.value.clientID == clientID }
                .map(\.key)
            let accessTokenHashes = accessTokensByHash
                .filter { $0.value.clientID == clientID }
                .map(\.key)
            let refreshTokenHashes = refreshTokensByHash
                .filter { $0.value.clientID == clientID }
                .map(\.key)

            clients.removeValue(forKey: clientID)
            approvedClientIDs.remove(clientID)
            for authorizationID in authorizationIDs {
                authorizations.removeValue(forKey: authorizationID)
            }
            for tokenHash in accessTokenHashes {
                accessTokensByHash.removeValue(forKey: tokenHash)
            }
            for tokenHash in refreshTokenHashes {
                refreshTokensByHash.removeValue(forKey: tokenHash)
            }
            try? persistGrantSnapshotLocked()

            return (
                OAuthRevocationSummary(
                    clients: 1,
                    authorizations: authorizationIDs.count,
                    accessTokens: accessTokenHashes.count,
                    refreshTokens: refreshTokenHashes.count
                ),
                approvalSnapshotLocked()
            )
        }
        notify(result.snapshot)
        return result.summary
    }

    private func exchangeAuthorizationCode(
        form: [String: String],
        clientAuthenticationSource: OAuthTokenClientAuthenticationSource,
        issuer: String,
        resource _: String,
        now: Date
    ) throws -> [String: Any] {
        guard let code = form["code"], !code.isEmpty else {
            throw OAuthError.invalidRequest("Missing code.")
        }
        guard let codeVerifier = form["code_verifier"], !codeVerifier.isEmpty else {
            throw OAuthError.invalidRequest("Missing code_verifier.")
        }
        guard Self.isValidPKCECodeVerifier(codeVerifier) else {
            throw OAuthError.invalidRequest("Invalid code_verifier.")
        }
        return try lock.withLock {
            expirePendingAuthorizations(now: now)
            let codeHash = Self.sha256Hex(code)
            guard let match = authorizations.first(where: { _, value in
                value.codeHash == codeHash
            }) else {
                throw OAuthError.invalidGrant("Unknown authorization code.")
            }

            var authorization = match.value
            guard authorization.status == .approved else {
                throw OAuthError.invalidGrant("Authorization was not approved.")
            }
            guard authorization.codeUsedAt == nil else {
                throw OAuthError.invalidGrant("Authorization code was already used.")
            }

            try validateTokenClientAuthenticationLocked(
                form: form,
                source: clientAuthenticationSource,
                expectedClientID: authorization.clientID
            )
            if let redirectURI = Self.nonEmptyFormValue(form["redirect_uri"]),
               authorization.redirectURI != redirectURI {
                throw OAuthError.invalidGrant("Client or redirect URI mismatch.")
            }
            guard authorization.issuer == issuer else {
                throw OAuthError.invalidGrant(Self.issuerMismatchDescription(expected: authorization.issuer, actual: issuer))
            }
            let requestedResource = try requestedResource(form["resource"], defaultResource: authorization.resource)
            guard authorization.resource == requestedResource else {
                throw OAuthError.invalidGrant("Resource mismatch.")
            }
            guard let codeExpiresAt = authorization.codeExpiresAt, codeExpiresAt > now else {
                throw OAuthError.invalidGrant("Authorization code expired.")
            }
            guard Self.pkceChallenge(for: codeVerifier) == authorization.codeChallenge else {
                throw OAuthError.invalidGrant("PKCE verification failed.")
            }

            if let client = clients[authorization.clientID],
               client.authenticationMethod == .clientSecret,
               !client.redirectURIs.contains(authorization.redirectURI) {
                clients[client.id] = client.binding(
                    redirectURI: authorization.redirectURI,
                    scopes: authorization.scopes
                )
            }
            authorization.codeUsedAt = now
            authorization.issuedCode = nil
            authorizations[match.key] = authorization
            // Each approved sign-in starts its own line of tokens. The ID is
            // random, not the request ID, which the sign-in page can see.
            return try issueTokensLocked(
                clientID: authorization.clientID,
                issuer: issuer,
                resource: authorization.resource,
                scopes: authorization.scopes,
                signInID: Self.randomToken(byteCount: 16),
                replacedTokenHash: nil,
                now: now
            )
        }
    }

    /// Trades a refresh token for a new access token and a new refresh token.
    /// The old refresh token stops working. If it is presented again later,
    /// someone else holds a copy, and nobody can tell which holder is the real
    /// app, so every token from that sign-in is revoked and both must sign in
    /// again. A repeat within `refreshRetryGrace` is a retry, not a theft.
    private func exchangeRefreshToken(
        form: [String: String],
        clientAuthenticationSource: OAuthTokenClientAuthenticationSource,
        issuer: String,
        resource _: String,
        now: Date
    ) throws -> [String: Any] {
        guard let refreshToken = form["refresh_token"], !refreshToken.isEmpty else {
            throw OAuthError.invalidRequest("Missing refresh_token.")
        }

        let refreshHash = Self.sha256Hex(refreshToken)
        let requestedScopes = try parseOptionalScopes(form["scope"])
        // The owner is told after the lock is released.
        var reusedByClientName: String?
        defer {
            if let reusedByClientName {
                refreshTokenReuseHandler?(reusedByClientName)
            }
        }

        // The checks every refresh must pass, against the current token or,
        // for a retry, against the token that replaced it.
        func validateLocked(_ record: TokenRecord) throws {
            guard record.issuer == issuer else {
                throw OAuthError.invalidGrant(Self.issuerMismatchDescription(expected: record.issuer, actual: issuer))
            }
            try validateTokenClientAuthenticationLocked(
                form: form,
                source: clientAuthenticationSource,
                expectedClientID: record.clientID
            )
            let requestedResource = try requestedResource(form["resource"], defaultResource: record.resource)
            guard record.resource == requestedResource else {
                throw OAuthError.invalidGrant("Resource mismatch.")
            }
            guard requestedScopes?.isSubset(of: record.scopes) != false else {
                throw OAuthError.invalidScope("Requested scope exceeds the original grant.")
            }
        }

        return try lock.withLock {
            pruneExpiredTokens(now: now)
            guard let record = refreshTokensByHash[refreshHash] else {
                // Not a current token. It was used before if a current token
                // replaced it, or if it names a sign-in that still has tokens.
                let successor = refreshTokensByHash.values.first { $0.replacedTokenHash == refreshHash }
                if let successor, now.timeIntervalSince(successor.issuedAt) <= Self.refreshRetryGrace {
                    // A retry gets the reply again, so it must pass the same
                    // checks. After a relaunch the reply is gone: refused,
                    // but not treated as theft.
                    try validateLocked(successor)
                    guard let reply = refreshReplies[refreshHash]?.reply else {
                        throw OAuthError.invalidGrant("Invalid refresh token.")
                    }
                    return reply
                }
                // No checks here: holding a used token is the evidence, even
                // for a caller that could not prove it is the app.
                if let signInID = successor?.signInID ?? Self.signInID(inRefreshToken: refreshToken),
                   let clientID = revokeSignInLocked(signInID) {
                    try? persistGrantSnapshotLocked()
                    reusedByClientName = clients[clientID]?.name ?? "An app"
                }
                throw OAuthError.invalidGrant("Invalid refresh token.")
            }

            try validateLocked(record)
            refreshTokensByHash.removeValue(forKey: refreshHash)
            let reply = try issueTokensLocked(
                clientID: record.clientID,
                issuer: issuer,
                resource: record.resource,
                scopes: requestedScopes ?? record.scopes,
                signInID: record.signInID,
                replacedTokenHash: refreshHash,
                now: now
            )
            refreshReplies[refreshHash] = (reply, now.addingTimeInterval(Self.refreshRetryGrace))
            return reply
        }
    }

    /// Removes every token that came from one approved sign-in and returns
    /// the client they belonged to, or nil when that sign-in has none left.
    private func revokeSignInLocked(_ signInID: String) -> String? {
        let tokens = Array(refreshTokensByHash.values) + Array(accessTokensByHash.values)
        guard let clientID = tokens.first(where: { $0.signInID == signInID })?.clientID else {
            return nil
        }
        refreshTokensByHash = refreshTokensByHash.filter { $0.value.signInID != signInID }
        accessTokensByHash = accessTokensByHash.filter { $0.value.signInID != signInID }
        return clientID
    }

    /// A refresh token starts with the ID of the sign-in it came from, so an
    /// old token is recognized for as long as that sign-in lives, without a
    /// growing list of every token ever used. The ID appears nowhere else, so
    /// only someone who held one of that sign-in's tokens can present it.
    /// Tokens issued before this scheme have no ID and return nil.
    private static func signInID(inRefreshToken token: String) -> String? {
        token.firstIndex(of: ".").map { String(token[..<$0]) }
    }

    /// Stores and returns a new access token and refresh token for one
    /// sign-in. The caller holds the lock, so replacing a refresh token and
    /// issuing its successor is one step that a second request cannot split.
    private func issueTokensLocked(
        clientID: String,
        issuer: String,
        resource: String,
        scopes: Set<String>,
        signInID: String,
        replacedTokenHash: String?,
        now: Date
    ) throws -> [String: Any] {
        let accessToken = Self.randomToken(byteCount: 32)
        let refreshToken = "\(signInID).\(Self.randomToken(byteCount: 32))"
        let accessExpiresIn = Int(accessTokenLifetime)
        let refreshExpiresIn = Int(refreshTokenLifetime)

        accessTokensByHash[Self.sha256Hex(accessToken)] = TokenRecord(
            clientID: clientID,
            issuer: issuer,
            resource: resource,
            scopes: scopes,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(accessExpiresIn)),
            signInID: signInID
        )
        refreshTokensByHash[Self.sha256Hex(refreshToken)] = TokenRecord(
            clientID: clientID,
            issuer: issuer,
            resource: resource,
            scopes: scopes,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(refreshExpiresIn)),
            signInID: signInID,
            replacedTokenHash: replacedTokenHash
        )
        try persistGrantSnapshotLocked()

        return [
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "token_type": "Bearer",
            "expires_in": accessExpiresIn,
            "refresh_expires_in": refreshExpiresIn,
            "scope": scopes.sorted().joined(separator: " "),
            "resource": resource
        ]
    }

    private func resolveRequestedResource(_ rawResource: String?, expectedResource: String) throws -> String {
        let expected = try Self.canonicalResourceURI(expectedResource)
        let requested = try requestedResource(rawResource, defaultResource: expected)
        guard requested == expected else {
            throw OAuthError.invalidRequest("Unsupported resource.")
        }
        return requested
    }

    private func requestedResource(_ rawResource: String?, defaultResource: String) throws -> String {
        let fallback = try Self.canonicalResourceURI(defaultResource)
        guard let rawResource = Self.nonEmptyFormValue(rawResource) else {
            return fallback
        }

        return try Self.canonicalResourceURI(rawResource)
    }

    private static func canonicalResourceURI(_ rawValue: String) throws -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw OAuthError.invalidRequest("Invalid resource.")
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw OAuthError.invalidRequest("Invalid resource.")
        }

        var canonical = URLComponents()
        canonical.scheme = scheme
        canonical.host = rawHost.lowercased()
        canonical.port = components.port
        canonical.path = Self.normalizedResourcePath(components.path)
        guard let string = canonical.string else {
            throw OAuthError.invalidRequest("Invalid resource.")
        }
        return string
    }

    private static func normalizedResourcePath(_ rawPath: String) -> String {
        guard rawPath.count > 1 else { return rawPath }
        var path = rawPath
        while path.count > 1, path.last == "/" {
            path.removeLast()
        }
        return path
    }

    private static func nonEmptyFormValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func inferredClientAuthenticationSource(
        form: [String: String]
    ) -> OAuthTokenClientAuthenticationSource {
        nonEmptyFormValue(form["client_secret"]) == nil ? .none : .clientSecretPost
    }

    private static func dynamicClientTrustID(clientID: String) -> String {
        "macremote-dcr-v2-\(sha256Hex(clientID).prefix(24))"
    }

    private static func confidentialClientTrustID(clientID: String) -> String {
        "macremote-confidential-\(sha256Hex(clientID).prefix(24))"
    }

    private static func publishedClientTrustID(clientID: String) -> String {
        "macremote-published-\(sha256Hex(clientID).prefix(24))"
    }

    private func validateTokenClientAuthenticationLocked(
        form: [String: String],
        source: OAuthTokenClientAuthenticationSource,
        expectedClientID: String
    ) throws {
        guard let client = clients[expectedClientID] else {
            throw OAuthError.invalidGrant("Unknown client_id.")
        }

        let clientID = Self.nonEmptyFormValue(form["client_id"])
        let clientSecret = Self.nonEmptyFormValue(form["client_secret"])

        switch client.authenticationMethod {
        case .none:
            if let clientID, clientID != expectedClientID {
                throw OAuthError.invalidGrant("Client or redirect URI mismatch.")
            }
            if clientSecret != nil {
                throw OAuthError.invalidRequest("Public clients must not send client_secret.")
            }
        case .clientSecret, .clientSecretBasic, .clientSecretPost:
            guard clientID == expectedClientID else {
                throw OAuthError.invalidClient("Client authentication failed.")
            }
            guard let clientSecret else {
                throw OAuthError.invalidClient("Client authentication required.")
            }
            switch client.authenticationMethod {
            case .clientSecret:
                guard source == .clientSecretBasic || source == .clientSecretPost else {
                    throw OAuthError.invalidClient("Client authentication required.")
                }
            case .clientSecretBasic:
                guard source == .clientSecretBasic else {
                    throw OAuthError.invalidClient("Client authentication method does not match registration.")
                }
            case .clientSecretPost:
                guard source == .clientSecretPost else {
                    throw OAuthError.invalidClient("Client authentication method does not match registration.")
                }
            case .none:
                break
            }
            guard let secretHash = client.secretHash,
                  Self.constantTimeEqual(Self.sha256Hex(clientSecret), secretHash) else {
                throw OAuthError.invalidClient("Client authentication failed.")
            }
        }
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        var difference = lhsBytes.count ^ rhsBytes.count
        for index in 0..<max(lhsBytes.count, rhsBytes.count) {
            let lhsByte = index < lhsBytes.count ? lhsBytes[index] : 0
            let rhsByte = index < rhsBytes.count ? rhsBytes[index] : 0
            difference |= Int(lhsByte ^ rhsByte)
        }
        return difference == 0
    }

    private static func isLoopbackHost(_ rawHost: String?) -> Bool {
        let host = rawHost?.lowercased()
        // Foundation currently preserves the brackets in URLComponents.host
        // for IPv6 literals; accept both representations across SDK versions.
        return host == "127.0.0.1" || host == "::1" || host == "[::1]" || host == "localhost"
    }

    private static func issuerMismatchDescription(expected: String, actual: String) -> String {
        "Issuer mismatch. OAuth was started with \(expected), but token exchange used \(actual). Restart login using one MacRemote URL consistently: local 127.0.0.1 or the public tunnel URL, not both."
    }

    /// The client a sign-in request names, checked against what it may ask
    /// for. An unknown ID gets a record only when the current sign-in method
    /// admits it: one of the owner's client IDs, or an ID this Mac issued to
    /// an app that registered itself.
    private func clientForAuthorizationLocked(
        clientID: String,
        redirectURI: String,
        requestedScopes: Set<String>,
        recoveryName: String
    ) throws -> Client {
        // Every path, including Client Secret apps whose redirect was never
        // registered: the sign-in page navigates to this address, so a
        // `javascript:` or `data:` value would run in the page.
        _ = try parseRedirectURIs([redirectURI])
        guard let client = clients[clientID] else {
            if let client = try configuredConfidentialClientLocked(
                clientID: clientID,
                clientName: recoveryName,
                requestedScopes: requestedScopes
            ) {
                return client
            }
            if let published = PublishedOAuthClient.named(clientID) {
                return try publishedClientLocked(
                    published,
                    redirectURI: redirectURI,
                    requestedScopes: requestedScopes
                )
            }
            return try recoverDynamicClient(
                clientID: clientID,
                clientName: recoveryName,
                redirectURI: redirectURI,
                requestedScopes: requestedScopes
            )
        }

        // A Client Secret app has no registered redirect until its first
        // sign-in completes with the secret. After that only the bound
        // address is accepted: this endpoint cannot check the secret.
        let allowsUnboundConfidentialRedirect = client.authenticationMethod == .clientSecret &&
            client.redirectURIs.isEmpty &&
            configuredConfidentialCredentialsLocked(clientID: client.id) != nil
        guard client.redirectURIs.contains(redirectURI) || allowsUnboundConfidentialRedirect else {
            throw OAuthError.invalidRequest("Unregistered redirect_uri.")
        }
        guard !requestedScopes.isEmpty, requestedScopes.isSubset(of: client.scopes) else {
            throw OAuthError.invalidScope("Unsupported scope.")
        }
        return client
    }

    private func configuredConfidentialClientLocked(
        clientID: String,
        clientName: String,
        requestedScopes: Set<String>
    ) throws -> Client? {
        guard let credentials = configuredConfidentialCredentialsLocked(clientID: clientID) else {
            return nil
        }
        guard !requestedScopes.isEmpty else {
            throw OAuthError.invalidScope("Unsupported scope.")
        }
        guard clients.count < Self.maxRegisteredClients else {
            throw OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
        }

        let sanitizedName = sanitizeClientName(clientName)
        let client = Client(
            id: credentials.clientID,
            trustID: Self.confidentialClientTrustID(clientID: credentials.clientID),
            name: sanitizedName,
            redirectURIs: [],
            scopes: requestedScopes,
            createdAt: Date(),
            authenticationMethod: .clientSecret,
            secretHash: Self.sha256Hex(credentials.clientSecret)
        )
        clients[client.id] = client
        return client
    }

    private func configuredConfidentialCredentialsLocked(clientID: String) -> OAuthConfidentialClientCredentials? {
        clientAuthentication.confidentialClients.first { $0.clientID == clientID }
    }

    /// Makes the record for an app MacRemote knows by its published client ID
    /// (`PublishedOAuthClient`). Its name and return address come from the
    /// built-in list, never from the request. The record lives by the same
    /// rule as a registration: memory only until approved, dropped if denied
    /// or ignored.
    private func publishedClientLocked(
        _ published: PublishedOAuthClient,
        redirectURI: String,
        requestedScopes: Set<String>
    ) throws -> Client {
        guard clientAuthentication.supportsDynamicClientRegistration else {
            throw OAuthError.invalidRequest("Unknown client_id.")
        }
        guard published.redirectURIs.contains(redirectURI) else {
            throw OAuthError.invalidRequest("Unregistered redirect_uri.")
        }
        guard !requestedScopes.isEmpty else {
            throw OAuthError.invalidScope("Unsupported scope.")
        }
        guard clients.count < Self.maxRegisteredClients else {
            throw OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
        }
        let client = Client(
            id: published.clientID,
            trustID: Self.publishedClientTrustID(clientID: published.clientID),
            name: published.name,
            redirectURIs: published.redirectURIs,
            scopes: requestedScopes,
            createdAt: Date()
        )
        clients[client.id] = client
        return client
    }

    /// Gives a record back to an app that returns with a client ID this Mac
    /// issued but no longer has: the owner signed the app out, denied it, or
    /// did not answer in time, and the app kept the ID. Such an app cannot see
    /// the refusal, because it happens in the browser, so without this it
    /// could never ask again. Only HTTPS return addresses qualify: nothing
    /// was registered to compare against, and a web address is one the owner
    /// can read in the request. The record lives by the same rule as a
    /// registration: memory only until approved, dropped if denied or ignored.
    private func recoverDynamicClient(
        clientID: String,
        clientName: String,
        redirectURI: String,
        requestedScopes: Set<String>
    ) throws -> Client {
        guard clientAuthentication.supportsDynamicClientRegistration else {
            throw OAuthError.invalidRequest("Unknown client_id.")
        }
        let redirectURIs = try parseRedirectURIs([redirectURI])
        guard Self.isRecoverableDynamicClientID(clientID, redirectURI: redirectURI) else {
            throw OAuthError.invalidRequest("Unknown client_id.")
        }
        guard !requestedScopes.isEmpty else {
            throw OAuthError.invalidScope("Unsupported scope.")
        }
        guard clients.count < Self.maxRegisteredClients else {
            throw OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
        }
        let sanitizedName = sanitizeClientName(clientName)
        let trustID = Self.dynamicClientTrustID(clientID: clientID)

        let client = Client(
            id: clientID,
            trustID: trustID,
            name: sanitizedName,
            redirectURIs: redirectURIs,
            scopes: requestedScopes,
            createdAt: Date()
        )
        clients[clientID] = client
        return client
    }

    private static func isRecoverableDynamicClientID(_ clientID: String) -> Bool {
        let prefix = "macremote-client-"
        guard clientID.hasPrefix(prefix), clientID.count <= 128 else { return false }
        let suffix = clientID.dropFirst(prefix.count)
        guard (16...64).contains(suffix.count) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return suffix.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func isRecoverableDynamicClientID(_ clientID: String, redirectURI: String) -> Bool {
        guard isRecoverableDynamicClientID(clientID),
              let components = URLComponents(string: redirectURI),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            return false
        }
        return true
    }

    /// A display name for a client that did not register one: a Client Secret
    /// app, or one returning with an ID this Mac no longer has on record. It is
    /// what the client calls itself, a known service matched by its exact
    /// domain, or else where its sign-in returns. Cosmetic only: the approval
    /// prompt shows the destination and a matching code, because none of this
    /// proves who is asking.
    private func recoveredClientName(queryItems: [String: String], redirectURI: String) -> String {
        if let name = queryItems["client_name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        let components = URLComponents(string: redirectURI)
        let scheme = components?.scheme?.lowercased() ?? ""
        let host = components?.host?.lowercased() ?? ""
        func isDomain(_ domain: String) -> Bool {
            host == domain || host.hasSuffix("." + domain)
        }
        if isDomain("notion.com") || isDomain("notion.so") {
            return "Notion"
        }
        if isDomain("claude.ai") || isDomain("claude.com") {
            return "Claude"
        }
        if isDomain("raycast.com") || scheme == "raycast" {
            return "Raycast"
        }
        if scheme == "https" || scheme == "http" {
            return host.isEmpty ? "Remote MCP Client" : host
        }
        return scheme.isEmpty ? "Remote MCP Client" : scheme
    }

    private func parseRedirectURIs(_ value: Any?, registration: Bool = false) throws -> [String] {
        func invalidRedirect(_ message: String) -> OAuthError {
            registration ? .invalidRedirectURI(message) : .invalidRequest(message)
        }

        guard let redirectURIs = value as? [String], !redirectURIs.isEmpty else {
            throw invalidRedirect("redirect_uris must be a non-empty string array.")
        }
        guard redirectURIs.count <= 10, redirectURIs.allSatisfy({ $0.utf8.count <= 2048 }) else {
            throw invalidRedirect("Too many redirect_uris, or one is too long.")
        }

        for redirectURI in redirectURIs {
            guard let components = URLComponents(string: redirectURI),
                  let scheme = components.scheme?.lowercased(),
                  components.user == nil,
                  components.password == nil,
                  components.fragment == nil else {
                throw invalidRedirect("Invalid redirect_uri.")
            }

            let host = components.host?.lowercased()
            let isHTTPS = scheme == "https" && host?.isEmpty == false
            let isLoopbackHTTP = scheme == "http" && Self.isLoopbackHost(host)
            let isPrivateUseAppScheme = Self.isPrivateUseRedirectScheme(scheme)
            guard isHTTPS || isLoopbackHTTP || isPrivateUseAppScheme else {
                throw invalidRedirect("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")
            }
        }

        return Array(Set(redirectURIs)).sorted()
    }

    private static func isPrivateUseRedirectScheme(_ scheme: String) -> Bool {
        let blockedSchemes = Set([
            "data",
            "file",
            "ftp",
            "http",
            "https",
            "javascript",
            "mailto"
        ])
        guard !blockedSchemes.contains(scheme), scheme.count <= 64 else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+.-")
        return scheme.rangeOfCharacter(from: allowed.inverted) == nil
    }

    private func registrationStringArray(
        _ value: Any?,
        field: String,
        defaultValue: [String]
    ) throws -> [String] {
        guard let value else { return defaultValue }
        guard let values = value as? [String],
              !values.isEmpty,
              values.allSatisfy({ !$0.isEmpty }) else {
            throw OAuthError.invalidClientMetadata("\(field) must be a non-empty string array.")
        }
        return Array(Set(values)).sorted()
    }

    private func registrationApplicationType(
        _ value: Any?,
        redirectURIs: [String]
    ) throws -> String? {
        guard let value else {
            // Older MCP clients predate the 2026-07-28 application_type
            // requirement. Keep accepting their registrations as a legacy
            // DCR compatibility path.
            return nil
        }
        guard let applicationType = value as? String,
              applicationType == "native" || applicationType == "web" else {
            throw OAuthError.invalidClientMetadata("application_type must be native or web.")
        }

        if applicationType == "web" {
            let allRedirectsAreHTTPS = redirectURIs.allSatisfy { redirectURI in
                guard let components = URLComponents(string: redirectURI) else {
                    return false
                }
                return components.scheme?.lowercased() == "https" &&
                    components.host?.isEmpty == false
            }
            guard allRedirectsAreHTTPS else {
                throw OAuthError.invalidRedirectURI(
                    "web application_type requires HTTPS redirect_uris."
                )
            }
        }

        return applicationType
    }

    /// These are validated, echoed back per RFC 7591, and then never shown.
    ///
    /// `logo_uri` in particular stays out of the UI on purpose, even though
    /// MacRemote does accept `data:` icons from an app's MCP handshake. The two
    /// look similar and are not: `logo_uri` arrives during Dynamic Client
    /// Registration, which is unauthenticated and happens *before* any human has
    /// approved anything. Honoring it would let a stranger who has done nothing
    /// but POST to /register put a picture of their choosing into MacRemote's
    /// approval window — the one surface whose whole job is to help Federico
    /// decide. It is also a URL, so drawing it would mean fetching from a host
    /// the registrant picked. Icons are only accepted after a client is
    /// authenticated, as inline `data:` bytes; see `Models/ClientSuppliedIcon.swift`.
    private func registrationResponseMetadata(from object: [String: Any]) throws -> [String: Any] {
        var metadata: [String: Any] = [:]
        let optionalURIFields = [
            "client_uri",
            "logo_uri",
            "tos_uri",
            "policy_uri",
            "jwks_uri"
        ]
        let optionalStringFields = [
            "software_id",
            "software_version",
            "software_statement"
        ]

        for field in optionalURIFields {
            guard let value = object[field] else { continue }
            guard let string = value as? String,
                  Self.isAbsoluteURI(string) else {
                throw OAuthError.invalidClientMetadata("\(field) must be an absolute URI.")
            }
            metadata[field] = string
        }

        for field in optionalStringFields {
            guard let value = object[field] else { continue }
            guard let string = value as? String, !string.isEmpty else {
                throw OAuthError.invalidClientMetadata("\(field) must be a non-empty string.")
            }
            metadata[field] = string
        }

        if let value = object["contacts"] {
            guard let contacts = value as? [String],
                  !contacts.isEmpty,
                  contacts.allSatisfy({ !$0.isEmpty }) else {
                throw OAuthError.invalidClientMetadata("contacts must be a non-empty string array.")
            }
            metadata["contacts"] = contacts
        }

        if object["jwks"] != nil, object["jwks_uri"] != nil {
            throw OAuthError.invalidClientMetadata("jwks and jwks_uri must not both be present.")
        }

        if let value = object["jwks"] {
            guard let jwks = value as? [String: Any], JSONSerialization.isValidJSONObject(jwks) else {
                throw OAuthError.invalidClientMetadata("jwks must be a JSON object.")
            }
            metadata["jwks"] = jwks
        }

        return metadata
    }

    private static func isAbsoluteURI(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let components = URLComponents(string: value),
              let scheme = components.scheme,
              !scheme.isEmpty else {
            return false
        }
        return true
    }

    private func parseScopes(_ scope: String?) throws -> Set<String> {
        try parseOptionalScopes(scope) ?? ["mcp:tools"]
    }

    private func parseOptionalScopes(_ scope: String?) throws -> Set<String>? {
        guard let scope else { return nil }
        let values = scope
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let allowed = Set(["mcp:tools"])
        let requested = Set(values)
        guard !requested.isEmpty, requested.isSubset(of: allowed) else {
            throw OAuthError.invalidScope("Unsupported scope.")
        }
        return requested
    }

    private static func isValidPKCECodeVerifier(_ verifier: String) -> Bool {
        guard (43...128).contains(verifier.utf8.count) else { return false }
        return verifier.utf8.allSatisfy { byte in
            switch byte {
            case 45, 46, 48...57, 65...90, 95, 97...122, 126:
                true
            default:
                false
            }
        }
    }

    /// A client names itself, so the name is untrusted text shown in approval
    /// prompts and notifications. Keep letters, digits, spaces, and plain
    /// punctuation; drop control and invisible characters, and symbols such as
    /// a check mark that could pass for a badge MacRemote awarded.
    private func sanitizeClientName(_ value: String?) -> String {
        let punctuation = CharacterSet(charactersIn: ".,-_'&()+/:")
        let kept = (value ?? "").unicodeScalars.map { scalar -> Character in
            if scalar.properties.isAlphabetic
                || scalar.properties.numericType != nil
                || scalar.properties.generalCategory == .nonspacingMark
                || punctuation.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let collapsed = String(kept).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? "Remote MCP Client" : String(collapsed.prefix(60))
    }

    private func approvalSnapshotLocked() -> [ApprovalRequest] {
        authorizations.values
            .map(\.approvalRequest)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func connectedClientSnapshotLocked(now: Date = Date()) -> [ConnectedClient] {
        clients.values.compactMap { client in
            let approvedAuthorizations = authorizations.values.filter {
                $0.clientID == client.id && $0.status == .approved
            }
            let accessRecords = accessTokensByHash.values.filter { $0.clientID == client.id }
            let refreshRecords = refreshTokensByHash.values.filter { $0.clientID == client.id }

            // Known gap: a client that registered but never got an approval is
            // invisible here, so the Apps list cannot sign it out individually.
            // Settings › Sign Out All Apps still clears it. Deliberate — the
            // Apps list shows apps the user actually let in.
            guard !approvedAuthorizations.isEmpty || !accessRecords.isEmpty || !refreshRecords.isEmpty else {
                return nil
            }

            let issuer = accessRecords.first?.issuer ?? refreshRecords.first?.issuer ?? approvedAuthorizations.first?.issuer
            let resource = accessRecords.first?.resource ?? refreshRecords.first?.resource ?? approvedAuthorizations.first?.resource
            let scopes = Set(
                client.scopes
                    .union(accessRecords.flatMap(\.scopes))
                    .union(refreshRecords.flatMap(\.scopes))
                    .union(approvedAuthorizations.flatMap(\.scopes))
            )
            let dateCandidates = [client.createdAt] +
                approvedAuthorizations.map(\.createdAt) +
                accessRecords.map(\.issuedAt) +
                refreshRecords.map(\.issuedAt)

            // Truthful session state. A client with an approved authorization
            // whose code is still unredeemed and unexpired is mid-sign-in, not
            // lapsed — the old "zero tokens means expired" test mislabeled
            // every app in the seconds between approval and token exchange.
            let sessionState: ConnectedAppSessionState
            if !accessRecords.isEmpty || !refreshRecords.isEmpty {
                sessionState = .active
            } else if approvedAuthorizations.contains(where: {
                $0.codeUsedAt == nil && ($0.codeExpiresAt ?? .distantPast) > now
            }) {
                sessionState = .awaitingSignIn
            } else {
                sessionState = .expired
            }

            return ConnectedClient(
                id: client.id,
                trustID: client.trustID,
                name: client.name,
                redirectURIs: client.redirectURIs,
                issuer: issuer,
                resource: resource,
                scopes: scopes.sorted(),
                createdAt: client.createdAt,
                lastAuthorizedAt: dateCandidates.max() ?? client.createdAt,
                activeAccessTokens: accessRecords.count,
                activeRefreshTokens: refreshRecords.count,
                authenticationMethod: client.authenticationMethod.connectedAppAuthMethod,
                sessionState: sessionState
            )
        }
        .sorted { lhs, rhs in
            if lhs.sessionState != rhs.sessionState {
                return lhs.sessionState.sortRank < rhs.sessionState.sortRank
            }
            if lhs.lastAuthorizedAt != rhs.lastAuthorizedAt {
                return lhs.lastAuthorizedAt > rhs.lastAuthorizedAt
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func notify(_ snapshot: [ApprovalRequest]) {
        changeHandler?(snapshot)
    }

    private func expirePendingAuthorizations(now: Date) {
        for (id, authorization) in authorizations where authorization.status == .pending {
            if now.timeIntervalSince(authorization.createdAt) > Self.pendingAuthorizationLifetime {
                var expired = authorization
                expired.status = .expired
                authorizations[id] = expired
                forgetClientIfNeverApprovedLocked(authorization.clientID)
            }
        }
        pruneExpiredTokens(now: now)
    }

    private func pruneResolvedAuthorizations(keeping limit: Int) {
        let resolved = authorizations
            .filter { $0.value.status != .pending }
            .sorted { $0.value.createdAt > $1.value.createdAt }

        guard resolved.count > limit else { return }

        for (id, _) in resolved.dropFirst(limit) {
            authorizations.removeValue(forKey: id)
        }
    }

    private func pruneExpiredTokens(now: Date) {
        accessTokensByHash = accessTokensByHash.filter { $0.value.expiresAt > now }
        refreshTokensByHash = refreshTokensByHash.filter { $0.value.expiresAt > now }
        refreshReplies = refreshReplies.filter { $0.value.until > now }
    }

    private func loadPersistedGrants() {
        guard let snapshot = try? grantStore?.loadSnapshot() else { return }
        let now = Date()
        let loadedClients = snapshot.clients
            .prefix(Self.maxRegisteredClients)
            .map { Client(stored: $0) }
        clients = Dictionary(uniqueKeysWithValues: loadedClients.map { ($0.id, $0) })
        // Everything on disk counts as approved. A file from a build that
        // also saved never-approved registrations cannot tell them apart from
        // an approved app whose tokens have lapsed, so both are kept.
        approvedClientIDs = Set(clients.keys)

        // Tokens saved before sign-ins were tracked name none. Each such app
        // gets one ID for all of them, so its next refresh joins the scheme.
        var legacySignInIDs: [String: String] = [:]
        func record(_ token: OAuthStoredToken) -> (String, TokenRecord)? {
            guard clients[token.clientID] != nil, token.expiresAt > now else { return nil }
            let signInID = token.signInID
                ?? legacySignInIDs[token.clientID]
                ?? Self.randomToken(byteCount: 16)
            if token.signInID == nil {
                legacySignInIDs[token.clientID] = signInID
            }
            return (token.tokenHash, TokenRecord(
                clientID: token.clientID,
                issuer: token.issuer,
                resource: token.resource,
                scopes: Set(token.scopes),
                issuedAt: token.issuedAt,
                expiresAt: token.expiresAt,
                signInID: signInID,
                replacedTokenHash: token.replacedTokenHash
            ))
        }
        accessTokensByHash = Dictionary(uniqueKeysWithValues: snapshot.accessTokens.compactMap(record))
        refreshTokensByHash = Dictionary(uniqueKeysWithValues: snapshot.refreshTokens.compactMap(record))
        try? persistGrantSnapshotLocked()
    }

    /// Writes approved clients and their tokens. A client the owner has not
    /// approved is never saved.
    private func persistGrantSnapshotLocked() throws {
        guard let grantStore else { return }
        let snapshot = OAuthGrantSnapshot(
            clients: clients.values
                .filter { approvedClientIDs.contains($0.id) }
                .sorted { $0.createdAt < $1.createdAt }
                .map(\.stored),
            accessTokens: accessTokensByHash
                .map { tokenHash, record in record.stored(tokenHash: tokenHash) }
                .sorted { $0.issuedAt < $1.issuedAt },
            refreshTokens: refreshTokensByHash
                .map { tokenHash, record in record.stored(tokenHash: tokenHash) }
                .sorted { $0.issuedAt < $1.issuedAt }
        )
        try grantStore.saveSnapshot(snapshot)
    }

    private func redirectURI(for authorization: PendingAuthorization, code: String) -> String {
        var components = URLComponents(string: authorization.redirectURI)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "code", value: code))
        items.append(URLQueryItem(name: "iss", value: authorization.issuer))
        if let state = authorization.state {
            items.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = items
        return components?.string ?? authorization.redirectURI
    }

    private func errorRedirectURI(for authorization: PendingAuthorization, error: String) -> String {
        var components = URLComponents(string: authorization.redirectURI)
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "error", value: error))
        items.append(URLQueryItem(name: "iss", value: authorization.issuer))
        if let state = authorization.state {
            items.append(URLQueryItem(name: "state", value: state))
        }
        components?.queryItems = items
        return components?.string ?? authorization.redirectURI
    }

    static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private static func sha256Hex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomToken(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "Secure random generation failed.")
        return Data(bytes).base64URLEncodedString()
    }
}

enum OAuthError: LocalizedError, Equatable, Sendable {
    case invalidRequest(String)
    case invalidGrant(String)
    case invalidClient(String)
    case invalidScope(String)
    case invalidClientMetadata(String)
    case invalidRedirectURI(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .invalidGrant(let message): message
        case .invalidClient(let message): message
        case .invalidScope(let message): message
        case .invalidClientMetadata(let message): message
        case .invalidRedirectURI(let message): message
        }
    }

    var errorCode: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidGrant: "invalid_grant"
        case .invalidClient: "invalid_client"
        case .invalidScope: "invalid_scope"
        case .invalidClientMetadata: "invalid_client_metadata"
        case .invalidRedirectURI: "invalid_redirect_uri"
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
