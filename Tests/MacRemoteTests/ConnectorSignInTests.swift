import Foundation
import Testing
@testable import MacRemote

/// D42/D43. Two promises are under test here, and they pull in opposite
/// directions: a fresh install must land on Dynamic OAuth no matter what,
/// and a Mac that already chose something else must keep that choice through
/// every launch and every app-picker change.
@MainActor
struct ConnectorSignInTests {

    // MARK: - Fresh install

    @Test func freshInstallDefaultsToDynamicOAuth() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        #expect(model.connectorAuthMode == .macRemoteOAuthOnly)
        #expect(model.connectorAuthMode == ConnectorAuthMode.productDefault)
        // No normalize-on-launch: reading a default never writes one.
        #expect(context.persistedAuthRawValue == nil)
    }

    @Test func freshInstallDefaultIsIndependentOfProvider() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        // Claude used to derive OAuth Client Secret from the provider alone.
        context.defaults.set("claude", forKey: SignInContext.providerKey)

        let model = context.makeModel()
        #expect(model.connectorProvider == .claude)
        #expect(model.connectorAuthMode == .macRemoteOAuthOnly)
        #expect(context.persistedAuthRawValue == nil)
    }

    // MARK: - Every persisted raw value survives a launch

    @Test func persistedClientSecretSurvivesLaunch() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        context.defaults.set("oauthClientSecret", forKey: SignInContext.authModeKey)

        let model = context.makeModel()
        #expect(model.connectorAuthMode == .oauthClientSecret)
        #expect(context.persistedAuthRawValue == "oauthClientSecret")
    }

    @Test func persistedDynamicOAuthSurvivesLaunch() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        context.defaults.set("macRemoteOAuthOnly", forKey: SignInContext.authModeKey)

        let model = context.makeModel()
        #expect(model.connectorAuthMode == .macRemoteOAuthOnly)
        #expect(context.persistedAuthRawValue == "macRemoteOAuthOnly")
    }

    @Test func persistedSingleHeaderSurvivesLaunch() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        context.defaults.set("singleHeaderToken", forKey: SignInContext.authModeKey)

        let model = context.makeModel()
        #expect(model.connectorAuthMode == .singleHeaderToken)
        #expect(context.persistedAuthRawValue == "singleHeaderToken")
    }

    @Test func retiredAccessRawValuesStillMigrateToDynamicOAuth() throws {
        for retired in ["serviceTokenHeaders", "serviceTokenAuthorizationHeader"] {
            let context = try SignInContext()
            defer { context.cleanUp() }
            context.defaults.set(retired, forKey: SignInContext.authModeKey)

            let model = context.makeModel()
            #expect(model.connectorAuthMode == .macRemoteOAuthOnly)
            // Migration happens on read. Launching alone must not rewrite the
            // stored value — no migration pass, no key rename.
            #expect(context.persistedAuthRawValue == retired)
        }
    }

    @Test func unknownPersistedRawValueFallsBackToProductDefault() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        context.defaults.set("someModeFromAFutureBuild", forKey: SignInContext.authModeKey)
        context.defaults.set("claude", forKey: SignInContext.providerKey)

        let model = context.makeModel()
        #expect(model.connectorAuthMode == ConnectorAuthMode.productDefault)
        #expect(context.persistedAuthRawValue == "someModeFromAFutureBuild")
    }

    // MARK: - The app picker is advisory (D43)

    @Test func providerChangeNeverChangesSignInMethod() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        model.setConnectorProvider(.claude)

        #expect(model.connectorAuthMode == .macRemoteOAuthOnly)
        #expect(context.persistedAuthRawValue == "macRemoteOAuthOnly")
    }

    @Test func providerChangeNeverGeneratesCredentials() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        // Claude's old recommendation minted a Keychain secret on selection.
        model.setConnectorProvider(.claude)
        model.setConnectorProvider(.notion)
        model.setConnectorProvider(.raycast)

        #expect(model.oauthClientCredentials.isEmpty)
        #expect(model.connectorHeaderToken == nil)
        // Ground truth, not the model's copy: nothing reached the Keychain.
        #expect(context.credentialStore.loadAll().isEmpty)
        #expect(context.headerTokenStore.loadAll().isEmpty)
        // And self-registration was never switched off behind the user's back.
        #expect(model.allowsDynamicClientRegistration)
    }

    @Test func providerChangePreservesANonDefaultSavedMethod() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        context.defaults.set("singleHeaderToken", forKey: SignInContext.authModeKey)

        let model = context.makeModel()
        // Claude is blocked with Single Header — advice, not a rewrite.
        model.setConnectorProvider(.claude)

        #expect(model.connectorAuthMode == .singleHeaderToken)
        #expect(context.persistedAuthRawValue == "singleHeaderToken")
        #expect(ConnectorProviderProfile.claude.status(for: .singleHeaderToken) == .blocked)
    }

    @Test func providerChangeStillPersistsTheProvider() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        model.setConnectorProvider(.notion)
        #expect(model.connectorProvider == .notion)
        #expect(context.defaults.string(forKey: SignInContext.providerKey) == "notion")

        let relaunched = context.makeModel()
        #expect(relaunched.connectorProvider == .notion)
    }

    // MARK: - Explicit choice still does the work

    @Test func explicitSignInMethodChangePersistsAndGenerates() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        model.setConnectorAuthMode(.oauthClientSecret)

        #expect(model.connectorAuthMode == .oauthClientSecret)
        #expect(context.persistedAuthRawValue == "oauthClientSecret")
        #expect(model.oauthClientCredentials.count == 1)

        // Choosing the same method again must not mint a second credential.
        model.setConnectorAuthMode(.oauthClientSecret)
        #expect(model.oauthClientCredentials.count == 1)
        #expect(context.credentialStore.loadAll().count == 1)

        let relaunched = context.makeModel()
        #expect(relaunched.connectorAuthMode == .oauthClientSecret)
    }

    @Test func switchingAwayFromSingleHeaderRevokesTheTokenAtTheCoordinator() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        model.setConnectorAuthMode(.singleHeaderToken)
        let token = try #require(model.connectorHeaderToken?.clientSecret)
        #expect(
            model.acceptsConnectorHeaderToken(
                token,
                issuer: SignInContext.issuer,
                resource: SignInContext.resource
            )
        )

        model.setConnectorAuthMode(.macRemoteOAuthOnly)
        #expect(
            model.acceptsConnectorHeaderToken(
                token,
                issuer: SignInContext.issuer,
                resource: SignInContext.resource
            ) == false
        )
        // R4: revoked, but still visible in Settings ▸ Security so it can be
        // deleted rather than left in the Keychain unseen.
        #expect(model.connectorHeaderToken?.clientSecret == token)

        model.deleteConnectorHeaderToken()
        #expect(model.connectorHeaderToken == nil)
        #expect(context.headerTokenStore.loadAll().isEmpty)
    }

    @Test func clientSecretModeDisablesDynamicRegistrationAndDynamicOAuthEnablesIt() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }

        let model = context.makeModel()
        #expect(model.allowsDynamicClientRegistration)

        model.setConnectorAuthMode(.oauthClientSecret)
        #expect(model.allowsDynamicClientRegistration == false)

        model.setConnectorAuthMode(.macRemoteOAuthOnly)
        #expect(model.allowsDynamicClientRegistration)
    }

    // MARK: - One sign-in method at a time

    /// Every ordered pair of methods. Whatever let an app in under the old
    /// method must stop working the moment the owner picks another: its
    /// access token, its refresh token, a new sign-in, and the header token.
    @Test(arguments: [
        (ConnectorAuthMode.macRemoteOAuthOnly, ConnectorAuthMode.oauthClientSecret),
        (.macRemoteOAuthOnly, .singleHeaderToken),
        (.oauthClientSecret, .macRemoteOAuthOnly),
        (.oauthClientSecret, .singleHeaderToken),
        (.singleHeaderToken, .macRemoteOAuthOnly),
        (.singleHeaderToken, .oauthClientSecret)
    ])
    func switchingMethodStopsTheOldMethodAtOnce(from old: ConnectorAuthMode, to new: ConnectorAuthMode) throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        model.setConnectorAuthMode(old)
        let admitted = try context.signIn(to: model)
        #expect(context.accepts(admitted, in: model))

        model.setConnectorAuthMode(new)

        #expect(!context.accepts(admitted, in: model))
        #expect(!context.canRenew(admitted, in: model))
        #expect(!context.canStartSignIn(admitted, in: model))
        #expect(model.connectedClients.isEmpty)
        // The new method works, so the switch replaced the old one.
        #expect(context.accepts(try context.signIn(to: model), in: model))
    }

    /// The owner's client ID and secret are a way in only while OAuth Client
    /// Secret is the method, even though Settings keeps them in every method.
    @Test func ownerCredentialsDoNotSignInUnderDynamicOAuth() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        model.generateOAuthClientCredentials(label: "Kept for later")
        let credential = try #require(model.oauthClientCredentials.first)

        #expect(model.connectorAuthMode == .macRemoteOAuthOnly)
        #expect(throws: OAuthError.invalidRequest("Unknown client_id.")) {
            try context.beginSignIn(clientID: credential.clientID, in: model)
        }
    }

    /// Single Header admits the header token and nothing else: no app can
    /// register itself while it is the method.
    @Test func singleHeaderClosesRegistration() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()

        model.setConnectorAuthMode(.singleHeaderToken)

        #expect(!model.allowsDynamicClientRegistration)
    }

    /// Settings states what a change of method signed out, in the words the
    /// Sign Out results already use, and Activity records the same.
    @Test func changingMethodReportsWhatItSignedOut() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        _ = try context.signIn(to: model)

        let toSecret = model.setConnectorAuthMode(.oauthClientSecret)
        #expect(toSecret == "Signed out 1 app that signed itself up — removed 1 registration, 1 sign-in, 1 access token, and 1 refresh token.")
        #expect(model.logs.contains {
            $0.message == "\(toSecret ?? "") OAuth Client Secret is now the only way to sign in."
        })

        _ = try context.signIn(to: model)
        let toDynamic = model.setConnectorAuthMode(.macRemoteOAuthOnly)
        #expect(toDynamic == "Signed out 1 app that used a client ID and secret — removed 1 registration, 1 sign-in, 1 access token, and 1 refresh token.")

        _ = try context.signIn(to: model)
        _ = try context.signIn(to: model)
        let toHeader = model.setConnectorAuthMode(.singleHeaderToken)
        #expect(toHeader == "Signed out 2 apps — removed 2 registrations, 2 sign-ins, 2 access tokens, and 2 refresh tokens.")

        let fromHeader = model.setConnectorAuthMode(.macRemoteOAuthOnly)
        #expect(fromHeader == "The Single Header token no longer works.")
    }

    /// Settings asks before a change that would sign apps out, so it must know
    /// the number beforehand, and that number must match what the change does.
    @Test func settingsKnowsHowManyAppsAMethodChangeWouldSignOut() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        _ = try context.signIn(to: model)
        _ = try context.signIn(to: model)

        #expect(model.connectedAppsSignedOut(bySwitchingTo: .macRemoteOAuthOnly) == 0)
        #expect(model.connectedAppsSignedOut(bySwitchingTo: .oauthClientSecret) == 2)
        #expect(model.connectedAppsSignedOut(bySwitchingTo: .singleHeaderToken) == 2)

        _ = model.setConnectorAuthMode(.oauthClientSecret)
        #expect(model.connectedClients.isEmpty)
        #expect(model.connectedAppsSignedOut(bySwitchingTo: .macRemoteOAuthOnly) == 0)
    }

    /// A client that only registered was never an app the owner let in. The
    /// change removes it, and has nothing to report.
    @Test func changingMethodWithNothingSignedInReportsNothing() throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        _ = try model.oauthCoordinatorForTesting.registerClient(from: [
            "client_name": "Never Approved",
            "redirect_uris": [SignInContext.redirectURI],
            "scope": "mcp:tools"
        ])

        #expect(model.setConnectorAuthMode(.oauthClientSecret) == nil)
        #expect(model.oauthCoordinatorForTesting.clientIdentities().isEmpty)
        #expect(model.setConnectorAuthMode(.oauthClientSecret) == nil)
    }

    // MARK: - A refresh token that comes back after it was used

    /// The owner is the one who can act on a copied sign-in, so Activity says
    /// which app it was and the Apps list stops showing it as signed in.
    @Test func reusedRefreshTokenIsWrittenToActivity() async throws {
        let context = try SignInContext()
        defer { context.cleanUp() }
        let model = context.makeModel()
        let coordinator = model.oauthCoordinatorForTesting
        guard case .app(_, _, _, let refreshToken) = try context.signIn(to: model) else {
            Issue.record("Dynamic OAuth signs in an app.")
            return
        }
        let form = ["grant_type": "refresh_token", "refresh_token": refreshToken]
        _ = try coordinator.exchangeToken(form: form, issuer: SignInContext.issuer, resource: SignInContext.resource)
        model.refreshConnectedClients()
        #expect(model.connectedClients.first?.activeRefreshTokens == 1)

        #expect(throws: OAuthError.invalidGrant("Invalid refresh token.")) {
            try coordinator.exchangeToken(
                form: form,
                issuer: SignInContext.issuer,
                resource: SignInContext.resource,
                now: Date().addingTimeInterval(OAuthCoordinator.refreshRetryGrace + 1)
            )
        }

        // The coordinator reports from the request's thread; the model
        // records it on the main actor a moment later.
        for _ in 0..<200 where !model.logs.contains(where: { $0.message.contains("already used") }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let lines = model.logs.filter { $0.message.contains("already used") }
        #expect(lines.count == 1)
        #expect(lines.first?.message.hasPrefix("Test App sent a refresh token that was already used") == true)
        #expect(lines.first?.level == .warning)
        #expect(model.connectedClients.first?.activeRefreshTokens == 0)
    }

    // MARK: - The editor covers everything that can be stored

    @Test func everyLiveRawValueIsCoveredByTheEditor() {
        #expect(ConnectorAuthMode.allCases.count == 3)
        for mode in ConnectorAuthMode.allCases {
            #expect(mode.title.isEmpty == false)
            #expect(mode.pickerTitle.isEmpty == false)
            #expect(mode.tradeoffDetail.isEmpty == false)
            #expect(ConnectorAuthMode.from(persistedRawValue: mode.rawValue) == mode)
        }
        #expect(ConnectorAuthMode.productDefault.pickerTitle == "Dynamic OAuth (Default)")
        #expect(ConnectorAuthMode.oauthClientSecret.isProductDefault == false)
        #expect(ConnectorAuthMode.singleHeaderToken.isProductDefault == false)
    }

    // MARK: - One picker, one place

    @Test func settingsIsTheOnlyPlaceThatChangesTheSignInMethod() throws {
        // D11/D42: exactly one control changes the sign-in method, and it lives
        // under the Advanced disclosure in Settings › General. AGENTS.md states
        // this as `grep -rn 'setConnectorAuthMode' Views` returning only
        // SettingsView.swift; a second call site anywhere else — an onboarding
        // shortcut, an app-picker side effect — is the D43 regression.
        var callSites: [String] = []
        for file in try swiftSources(in: "Views") {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("setConnectorAuthMode(") {
                callSites.append(file.lastPathComponent)
            }
        }
        #expect(callSites == ["SettingsView.swift"])
    }
}

// MARK: - Fixture

/// Each test owns its defaults, tool registry, and in-memory credentials.
@MainActor
private struct SignInContext {
    static let authModeKey = "MacRemote.connector.accessMode"
    static let providerKey = "MacRemote.connector.provider"
    static let issuer = "https://macremote.example"
    static let resource = "https://macremote.example/mcp"
    /// Loopback, so a signed-out app cannot come back by asking again with
    /// the client ID it kept: only web return addresses are given a new record.
    static let redirectURI = "http://127.0.0.1/callback"

    let suiteName: String
    let defaults: UserDefaults
    let credentialStore: OAuthClientCredentialStore
    let headerTokenStore: OAuthClientCredentialStore
    private let directory: URL

    init() throws {
        suiteName = "MacRemoteSignInTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "MacRemoteSignInTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        credentialStore = OAuthClientCredentialStore(
            userDefaults: defaults,
            keychain: InMemoryKeychainSecretStore()
        )
        headerTokenStore = OAuthClientCredentialStore(
            userDefaults: defaults,
            service: "com.macstories.MacRemote.tests.connectorHeaderToken",
            keychain: InMemoryKeychainSecretStore()
        )
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var persistedAuthRawValue: String? {
        defaults.string(forKey: Self.authModeKey)
    }

    func makeModel() -> AppModel {
        makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: directory.appendingPathComponent("tools.json")),
            oauthClientCredentialStore: credentialStore,
            connectorHeaderTokenStore: headerTokenStore
        )
    }

    /// What one sign-in left in the app's hands, under whichever method was
    /// current: OAuth tokens, or the fixed header token.
    enum Admitted {
        case app(clientID: String, clientSecret: String?, accessToken: String, refreshToken: String)
        case headerToken(String)
    }

    /// Signs one more app in the way the model's current method allows.
    func signIn(to model: AppModel) throws -> Admitted {
        let coordinator = model.oauthCoordinatorForTesting
        let clientID: String
        let clientSecret: String?
        switch model.connectorAuthMode {
        case .singleHeaderToken:
            return .headerToken(try #require(model.connectorHeaderToken?.clientSecret))
        case .oauthClientSecret:
            let credential = try #require(model.oauthClientCredentials.first)
            (clientID, clientSecret) = (credential.clientID, credential.clientSecret)
        case .macRemoteOAuthOnly:
            let registration = try coordinator.registerClient(from: [
                "client_name": "Test App",
                "redirect_uris": [Self.redirectURI],
                "scope": "mcp:tools"
            ])
            (clientID, clientSecret) = (try #require(registration["client_id"] as? String), nil)
        }

        let verifier = String(repeating: "v", count: 64)
        let requestID = try beginSignIn(clientID: clientID, verifier: verifier, in: model)
        #expect(coordinator.approve(requestID: requestID))
        let redirect = try #require(coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String)
        let code = try #require(URLComponents(string: redirect)?.queryItems?.first { $0.name == "code" }?.value)
        var form = [
            "grant_type": "authorization_code",
            "client_id": clientID,
            "redirect_uri": Self.redirectURI,
            "code": code,
            "code_verifier": verifier,
            "resource": Self.resource
        ]
        form["client_secret"] = clientSecret
        let token = try coordinator.exchangeToken(form: form, issuer: Self.issuer, resource: Self.resource)
        model.refreshConnectedClients()
        return .app(
            clientID: clientID,
            clientSecret: clientSecret,
            accessToken: try #require(token["access_token"] as? String),
            refreshToken: try #require(token["refresh_token"] as? String)
        )
    }

    @discardableResult
    func beginSignIn(
        clientID: String,
        verifier: String = String(repeating: "v", count: 64),
        in model: AppModel
    ) throws -> UUID {
        try model.oauthCoordinatorForTesting.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": Self.redirectURI,
                "scope": "mcp:tools",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": Self.resource
            ],
            issuer: Self.issuer,
            resource: Self.resource
        )
    }

    /// Whether a request carrying this credential would be let in right now.
    func accepts(_ admitted: Admitted, in model: AppModel) -> Bool {
        switch admitted {
        case .app(_, _, let accessToken, _):
            model.oauthCoordinatorForTesting.validateAccessToken(
                accessToken,
                issuer: Self.issuer,
                resource: Self.resource
            )
        case .headerToken(let token):
            model.acceptsConnectorHeaderToken(token, issuer: Self.issuer, resource: Self.resource)
        }
    }

    /// Whether the app could still trade its refresh token for new tokens.
    func canRenew(_ admitted: Admitted, in model: AppModel) -> Bool {
        guard case .app(let clientID, let clientSecret, _, let refreshToken) = admitted else { return false }
        var form = ["grant_type": "refresh_token", "client_id": clientID, "refresh_token": refreshToken]
        form["client_secret"] = clientSecret
        let renewed = try? model.oauthCoordinatorForTesting.exchangeToken(
            form: form,
            issuer: Self.issuer,
            resource: Self.resource
        )
        return renewed != nil
    }

    /// Whether the app could ask the owner to let it in again as it is.
    func canStartSignIn(_ admitted: Admitted, in model: AppModel) -> Bool {
        guard case .app(let clientID, _, _, _) = admitted else { return false }
        return (try? beginSignIn(clientID: clientID, in: model)) != nil
    }

    func cleanUp() {
        credentialStore.clear()
        headerTokenStore.clear()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}
