import CryptoKit
import Foundation
import Security

final class OAuthCoordinator: @unchecked Sendable {
    typealias ChangeHandler = @Sendable ([ApprovalRequest]) -> Void

    private struct Client {
        let id: String
        let name: String
        let redirectURIs: [String]
        let scopes: Set<String>
        let createdAt: Date
    }

    private struct PendingAuthorization {
        let id: UUID
        let clientID: String
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
                clientName: clientName,
                redirectURI: redirectURI,
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
        let expiresAt: Date
    }

    private struct RefreshTokenRecord {
        let clientID: String
        let issuer: String
        let resource: String
        let scopes: Set<String>
        let expiresAt: Date
    }

    private let lock = NSLock()
    private let changeHandler: ChangeHandler?
    private var clients: [String: Client] = [:]
    private var authorizations: [UUID: PendingAuthorization] = [:]
    private var accessTokensByHash: [String: AccessTokenRecord] = [:]
    private var refreshTokensByHash: [String: RefreshTokenRecord] = [:]

    init(changeHandler: ChangeHandler? = nil) {
        self.changeHandler = changeHandler
    }

    func registerClient(from jsonObject: Any) throws -> [String: Any] {
        guard let object = jsonObject as? [String: Any] else {
            throw OAuthError.invalidRequest("Expected JSON object.")
        }

        let clientName = sanitizeClientName(object["client_name"] as? String)
        let redirectURIs = try parseRedirectURIs(object["redirect_uris"])
        let scopes = parseScopes(object["scope"] as? String)
        let clientID = "macremote-client-\(Self.randomToken(byteCount: 16))"
        let client = Client(
            id: clientID,
            name: clientName,
            redirectURIs: redirectURIs,
            scopes: scopes,
            createdAt: Date()
        )

        lock.withLock {
            clients[clientID] = client
        }

        return [
            "client_id": clientID,
            "client_name": clientName,
            "redirect_uris": redirectURIs,
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "scope": scopes.sorted().joined(separator: " ")
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
        let client = try clientForAuthorization(clientID: clientID, redirectURI: redirectURI, requestedScopes: requestedScopes)
        let resolvedResource = try resolveRequestedResource(queryItems["resource"], expectedResource: resource)
        let id = UUID()
        let authorization = PendingAuthorization(
            id: id,
            clientID: clientID,
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

        let snapshot: [ApprovalRequest] = lock.withLock {
            expirePendingAuthorizations(now: Date())
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
        let tokenHash = Self.sha256Hex(token)
        let now = Date()
        return lock.withLock {
            pruneExpiredTokens(now: now)
            guard let record = accessTokensByHash[tokenHash] else { return false }
            return record.expiresAt > now &&
                record.issuer == issuer &&
                record.resource == resource &&
                record.scopes.contains(requiredScope)
        }
    }

    func approvalSnapshot() -> [ApprovalRequest] {
        lock.withLock {
            expirePendingAuthorizations(now: Date())
            return approvalSnapshotLocked()
        }
    }

    private func exchangeAuthorizationCode(form: [String: String], issuer: String, resource: String) throws -> [String: Any] {
        guard let code = form["code"], !code.isEmpty else {
            throw OAuthError.invalidRequest("Missing code.")
        }
        guard let clientID = form["client_id"], !clientID.isEmpty else {
            throw OAuthError.invalidRequest("Missing client_id.")
        }
        guard let redirectURI = form["redirect_uri"], !redirectURI.isEmpty else {
            throw OAuthError.invalidRequest("Missing redirect_uri.")
        }
        guard let codeVerifier = form["code_verifier"], !codeVerifier.isEmpty else {
            throw OAuthError.invalidRequest("Missing code_verifier.")
        }

        let now = Date()
        let authorizationID: UUID = try lock.withLock {
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
            guard authorization.clientID == clientID, authorization.redirectURI == redirectURI else {
                throw OAuthError.invalidGrant("Client or redirect URI mismatch.")
            }
            guard authorization.issuer == issuer else {
                throw OAuthError.invalidGrant("Issuer mismatch.")
            }
            let requestedResource = try resolveRequestedResource(form["resource"], expectedResource: resource)
            guard authorization.resource == requestedResource else {
                throw OAuthError.invalidGrant("Resource mismatch.")
            }
            guard let codeExpiresAt = authorization.codeExpiresAt, codeExpiresAt > now else {
                throw OAuthError.invalidGrant("Authorization code expired.")
            }
            guard Self.pkceChallenge(for: codeVerifier) == authorization.codeChallenge else {
                throw OAuthError.invalidGrant("PKCE verification failed.")
            }

            authorization.codeUsedAt = now
            authorization.issuedCode = nil
            authorizations[match.key] = authorization
            return match.key
        }

        let scopes = lock.withLock {
            authorizations[authorizationID]?.scopes ?? ["mcp:tools"]
        }
        return issueTokenResponse(clientID: clientID, issuer: issuer, resource: resource, scopes: scopes, now: now)
    }

    private func exchangeRefreshToken(form: [String: String], issuer: String, resource: String) throws -> [String: Any] {
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
                throw OAuthError.invalidGrant("Issuer mismatch.")
            }
            let requestedResource = try resolveRequestedResource(form["resource"], expectedResource: resource)
            guard record.resource == requestedResource else {
                throw OAuthError.invalidGrant("Resource mismatch.")
            }
            refreshTokensByHash.removeValue(forKey: refreshHash)
            return record
        }

        return issueTokenResponse(clientID: record.clientID, issuer: issuer, resource: resource, scopes: record.scopes, now: now)
    }

    private func issueTokenResponse(clientID: String, issuer: String, resource: String, scopes: Set<String>, now: Date) -> [String: Any] {
        let accessToken = Self.randomToken(byteCount: 32)
        let refreshToken = Self.randomToken(byteCount: 32)
        let accessHash = Self.sha256Hex(accessToken)
        let refreshHash = Self.sha256Hex(refreshToken)
        let accessExpiresIn = 900
        let refreshExpiresIn = 86_400

        lock.withLock {
            accessTokensByHash[accessHash] = AccessTokenRecord(
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes,
                expiresAt: now.addingTimeInterval(TimeInterval(accessExpiresIn))
            )
            refreshTokensByHash[refreshHash] = RefreshTokenRecord(
                clientID: clientID,
                issuer: issuer,
                resource: resource,
                scopes: scopes,
                expiresAt: now.addingTimeInterval(TimeInterval(refreshExpiresIn))
            )
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
        guard let rawResource, !rawResource.isEmpty else {
            return expected
        }

        let requested = try Self.canonicalResourceURI(rawResource)
        guard requested == expected else {
            throw OAuthError.invalidRequest("Unsupported resource.")
        }
        return requested
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
        canonical.path = components.path
        guard let string = canonical.string else {
            throw OAuthError.invalidRequest("Invalid resource.")
        }
        return string
    }

    private func clientForAuthorization(clientID: String, redirectURI: String, requestedScopes: Set<String>) throws -> Client {
        try lock.withLock {
            guard let client = clients[clientID] else {
                throw OAuthError.invalidRequest("Unknown client_id.")
            }
            guard client.redirectURIs.contains(redirectURI) else {
                throw OAuthError.invalidRequest("Unregistered redirect_uri.")
            }
            guard !requestedScopes.isEmpty, requestedScopes.isSubset(of: client.scopes) else {
                throw OAuthError.invalidRequest("Unsupported scope.")
            }
            return client
        }
    }

    private func parseRedirectURIs(_ value: Any?) throws -> [String] {
        guard let redirectURIs = value as? [String], !redirectURIs.isEmpty else {
            throw OAuthError.invalidRequest("redirect_uris must be a non-empty string array.")
        }

        for redirectURI in redirectURIs {
            guard let components = URLComponents(string: redirectURI),
                  let scheme = components.scheme?.lowercased(),
                  let host = components.host?.lowercased(),
                  !host.isEmpty else {
                throw OAuthError.invalidRequest("Invalid redirect_uri.")
            }

            let isHTTPS = scheme == "https"
            let isLoopbackHTTP = scheme == "http" && (host == "127.0.0.1" || host == "localhost")
            guard isHTTPS || isLoopbackHTTP else {
                throw OAuthError.invalidRequest("redirect_uri must use HTTPS or loopback HTTP.")
            }
        }

        return Array(Set(redirectURIs)).sorted()
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

    private func pruneExpiredTokens(now: Date) {
        accessTokensByHash = accessTokensByHash.filter { $0.value.expiresAt > now }
        refreshTokensByHash = refreshTokensByHash.filter { $0.value.expiresAt > now }
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

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .invalidGrant(let message): message
        }
    }

    var errorCode: String {
        switch self {
        case .invalidRequest: "invalid_request"
        case .invalidGrant: "invalid_grant"
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
