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

    var supportsDynamicClientRegistration: Bool {
        !requiresConfidentialClient
    }

    var tokenEndpointAuthMethodsSupported: [String] {
        requiresConfidentialClient ? ["client_secret_basic", "client_secret_post"] : ["none"]
    }
}

final class OAuthCoordinator: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([ApprovalRequest]) -> Void

    static let maxRegisteredClients = 64
    static let maxPendingAuthorizations = 16
    static let maxStoredAuthorizations = 64

    private enum ClientAuthenticationMethod: String, Sendable {
        case none
        case clientSecret
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
            self.authenticationMethod = ClientAuthenticationMethod(rawValue: stored.authenticationMethod ?? "") ?? .none
            self.secretHash = stored.secretHash
            self.trustID = stored.trustID ?? OAuthCoordinator.clientTrustID(
                name: stored.name,
                redirectURIs: stored.redirectURIs,
                scopes: Set(stored.scopes)
            )
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

        func merged(name: String, redirectURIs: [String], scopes: Set<String>) -> Client {
            Client(
                id: id,
                trustID: trustID,
                name: self.name.isEmpty ? name : self.name,
                redirectURIs: Array(Set(self.redirectURIs + redirectURIs)).sorted(),
                scopes: self.scopes.union(scopes),
                createdAt: createdAt,
                authenticationMethod: authenticationMethod,
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

    private struct AccessTokenRecord {
        let clientID: String
        let issuer: String
        let resource: String
        let scopes: Set<String>
        let issuedAt: Date
        let expiresAt: Date

        init(clientID: String, issuer: String, resource: String, scopes: Set<String>, issuedAt: Date, expiresAt: Date) {
            self.clientID = clientID
            self.issuer = issuer
            self.resource = resource
            self.scopes = scopes
            self.issuedAt = issuedAt
            self.expiresAt = expiresAt
        }

        init(stored: OAuthStoredToken) {
            self.clientID = stored.clientID
            self.issuer = stored.issuer
            self.resource = stored.resource
            self.scopes = Set(stored.scopes)
            self.issuedAt = stored.issuedAt
            self.expiresAt = stored.expiresAt
        }

        func stored(tokenHash: String) -> OAuthStoredToken {
            OAuthStoredToken(
                tokenHash: tokenHash,
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes.sorted(),
                issuedAt: issuedAt,
                expiresAt: expiresAt
            )
        }
    }

    private struct RefreshTokenRecord {
        let clientID: String
        let issuer: String
        let resource: String
        let scopes: Set<String>
        let issuedAt: Date
        let expiresAt: Date

        init(clientID: String, issuer: String, resource: String, scopes: Set<String>, issuedAt: Date, expiresAt: Date) {
            self.clientID = clientID
            self.issuer = issuer
            self.resource = resource
            self.scopes = scopes
            self.issuedAt = issuedAt
            self.expiresAt = expiresAt
        }

        init(stored: OAuthStoredToken) {
            self.clientID = stored.clientID
            self.issuer = stored.issuer
            self.resource = stored.resource
            self.scopes = Set(stored.scopes)
            self.issuedAt = stored.issuedAt
            self.expiresAt = stored.expiresAt
        }

        func stored(tokenHash: String) -> OAuthStoredToken {
            OAuthStoredToken(
                tokenHash: tokenHash,
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes.sorted(),
                issuedAt: issuedAt,
                expiresAt: expiresAt
            )
        }
    }

    private let lock = NSLock()
    private let changeHandler: ChangeHandler?
    private let grantStore: OAuthGrantStore?
    private var clientAuthentication: OAuthClientAuthenticationPolicy
    private var clients: [String: Client] = [:]
    private var authorizations: [UUID: PendingAuthorization] = [:]
    private var accessTokensByHash: [String: AccessTokenRecord] = [:]
    private var refreshTokensByHash: [String: RefreshTokenRecord] = [:]

    init(
        clientAuthentication: OAuthClientAuthenticationPolicy = .dynamicPublicClients,
        changeHandler: ChangeHandler? = nil,
        grantStore: OAuthGrantStore? = nil
    ) {
        self.clientAuthentication = clientAuthentication
        self.changeHandler = changeHandler
        self.grantStore = grantStore
        loadPersistedGrants()
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

        let clientName = sanitizeClientName(object["client_name"] as? String)
        let redirectURIs = try parseRedirectURIs(object["redirect_uris"])
        let scopes = parseScopes(object["scope"] as? String)
        let trustID = Self.clientTrustID(name: clientName, redirectURIs: redirectURIs, scopes: scopes)
        let clientID = "macremote-client-\(Self.randomToken(byteCount: 16))"
        let client = Client(
            id: clientID,
            trustID: trustID,
            name: clientName,
            redirectURIs: redirectURIs,
            scopes: scopes,
            createdAt: Date()
        )

        let registeredClient: Client = try lock.withLock {
            if let existing = clients.values.first(where: { $0.trustID == trustID }) {
                let merged = existing.merged(name: clientName, redirectURIs: redirectURIs, scopes: scopes)
                clients[existing.id] = merged
                try persistGrantSnapshotLocked()
                return merged
            }

            guard clients.count < Self.maxRegisteredClients else {
                throw OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
            }
            clients[clientID] = client
            do {
                try persistGrantSnapshotLocked()
            } catch {
                clients.removeValue(forKey: clientID)
                throw error
            }
            return client
        }

        return [
            "client_id": registeredClient.id,
            "client_name": registeredClient.name,
            "redirect_uris": registeredClient.redirectURIs,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": registeredClient.scopes.sorted().joined(separator: " ")
        ]
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

        let requestedScopes = parseScopes(queryItems["scope"])
        let client = try clientForAuthorization(
            clientID: clientID,
            redirectURI: redirectURI,
            requestedScopes: requestedScopes,
            recoveryName: recoveredClientName(queryItems: queryItems, redirectURI: redirectURI)
        )
        let resolvedResource = try resolveRequestedResource(queryItems["resource"], expectedResource: resource)
        let id = UUID()
        let authorization = PendingAuthorization(
            id: id,
            clientID: clientID,
            clientTrustID: client.trustID,
            clientName: client.name,
            redirectURI: redirectURI,
            scopes: requestedScopes,
            state: queryItems["state"],
            codeChallenge: codeChallenge,
            createdAt: Date(),
            issuer: issuer,
            resource: resolvedResource,
            status: .pending
        )

        let snapshot: [ApprovalRequest] = try lock.withLock {
            expirePendingAuthorizations(now: Date())
            pruneResolvedAuthorizations(keeping: Self.maxStoredAuthorizations - 1)
            guard authorizations.values.filter({ $0.status == .pending }).count < Self.maxPendingAuthorizations else {
                throw OAuthError.invalidRequest("Too many pending authorization requests. Approve, deny, or wait for expiration.")
            }
            guard authorizations.count < Self.maxStoredAuthorizations else {
                throw OAuthError.invalidRequest("Too many authorization requests. Revoke grants and try again.")
            }
            authorizations[id] = authorization
            return approvalSnapshotLocked()
        }
        notify(snapshot)
        return id
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
            return (true, approvalSnapshotLocked())
        }
        notify(result.snapshot)
        return result.changed
    }

    func exchangeToken(form: [String: String], issuer: String, resource: String) throws -> [String: Any] {
        switch form["grant_type"] {
        case "authorization_code":
            return try exchangeAuthorizationCode(form: form, issuer: issuer, resource: resource)
        case "refresh_token":
            return try exchangeRefreshToken(form: form, issuer: issuer, resource: resource)
        default:
            throw OAuthError.invalidRequest("Unsupported grant_type.")
        }
    }

    func validateAccessToken(_ token: String, issuer: String, resource: String, requiredScope: String = "mcp:tools") -> Bool {
        clientContext(forAccessToken: token, issuer: issuer, resource: resource, requiredScope: requiredScope) != nil
    }

    func clientContext(
        forAccessToken token: String,
        issuer: String,
        resource: String,
        requiredScope: String = "mcp:tools"
    ) -> AuthenticatedClientContext? {
        clientContext(
            forAccessToken: token,
            issuer: issuer,
            acceptedResources: [resource],
            requiredScope: requiredScope
        )
    }

    func clientContext(
        forAccessToken token: String,
        issuer: String,
        acceptedResources: [String],
        requiredScope: String = "mcp:tools"
    ) -> AuthenticatedClientContext? {
        let tokenHash = Self.sha256Hex(token)
        let now = Date()
        let canonicalAcceptedResources = Set(acceptedResources.compactMap { try? Self.canonicalResourceURI($0) })
        guard !canonicalAcceptedResources.isEmpty else { return nil }

        return lock.withLock {
            pruneExpiredTokens(now: now)
            guard let record = accessTokensByHash[tokenHash] else { return nil }
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
            authorizations.removeAll()
            accessTokensByHash.removeAll()
            refreshTokensByHash.removeAll()
            grantStore?.clear()
            return summary
        }
        notify([])
        return summary
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

    private func exchangeAuthorizationCode(form: [String: String], issuer: String, resource _: String) throws -> [String: Any] {
        guard let code = form["code"], !code.isEmpty else {
            throw OAuthError.invalidRequest("Missing code.")
        }
        guard let codeVerifier = form["code_verifier"], !codeVerifier.isEmpty else {
            throw OAuthError.invalidRequest("Missing code_verifier.")
        }

        let now = Date()
        let tokenSubject: (clientID: String, resource: String, scopes: Set<String>) = try lock.withLock {
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

            try validateTokenClientAuthenticationLocked(form: form, expectedClientID: authorization.clientID)
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
            return (authorization.clientID, authorization.resource, authorization.scopes)
        }

        return try issueTokenResponse(
            clientID: tokenSubject.clientID,
            issuer: issuer,
            resource: tokenSubject.resource,
            scopes: tokenSubject.scopes,
            now: now
        )
    }

    private func exchangeRefreshToken(form: [String: String], issuer: String, resource _: String) throws -> [String: Any] {
        guard let refreshToken = form["refresh_token"], !refreshToken.isEmpty else {
            throw OAuthError.invalidRequest("Missing refresh_token.")
        }

        let refreshHash = Self.sha256Hex(refreshToken)
        let now = Date()
        let record: RefreshTokenRecord = try lock.withLock {
            pruneExpiredTokens(now: now)
            guard let record = refreshTokensByHash[refreshHash] else {
                throw OAuthError.invalidGrant("Invalid refresh token.")
            }
            guard record.expiresAt > now else {
                throw OAuthError.invalidGrant("Refresh token expired.")
            }
            guard record.issuer == issuer else {
                throw OAuthError.invalidGrant(Self.issuerMismatchDescription(expected: record.issuer, actual: issuer))
            }
            try validateTokenClientAuthenticationLocked(form: form, expectedClientID: record.clientID)
            let requestedResource = try requestedResource(form["resource"], defaultResource: record.resource)
            guard record.resource == requestedResource else {
                throw OAuthError.invalidGrant("Resource mismatch.")
            }
            refreshTokensByHash.removeValue(forKey: refreshHash)
            return record
        }

        return try issueTokenResponse(
            clientID: record.clientID,
            issuer: issuer,
            resource: record.resource,
            scopes: record.scopes,
            now: now
        )
    }

    private func issueTokenResponse(clientID: String, issuer: String, resource: String, scopes: Set<String>, now: Date) throws -> [String: Any] {
        let accessToken = Self.randomToken(byteCount: 32)
        let refreshToken = Self.randomToken(byteCount: 32)
        let accessHash = Self.sha256Hex(accessToken)
        let refreshHash = Self.sha256Hex(refreshToken)
        let accessExpiresIn = 900
        let refreshExpiresIn = 86_400

        try lock.withLock {
            accessTokensByHash[accessHash] = AccessTokenRecord(
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(TimeInterval(accessExpiresIn))
            )
            refreshTokensByHash[refreshHash] = RefreshTokenRecord(
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes,
                issuedAt: now,
                expiresAt: now.addingTimeInterval(TimeInterval(refreshExpiresIn))
            )
            try persistGrantSnapshotLocked()
        }

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

    private static func clientTrustID(name: String, redirectURIs: [String], scopes: Set<String>) -> String {
        let normalizedScopes = scopes.sorted().joined(separator: " ")
        let normalizedName = normalizedClientName(name)
        let redirects = redirectURIs.map(canonicalTrustRedirectURI).sorted()
        let allLoopback = redirectURIs.allSatisfy(isLoopbackRedirectURI)
        let identity: String

        if allLoopback {
            identity = "loopback:\(normalizedName)"
        } else {
            identity = "redirects:\(redirects.joined(separator: "|"))"
        }

        let material = "macremote-client-trust:v1\n\(identity)\nscopes:\(normalizedScopes)"
        return "macremote-trust-\(sha256Hex(material).prefix(24))"
    }

    private static func confidentialClientTrustID(clientID: String) -> String {
        "macremote-confidential-\(sha256Hex(clientID).prefix(24))"
    }

    private func validateTokenClientAuthenticationLocked(form: [String: String], expectedClientID: String) throws {
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
        case .clientSecret:
            guard clientID == expectedClientID else {
                throw OAuthError.invalidClient("Client authentication failed.")
            }
            guard let clientSecret else {
                throw OAuthError.invalidClient("Client authentication required.")
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

    private static func normalizedClientName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let scalars = trimmed.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
        return collapsed.isEmpty ? "remote-mcp-client" : collapsed
    }

    private static func canonicalTrustRedirectURI(_ rawValue: String) -> String {
        guard var components = URLComponents(string: rawValue),
              let rawScheme = components.scheme else {
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        let scheme = rawScheme.lowercased()
        components.scheme = scheme
        components.host = components.host?.lowercased()

        if isLoopbackRedirectURI(rawValue) {
            components.port = nil
            components.query = nil
            components.fragment = nil
            return "loopback-http"
        }

        components.fragment = nil
        return components.string ?? rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isLoopbackRedirectURI(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "http" else {
            return false
        }
        let host = components.host?.lowercased()
        return host == "127.0.0.1" || host == "localhost"
    }

    private static func issuerMismatchDescription(expected: String, actual: String) -> String {
        "Issuer mismatch. OAuth was started with \(expected), but token exchange used \(actual). Restart login using one MacRemote URL consistently: local 127.0.0.1 or the public tunnel URL, not both."
    }

    private func clientForAuthorization(
        clientID: String,
        redirectURI: String,
        requestedScopes: Set<String>,
        recoveryName: String
    ) throws -> Client {
        try lock.withLock {
            guard let client = clients[clientID] else {
                if let client = try configuredConfidentialClientLocked(
                    clientID: clientID,
                    clientName: recoveryName,
                    requestedScopes: requestedScopes
                ) {
                    return client
                }
                guard clientAuthentication.supportsDynamicClientRegistration else {
                    throw OAuthError.invalidRequest("Unknown client_id.")
                }
                return try recoverDynamicClient(
                    clientID: clientID,
                    clientName: recoveryName,
                    redirectURI: redirectURI,
                    requestedScopes: requestedScopes
                )
            }

            let allowsUnboundConfidentialRedirect = client.authenticationMethod == .clientSecret &&
                configuredConfidentialCredentialsLocked(clientID: client.id) != nil
            guard client.redirectURIs.contains(redirectURI) || allowsUnboundConfidentialRedirect else {
                throw OAuthError.invalidRequest("Unregistered redirect_uri.")
            }
            guard !requestedScopes.isEmpty, requestedScopes.isSubset(of: client.scopes) else {
                throw OAuthError.invalidRequest("Unsupported scope.")
            }
            return client
        }
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
            throw OAuthError.invalidRequest("Unsupported scope.")
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
        do {
            try persistGrantSnapshotLocked()
        } catch {
            clients.removeValue(forKey: client.id)
            throw error
        }
        return client
    }

    private func configuredConfidentialCredentialsLocked(clientID: String) -> OAuthConfidentialClientCredentials? {
        clientAuthentication.confidentialClients.first { $0.clientID == clientID }
    }

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
            throw OAuthError.invalidRequest("Unsupported scope.")
        }
        guard clients.count < Self.maxRegisteredClients else {
            throw OAuthError.invalidRequest("Too many registered OAuth clients. Revoke grants and try again.")
        }
        let sanitizedName = sanitizeClientName(clientName)
        let trustID = Self.clientTrustID(name: sanitizedName, redirectURIs: redirectURIs, scopes: requestedScopes)

        let client = Client(
            id: clientID,
            trustID: trustID,
            name: sanitizedName,
            redirectURIs: redirectURIs,
            scopes: requestedScopes,
            createdAt: Date()
        )
        clients[clientID] = client
        do {
            try persistGrantSnapshotLocked()
        } catch {
            clients.removeValue(forKey: clientID)
            throw error
        }
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

    private func recoveredClientName(queryItems: [String: String], redirectURI: String) -> String {
        if let name = queryItems["client_name"], !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        let components = URLComponents(string: redirectURI)
        let host = components?.host?.lowercased()
        let scheme = components?.scheme?.lowercased()
        if host?.contains("notion") == true || queryItems["notion_user_id"] != nil {
            return "Notion"
        }
        if host?.contains("claude") == true {
            return "Claude"
        }
        if host?.contains("raycast") == true || scheme?.contains("raycast") == true {
            return "Raycast"
        }
        return host ?? "Remote MCP Client"
    }

    private func parseRedirectURIs(_ value: Any?) throws -> [String] {
        guard let redirectURIs = value as? [String], !redirectURIs.isEmpty else {
            throw OAuthError.invalidRequest("redirect_uris must be a non-empty string array.")
        }

        for redirectURI in redirectURIs {
            guard let components = URLComponents(string: redirectURI),
                  let scheme = components.scheme?.lowercased(),
                  components.user == nil,
                  components.password == nil,
                  components.fragment == nil else {
                throw OAuthError.invalidRequest("Invalid redirect_uri.")
            }

            let isHTTPS = scheme == "https"
            let host = components.host?.lowercased()
            let isLoopbackHTTP = scheme == "http" && (host == "127.0.0.1" || host == "localhost")
            let isPrivateUseAppScheme = Self.isPrivateUseRedirectScheme(scheme)
            guard isHTTPS || isLoopbackHTTP || isPrivateUseAppScheme else {
                throw OAuthError.invalidRequest("redirect_uri must use HTTPS, loopback HTTP, or a private-use app scheme.")
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

    private func parseScopes(_ scope: String?) -> Set<String> {
        let values = (scope ?? "mcp:tools")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        let allowed = Set(["mcp:tools"])
        let requested = Set(values)
        return requested.isEmpty ? allowed : requested.intersection(allowed)
    }

    private func sanitizeClientName(_ value: String?) -> String {
        let trimmed = (value ?? "Remote MCP Client").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "Remote MCP Client" : trimmed
        return String(fallback.prefix(80))
    }

    private func approvalSnapshotLocked() -> [ApprovalRequest] {
        authorizations.values
            .map(\.approvalRequest)
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func connectedClientSnapshotLocked() -> [ConnectedClient] {
        clients.values.compactMap { client in
            let approvedAuthorizations = authorizations.values.filter {
                $0.clientID == client.id && $0.status == .approved
            }
            let accessRecords = accessTokensByHash.values.filter { $0.clientID == client.id }
            let refreshRecords = refreshTokensByHash.values.filter { $0.clientID == client.id }

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
                activeRefreshTokens: refreshRecords.count
            )
        }
        .sorted { lhs, rhs in
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
            if now.timeIntervalSince(authorization.createdAt) > 300 {
                var expired = authorization
                expired.status = .expired
                authorizations[id] = expired
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
    }

    private func loadPersistedGrants() {
        guard let snapshot = try? grantStore?.loadSnapshot() else { return }
        let now = Date()
        let loadedClients = snapshot.clients
            .prefix(Self.maxRegisteredClients)
            .map { Client(stored: $0) }
        clients = Dictionary(uniqueKeysWithValues: loadedClients.map { ($0.id, $0) })

        accessTokensByHash = Dictionary(
            uniqueKeysWithValues: snapshot.accessTokens.compactMap { token in
                guard clients[token.clientID] != nil, token.expiresAt > now else { return nil }
                return (token.tokenHash, AccessTokenRecord(stored: token))
            }
        )
        refreshTokensByHash = Dictionary(
            uniqueKeysWithValues: snapshot.refreshTokens.compactMap { token in
                guard clients[token.clientID] != nil, token.expiresAt > now else { return nil }
                return (token.tokenHash, RefreshTokenRecord(stored: token))
            }
        )
        try? persistGrantSnapshotLocked()
    }

    private func persistGrantSnapshotLocked() throws {
        guard let grantStore else { return }
        let snapshot = OAuthGrantSnapshot(
            clients: clients.values
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

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .invalidGrant(let message): message
        case .invalidClient(let message): message
        }
    }

    var errorCode: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidGrant: "invalid_grant"
        case .invalidClient: "invalid_client"
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
