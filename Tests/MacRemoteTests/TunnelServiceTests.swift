import Foundation
import Testing
@testable import MacRemote

struct TunnelServiceTests {
    @Test func parsesTryCloudflareURLFromOutput() {
        let output = "INFO Your quick Tunnel has been created! Visit it at https://quiet-river-123.trycloudflare.com"
        #expect(
            TunnelService.firstPublicURL(in: output)?.absoluteString ==
            "https://quiet-river-123.trycloudflare.com"
        )
    }

    @Test func ignoresNonTryCloudflareURL() {
        let output = "Forwarding to http://127.0.0.1:60735"
        #expect(TunnelService.firstPublicURL(in: output) == nil)
    }

    /// The helper prints Cloudflare's API host when it cannot create a link.
    /// Reading that as the public address made the app report "public" at a
    /// URL that was never this Mac's.
    @Test func cloudflareAPIHostInAnErrorLineIsNotThePublicURL() {
        let failure = #"failed to request quick Tunnel: Post "https://api.trycloudflare.com/tunnel": dial tcp: no route to host"#
        #expect(TunnelService.firstPublicURL(in: failure) == nil)
        #expect(
            TunnelService.firstPublicURL(in: failure + "\nVisit https://quiet-river-123.trycloudflare.com")?.host()
                == "quiet-river-123.trycloudflare.com"
        )
    }

    @Test func helperLeftRunningByAPreviousLaunchIsStopped() async throws {
        let fixture = try makeTunnelScript("exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let record = fixture.directory.appendingPathComponent("helper.json")
        let resolver = TunnelService.CloudflaredResolver.pathOnly { fixture.executable.path }

        // The "previous launch": it starts the helper and never stops it.
        let previous = TunnelService(resolver: resolver, childRecordURL: record)
        try previous.startQuickTunnel(localServerURL: URL(string: "http://127.0.0.1:8765")!) { _ in }
        #expect(previous.isProcessRunning())
        #expect(FileManager.default.fileExists(atPath: record.path))

        let next = TunnelService(resolver: resolver, childRecordURL: record)
        #expect(next.stopHelperLeftByPreviousLaunch())
        for _ in 0..<200 where previous.isProcessRunning() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!previous.isProcessRunning())
        // Nothing left to stop the second time.
        #expect(!next.stopHelperLeftByPreviousLaunch())
    }

    @Test func recognizesNamedTunnelRegistrationEvidence() {
        #expect(TunnelService.containsRegisteredConnectionEvidence(
            in: "INF Registered tunnel connection connIndex=0 connection=abc"
        ))
        #expect(!TunnelService.containsRegisteredConnectionEvidence(
            in: "INF Starting tunnel tunnelID=abc"
        ))
    }

    @Test func namedTunnelDoesNotStartWithoutRegistrationEvidence() async throws {
        let fixture = try makeTunnelScript("sleep 2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService(namedStartupTimeout: 0.05) { fixture.executable.path }

        try service.startNamedTunnel(deployment: namedTunnelDeployment()) { event in
            recorder.record(event)
        }

        let events = await waitForTunnelEvent(recorder) { event in
            if case .failed = event { return true }
            return false
        }
        #expect(!events.contains { event in
            if case .started = event { return true }
            return false
        })
        #expect(events.contains { event in
            if case .failed(let message) = event { return message == TunnelService.namedTunnelStartupFailure }
            return false
        })
        service.stop()
    }

    @Test func namedTunnelStartsAfterRegistrationEvidence() async throws {
        let fixture = try makeTunnelScript("printf '%s\\n' 'INF Registered tunnel connection connIndex=0'; sleep 2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService(namedStartupTimeout: 0.5) { fixture.executable.path }
        let deployment = namedTunnelDeployment()

        try service.startNamedTunnel(deployment: deployment) { event in
            recorder.record(event)
        }

        let events = await waitForTunnelEvent(recorder) { event in
            if case .started = event { return true }
            return false
        }
        #expect(events.contains { event in
            if case .started(let url) = event { return url == deployment.publicURL }
            return false
        })
        #expect(service.status(localServerURL: URL(string: "http://127.0.0.1:8765")!) == .running(deployment.publicURL))
        service.stop()
    }

    @Test func publicHostIsKnownOnlyWhileTheHelperRuns() async throws {
        let fixture = try makeTunnelScript("printf '%s\\n' 'INF Registered tunnel connection connIndex=0'; sleep 2")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService(namedStartupTimeout: 0.5) { fixture.executable.path }
        #expect(service.publicHost() == nil)

        try service.startNamedTunnel(deployment: namedTunnelDeployment()) { event in
            recorder.record(event)
        }
        _ = await waitForTunnelEvent(recorder) { event in
            if case .started = event { return true }
            return false
        }
        #expect(service.publicHost() == "macremote.example.com")

        service.stop()
        #expect(service.publicHost() == nil)
    }

    @Test func namedTunnelReportsProcessFailureBeforeRegistration() async throws {
        let fixture = try makeTunnelScript("exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService(namedStartupTimeout: 0.5) { fixture.executable.path }

        try service.startNamedTunnel(deployment: namedTunnelDeployment()) { event in
            recorder.record(event)
        }

        let events = await waitForTunnelEvent(recorder) { event in
            if case .failed = event { return true }
            return false
        }
        #expect(!events.contains { event in
            if case .started = event { return true }
            return false
        })
        #expect(events.contains { event in
            if case .failed(let message) = event { return message.contains("status 7") }
            return false
        })
    }

    /// The helper prints an Instant Link's address before it has connected to
    /// Cloudflare. Until a connection registers, the address reaches nothing.
    @Test func instantLinkIsNotUpUntilAConnectionRegisters() async throws {
        let fixture = try makeTunnelScript(gated: true, """
        printf '%s\\n' 'INF |  https://quiet-river-123.trycloudflare.com  |'
        read line < "$gate"
        printf '%s\\n' 'INF Registered tunnel connection connIndex=0'
        exec /usr/bin/tail -f /dev/null
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService { fixture.executable.path }
        defer { service.stop() }
        let localServerURL = URL(string: "http://127.0.0.1:8765")!

        try service.startQuickTunnel(localServerURL: localServerURL) { recorder.record($0) }
        _ = await waitForTunnelEvent(recorder) { event in
            if case .log(let line) = event { return line.contains("trycloudflare.com") }
            return false
        }
        #expect(service.status(localServerURL: localServerURL) == .starting)
        #expect(!recorder.snapshot().contains { $0.isStarted })

        try await fixture.openGate()
        _ = await waitForTunnelEvent(recorder, matching: \.isStarted)
        #expect(service.status(localServerURL: localServerURL) ==
            .running(URL(string: "https://quiet-river-123.trycloudflare.com")!))
    }

    @Test func linkGoesDownWhenTheHelperHasNoConnectionsAndComesBack() async throws {
        let connected = try await ConnectedTunnelFixture()
        defer { connected.tearDown() }

        connected.probe.answer = 0
        await connected.service.refreshEdgeConnection()
        #expect(connected.recorder.snapshot().contains { $0.isConnectionLost })
        #expect(connected.status == .starting)
        // The server must keep answering for this host: a request that still
        // gets through proves the link works, whatever the count said.
        #expect(connected.service.publicHost() == connected.publicURL.host())

        connected.probe.answer = 3
        await connected.service.refreshEdgeConnection()
        #expect(connected.recorder.snapshot().count { $0.isStarted } == 2)
        #expect(connected.status == .running(connected.publicURL))
        #expect(connected.probe.askedURLs.allSatisfy { $0.absoluteString == "http://127.0.0.1:20241/ready" })
    }

    @Test func anUnansweredConnectionCheckLeavesTheLinkUp() async throws {
        let connected = try await ConnectedTunnelFixture()
        defer { connected.tearDown() }

        connected.probe.answer = nil
        await connected.service.refreshEdgeConnection()

        #expect(!connected.recorder.snapshot().contains { $0.isConnectionLost })
        #expect(connected.status == .running(connected.publicURL))
    }

    /// A check that was sent before a connection registered can answer "none"
    /// after it. That old answer must not take the new link down.
    @Test func anOlderNoConnectionsAnswerDoesNotTakeDownANewerConnection() async throws {
        let fixture = try makeTunnelScript(gated: true, """
        printf '%s\\n' 'INF Starting metrics server on 127.0.0.1:20241/metrics'
        read line < "$gate"
        printf '%s\\n' 'INF Registered tunnel connection connIndex=0'
        exec /usr/bin/tail -f /dev/null
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let slowAnswer = SlowFirstAnswer()
        let service = TunnelService(namedStartupTimeout: 30, readyConnections: { _ in await slowAnswer.next() }) {
            fixture.executable.path
        }
        defer { service.stop() }
        let deployment = namedTunnelDeployment()

        try service.startNamedTunnel(deployment: deployment) { recorder.record($0) }
        _ = await waitForTunnelEvent(recorder) { event in
            if case .log(let line) = event { return line.contains("metrics server") }
            return false
        }
        let earlyCheck = Task { await service.refreshEdgeConnection() }
        await slowAnswer.waitUntilAsked()

        try await fixture.openGate()
        _ = await waitForTunnelEvent(recorder, matching: \.isStarted)
        await slowAnswer.release()
        await earlyCheck.value
        try await Task.sleep(for: .milliseconds(100))

        #expect(!recorder.snapshot().contains { $0.isConnectionLost })
        #expect(service.status(localServerURL: URL(string: "http://127.0.0.1:8765")!) == .running(deployment.publicURL))
    }

    @Test func helperStatusPageIsReadOnlyFromThisMac() {
        #expect(
            TunnelService.readinessURL(in: "INF Starting metrics server on 127.0.0.1:53124/metrics")?.absoluteString
                == "http://127.0.0.1:53124/ready"
        )
        #expect(TunnelService.readinessURL(in: "INF Starting metrics server on 203.0.113.9:53124/metrics") == nil)
        #expect(TunnelService.readinessURL(in: "INF Starting tunnel tunnelID=abc") == nil)
    }

    @Test func readsTheConnectionCountFromTheHelperAnswer() {
        let ready = Data(#"{"status":200,"readyConnections":4,"connectorId":"0c5e7a3e"}"#.utf8)
        let notReady = Data(#"{"status":503,"readyConnections":0,"connectorId":"0c5e7a3e"}"#.utf8)
        #expect(TunnelService.readyConnectionCount(from: ready) == 4)
        #expect(TunnelService.readyConnectionCount(from: notReady) == 0)
        #expect(TunnelService.readyConnectionCount(from: Data("not json".utf8)) == nil)
    }

    @MainActor
    @Test func appModelStopsShowingTheLinkWhileItsConnectionIsLost() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        let publicURL = URL(string: "https://quiet-river-123.trycloudflare.com")!

        model.handleTunnelEvent(.started(publicURL))
        #expect(model.currentPublicMCPURL != nil)

        model.handleTunnelEvent(.connectionLost)
        #expect(model.tunnelStatus == .reconnecting(attempt: 1))
        #expect(model.currentPublicMCPURL == nil)
        // The helper is still running, so the session is still supervised.
        #expect(defaults.bool(forKey: "MacRemote.tunnelSupervision.active"))

        model.handleTunnelEvent(.started(publicURL))
        #expect(model.tunnelStatus == .running(publicURL))
    }

    @MainActor
    @Test func aLateConnectionLostEventDoesNotHideAFailure() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.tunnelStatus = .failed("The helper stopped.")

        model.handleTunnelEvent(.connectionLost)

        #expect(model.tunnelStatus == .failed("The helper stopped."))
    }

    /// Cloudflare rejects a run token that was replaced, or whose tunnel was
    /// deleted. That is reported apart from other failures, because trying
    /// the same token again cannot work.
    @Test func helperThatExitsAfterCloudflareRejectsItsTokenReportsARefusal() async throws {
        let fixture = try makeTunnelScript("""
        printf '%s\\n' 'ERR Register tunnel error from server side error="Unauthorized: Invalid tunnel secret"'
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService(namedStartupTimeout: 30) { fixture.executable.path }

        try service.startNamedTunnel(deployment: namedTunnelDeployment()) { recorder.record($0) }

        let events = await waitForTunnelEvent(recorder, matching: \.isRunTokenRefused)
        #expect(events.contains { $0.isRunTokenRefused })
        #expect(!events.contains { $0.isFailed })
    }

    @Test func helperThatNeverConnectsAfterARejectedTokenReportsARefusal() async throws {
        let fixture = try makeTunnelScript("""
        printf '%s\\n' 'ERR Register tunnel error from server side error="Unauthorized: Invalid tunnel secret"'
        exec /usr/bin/tail -f /dev/null
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        // Long enough for the stand-in to start and print its line while every
        // other test runs beside it, and inside the 2 s this test waits.
        let service = TunnelService(namedStartupTimeout: 1.0) { fixture.executable.path }
        defer { service.stop() }

        try service.startNamedTunnel(deployment: namedTunnelDeployment()) { recorder.record($0) }

        let events = await waitForTunnelEvent(recorder, matching: \.isRunTokenRefused)
        #expect(events.contains { $0.isRunTokenRefused })
        #expect(!events.contains { $0.isFailed })
    }

    /// Cloudflare can reject a tunnel for a few seconds right after it is
    /// created. A connection that registers afterwards proves the token works.
    @Test func aRejectionFollowedByAConnectionIsNotARefusal() async throws {
        let fixture = try makeTunnelScript(gated: true, """
        printf '%s\\n' 'ERR Register tunnel error from server side error="Unauthorized: Invalid tunnel secret"'
        printf '%s\\n' 'INF Registered tunnel connection connIndex=0'
        read line < "$gate"
        exit 1
        """)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let recorder = TunnelEventRecorder()
        let service = TunnelService(namedStartupTimeout: 30) { fixture.executable.path }

        try service.startNamedTunnel(deployment: namedTunnelDeployment()) { recorder.record($0) }
        _ = await waitForTunnelEvent(recorder, matching: \.isStarted)
        try await fixture.openGate()

        let events = await waitForTunnelEvent(recorder, matching: \.isFailed)
        #expect(events.contains { $0.isFailed })
        #expect(!events.contains { $0.isRunTokenRefused })
    }

    @Test func runTokenIsSavedForOneTunnelAndReplacedByTheNext() throws {
        let store = CloudflareRunTokenStore(keychain: InMemoryKeychainSecretStore())
        #expect(store.token(forTunnelID: "tunnel-a") == nil)

        try store.save("secret-a", tunnelID: "tunnel-a")
        #expect(store.token(forTunnelID: "tunnel-a") == "secret-a")
        // A token is never handed out for a tunnel it was not saved for.
        #expect(store.token(forTunnelID: "tunnel-b") == nil)

        try store.save("secret-b", tunnelID: "tunnel-b")
        #expect(store.token(forTunnelID: "tunnel-a") == nil)
        #expect(store.token(forTunnelID: "tunnel-b") == "secret-b")

        store.delete()
        #expect(store.token(forTunnelID: "tunnel-b") == nil)
    }

    /// The point of the saved run token: after a relaunch, Go Public brings a
    /// deployed domain back with no API token and no Wrangler.
    @MainActor
    @Test func deployedDomainGoesPublicAgainAfterRelaunchWithoutCloudflareCredentials() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: """
        printf '%s' "$TUNNEL_TOKEN" > "$(dirname "$0")/token"
        printf '%s' "$*" > "$(dirname "$0")/arguments"
        printf '%s\\n' 'INF Registered tunnel connection connIndex=0'
        exec /usr/bin/tail -f /dev/null
        """)
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel()
        defer { model.stopTunnel() }

        model.startTunnel()
        await waitUntil { model.tunnelStatus.isRunning }

        #expect(model.tunnelStatus == .running(URL(string: "https://macremote-m5.example.com")!))
        #expect(model.cloudflareCustomDomainState == .deployed("macremote-m5.example.com"))
        #expect(model.lastCloudflareDeployment?.hostname == "macremote-m5.example.com")
        #expect(!model.connectionAddressSetupRequested)
        #expect(model.cloudflareDraft.apiToken.isEmpty)
        #expect(try relaunch.helperFile("token") == "tunnel-secret")
        #expect(try relaunch.helperFile("arguments") == "tunnel --no-autoupdate --metrics 127.0.0.1:0 run")
    }

    /// Preferences written by the build before this one have no port and no
    /// zone name. They must still load, and they fall back to a deploy.
    @MainActor
    @Test func preferencesSavedByTheEarlierBuildStillLoadAndAskForADeploy() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        relaunch.defaults.set(Data("""
        {"selectedZoneID":"zone-id","subdomain":"macremote-m5","deployment":\
        {"zoneID":"zone-id","accountID":"account-id","hostname":"macremote-m5.example.com","tunnelID":"tunnel-id"}}
        """.utf8), forKey: CloudflareCustomDomainPreferences.defaultsKey)
        let model = try await relaunch.makeRelaunchedModel()

        #expect(model.cloudflareDraft.subdomain == "macremote-m5")
        #expect(model.savedCloudflareDomain?.tunnelID == "tunnel-id")
        #expect(model.savedCloudflareDomain?.localPort == nil)

        model.startTunnel()
        #expect(model.connectionAddressSetupRequested)
        #expect(!model.tunnelStatus.isRunning && !model.tunnelStatus.isRecovering)
    }

    @MainActor
    @Test func missingRunTokenSendsTheOwnerToDeployInsteadOfStartingAnInstantLink() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        relaunch.runTokenStore.delete()
        let model = try await relaunch.makeRelaunchedModel()

        model.startTunnel()

        #expect(model.connectionAddressSetupRequested)
        #expect(model.tunnelStatus == .ready)
        #expect(model.logs.contains { $0.message.contains("Deploy it from Address") })
    }

    /// Cloudflare sends the tunnel's requests to the port the domain was
    /// deployed with. On any other port the link would come up and reach
    /// nothing, so it is not started.
    @MainActor
    @Test func aLocalServerOnAnotherPortSendsTheOwnerToDeploy() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel(localPort: 54_901)

        model.startTunnel()

        #expect(model.connectionAddressSetupRequested)
        #expect(model.tunnelStatus == .ready)
        // The token stays: the port can be free again at the next launch.
        #expect(relaunch.runTokenStore.token(forTunnelID: "tunnel-id") == "tunnel-secret")
    }

    @MainActor
    @Test func changingTheDomainDeletesTheSavedRunToken() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel()
        #expect(model.chosenDeployedHostname == "macremote-m5.example.com")

        model.cloudflareDraft.subdomain = "macremote-m6"
        #expect(relaunch.runTokenStore.token(forTunnelID: "tunnel-id") == nil)
        #expect(model.chosenDeployedHostname == nil)

        // Choosing the old address again does not bring the token back.
        model.cloudflareDraft.subdomain = "macremote-m5"
        model.startTunnel()
        #expect(model.connectionAddressSetupRequested)
    }

    @MainActor
    @Test func choosingAnotherZoneDeletesTheSavedRunToken() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel()

        model.cloudflareDraft.selectedZoneID = "other-zone"

        #expect(relaunch.runTokenStore.token(forTunnelID: "tunnel-id") == nil)
    }

    /// The app clears the chosen domain by itself when a domain list fails to
    /// load. That is not the owner changing the address.
    @MainActor
    @Test func aFailedDomainLoadKeepsTheSavedRunToken() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel()

        model.applyLoadedCloudflareZones([])

        #expect(model.cloudflareDraft.selectedZoneID == nil)
        #expect(relaunch.runTokenStore.token(forTunnelID: "tunnel-id") == "tunnel-secret")
        #expect(model.chosenDeployedHostname == "macremote-m5.example.com")
    }

    @MainActor
    @Test func refusedRunTokenIsDeletedAndTheNextGoPublicAsksForADeploy() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: """
        printf '%s\\n' 'ERR Register tunnel error from server side error="Unauthorized: Invalid tunnel secret"'
        exit 1
        """)
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel()

        model.startTunnel()
        await waitUntil {
            if case .failed = model.tunnelStatus { return true }
            return false
        }

        let refusal = "Cloudflare no longer accepts the saved key for macremote-m5.example.com. Deploy your domain again from Address."
        #expect(model.tunnelStatus == .failed(refusal))
        #expect(model.cloudflareCustomDomainState.deployFailure?.message == refusal)
        #expect(relaunch.runTokenStore.token(forTunnelID: "tunnel-id") == nil)
        #expect(!model.connectionAddressSetupRequested)

        model.startTunnel()
        #expect(model.connectionAddressSetupRequested)
    }

    /// A tunnel deployed a moment ago can be rejected while Cloudflare learns
    /// about it. That is an ordinary failure and keeps the saved token.
    @MainActor
    @Test func aRefusalOutsideASavedTokenStartIsAnOrdinaryFailure() async throws {
        let relaunch = try DeployedDomainRelaunch(helper: "exit 0")
        defer { relaunch.tearDown() }
        let model = try await relaunch.makeRelaunchedModel()

        model.handleTunnelEvent(.runTokenRefused("The helper stopped."))

        #expect(model.tunnelStatus == .failed("The helper stopped."))
        #expect(relaunch.runTokenStore.token(forTunnelID: "tunnel-id") == "tunnel-secret")
    }

    @MainActor
    @Test func appModelCurrentPublicMCPURLUsesStableAlias() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.instanceID = "abc123"
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)

        #expect(
            model.currentPublicMCPURL?.absoluteString ==
            "https://quiet-river-123.trycloudflare.com/mcp"
        )
    }

    @MainActor
    @Test func rotateInstanceIDStopsExposureClearsApprovalsAndPersistsNewID() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let originalInstanceID = "0123456789abcdef0123456789abcdef"
        defaults.set(originalInstanceID, forKey: "MacRemote.instanceID")
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.serverStatus = .running(URL(string: "http://127.0.0.1:60123")!)
        model.localServerURL = URL(string: "http://127.0.0.1:60123")!
        model.tunnelStatus = .running(URL(string: "https://quiet-river-123.trycloudflare.com")!)
        model.approvals = [
            ApprovalRequest(
                id: UUID(),
                clientID: "client-id",
                clientTrustID: "trust-id",
                clientName: "Client",
                redirectURI: "https://example.com/callback",
                issuer: "https://quiet-river-123.trycloudflare.com",
                resource: "https://quiet-river-123.trycloudflare.com/mcp/\(originalInstanceID)",
                requestedScopes: ["mcp:tools"],
                createdAt: Date(),
                state: .pending
            )
        ]
        model.toolCallApprovals = [
            ToolCallApprovalRequest(
                id: UUID(),
                toolID: "remctl.run",
                toolName: "Run RemCTL",
                capability: .destructive,
                createdAt: Date(),
                state: .pending
            )
        ]

        #expect(model.currentPublicMCPURL?.absoluteString == "https://quiet-river-123.trycloudflare.com/mcp")

        model.rotateInstanceID()

        #expect(model.instanceID != originalInstanceID)
        #expect(model.instanceID.count == 32)
        #expect(defaults.string(forKey: "MacRemote.instanceID") == model.instanceID)
        #expect(model.serverStatus == .stopped)
        #expect(model.localServerURL == nil)
        #expect(model.currentPublicMCPURL == nil)
        #expect(model.approvals.isEmpty)
        #expect(model.toolCallApprovals.isEmpty)
        // §2.4: rotation no longer jumps navigation — Settings › Security confirms in place.
        #expect(model.instanceRotationConfirmation == "New private address created")
        #expect(model.logs.first?.message.contains("Rotated instance ID") == true)
    }

    @MainActor
    @Test func customDomainDeployIsAllowedBeforeLocalServerStarts() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.serverStatus = .stopped
        model.localServerURL = nil
        model.cloudflareZones = [
            CloudflareZone(
                id: "zone-id",
                name: "example.com",
                accountID: "account-id",
                accountName: "Test Account"
            )
        ]
        model.cloudflareDraft.selectedZoneID = "zone-id"
        model.cloudflareDraft.subdomain = "macremote-fresh-clients"
        model.cloudflareDraft.apiToken = "test-token"
        model.cloudflareCustomDomainState = .ready

        #expect(model.canDeployCustomDomainTunnel)
        #expect(model.customDomainDeployHint == "Deploy will start the local MCP server first.")
    }

    @MainActor
    @Test func customDomainDeployIsDisabledWhenHelperIsUnavailable() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults, cloudflaredPath: nil)
        model.cloudflareZones = [cloudflareZone(id: "zone-id", name: "example.com")]
        model.cloudflareDraft.selectedZoneID = "zone-id"
        model.cloudflareDraft.subdomain = "macremote-fresh-clients"
        model.cloudflareDraft.apiToken = "test-token"
        model.cloudflareCustomDomainState = .ready

        #expect(model.tunnelStatus == .unavailable)
        #expect(!model.canDeployCustomDomainTunnel)
        #expect(model.customDomainDeployHint == CloudflareServiceError.cloudflaredUnavailable.localizedDescription)

        model.deployCustomDomainTunnel()
        #expect(model.cloudflareCustomDomainState.deployFailure?.stage == .start)
    }

    @MainActor
    @Test func customDomainDeployWithoutPastedTokenNeedsWrangler() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.cloudflareZones = [cloudflareZone(id: "zone-id", name: "example.com")]
        model.cloudflareDraft.selectedZoneID = "zone-id"
        model.cloudflareDraft.subdomain = "macremote-fresh-clients"
        model.cloudflareCustomDomainState = .ready

        // A signed-in Wrangler can deploy without a pasted token. Whether it is
        // installed depends on this Mac, so check the branch that applies.
        let wranglerUnavailable = CloudflareServiceError.wranglerUnavailable.localizedDescription
        if model.hasWranglerForCloudflareSetup {
            #expect(model.canDeployCustomDomainTunnel)
            #expect(model.customDomainDeployHint != wranglerUnavailable)
        } else {
            #expect(!model.canDeployCustomDomainTunnel)
            #expect(model.customDomainDeployHint == wranglerUnavailable)
        }

        model.cloudflareDraft.apiToken = "test-token"
        #expect(model.canDeployCustomDomainTunnel)
        #expect(model.customDomainDeployHint != wranglerUnavailable)
    }

    @MainActor
    @Test func customDomainAddressSurvivesRelaunchButCredentialsDoNot() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let zone = cloudflareZone(id: "zone-id", name: "example.com")
        let runTokenStore = CloudflareRunTokenStore(keychain: InMemoryKeychainSecretStore())
        let first = try makeIsolatedAppModel(userDefaults: defaults, runTokenStore: runTokenStore)
        first.cloudflareDraft.selectedZoneID = zone.id
        first.cloudflareDraft.subdomain = "macremote-m5"
        first.cloudflareDraft.apiToken = "pasted-secret"
        first.rememberCloudflareDomain(CloudflareCustomDomainDeployment(
            zone: zone,
            hostname: "macremote-m5.example.com",
            tunnelID: "tunnel-id",
            tunnelName: CloudflareService.tunnelName(hostname: "macremote-m5.example.com"),
            tunnelToken: "tunnel-secret",
            localPort: 54_900
        ))

        let stored = try #require(defaults.data(forKey: CloudflareCustomDomainPreferences.defaultsKey))
        let storedText = String(decoding: stored, as: UTF8.self)
        #expect(!storedText.contains("pasted-secret"))
        #expect(!storedText.contains("tunnel-secret"))
        // The run token is the one secret kept, and only in the Keychain.
        #expect(runTokenStore.token(forTunnelID: "tunnel-id") == "tunnel-secret")

        let relaunched = try makeIsolatedAppModel(userDefaults: defaults)
        #expect(relaunched.cloudflareDraft.selectedZoneID == zone.id)
        #expect(relaunched.cloudflareDraft.subdomain == "macremote-m5")
        #expect(relaunched.cloudflareDraft.apiToken.isEmpty)
        let saved = try #require(relaunched.savedCloudflareDomain)
        #expect(saved.tunnelID == "tunnel-id")
        #expect(saved.localPort == 54_900)
        #expect(saved.matches(zone: zone, subdomain: "macremote-m5"))
        #expect(!saved.matches(zone: zone, subdomain: "macremote"))
        #expect(!saved.matches(
            zone: CloudflareZone(id: zone.id, name: zone.name, accountID: "other-account", accountName: "Other"),
            subdomain: "macremote-m5"
        ))
        // Restoring the address never starts a public link by itself.
        #expect(!relaunched.tunnelStatus.isRunning)
    }

    @MainActor
    @Test func missingOrDamagedCustomDomainPreferencesRequireAnExplicitAddress() throws {
        for stored in [nil, Data("not json".utf8)] {
            let defaults = try makeIsolatedDefaults()
            defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
            if let stored {
                defaults.set(stored, forKey: CloudflareCustomDomainPreferences.defaultsKey)
            }

            let model = try makeIsolatedAppModel(userDefaults: defaults)
            #expect(model.cloudflareDraft.selectedZoneID == nil)
            #expect(model.cloudflareDraft.subdomain.isEmpty)
            #expect(model.savedCloudflareDomain == nil)
        }
    }

    @Test func welcomeExplainsBothCloudflareAddressChoices() {
        #expect(AddressMode.instantLink.welcomeTitle == "Instant Link")
        #expect(AddressMode.instantLink.welcomeDetail.contains("No Cloudflare account or domain"))
        #expect(AddressMode.instantLink.welcomeDetail.contains("random temporary address"))
        #expect(AddressMode.instantLink.welcomeRequirements.isEmpty)

        #expect(AddressMode.yourDomain.welcomeTitle == "Your Domain")
        #expect(AddressMode.yourDomain.welcomeDetail.contains("stable address"))
        #expect(AddressMode.yourDomain.welcomeDetail.contains("Cloudflare account"))
        #expect(AddressMode.yourDomain.welcomeRequirements.count == 3)
        #expect(AddressMode.yourDomain.welcomeRequirements.joined(separator: " ").contains("never saves the token"))
        #expect(AddressMode.yourDomain.welcomeRequirements.joined(separator: " ").contains("load your domains"))
        #expect(AddressMode.yourDomain.welcomeRequirements.joined(separator: " ").contains("choose the domain and subdomain"))
    }

    @Test func domainDiscoveryRequiresTokenOrInstalledWrangler() {
        #expect(CloudflareService.canLoadZones(apiToken: nil, wranglerPath: nil) == false)
        #expect(CloudflareService.canLoadZones(apiToken: "  ", wranglerPath: nil) == false)
        #expect(CloudflareService.canLoadZones(apiToken: "session-token", wranglerPath: nil))
        #expect(CloudflareService.canLoadZones(apiToken: nil, wranglerPath: "/opt/homebrew/bin/wrangler"))
    }

    @MainActor
    @Test func domainLoadFailuresStayVisibleAndDistinctFromDeployFailures() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.cloudflareDraft.apiToken = "invalid-token"

        let invalidToken = CloudflareServiceError.insufficientPermissions("list Cloudflare zones").localizedDescription
        model.cloudflareCustomDomainState = .failed(.loadingDomains(message: invalidToken))
        #expect(model.cloudflareCustomDomainState.domainLoadFailureMessage == invalidToken)
        #expect(model.customDomainDeployHint == invalidToken)

        let signedOut = CloudflareServiceError.wranglerNotAuthenticated.localizedDescription
        model.cloudflareCustomDomainState = .failed(.loadingDomains(message: signedOut))
        #expect(model.cloudflareCustomDomainState.domainLoadFailureMessage == signedOut)
        #expect(signedOut.contains("signed out"))
        #expect(signedOut.contains("Terminal") == false)

        model.cloudflareCustomDomainState = .failed(.deploying(stage: .checkAccess, message: invalidToken))
        #expect(model.cloudflareCustomDomainState.domainLoadFailureMessage == nil)
        #expect(model.cloudflareCustomDomainState.deployFailure?.stage == .checkAccess)
    }

    @Test func genericCloudflareFailuresUseHumanCopyAndSanitizedTechnicalDetail() {
        let presentation = AppModel.cloudflareFailurePresentation(
            for: CloudflareServiceError.api("Cloudflare request failed\nAuthorization: Bearer secret-token"),
            stage: .configureDNS,
            apiToken: "secret-token"
        )

        #expect(presentation.message ==
            "MacRemote couldn't configure DNS for this hostname. Check the selected domain, then try again.")
        #expect(!presentation.message.contains("Cloudflare request failed"))
        #expect(presentation.technicalDetail?.contains("secret-token") == false)
        #expect(presentation.technicalDetail?.contains("\n") == false)
        #expect(presentation.technicalDetail?.contains("[redacted]") == true)
    }

    @MainActor
    @Test func zeroDomainsShowsClearFailureAndNoSelection() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.cloudflareDraft.selectedZoneID = "stale-zone"

        model.applyLoadedCloudflareZones([])

        #expect(model.cloudflareZones.isEmpty)
        #expect(model.cloudflareDraft.selectedZoneID == nil)
        #expect(model.cloudflareCustomDomainState.domainLoadFailureMessage ==
            "No Cloudflare domains were found. Add a domain to Cloudflare, then choose Load Domains again.")
    }

    @MainActor
    @Test func aSingleLoadedDomainIsNotAutoSelected() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)

        model.applyLoadedCloudflareZones([cloudflareZone(id: "one", name: "example.com")])

        #expect(model.cloudflareCustomDomainState == .ready)
        #expect(model.cloudflareDraft.selectedZoneID == nil)
    }

    @MainActor
    @Test func multipleDomainsRetainOnlyAnExplicitValidSelection() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let model = try makeIsolatedAppModel(userDefaults: defaults)
        let zones = [
            cloudflareZone(id: "one", name: "example.com"),
            cloudflareZone(id: "two", name: "example.net")
        ]

        model.cloudflareDraft.selectedZoneID = "two"
        model.applyLoadedCloudflareZones(zones)
        #expect(model.cloudflareDraft.selectedZoneID == "two")

        model.cloudflareDraft.selectedZoneID = "removed"
        model.applyLoadedCloudflareZones(zones)
        #expect(model.cloudflareDraft.selectedZoneID == nil)
    }

    @Test func welcomeOnlyPromptsToMoveCopiesOutsideApplications() {
        #expect(
            WelcomeInstallLocation.needsApplicationsMove(
                bundleURL: URL(fileURLWithPath: "/Applications/MacRemote.app")
            ) == false
        )
        #expect(
            WelcomeInstallLocation.needsApplicationsMove(
                bundleURL: URL(fileURLWithPath: "/Users/test/Downloads/MacRemote.app")
            )
        )
    }

    @MainActor
    @Test func welcomeDomainHandoffIsOneShotAndOpensConnection() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }

        let model = try makeIsolatedAppModel(userDefaults: defaults)
        model.selection = .tools

        model.requestConnectionAddressSetup()

        #expect(model.selection == .connection)
        #expect(model.connectionAddressSetupRequested)

        model.clearConnectionAddressSetupRequest()
        #expect(model.connectionAddressSetupRequested == false)
    }
}

private func cloudflareZone(id: String, name: String) -> CloudflareZone {
    CloudflareZone(
        id: id,
        name: name,
        accountID: "account-id",
        accountName: "Test Account"
    )
}

private func makeIsolatedDefaults(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> UserDefaults {
    let suiteName = "MacRemoteTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated UserDefaults suite.", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    defaults.set(suiteName, forKey: "MacRemoteTests.suiteName")
    return defaults
}

@MainActor
private func makeIsolatedAppModel(
    userDefaults: UserDefaults,
    cloudflaredPath: String? = "/usr/bin/true",
    runTokenStore: CloudflareRunTokenStore? = nil
) throws -> AppModel {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
    return makeTestAppModel(
        userDefaults: userDefaults,
        toolStore: store,
        cloudflaredManager: makeIsolatedCloudflaredManager(externalPath: cloudflaredPath),
        cloudflareRunTokenStore: runTokenStore
    )
}

/// The state a deploy leaves behind, as the next launch finds it: Your Domain
/// chosen, the deployed address in preferences, its run token in a stand-in
/// Keychain, and a script in place of Cloudflare's helper. No API token and no
/// Wrangler exist anywhere in it.
@MainActor
private struct DeployedDomainRelaunch {
    let defaults: UserDefaults
    let runTokenStore = CloudflareRunTokenStore(keychain: InMemoryKeychainSecretStore())
    let helper: TunnelScriptFixture

    init(helper body: String) throws {
        defaults = try makeIsolatedDefaults()
        helper = try makeTunnelScript(body)
        defaults.set("yourDomain", forKey: "MacRemote.addressMode")

        let deployed = try makeIsolatedAppModel(userDefaults: defaults, runTokenStore: runTokenStore)
        deployed.cloudflareDraft.selectedZoneID = "zone-id"
        deployed.cloudflareDraft.subdomain = "macremote-m5"
        deployed.rememberCloudflareDomain(CloudflareCustomDomainDeployment(
            zone: cloudflareZone(id: "zone-id", name: "example.com"),
            hostname: "macremote-m5.example.com",
            tunnelID: "tunnel-id",
            tunnelName: CloudflareService.tunnelName(hostname: "macremote-m5.example.com"),
            tunnelToken: "tunnel-secret",
            localPort: 54_900
        ))
    }

    /// A new model over the same preferences and Keychain, with its local
    /// server running on `localPort`.
    func makeRelaunchedModel(localPort: Int = 54_900) async throws -> AppModel {
        let model = try makeIsolatedAppModel(
            userDefaults: defaults,
            cloudflaredPath: helper.executable.path,
            runTokenStore: runTokenStore
        )
        // The model looks for Cloudflare's helper in the background at launch
        // and refreshes the link status when that lands. Let it land first.
        await waitUntil { !model.cloudflaredHelperState.isWorking }
        let localServerURL = URL(string: "http://127.0.0.1:\(localPort)")!
        model.localServerURL = localServerURL
        model.serverStatus = .running(localServerURL)
        model.refreshTunnelStatus()
        return model
    }

    func helperFile(_ name: String) throws -> String {
        try String(contentsOf: helper.directory.appendingPathComponent(name), encoding: .utf8)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: helper.directory)
        defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
    }
}

/// Waits for main-actor state that changes when a helper event arrives.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() {
        try? await Task.sleep(for: .milliseconds(10))
    }
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}

private struct TunnelScriptFixture {
    let directory: URL
    let executable: URL

    /// Lets a gated script continue past its `read line < "$gate"`. Waits for
    /// the script to reach that line instead of guessing how long it takes.
    func openGate() async throws {
        let gate = directory.appendingPathComponent("gate").path
        for _ in 0..<500 {
            let descriptor = open(gate, O_WRONLY | O_NONBLOCK)
            if descriptor >= 0 {
                _ = write(descriptor, "go\n", 3)
                close(descriptor)
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NSError(domain: "MacRemoteTunnelServiceTests", code: 2)
    }
}

/// A stand-in for Cloudflare's helper. A gated script can stop at
/// `read line < "$gate"` until the test calls `openGate()`.
private func makeTunnelScript(gated: Bool = false, _ body: String) throws -> TunnelScriptFixture {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacRemoteTunnelServiceTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("cloudflared-fixture")
    var contents = "#!/bin/sh\n\(body)\n"
    if gated {
        let gate = directory.appendingPathComponent("gate").path
        guard mkfifo(gate, 0o600) == 0 else {
            throw NSError(domain: "MacRemoteTunnelServiceTests", code: 3)
        }
        contents = "#!/bin/sh\ngate='\(gate)'\n\(body)\n"
    }
    guard FileManager.default.createFile(atPath: executable.path, contents: Data(contents.utf8)) else {
        throw NSError(domain: "MacRemoteTunnelServiceTests", code: 1)
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return TunnelScriptFixture(directory: directory, executable: executable)
}

private func namedTunnelDeployment() -> CloudflareCustomDomainDeployment {
    CloudflareCustomDomainDeployment(
        zone: cloudflareZone(id: "zone-id", name: "example.com"),
        hostname: "macremote.example.com",
        tunnelID: "tunnel-id",
        tunnelName: "macremote-macremote-example-com",
        tunnelToken: "tunnel-token",
        localPort: 8765
    )
}

private extension TunnelServiceEvent {
    var isStarted: Bool {
        if case .started = self { return true }
        return false
    }

    var isConnectionLost: Bool {
        if case .connectionLost = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var isRunTokenRefused: Bool {
        if case .runTokenRefused = self { return true }
        return false
    }
}

/// What the fake helper status page answers, set by the test.
private final class ReadyConnectionsAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var storedAnswer: Int?
    private var storedURLs: [URL] = []

    var answer: Int? {
        get { lock.withLock { storedAnswer } }
        set { lock.withLock { storedAnswer = newValue } }
    }

    var askedURLs: [URL] {
        lock.withLock { storedURLs }
    }

    func ask(_ url: URL) -> Int? {
        lock.withLock {
            storedURLs.append(url)
            return storedAnswer
        }
    }
}

/// A Your Domain link that has started and registered one connection, with a
/// helper status page the test controls.
private struct ConnectedTunnelFixture {
    let script: TunnelScriptFixture
    let service: TunnelService
    let recorder = TunnelEventRecorder()
    let probe = ReadyConnectionsAnswer()
    let publicURL: URL

    init() async throws {
        script = try makeTunnelScript("""
        printf '%s\\n' 'INF Starting metrics server on 127.0.0.1:20241/metrics'
        printf '%s\\n' 'INF Registered tunnel connection connIndex=0'
        exec /usr/bin/tail -f /dev/null
        """)
        let path = script.executable.path
        service = TunnelService(namedStartupTimeout: 30, readyConnections: { [probe] url in probe.ask(url) }) { path }
        let deployment = namedTunnelDeployment()
        publicURL = deployment.publicURL
        try service.startNamedTunnel(deployment: deployment) { [recorder] in recorder.record($0) }
        _ = await waitForTunnelEvent(recorder, matching: \.isStarted)
    }

    var status: TunnelStatus {
        service.status(localServerURL: URL(string: "http://127.0.0.1:8765")!)
    }

    func tearDown() {
        service.stop()
        try? FileManager.default.removeItem(at: script.directory)
    }
}

/// A helper status page whose first answer, "no connections", is held back
/// until the test releases it. Later checks get no answer.
private actor SlowFirstAnswer {
    private var asked = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func next() async -> Int? {
        guard !asked else { return nil }
        asked = true
        resumeWaiters()
        while !released {
            await withCheckedContinuation { waiters.append($0) }
        }
        return 0
    }

    func waitUntilAsked() async {
        while !asked {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        released = true
        resumeWaiters()
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters = []
        pending.forEach { $0.resume() }
    }
}

private final class TunnelEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events = [TunnelServiceEvent]()

    func record(_ event: TunnelServiceEvent) {
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [TunnelServiceEvent] {
        lock.withLock { events }
    }
}

private func waitForTunnelEvent(
    _ recorder: TunnelEventRecorder,
    matching predicate: (TunnelServiceEvent) -> Bool
) async -> [TunnelServiceEvent] {
    for _ in 0..<200 {
        let events = recorder.snapshot()
        if events.contains(where: predicate) {
            return events
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return recorder.snapshot()
}

/// The tether logic, run in-process against stand-in "app" and "helper"
/// processes. The real tether is the app executable started with
/// `HelperTether.flag`.
struct HelperTetherTests {
    private func sleeper(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        return process
    }

    @Test func helperIsStoppedWhenTheAppExits() async throws {
        let app = try sleeper("0.3")
        let helper = try sleeper("30")
        defer { helper.terminate() }

        // A process that is not the expected helper is never signalled.
        #expect(HelperTether.watch(
            appPID: app.processIdentifier,
            helperPID: helper.processIdentifier,
            helperPath: "/usr/bin/true"
        ) == .notWatching)
        #expect(helper.isRunning)

        let appPID = app.processIdentifier
        let helperPID = helper.processIdentifier
        let outcome = await Task.detached {
            HelperTether.watch(appPID: appPID, helperPID: helperPID, helperPath: "/bin/sleep")
        }.value
        #expect(outcome == .stoppedHelper)
        helper.waitUntilExit()
        #expect(helper.terminationReason == .uncaughtSignal)
        #expect(helper.terminationStatus == SIGTERM)
    }

    @Test func tetherLeavesWhenTheHelperExitsFirst() async throws {
        let app = try sleeper("30")
        defer { app.terminate() }
        let helper = try sleeper("0.2")

        let appPID = app.processIdentifier
        let helperPID = helper.processIdentifier
        let outcome = await Task.detached {
            HelperTether.watch(appPID: appPID, helperPID: helperPID, helperPath: "/bin/sleep")
        }.value
        #expect(outcome == .helperExitedFirst)
        #expect(app.isRunning)
    }
}
