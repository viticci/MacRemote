import AppKit
import SwiftUI
import UserNotifications

// MARK: - Connection (SPEC §4 — the cockpit; absorbs Dashboard + Tunnel)

struct ConnectionView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @SceneStorage("connection.readinessCollapsed") private var isReadinessCollapsed = false
    @SceneStorage("connection.addressCollapsed") private var isAddressCollapsed = true

    var body: some View {
        @Bindable var appModel = appModel

        ZStack {
            // The app's single backgroundExtensionEffect (GUIDELINES §3) — the
            // state-tinted wash extends under the sidebar (D5).
            ConnectionCanvasWash(role: washRole)
                .backgroundExtensionEffect()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s6) {
                        heroSection
                        subFactsLine
                        SetupChecklistSection()
                        statusTileGrid
                        if !isReadinessCollapsed {
                            ConnectionReadinessCard(isCollapsed: $isReadinessCollapsed)
                                .id("connection.readiness")
                        }
                        if !isAddressCollapsed {
                            ConnectionAddressCard(isCollapsed: $isAddressCollapsed)
                                .id("connection.address")
                        }
                        activityStrip
                    }
                    .padding(Space.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onChange(of: appModel.readinessRowToExpand) { _, row in
                    guard row != nil else { return }
                    withAnimation(reduceMotion ? nil : .snappy) {
                        isReadinessCollapsed = false
                        proxy.scrollTo("connection.readiness", anchor: .top)
                    }
                }
                .onChange(of: appModel.connectionAddressSetupRequested) { _, requested in
                    guard requested else { return }
                    revealAddressSetup(using: proxy)
                }
                .onAppear {
                    if appModel.readinessRowToExpand != nil {
                        isReadinessCollapsed = false
                        proxy.scrollTo("connection.readiness", anchor: .top)
                    }
                    if appModel.connectionAddressSetupRequested {
                        revealAddressSetup(using: proxy)
                    }
                }
            }
        }
        .pageContainerShape()
        .navigationTitle("Connection")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                serverToggleButton
                Button("Copy URL", systemImage: "doc.on.doc") {
                    appModel.copyPublicURL()
                }
                .disabled(appModel.currentPublicMCPURL == nil)
                .help("Copy Public URL")
            }
        }
        .confirmationDialog(
            "Go public?",
            isPresented: $appModel.goPublicConfirmationRequested
        ) {
            Button("Go Public") {
                appModel.startTunnel()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(goPublicMessage)
        }
    }

    private func revealAddressSetup(using proxy: ScrollViewProxy) {
        withAnimation(reduceMotion ? nil : .snappy) {
            isAddressCollapsed = false
        }
        Task { @MainActor in
            await Task.yield()
            withAnimation(reduceMotion ? nil : .snappy) {
                proxy.scrollTo("connection.address", anchor: .top)
            }
            appModel.clearConnectionAddressSetupRequest()
        }
    }

    // MARK: Status tile grid (collapsed cards live here; open cards render full-width below)

    private var statusTileGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240, maximum: 420), spacing: Space.s4, alignment: .topLeading)],
            alignment: .leading,
            spacing: Space.s4
        ) {
            if isReadinessCollapsed {
                ConnectionReadinessTile {
                    withAnimation(reduceMotion ? nil : .snappy) { isReadinessCollapsed = false }
                }
            }
            if isAddressCollapsed {
                ConnectionAddressTile {
                    withAnimation(reduceMotion ? nil : .snappy) { isAddressCollapsed = false }
                }
            }
        }
    }

    // MARK: Hero

    private var heroSection: some View {
        ConnectionHero(state: heroState, actions: heroActions)
            .frame(maxWidth: .infinity)
            .padding(.top, Space.s8)
            .opacity(isSweeping ? 0.92 : 1)
            .animation(.easeInOut(duration: 0.3), value: isSweeping)
    }

    private var heroState: ConnectionHeroState {
        let exposure = appModel.toolExposureSummary
        switch appModel.serverStatus {
        case .starting:
            return .starting
        case .failed(let message):
            if exposure.total == 0 || message == "Share at least one tool before starting the local server." {
                return .zeroTools
            }
            return .failed(message: message)
        case .stopped:
            return exposure.total == 0 ? .zeroTools : .off
        case .running:
            switch appModel.tunnelStatus {
            case .starting, .reconnecting:
                return .publicPending
            case .running(let baseURL):
                return .publicRunning(
                    url: appModel.publicMCPURL(for: baseURL).absoluteString,
                    captions: publicCaptions(baseURL)
                )
            case .failed(let message):
                return .partialFailure(message: message)
            case .ready, .stopped, .unavailable:
                return .local(
                    localURL: appModel.localServerURL?.absoluteString ?? "http://127.0.0.1",
                    canGoPublic: appModel.tunnelStatus != .unavailable
                )
            }
        }
    }

    private func publicCaptions(_ baseURL: URL) -> [String] {
        var lines: [String] = []
        if let deployment = appModel.lastCloudflareDeployment, baseURL.host() == deployment.hostname {
            lines.append("Cloudflare Tunnel · Your Domain · stable address")
        } else {
            lines.append("Cloudflare Tunnel · Instant Link · changes when you go public again")
        }
        if let localURL = appModel.localServerURL, let host = localURL.host(), let port = localURL.port {
            lines.append("Forwards only to MacRemote's local server (\(host):\(port))")
        }
        return lines
    }

    private var heroActions: ConnectionHeroActions {
        ConnectionHeroActions(
            startServer: { appModel.startLocalServer() },
            stopServer: { appModel.stopLocalServer() },
            goPublic: { appModel.requestGoPublic() },
            stopSharing: { appModel.stopTunnel() },
            retry: retryAction,
            openTools: { appModel.selection = .tools },
            copyPublicURL: { appModel.copyPublicURL() }
        )
    }

    private var retryAction: () -> Void {
        if case .partialFailure = heroState {
            return { appModel.startTunnel() }
        }
        return { appModel.startLocalServer() }
    }

    private var isSweeping: Bool {
        appModel.connectionReadiness.contains { $0.status == .checking }
    }

    // MARK: Canvas + toolbar state

    private var washRole: StatusRole {
        if appModel.hasConnectionFailure {
            return .error
        }
        switch heroState {
        case .publicRunning: return .ready
        case .local, .starting, .publicPending: return .working
        case .off, .zeroTools: return .off
        case .partialFailure, .failed: return .error
        }
    }

    private var subtitle: String {
        var line: String
        switch heroState {
        case .off: line = "Off"
        case .zeroTools: line = "Off — add a tool to start"
        case .starting: line = "Starting"
        case .local: line = "Local only"
        case .publicPending: line = "Waiting for Cloudflare"
        case .publicRunning(let url, _): line = "Public — \(URL(string: url)?.host() ?? url)"
        case .partialFailure: line = "Server running · link stopped"
        case .failed: line = "Connection failed"
        }
        let pending = appModel.pendingRequestCount
        if pending > 0 {
            line += " · \(pending) request\(pending == 1 ? "" : "s") waiting"
        }
        return line
    }

    @ViewBuilder
    private var serverToggleButton: some View {
        if appModel.serverStatus.isRunning {
            Button("Stop Server", systemImage: "stop.fill") {
                appModel.stopLocalServer()
            }
            .help("Stop the local server")
        } else {
            Button("Start Server", systemImage: "play.fill") {
                appModel.startLocalServer()
            }
            .disabled(appModel.serverStatus == .starting || appModel.toolExposureSummary.total == 0)
            .help(appModel.toolExposureSummary.total == 0
                  ? "Share at least one tool before starting the local server."
                  : "Start the local server")
        }
    }

    // Canonical rewrite #1 with live counts (GUIDELINES §4.4).
    private var goPublicMessage: String {
        "\(appModel.toolExposureSummary.publicLinkSentence) New apps still need your approval to connect."
    }

    // MARK: Sub-facts line (DA-13/DA-14/TU-35 — every count is a live control)

    private var subFactsLine: some View {
        let summary = appModel.toolExposureSummary
        let appCount = appModel.connectedClients.count
        return HStack(spacing: Space.s2) {
            factButton(count: summary.total, label: summary.total == 1 ? "tool shared" : "tools shared") {
                appModel.selection = .tools
            }
            factSeparator
            factButton(count: summary.readOnly, label: "read-only") {
                appModel.selection = .tools
            }
            factSeparator
            AskFirstFact(count: summary.gatedToolCount, names: summary.nonReadOnlyToolNames)
            factSeparator
            factButton(count: appCount, label: appCount == 1 ? "app" : "apps") {
                appModel.selection = .apps
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var factSeparator: some View {
        Text("·")
            .font(.callout)
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func factButton(count: Int, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("\(count) \(label)")
                .font(.callout)
                .countText()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help("Open \(label.contains("app") ? "Apps" : "Tools")")
    }

    // MARK: Activity strip (DA-17 — dead end fixed)

    private var activityStrip: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                Text("Activity")
                    .font(TypeRamp.cardTitle)
                Text("This session")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Activity") {
                    appModel.selection = .activity
                }
                .buttonStyle(.link)
            }
            if appModel.logs.isEmpty {
                Text("Nothing yet this session.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(appModel.logs.prefix(5)) { entry in
                        ActivityLogRow(
                            time: entry.date,
                            level: activityLevel(entry.level),
                            message: entry.message
                        )
                    }
                }
            }
        }
    }

    private func activityLevel(_ level: AppLogEntry.Level) -> ActivityLogRow.Level {
        switch level {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}

// MARK: - Ask-first fact (DA-14 — capped name-list popover kills the comma wall)

private struct AskFirstFact: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let count: Int
    let names: [String]

    @State private var isShowingNames = false
    @State private var showsAllNames = false

    private static let nameCap = 12

    var body: some View {
        Button {
            showsAllNames = false
            isShowingNames = true
        } label: {
            Text("\(count) ask first")
                .font(.callout)
                .countText()
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help("Which tools ask first?")
        .popover(isPresented: $isShowingNames, arrowEdge: .bottom) {
            popoverContent
        }
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(count == 1 ? "1 tool asks you before running" : "\(count) tools ask you before running")
                .font(TypeRamp.cardTitle)
            Text("Each run stops for your approval on this Mac.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            if !names.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s1) {
                        ForEach(visibleNames, id: \.self) { name in
                            Text(name)
                                .font(.callout)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                if hiddenCount > 0 {
                    Button("and \(hiddenCount) more…") {
                        withAnimation(reduceMotion ? nil : .snappy) {
                            showsAllNames = true
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .padding(Space.s4)
        .frame(width: 300)
    }

    private var visibleNames: [String] {
        showsAllNames ? names : Array(names.prefix(Self.nameCap))
    }

    private var hiddenCount: Int {
        showsAllNames ? 0 : max(0, names.count - Self.nameCap)
    }
}

// MARK: - Canvas wash (D5 — static semantic tint, one 0.6 s ease per transition)

private struct ConnectionCanvasWash: View {
    let role: StatusRole

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !reduceTransparency, contrast != .increased {
                LinearGradient(
                    colors: [role.tint.opacity(role == .error ? 0.26 : 0.15), .clear],
                    startPoint: .top,
                    endPoint: role == .error ? UnitPoint(x: 0.5, y: 0.35) : .bottom
                )
            }
        }
        .ignoresSafeArea()
        // Tint changes only on state transitions; the ease is a crossfade, so
        // Reduce Motion needs no separate path (D5).
        .animation(.easeInOut(duration: 0.6), value: role)
        .accessibilityHidden(true)
    }
}

// MARK: - Setup checklist host (§3 skip behavior + D16 mechanics)

private struct SetupChecklistSection: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("MacRemote.setupChecklistGraduated") private var hasGraduated = false
    @AppStorage("MacRemote.setupChecklistCapsuleDismissed") private var isCapsuleDismissed = false
    @AppStorage("MacRemote.setupChecklistRegressionNotified") private var hasEscalatedRegression = false

    @State private var debouncedFailingStepID: String?
    @State private var regressionTask: Task<Void, Never>?
    @State private var sessionRegressionCount = 0

    var body: some View {
        Group {
            if let display {
                SetupChecklist(
                    steps: steps,
                    display: display,
                    onDismiss: display == .capsule ? { isCapsuleDismissed = true } : nil
                )
            }
        }
        .onChange(of: doneVector) { _, _ in
            reconcile()
        }
        .onAppear {
            reconcile()
        }
    }

    // MARK: Steps (skip behavior — "1 Add tools → 2 Start server → 3 Go public → 4 Connect an app")

    private var steps: [SetupStep] {
        let exposure = appModel.toolExposureSummary
        let serverRunning = appModel.serverStatus.isRunning
        let isPublic = appModel.tunnelStatus.isRunning
        let hasApps = !appModel.connectedClients.isEmpty

        return [
            SetupStep(
                id: "tools",
                title: "Add tools",
                detail: exposure.total > 0 ? nil : "Share at least one tool from the library.",
                isDone: exposure.total > 0,
                jumpTitle: exposure.total > 0 ? nil : "Open Tools",
                jump: exposure.total > 0 ? nil : { appModel.selection = .tools }
            ),
            SetupStep(
                id: "server",
                title: "Start server",
                isDone: serverRunning,
                jumpTitle: serverRunning || exposure.total == 0 ? nil : "Start Server",
                jump: serverRunning || exposure.total == 0 ? nil : { appModel.startLocalServer() }
            ),
            SetupStep(
                id: "public",
                title: "Go public",
                isDone: isPublic,
                jumpTitle: isPublic || !serverRunning ? nil : "Go Public…",
                jump: isPublic || !serverRunning ? nil : { appModel.requestGoPublic() }
            ),
            SetupStep(
                id: "app",
                title: "Connect an app",
                // An app can be "done" from an earlier session while steps 2–3
                // are not — explain it so the sequence doesn't look impossible.
                detail: hasApps
                    ? (isPublic ? nil : "Connected before — it reaches this Mac again when you go public.")
                    : "Paste your public link into the app; it asks to connect.",
                isDone: hasApps,
                jumpTitle: hasApps ? "Open Apps" : nil,
                jump: hasApps ? { appModel.selection = .apps } : nil
            )
        ]
    }

    private var doneVector: [Bool] {
        steps.map(\.isDone)
    }

    private var allDone: Bool {
        doneVector.allSatisfy(\.self)
    }

    private var firstFailingStepID: String? {
        steps.first { !$0.isDone }?.id
    }

    private var display: SetupChecklistDisplay? {
        guard appModel.isSetupChecklistEnabled else { return nil }
        if !hasGraduated {
            return .expanded
        }
        if allDone {
            return isCapsuleDismissed ? nil : .capsule
        }
        if let debouncedFailingStepID {
            return .regression(failingStepID: debouncedFailingStepID)
        }
        // Inside the 30 s debounce window the capsule holds steady (D16).
        return isCapsuleDismissed ? nil : .capsule
    }

    // MARK: D16 mechanics — graduation, 30 s regression debounce, one-shot escalation

    private func reconcile() {
        if !hasGraduated {
            // Upgrader seeding: a user with tools AND a previously connected app
            // has plainly finished setup before this key existed — land them on
            // the capsule/regression view, not the raw expanded first-run list.
            let isEstablishedUser = appModel.toolExposureSummary.total > 0
                && !appModel.connectedClients.isEmpty
            if allDone || isEstablishedUser {
                withAnimation(reduceMotion ? nil : .snappy) {
                    hasGraduated = true
                }
            }
            return
        }

        if allDone {
            regressionTask?.cancel()
            regressionTask = nil
            if debouncedFailingStepID != nil {
                withAnimation(reduceMotion ? nil : .snappy) {
                    debouncedFailingStepID = nil
                }
            }
            return
        }

        guard regressionTask == nil, debouncedFailingStepID == nil else { return }
        regressionTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            regressionTask = nil
            guard let failing = firstFailingStepID else { return }
            withAnimation(reduceMotion ? nil : .snappy) {
                debouncedFailingStepID = failing
            }
            sessionRegressionCount += 1
            if sessionRegressionCount >= 2, !hasEscalatedRegression {
                postRegressionNotification(for: failing)
                hasEscalatedRegression = true
            }
        }
    }

    private func postRegressionNotification(for stepID: String) {
        guard Bundle.main.bundleIdentifier != nil,
              appModel.notificationPermissionStatus == .authorized,
              let step = steps.first(where: { $0.id == stepID }) else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Setup needs attention"
        content.body = "\(step.title) stopped passing. Open MacRemote to fix it."
        let request = UNNotificationRequest(
            identifier: "macremote.setupChecklist.regression",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
