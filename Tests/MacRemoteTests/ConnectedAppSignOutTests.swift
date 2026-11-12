import Foundation
import Testing
@testable import MacRemote

/// D45. Signing an app out promises six things are removed. These tests hold
/// the promise to ground truth, and hold the blast radius to one app.
struct ConnectedAppSignOutTests {

    // MARK: - Exact counts

    @Test func signOutReportsTheRealCountForEveryCategory() async throws {
        let fixture = try await SignOutFixture(pendingCallsPerApp: 1)
        let store = try fixture.makePermissionStore()
        let tool = signOutTool(id: "test.first")
        let otherTool = signOutTool(id: "test.second")
        store.setAllowed(true, clientTrustID: fixture.first.trustID, tool: tool)
        store.setAllowed(true, clientTrustID: fixture.first.trustID, tool: otherTool)

        let result = try #require(
            ConnectedAppSignOutResult.revoke(
                client: fixture.first,
                authCoordinator: fixture.authCoordinator,
                toolCallApprovalCoordinator: fixture.approvalCoordinator,
                permissionStore: store
            )
        )

        #expect(result.appName == fixture.first.name)
        #expect(result.registrations == 1)
        #expect(result.authorizations == 1)
        #expect(result.accessTokens == 1)
        #expect(result.refreshTokens == 1)
        #expect(result.pendingRequests == 1)
        #expect(result.alwaysAllowRules == 2)

        // Ground truth, not bookkeeping: the tokens really stopped working.
        #expect(fixture.validates(fixture.firstTokens.accessToken) == false)
        #expect(fixture.authCoordinator.connectedClientSnapshot().map(\.id) == [fixture.second.id])
        #expect(store.allowedToolIDs(for: fixture.first.trustID, matching: [tool, otherTool]).isEmpty)

        await fixture.cancelRemainingWork()
    }

    @Test func signOutDeniesOnlyThatAppsWaitingRequests() async throws {
        let fixture = try await SignOutFixture(pendingCallsPerApp: 1)
        let store = try fixture.makePermissionStore()

        let result = try #require(
            ConnectedAppSignOutResult.revoke(
                client: fixture.first,
                authCoordinator: fixture.authCoordinator,
                toolCallApprovalCoordinator: fixture.approvalCoordinator,
                permissionStore: store
            )
        )
        #expect(result.pendingRequests == 1)

        // The signed-out app's caller is released with a denial...
        #expect(try await fixture.firstCallTasks[0].value == false)
        // ...and the other app is still waiting for a decision.
        let stillPending = fixture.approvalCoordinator.approvalSnapshot()
            .filter { $0.state == .pending }
        #expect(stillPending.count == 1)
        #expect(stillPending.first?.clientTrustID == fixture.second.trustID)

        await fixture.cancelRemainingWork()
    }

    @Test func signOutNeverMatchesOnDisplayName() async throws {
        // Two independent registrations both calling themselves "Claude". One
        // must not be able to sign the other out.
        let fixture = try await SignOutFixture(
            pendingCallsPerApp: 1,
            firstName: "Claude",
            secondName: "Claude"
        )
        let store = try fixture.makePermissionStore()
        let tool = signOutTool(id: "test.first")
        store.setAllowed(true, clientTrustID: fixture.second.trustID, tool: tool)

        #expect(fixture.first.name == fixture.second.name)
        #expect(fixture.first.trustID != fixture.second.trustID)

        let result = try #require(
            ConnectedAppSignOutResult.revoke(
                client: fixture.first,
                authCoordinator: fixture.authCoordinator,
                toolCallApprovalCoordinator: fixture.approvalCoordinator,
                permissionStore: store
            )
        )
        #expect(result.alwaysAllowRules == 0)

        // The namesake app kept its tokens, its rule, and its waiting request.
        #expect(fixture.validates(fixture.secondTokens.accessToken))
        #expect(store.allowedToolIDs(for: fixture.second.trustID, matching: [tool]) == [tool.id])
        #expect(
            fixture.approvalCoordinator.approvalSnapshot()
                .count { $0.state == .pending } == 1
        )

        await fixture.cancelRemainingWork()
    }

    @Test func signOutClearsOnlyThatTrustIDsAlwaysAllowRules() async throws {
        let fixture = try await SignOutFixture(pendingCallsPerApp: 0)
        let store = try fixture.makePermissionStore()
        let tool = signOutTool(id: "test.first")
        store.setAllowed(true, clientTrustID: fixture.first.trustID, tool: tool)
        store.setAllowed(true, clientTrustID: fixture.second.trustID, tool: tool)

        let result = try #require(
            ConnectedAppSignOutResult.revoke(
                client: fixture.first,
                authCoordinator: fixture.authCoordinator,
                toolCallApprovalCoordinator: fixture.approvalCoordinator,
                permissionStore: store
            )
        )

        #expect(result.alwaysAllowRules == 1)
        #expect(store.isAllowed(clientTrustID: fixture.first.trustID, tool: tool) == false)
        #expect(store.isAllowed(clientTrustID: fixture.second.trustID, tool: tool))
    }

    @Test func signOutOfAnUnknownClientChangesNothing() async throws {
        let fixture = try await SignOutFixture(pendingCallsPerApp: 1)
        let store = try fixture.makePermissionStore()
        let tool = signOutTool(id: "test.first")
        store.setAllowed(true, clientTrustID: fixture.first.trustID, tool: tool)

        let ghost = ConnectedClient(
            id: "client-that-never-existed",
            trustID: fixture.first.trustID,
            name: fixture.first.name,
            redirectURIs: [],
            issuer: nil,
            resource: nil,
            scopes: [],
            createdAt: .distantPast,
            lastAuthorizedAt: .distantPast,
            activeAccessTokens: 0,
            activeRefreshTokens: 0
        )

        let result = ConnectedAppSignOutResult.revoke(
            client: ghost,
            authCoordinator: fixture.authCoordinator,
            toolCallApprovalCoordinator: fixture.approvalCoordinator,
            permissionStore: store
        )

        #expect(result == nil)
        // Nothing was denied, cleared, or invalidated on the way to that nil —
        // note the ghost even carried a real trust ID.
        #expect(fixture.validates(fixture.firstTokens.accessToken))
        #expect(store.isAllowed(clientTrustID: fixture.first.trustID, tool: tool))
        #expect(fixture.authCoordinator.connectedClientSnapshot().count == 2)
        #expect(
            fixture.approvalCoordinator.approvalSnapshot()
                .count { $0.state == .pending } == 2
        )

        await fixture.cancelRemainingWork()
    }

    @Test func signOutLeavesASavedClientCredentialUsable() throws {
        // A confidential app's secret lives in the Keychain, not in the OAuth
        // grant state. Signing it out must not destroy the saved credential —
        // it has to be able to sign in again with the same one.
        let coordinator = OAuthCoordinator()
        let issuer = "https://macremote.example"
        let resource = "\(issuer)/mcp"
        let redirectURI = "https://raycast.com/redirect/extension"
        let clientID = "macremote-oauth-Zt7k2p9WqfLmN3xR8sVb"
        let clientSecret = "generated-secret-abcdefghijklmnopqrstuvwxyz0123456789"
        coordinator.updateClientAuthentication(
            .confidentialClientsRequired([
                OAuthConfidentialClientCredentials(clientID: clientID, clientSecret: clientSecret)
            ])
        )

        let tokens = try authorizeAndExchange(
            coordinator: coordinator,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.validateAccessToken(tokens.accessToken, issuer: issuer, resource: resource))
        let client = try #require(
            coordinator.connectedClientSnapshot().first { $0.id == clientID }
        )
        #expect(client.authenticationMethod.isConfidential)

        let store = try makeIsolatedPermissionStore()
        let result = try #require(
            ConnectedAppSignOutResult.revoke(
                client: client,
                authCoordinator: coordinator,
                toolCallApprovalCoordinator: nil,
                permissionStore: store
            )
        )
        #expect(result.accessTokens == 1)
        #expect(coordinator.validateAccessToken(tokens.accessToken, issuer: issuer, resource: resource) == false)

        // Same credential, brand new session.
        let reconnected = try authorizeAndExchange(
            coordinator: coordinator,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.validateAccessToken(reconnected.accessToken, issuer: issuer, resource: resource))
    }

    // MARK: - Sign Out All Apps

    @Test func signOutAllRemovesEverythingAndReportsTheAggregate() async throws {
        let fixture = try await SignOutFixture(pendingCallsPerApp: 1)
        let store = try fixture.makePermissionStore()
        let tool = signOutTool(id: "test.first")
        store.setAllowed(true, clientTrustID: fixture.first.trustID, tool: tool)
        store.setAllowed(true, clientTrustID: fixture.second.trustID, tool: tool)

        // The same three primitives AppModel.signOutAllApps() composes.
        let summary = fixture.authCoordinator.revokeAllGrants()
        let deniedRequests = fixture.approvalCoordinator.denyAllPending()
        let cleared = store.clear()

        #expect(summary.clients == 2)
        #expect(summary.authorizations == 2)
        #expect(summary.accessTokens == 2)
        #expect(summary.refreshTokens == 2)
        #expect(deniedRequests == 2)
        #expect(cleared.removedRules == 2)

        #expect(fixture.authCoordinator.connectedClientSnapshot().isEmpty)
        #expect(fixture.validates(fixture.firstTokens.accessToken) == false)
        #expect(fixture.validates(fixture.secondTokens.accessToken) == false)
        #expect(cleared.snapshot.isEmpty)
        #expect(try await fixture.firstCallTasks[0].value == false)
        #expect(try await fixture.secondCallTasks[0].value == false)
    }

    // MARK: - Through AppModel, the way Settings and Apps actually call it

    @MainActor
    @Test func signingOneAppOutThroughAppModelUpdatesEveryPublishedList() async throws {
        let context = try AppModelSignOutContext()
        defer { context.cleanUp() }
        let first = try context.signIn(name: "First App", redirectURI: "https://first.example/callback")
        let second = try context.signIn(name: "Second App", redirectURI: "https://second.example/callback")
        let firstClient = try context.publishedClient(id: first.clientID)
        let secondClient = try context.publishedClient(id: second.clientID)

        context.model.tools = [signOutTool(id: "test.first"), signOutTool(id: "test.second")]
        context.model.setToolAlwaysAllowed(true, toolID: "test.first", clientID: first.clientID)
        context.model.setToolAlwaysAllowed(true, toolID: "test.second", clientID: second.clientID)

        let firstCall = context.startPendingCall(id: "test.first", client: firstClient)
        let secondCall = context.startPendingCall(id: "test.second", client: secondClient)
        try await context.waitForPendingCount(2)

        let result = try context.model.signOutApp(id: first.clientID).get()

        #expect(result.appName == firstClient.name)
        #expect(result.registrations == 1)
        #expect(result.authorizations == 1)
        #expect(result.accessTokens == 1)
        #expect(result.refreshTokens == 1)
        #expect(result.pendingRequests == 1)
        #expect(result.alwaysAllowRules == 1)

        // Every list the views bind to caught up in the same call.
        #expect(context.model.connectedClients.map(\.id) == [second.clientID])
        let stillPending = context.model.toolCallApprovals.filter { $0.state == .pending }
        #expect(stillPending.map(\.clientID) == [second.clientID])
        #expect(context.model.alwaysAllowedToolIDs(for: first.clientID).isEmpty)
        #expect(context.model.alwaysAllowedToolIDs(for: second.clientID) == ["test.second"])

        // Ground truth: the signed-out app's caller was released with a denial
        // and its token really stopped working, while the other app is intact.
        #expect(try await firstCall.value == false)
        #expect(context.validates(first.accessToken) == false)
        #expect(context.validates(second.accessToken))

        await context.cancel(secondCall)
    }

    @MainActor
    @Test func signingOutEveryAppThroughAppModelClearsEverythingItPublishes() async throws {
        let context = try AppModelSignOutContext()
        defer { context.cleanUp() }
        let first = try context.signIn(name: "First App", redirectURI: "https://first.example/callback")
        let second = try context.signIn(name: "Second App", redirectURI: "https://second.example/callback")
        let firstClient = try context.publishedClient(id: first.clientID)
        let secondClient = try context.publishedClient(id: second.clientID)

        context.model.tools = [signOutTool(id: "test.first"), signOutTool(id: "test.second")]
        context.model.setToolAlwaysAllowed(true, toolID: "test.first", clientID: first.clientID)
        context.model.setToolAlwaysAllowed(true, toolID: "test.second", clientID: second.clientID)

        let firstCall = context.startPendingCall(id: "test.first", client: firstClient)
        let secondCall = context.startPendingCall(id: "test.second", client: secondClient)
        try await context.waitForPendingCount(2)

        let result = context.model.signOutAllApps()

        #expect(result.appName == "every app")
        #expect(result.registrations == 2)
        #expect(result.authorizations == 2)
        #expect(result.accessTokens == 2)
        #expect(result.refreshTokens == 2)
        #expect(result.pendingRequests == 2)
        #expect(result.alwaysAllowRules == 2)

        #expect(context.model.connectedClients.isEmpty)
        #expect(context.model.approvals.isEmpty)
        #expect(context.model.toolCallApprovals.contains { $0.state == .pending } == false)
        #expect(context.model.clientToolPermissionSnapshot.isEmpty)
        #expect(try await firstCall.value == false)
        #expect(try await secondCall.value == false)
        #expect(context.validates(first.accessToken) == false)
        #expect(context.validates(second.accessToken) == false)
    }

    @MainActor
    @Test func signingOutAnUnknownAppReturnsAppNotFoundAndChangesNothing() async throws {
        let context = try AppModelSignOutContext()
        defer { context.cleanUp() }
        let first = try context.signIn(name: "First App", redirectURI: "https://first.example/callback")
        let firstClient = try context.publishedClient(id: first.clientID)
        context.model.tools = [signOutTool(id: "test.first")]
        context.model.setToolAlwaysAllowed(true, toolID: "test.first", clientID: first.clientID)
        let call = context.startPendingCall(id: "test.first", client: firstClient)
        try await context.waitForPendingCount(1)

        let outcome = context.model.signOutApp(id: "client-that-never-existed")

        guard case .failure(let error) = outcome else {
            Issue.record("Expected appNotFound, got \(outcome).")
            await context.cancel(call)
            return
        }
        #expect(error == .appNotFound)
        // Nothing was denied, cleared, or invalidated on the way to that failure.
        #expect(context.model.connectedClients.map(\.id) == [first.clientID])
        #expect(context.model.toolCallApprovals.count { $0.state == .pending } == 1)
        #expect(context.model.alwaysAllowedToolIDs(for: first.clientID) == ["test.first"])
        #expect(context.validates(first.accessToken))

        await context.cancel(call)
    }

    @MainActor
    @Test func rotatingACredentialDeniesOnlyThatAppsWaitingCalls() async throws {
        let context = try AppModelSignOutContext()
        defer { context.cleanUp() }

        // The Settings › Security button, end to end: two apps sign in with
        // saved credentials, then one credential is rotated under its app.
        // Saved credentials are a way in only under OAuth Client Secret.
        context.model.setConnectorAuthMode(.oauthClientSecret)
        context.model.generateOAuthClientCredentials(label: "Second App")
        #expect(context.model.oauthClientCredentials.count == 2)
        let credential = try #require(context.model.oauthClientCredentials.first)
        let other = try #require(context.model.oauthClientCredentials.last)
        let rotated = try context.signInConfidential(
            clientID: credential.clientID,
            clientSecret: credential.clientSecret,
            redirectURI: "https://first.example/callback"
        )
        let second = try context.signInConfidential(
            clientID: other.clientID,
            clientSecret: other.clientSecret,
            redirectURI: "https://second.example/callback"
        )
        let rotatedClient = try context.publishedClient(id: credential.clientID)
        let secondClient = try context.publishedClient(id: other.clientID)

        context.model.tools = [signOutTool(id: "test.first"), signOutTool(id: "test.second")]
        let firstCall = context.startPendingCall(id: "test.first", client: rotatedClient)
        let secondCall = context.startPendingCall(id: "test.second", client: secondClient)
        try await context.waitForPendingCount(2)

        context.model.rotateOAuthClientCredentials(clientID: credential.clientID)

        // A new secret really was minted, and the old identity is gone.
        #expect(context.model.oauthClientCredentials.count == 2)
        #expect(!context.model.oauthClientCredentials.contains { $0.clientID == credential.clientID })

        #expect(try await firstCall.value == false)
        let waiting = context.model.toolCallApprovals.filter { $0.state == .pending }
        #expect(waiting.map(\.clientID) == [other.clientID])
        #expect(context.model.connectedClients.map(\.id) == [other.clientID])
        #expect(context.validates(rotated.accessToken) == false)
        #expect(context.validates(second.accessToken))

        await context.cancel(secondCall)
    }

    @MainActor
    @Test func deletingACredentialDeniesOnlyThatAppsWaitingCalls() async throws {
        // Same revocation path as rotation, reached without a Keychain write, so
        // there is real coverage even on a runner denied Keychain access.
        let context = try AppModelSignOutContext()
        defer { context.cleanUp() }
        let first = try context.signIn(name: "First App", redirectURI: "https://first.example/callback")
        let second = try context.signIn(name: "Second App", redirectURI: "https://second.example/callback")
        let firstClient = try context.publishedClient(id: first.clientID)
        let secondClient = try context.publishedClient(id: second.clientID)

        context.model.tools = [signOutTool(id: "test.first"), signOutTool(id: "test.second")]
        let firstCall = context.startPendingCall(id: "test.first", client: firstClient)
        let secondCall = context.startPendingCall(id: "test.second", client: secondClient)
        try await context.waitForPendingCount(2)

        context.model.deleteOAuthClientCredentials(clientID: first.clientID)

        #expect(try await firstCall.value == false)
        let stillPending = context.model.toolCallApprovals.filter { $0.state == .pending }
        #expect(stillPending.map(\.clientID) == [second.clientID])
        #expect(context.model.connectedClients.map(\.id) == [second.clientID])
        #expect(context.validates(first.accessToken) == false)
        #expect(context.validates(second.accessToken))

        await context.cancel(secondCall)
    }

    // MARK: - Shared trust ID, distinct apps (L1)

    @MainActor
    @Test func registrationsSharingMetadataDoNotCrossDeny() async throws {
        // Two registrations with identical name, redirects, and scopes.
        // MacRemote deliberately does not deduplicate those — each gets its
        // own client ID. Signing one out must not cancel the other's waiting
        // calls.
        let coordinator = OAuthCoordinator()
        let redirectURI = "https://claude.ai/api/mcp/auth_callback"
        let metadata: [String: Any] = [
            "client_name": "Claude",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ]

        func register() throws -> String {
            let response = try coordinator.registerClient(from: metadata)
            let clientID = try #require(response["client_id"] as? String)
            _ = try authorizeAndExchange(
                coordinator: coordinator,
                clientID: clientID,
                clientSecret: nil,
                redirectURI: redirectURI,
                issuer: "https://macremote.example",
                resource: "https://macremote.example/mcp"
            )
            return clientID
        }

        let firstID = try register()
        let secondID = try register()

        let snapshot = coordinator.connectedClientSnapshot()
        let first = try #require(snapshot.first { $0.id == firstID })
        let second = try #require(snapshot.first { $0.id == secondID })
        // Distinct DCR registrations have distinct trust identities. Sign-out
        // still selects by client ID first, so neither metadata nor a glyph can
        // cross-deny another app's pending call.
        #expect(first.id != second.id)
        #expect(first.trustID != second.trustID)

        let approvals = ToolCallApprovalCoordinator(timeoutSeconds: 120)
        let firstCall = pendingCall(id: "test.first", client: first, in: approvals)
        let secondCall = pendingCall(id: "test.second", client: second, in: approvals)
        try await waitForPendingApprovals(2, in: approvals)

        let denied = approvals.denyPending(clientTrustID: first.trustID, clientID: first.id)

        #expect(denied == 1)
        #expect(try await firstCall.value == false)
        let stillPending = approvals.approvalSnapshot().filter { $0.state == .pending }
        #expect(stillPending.map(\.clientID) == [second.id])

        secondCall.cancel()
        _ = try? await secondCall.value
    }

    // MARK: - Copy

    @Test func theSummaryOmitsWhatWasZeroAndInflectsWhatWasNot() {
        let full = ConnectedAppSignOutResult(
            appName: "Claude",
            registrations: 1,
            authorizations: 1,
            accessTokens: 2,
            refreshTokens: 1,
            pendingRequests: 1,
            alwaysAllowRules: 3
        )
        #expect(full.summary == "Signed out Claude — removed 1 registration, 1 sign-in, 2 access tokens, 1 refresh token, 1 waiting request, and 3 Always Allow rules.")
        #expect(full.removedItemCount == 9)

        let sparse = ConnectedAppSignOutResult(
            appName: "Raycast",
            registrations: 1,
            authorizations: 0,
            accessTokens: 0,
            refreshTokens: 0,
            pendingRequests: 0,
            alwaysAllowRules: 0
        )
        #expect(sparse.summary == "Signed out Raycast — removed 1 registration.")

        let pair = ConnectedAppSignOutResult(
            appName: "every app",
            registrations: 2,
            authorizations: 0,
            accessTokens: 0,
            refreshTokens: 0,
            pendingRequests: 0,
            alwaysAllowRules: 5
        )
        #expect(pair.summary == "Signed out every app — removed 2 registrations and 5 Always Allow rules.")

        let empty = ConnectedAppSignOutResult(
            appName: "every app",
            registrations: 0,
            authorizations: 0,
            accessTokens: 0,
            refreshTokens: 0,
            pendingRequests: 0,
            alwaysAllowRules: 0
        )
        #expect(empty.summary == "Signed out every app — there was nothing left to remove.")
    }
}

// MARK: - Fixture

/// Two fully signed-in apps, each optionally holding waiting tool calls.
private struct SignOutFixture {
    let authCoordinator: OAuthCoordinator
    let approvalCoordinator: ToolCallApprovalCoordinator
    let issuer = "https://macremote.example"
    let resource = "https://macremote.example/mcp"
    let first: ConnectedClient
    let second: ConnectedClient
    let firstTokens: (accessToken: String, refreshToken: String)
    let secondTokens: (accessToken: String, refreshToken: String)
    let firstCallTasks: [Task<Bool, any Error>]
    let secondCallTasks: [Task<Bool, any Error>]

    init(
        pendingCallsPerApp: Int,
        firstName: String = "First App",
        secondName: String = "Second App"
    ) async throws {
        let authCoordinator = OAuthCoordinator()
        let approvalCoordinator = ToolCallApprovalCoordinator(timeoutSeconds: 120)
        self.authCoordinator = authCoordinator
        self.approvalCoordinator = approvalCoordinator

        let firstRegistration = try registerAndSignIn(
            coordinator: authCoordinator,
            clientName: firstName,
            redirectURI: "https://first.example/callback",
            issuer: issuer,
            resource: resource
        )
        let secondRegistration = try registerAndSignIn(
            coordinator: authCoordinator,
            clientName: secondName,
            redirectURI: "https://second.example/callback",
            issuer: issuer,
            resource: resource
        )

        let snapshot = authCoordinator.connectedClientSnapshot()
        first = try #require(snapshot.first { $0.id == firstRegistration.clientID })
        second = try #require(snapshot.first { $0.id == secondRegistration.clientID })
        firstTokens = (firstRegistration.accessToken, firstRegistration.refreshToken)
        secondTokens = (secondRegistration.accessToken, secondRegistration.refreshToken)

        firstCallTasks = Self.startPendingCalls(
            count: pendingCallsPerApp,
            prefix: "first",
            client: first,
            in: approvalCoordinator
        )
        secondCallTasks = Self.startPendingCalls(
            count: pendingCallsPerApp,
            prefix: "second",
            client: second,
            in: approvalCoordinator
        )

        let expected = pendingCallsPerApp * 2
        if expected > 0 {
            try await Self.waitForPendingCount(expected, in: approvalCoordinator)
        }
    }

    func makePermissionStore() throws -> ClientToolPermissionStore {
        try makeIsolatedPermissionStore()
    }

    func validates(_ accessToken: String) -> Bool {
        authCoordinator.validateAccessToken(accessToken, issuer: issuer, resource: resource)
    }

    /// Leaves no task hanging on a continuation after the test's assertions.
    func cancelRemainingWork() async {
        for task in firstCallTasks + secondCallTasks {
            task.cancel()
            _ = try? await task.value
        }
    }

    private static func startPendingCalls(
        count: Int,
        prefix: String,
        client: ConnectedClient,
        in coordinator: ToolCallApprovalCoordinator
    ) -> [Task<Bool, any Error>] {
        let context = AuthenticatedClientContext(
            clientID: client.id,
            clientTrustID: client.trustID,
            clientName: client.name,
            issuer: client.issuer ?? "",
            resource: client.resource ?? "",
            scopes: client.scopes,
            accessTokenExpiresAt: Date().addingTimeInterval(900)
        )
        return (0..<count).map { index in
            let tool = signOutTool(id: "test.\(prefix).\(index)")
            return Task {
                try await coordinator.requestApproval(
                    tool: tool,
                    parameters: [:],
                    client: context
                )
            }
        }
    }

    private static func waitForPendingCount(
        _ expected: Int,
        in coordinator: ToolCallApprovalCoordinator,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<100 {
            if coordinator.approvalSnapshot().count(where: { $0.state == .pending }) == expected {
                return
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("Timed out waiting for \(expected) pending tool calls.", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
}

// MARK: - AppModel fixture

/// One isolated Mac with a live `AppModel`, so sign-out is exercised through the
/// same API Settings and the Apps page call — not through the primitives it
/// composes. The Cloudflare helper is isolated too, or the model would read the
/// real Application Support folder and the real PATH.
@MainActor
private struct AppModelSignOutContext {
    static let issuer = "https://macremote.example"
    static let resource = "https://macremote.example/mcp"

    let model: AppModel
    private let suiteName: String
    private let defaults: UserDefaults
    private let directory: URL
    /// The in-memory credential store persists across this context's operations.
    private let credentialStore: OAuthClientCredentialStore

    init() throws {
        suiteName = "MacRemoteSignOutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw NSError(domain: "MacRemoteTests", code: 1)
        }
        defaults.removePersistentDomain(forName: suiteName)
        self.defaults = defaults
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        credentialStore = OAuthClientCredentialStore(
            userDefaults: defaults,
            keychain: InMemoryKeychainSecretStore()
        )
        model = makeTestAppModel(
            userDefaults: defaults,
            toolStore: ToolRegistryStore(fileURL: directory.appendingPathComponent("tools.json")),
            oauthClientCredentialStore: credentialStore
        )
    }

    var coordinator: OAuthCoordinator { model.oauthCoordinatorForTesting }
    var approvalCoordinator: ToolCallApprovalCoordinator { model.toolCallApprovalCoordinatorForTesting }

    func signIn(
        name: String,
        redirectURI: String
    ) throws -> (clientID: String, accessToken: String, refreshToken: String) {
        let signedIn = try registerAndSignIn(
            coordinator: coordinator,
            clientName: name,
            redirectURI: redirectURI,
            issuer: Self.issuer,
            resource: Self.resource
        )
        model.refreshConnectedClients()
        return signedIn
    }

    /// Signs in an app that authenticates with a saved client secret rather than
    /// registering itself.
    func signInConfidential(
        clientID: String,
        clientSecret: String,
        redirectURI: String
    ) throws -> (accessToken: String, refreshToken: String) {
        let tokens = try authorizeAndExchange(
            coordinator: coordinator,
            clientID: clientID,
            clientSecret: clientSecret,
            redirectURI: redirectURI,
            issuer: Self.issuer,
            resource: Self.resource
        )
        model.refreshConnectedClients()
        return tokens
    }

    /// The client as the views see it, not as the coordinator holds it.
    func publishedClient(
        id: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> ConnectedClient {
        try #require(
            model.connectedClients.first { $0.id == id },
            "\(id) is not in the published client list.",
            sourceLocation: sourceLocation
        )
    }

    func validates(_ accessToken: String) -> Bool {
        coordinator.validateAccessToken(accessToken, issuer: Self.issuer, resource: Self.resource)
    }

    func startPendingCall(id: String, client: ConnectedClient) -> Task<Bool, any Error> {
        pendingCall(id: id, client: client, in: approvalCoordinator)
    }

    func waitForPendingCount(
        _ expected: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitForPendingApprovals(
            expected,
            in: approvalCoordinator,
            sourceLocation: sourceLocation
        )
    }

    func cancel(_ task: Task<Bool, any Error>) async {
        task.cancel()
        _ = try? await task.value
    }

    func cleanUp() {
        credentialStore.clear()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Helpers

/// A tool call parked on the approval gate, exactly as the MCP server parks one.
private func pendingCall(
    id: String,
    client: ConnectedClient,
    in coordinator: ToolCallApprovalCoordinator
) -> Task<Bool, any Error> {
    let context = AuthenticatedClientContext(
        clientID: client.id,
        clientTrustID: client.trustID,
        clientName: client.name,
        issuer: client.issuer ?? "",
        resource: client.resource ?? "",
        scopes: client.scopes,
        accessTokenExpiresAt: Date().addingTimeInterval(900)
    )
    let tool = signOutTool(id: id)
    return Task {
        try await coordinator.requestApproval(tool: tool, parameters: [:], client: context)
    }
}

private func waitForPendingApprovals(
    _ expected: Int,
    in coordinator: ToolCallApprovalCoordinator,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<200 {
        if coordinator.approvalSnapshot().count(where: { $0.state == .pending }) == expected {
            return
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    Issue.record("Timed out waiting for \(expected) pending tool calls.", sourceLocation: sourceLocation)
    throw NSError(domain: "MacRemoteTests", code: 1)
}

private func signOutTool(id: String) -> ToolDefinition {
    ToolDefinition(
        id: id,
        name: id,
        summary: "Sign-out test tool.",
        executablePath: "/bin/echo",
        argumentPattern: ["{args}"],
        parameters: [],
        capability: .write,
        timeoutSeconds: 5,
        outputByteLimit: 1024
    )
}

private func makeIsolatedPermissionStore(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> ClientToolPermissionStore {
    let suiteName = "MacRemoteSignOutTests-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated UserDefaults suite.", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    defaults.removePersistentDomain(forName: suiteName)
    return ClientToolPermissionStore(userDefaults: defaults)
}

private func registerAndSignIn(
    coordinator: OAuthCoordinator,
    clientName: String,
    redirectURI: String,
    issuer: String,
    resource: String
) throws -> (clientID: String, accessToken: String, refreshToken: String) {
    let registration = try coordinator.registerClient(from: [
        "client_name": clientName,
        "redirect_uris": [redirectURI],
        "scope": "mcp:tools"
    ])
    let clientID = try #require(registration["client_id"] as? String)
    let tokens = try authorizeAndExchange(
        coordinator: coordinator,
        clientID: clientID,
        clientSecret: nil,
        redirectURI: redirectURI,
        issuer: issuer,
        resource: resource
    )
    return (clientID, tokens.accessToken, tokens.refreshToken)
}

private func authorizeAndExchange(
    coordinator: OAuthCoordinator,
    clientID: String,
    clientSecret: String?,
    redirectURI: String,
    issuer: String,
    resource: String
) throws -> (accessToken: String, refreshToken: String) {
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
    let redirect = try #require(
        coordinator.authorizationStatus(requestID: requestID)["redirect_uri"] as? String
    )
    let code = try #require(
        URLComponents(string: redirect)?.queryItems?.first(where: { $0.name == "code" })?.value
    )
    var form = [
        "grant_type": "authorization_code",
        "client_id": clientID,
        "redirect_uri": redirectURI,
        "code": code,
        "code_verifier": verifier,
        "resource": resource
    ]
    if let clientSecret {
        form["client_secret"] = clientSecret
    }
    let token = try coordinator.exchangeToken(form: form, issuer: issuer, resource: resource)
    return (
        try #require(token["access_token"] as? String),
        try #require(token["refresh_token"] as? String)
    )
}
