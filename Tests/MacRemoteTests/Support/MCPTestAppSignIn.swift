import Foundation
import Testing
@testable import MacRemote

/// Signs a second, made-up app in with Dynamic OAuth and returns its client,
/// for tests that check one app cannot reach another app's state.
func dynamicOAuthTestClient(
    coordinator: OAuthCoordinator,
    baseURL: URL,
    endpoint: URL,
    mode: MCPTestProtocolMode
) throws -> MCPTestClient {
    let issuer = baseURL.absoluteString
    let resource = endpoint.absoluteString
    let redirectURI = "http://127.0.0.1/callback"
    let registration = try coordinator.registerClient(from: [
        "client_name": "Other App",
        "redirect_uris": [redirectURI],
        "scope": "mcp:tools"
    ])
    let clientID = try #require(registration["client_id"] as? String)
    let verifier = "verifier-\(UUID().uuidString)-\(UUID().uuidString)"
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
    let code = try #require(URLComponents(string: redirect)?.queryItems?.first { $0.name == "code" }?.value)
    let token = try coordinator.exchangeToken(
        form: [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": resource
        ],
        issuer: issuer,
        resource: resource
    )
    return MCPTestClient(
        baseURL: endpoint,
        bearerToken: try #require(token["access_token"] as? String),
        mode: mode
    )
}
