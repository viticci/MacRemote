import AppKit
import SwiftUI

// MARK: - Welcome window (SPEC §3 — five screens, progress dots, every screen skippable)
//
// Material discipline per GUIDELINES §3: no direct glass-effect calls here. Glass enters
// only through the embedded ConnectionHero (S4) and the system
// `.glass`/`.glassProminent` button styles on onboarding primaries.

private enum WelcomeScreen: Int, CaseIterable, Identifiable {
    case welcome
    case pickTools
    case permissions
    case connection
    case connectApp

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .pickTools: "Pick what this Mac can share"
        case .permissions: "Some tools need permission first"
        case .connection: "Start the connection"
        case .connectApp: "Connect your app"
        }
    }
}

/// Keeps the clean-Mac starter choice explicit and testable without inventing
/// a second catalog. The preset remains inert until the user selects its card
/// and presses Add Tools.
enum WelcomeToolChoices {
    static let currentDateBundleID = "welcome.current-date"
    static let currentDatePresetID = "preset.utilities.current_date"

    static func bundles(
        catalogBundles: [DefaultToolPresetSet],
        currentDatePreset: DefaultToolPreset?
    ) -> [DefaultToolPresetSet] {
        guard let currentDatePreset,
              !catalogBundles.contains(where: { $0.id == currentDateBundleID }) else {
            return catalogBundles
        }
        return catalogBundles + [
            DefaultToolPresetSet(
                id: currentDateBundleID,
                name: currentDatePreset.name,
                summary: "A safe starter tool that returns the current local timestamp.",
                presets: [currentDatePreset]
            )
        ]
    }

    static func initialSelection(in bundles: [DefaultToolPresetSet]) -> Set<String> {
        bundles.contains(where: { $0.id == "set.detected_clis" }) ? ["set.detected_clis"] : []
    }

    static func selectedPresets(
        in bundles: [DefaultToolPresetSet],
        selectedBundleIDs: Set<String>
    ) -> [DefaultToolPreset] {
        var seen = Set<String>()
        return bundles
            .filter { selectedBundleIDs.contains($0.id) }
            .flatMap(\.presets)
            .filter { seen.insert($0.id).inserted }
    }

    static func canStartConnection(sharedToolCount: Int) -> Bool {
        sharedToolCount > 0
    }

    static func addButtonTitle(selectedCount: Int, newCount: Int) -> String {
        guard selectedCount > 0 else { return "Add Tools" }
        if newCount == 0 { return "Continue" }
        return newCount == 1 ? "Add 1 Tool" : "Add \(newCount) Tools"
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var screen: WelcomeScreen = .welcome
    @State private var bundles: [DefaultToolPresetSet] = []
    @State private var presetsBySetID: [String: [DefaultToolPreset]] = [:]
    @State private var selectedBundleIDs: Set<String> = []
    @State private var addToolsError: String?
    @State private var goPublicAfterStart = false
    @State private var expandAll = DetailsExpandAll()
    @State private var lingeringInterrupt: PendingInterrupt?
    @State private var lingeringPhase: ApprovalCard.Phase?
    @State private var hasResolvedRequestHere = false
    @State private var lingerTask: Task<Void, Never>?
    @State private var installedHelperHere = false
    @State private var helperLingerTask: Task<Void, Never>?
    @AppStorage("MacRemote.addressMode") private var storedAddressMode = AddressMode.instantLink.rawValue

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch screen {
                case .welcome: welcomeScreen
                case .pickTools: pickToolsScreen
                case .permissions: permissionsScreen
                case .connection: connectionScreen
                case .connectApp: connectAppScreen
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            .id(screen)

            footer
        }
        .padding(Space.s5)
        .pageContainerShape()
        .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: screen)
        .onAppear(perform: loadBundles)
        .onChange(of: appModel.serverStatus) { _, newValue in
            if case .running = newValue, goPublicAfterStart {
                goPublicAfterStart = false
                appModel.startTunnel()
            }
            if case .failed = newValue {
                goPublicAfterStart = false
            }
        }
        // S3 embeds the Access Fixer itself, so the app-global FDA sheet (which
        // Check Again re-presents in the main window) is absorbed while it shows.
        .onChange(of: appModel.fullDiskAccessPrompt) { _, newValue in
            if screen == .permissions, newValue != nil {
                appModel.dismissFullDiskAccessPrompt()
            }
        }
        .onChange(of: appModel.fullDiskAccessReport.isReady) { _, isReady in
            if screen == .permissions, isReady {
                advance(from: .permissions)
            }
        }
        .onDisappear {
            lingerTask?.cancel()
            helperLingerTask?.cancel()
        }
    }

    // MARK: - Screen 1 — Welcome

    private var welcomeScreen: some View {
        ScrollView {
            VStack(spacing: Space.s6) {
                iconArtwork
                Text("Your Mac, on call.")
                    .font(TypeRamp.welcomeTitle)
                Text("MacRemote lets ChatGPT, Claude, and other MCP apps use tools on this Mac.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)

                VStack(alignment: .leading, spacing: Space.s3) {
                    valueRow("wrench.and.screwdriver", "Share only the tools you choose")
                    valueRow("person.badge.key", "Choose how apps sign in")
                    valueRow("lock.shield", "Keep risky tools behind an approval")
                }

                if WelcomeInstallLocation.needsApplicationsMove(bundleURL: Bundle.main.bundleURL) {
                    installLocationNotice
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Space.s6)
            .padding(.bottom, Space.s1)
        }
    }

    private var installLocationNotice: some View {
        HStack(alignment: .center, spacing: Space.s3) {
            Image(systemName: "folder.badge.plus")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Move MacRemote to Applications, then reopen it there. This keeps macOS permissions attached to one copy.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Applications") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: 520)
        .background(.quaternary.opacity(0.4), in: AppShape.mono)
    }

    private var iconArtwork: some View {
        ZStack {
            // Brand azure lives only in onboarding artwork (GUIDELINES §1.4).
            LinearGradient(
                colors: [
                    Color(red: 0x45 / 255, green: 0xA0 / 255, blue: 0xFA / 255).opacity(0.55),
                    Color(red: 0x89 / 255, green: 0xCA / 255, blue: 0xF9 / 255).opacity(0.35)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(nsImage: appIcon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 96, height: 96)
        }
        .frame(maxWidth: 480, maxHeight: 150)
        .clipShape(AppShape.card)
        .accessibilityHidden(true)
    }

    private var appIcon: NSImage {
        NSApp?.applicationIconImage ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    private func valueRow(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: Space.s3) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 24)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
        }
    }

    // MARK: - Screen 2 — Pick what this Mac can share

    private var pickToolsScreen: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(WelcomeScreen.pickTools.title)
                .font(TypeRamp.heroStatus)
            Text("Choose an available bundle or start with Current Date, a safe tool built into macOS. You can change everything later.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s3) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Space.s3)], spacing: Space.s3) {
                        ForEach(bundles) { bundle in
                            bundleCard(bundle)
                        }
                    }

                    if !selectedPresets.isEmpty {
                        DetailsDisclosure("Show selected tools", id: "welcome.selectedTools", expandAll: $expandAll) {
                            VStack(alignment: .leading, spacing: Space.s2) {
                                ForEach(selectedPresets, id: \.id) { preset in
                                    HStack(spacing: Space.s2) {
                                        Text(preset.name)
                                            .font(TypeRamp.rowDetail)
                                        StateChip(capability: preset.capability)
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }

                }
                .padding(.vertical, Space.s1)
            }

            selectionFooter
        }
    }

    private func bundleCard(_ bundle: DefaultToolPresetSet) -> some View {
        let isSelected = selectedBundleIDs.contains(bundle.id)
        let count = presetsBySetID[bundle.id]?.count ?? 0
        return Button {
            if isSelected {
                selectedBundleIDs.remove(bundle.id)
            } else {
                selectedBundleIDs.insert(bundle.id)
            }
            addToolsError = nil
        } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("\(bundle.name) · \(counted(count, "tool"))")
                        .font(TypeRamp.cardTitle)
                        .multilineTextAlignment(.leading)
                    Text(bundle.summary)
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                in: AppShape.card
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private var selectionFooter: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s1) {
                Text("\(counted(selectedPresets.count, "tool")) selected")
                    .countText()
                Text("·")
                Text("\(selectedAsksFirstCount) will ask you before running")
                    .countText()
                if !selectedPresets.isEmpty && newSelectedCount == 0 {
                    Text("·")
                    Text("all already on this Mac")
                        .countText()
                } else if newSelectedCount > 0 && newSelectedCount < selectedPresets.count {
                    Text("·")
                    Text("\(newSelectedCount) new")
                        .countText()
                }
            }
            // Errors live here, outside the scroll view, so they can never
            // land below the fold after a tall bundle grid.
            if let addToolsError {
                Text(addToolsError)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.orange)
            }
        }
        .font(TypeRamp.rowDetail)
        .foregroundStyle(.secondary)
    }

    private var selectedPresets: [DefaultToolPreset] {
        WelcomeToolChoices.selectedPresets(
            in: bundles,
            selectedBundleIDs: selectedBundleIDs
        )
    }

    private var selectedAsksFirstCount: Int {
        selectedPresets.count { $0.capability != .readOnly }
    }

    private func loadBundles() {
        guard bundles.isEmpty else { return }
        let sets = WelcomeToolChoices.bundles(
            catalogBundles: DefaultToolPresetCatalog.presetSets,
            currentDatePreset: DefaultToolPresetCatalog.preset(id: WelcomeToolChoices.currentDatePresetID)
        )
        bundles = sets
        presetsBySetID = Dictionary(uniqueKeysWithValues: sets.map { ($0.id, $0.presets) })
        selectedBundleIDs = WelcomeToolChoices.initialSelection(in: sets)
    }

    private func addSelectedTools() {
        let presets = selectedPresets
        guard newSelectedCount > 0 else {
            // Everything selected is already installed — that's success, not an error.
            advance(from: .pickTools)
            return
        }
        let sourceNames = bundles
            .filter { selectedBundleIDs.contains($0.id) }
            .map(\.name)
            .joined(separator: ", ")
        let error = appModel.addUserTools(from: presets, sourceName: sourceNames)
        if let error {
            addToolsError = error
        } else {
            advance(from: .pickTools)
        }
    }

    // MARK: - Screen 3 — Some tools need permission first (conditional)

    private var permissionsScreen: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(permissionsTitle)
                .font(TypeRamp.heroStatus)
            permissionsBody
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if !privacyServicesToPrime.isEmpty {
                        VStack(alignment: .leading, spacing: Space.s2) {
                            HStack(spacing: Space.s2) {
                                ForEach(privacyServicesToPrime, id: \.self) { service in
                                    StateChip(service.title, systemImage: service.systemImage, tint: .secondary)
                                }
                            }
                            Text("macOS will ask when the first call happens — approve it once.")
                                .font(TypeRamp.truthNote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if needsFullDiskAccessPriming {
                        Card {
                            AccessFixer(
                                state: accessFixerState,
                                targets: appModel.fullDiskAccessReport.targets,
                                automaticChecksPassed: appModel.fullDiskAccessReport.automaticChecksPassed,
                                actions: accessFixerActions,
                                onCopyTarget: copyAccessTarget,
                                onRevealTarget: revealAccessTarget
                            )
                        }
                    }
                }
                .padding(.vertical, Space.s1)
            }
        }
    }

    /// Reachable from the progress dots even when nothing needs a permission,
    /// so the empty case has to say so instead of implying a task.
    private var permissionsTitle: String {
        permissionClauses.isEmpty ? "Nothing needs permission yet" : WelcomeScreen.permissions.title
    }

    private var permissionClauses: [String] {
        var clauses: [String] = []
        let services = privacyServicesToPrime
        if !services.isEmpty {
            if services == [.reminders] {
                clauses.append("Reminders tools need macOS's OK to read your reminders")
            } else {
                let names = services.map(\.title).formatted(.list(type: .and))
                clauses.append("\(names) tools need macOS's OK")
            }
        }
        if fullDiskAccessToolCount > 0 {
            clauses.append(fullDiskAccessToolCount == 1
                ? "1 tool needs Full Disk Access"
                : "\(fullDiskAccessToolCount) tools need Full Disk Access")
        }
        return clauses
    }

    private var permissionsBody: Text {
        let clauses = permissionClauses
        guard !clauses.isEmpty else {
            return Text("Nothing you've shared needs a macOS permission right now. If that changes, Readiness says so on the Connection page.")
        }
        let lead = clauses.joined(separator: ", and ")
        return Text("\(lead). MacRemote never grants itself anything — you do it in System Settings, and macOS asks the first time a tool runs. \(Text("MacRemote can't read anything you don't approve.").fontWeight(.semibold))")
    }

    private var sharedTools: [ToolDefinition] {
        appModel.allTools.filter { appModel.isToolExposed($0) }
    }

    private var privacyServicesToPrime: [ToolPermissionRequirement] {
        let requirements = sharedTools
            .flatMap(\.permissionRequirements)
            .filter { !$0.isFullDiskAccess }
        return ToolPermissionRequirement.normalized(requirements)
    }

    private var fullDiskAccessToolCount: Int {
        sharedTools.count { $0.permissionRequirements.contains(.fullDiskAccess) }
    }

    private var needsFullDiskAccessPriming: Bool {
        fullDiskAccessToolCount > 0 && !appModel.fullDiskAccessReport.isReady
    }

    private var needsPermissionScreen: Bool {
        needsFullDiskAccessPriming
            || (!privacyServicesToPrime.isEmpty && !appModel.macOSPrivacyAccessReport.isReady)
    }

    private var accessFixerState: AccessFixerState {
        switch appModel.fullDiskAccessReport.state {
        case .checking: .checking
        case .ready: .ready
        case .failed(let message): .failed(message)
        case .confirmationRequired: .confirmSetup
        case .unknown, .required, .helperOpened: .required
        }
    }

    private var accessFixerActions: AccessFixerActions {
        AccessFixerActions(
            checkAgain: { appModel.checkFullDiskAccess() },
            openSystemSettings: { appModel.openFullDiskAccessHelper() },
            later: { advance(from: .permissions) },
            relaunch: { appModel.relaunchMacRemote() },
            readdInSystemSettings: { appModel.resetMacRemoteFullDiskAccessGrant() },
            confirmSetup: appModel.fullDiskAccessReport.requiresManualConfirmation
                ? { appModel.confirmFullDiskAccessSetup() }
                : nil,
            copyAllPaths: {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(
                    appModel.fullDiskAccessReport.targets.map(\.path).joined(separator: "\n"),
                    forType: .string
                )
                appModel.appendLog(level: .info, "Copied all Full Disk Access target paths.")
            },
            copyFirstTarget: {
                if let first = appModel.fullDiskAccessReport.targets.first {
                    copyAccessTarget(first)
                }
            },
            openConnectionReadiness: {
                appModel.revealReadinessRow(.fullDiskAccess)
                appModel.openMainWindow()
            }
        )
    }

    private func copyAccessTarget(_ target: FullDiskAccessTarget) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(target.path, forType: .string)
        pasteboard.setString(URL(fileURLWithPath: target.path).absoluteString, forType: .fileURL)
        appModel.appendLog(level: .info, "Copied Full Disk Access target: \(target.title).")
    }

    private func revealAccessTarget(_ target: FullDiskAccessTarget) {
        NSWorkspace.shared.selectFile(target.path, inFileViewerRootedAtPath: "")
        appModel.appendLog(level: .info, "Revealed Full Disk Access target: \(target.title).")
    }

    // MARK: - Screen 4 — Start the connection

    private var connectionScreen: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(WelcomeScreen.connection.title)
                .font(TypeRamp.heroStatus)
            Text("Start locally first. For your other devices, choose one Cloudflare public link. Both choices share only the tools you picked and don't open ports on your network.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    publicAddressChoice

                    ConnectionHero(state: heroState, isCompact: true, actions: heroActions)
                        .frame(maxWidth: .infinity)

                    if showsHelperRow {
                        cloudflaredMissingRow
                    }

                    Text("If macOS asks about incoming connections, allow it — that's the local server.")
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)

                    Text("Apps on this Mac can connect over the local server. Your other devices need your public link.")
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if showsReadinessTicker {
                        readinessTicker
                    }

                    if addressMode == .instantLink,
                       appModel.toolExposureSummary.total > 0,
                       !appModel.tunnelStatus.isRunning {
                        Text(exposureSummarySentence)
                            .font(TypeRamp.truthNote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, Space.s1)
            }
        }
        .onAppear {
            appModel.refreshTunnelStatus()
        }
        .onChange(of: appModel.cloudflaredHelperState) { previous, current in
            handleHelperStateChange(from: previous, to: current)
        }
    }

    private var addressMode: AddressMode {
        AddressMode(rawValue: storedAddressMode) ?? .instantLink
    }

    private var publicAddressChoice: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Choose a public address")
                .font(TypeRamp.cardTitle)

            HStack(alignment: .top, spacing: Space.s3) {
                ForEach(AddressMode.allCases) { option in
                    publicAddressOption(option)
                }
            }

            if addressMode == .yourDomain {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Before you set up Your Domain")
                        .font(TypeRamp.cardTitle)
                    ForEach(Array(addressMode.welcomeRequirements.enumerated()), id: \.offset) { index, requirement in
                        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                            Text("\(index + 1)")
                                .font(TypeRamp.chip)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(requirement)
                                .font(TypeRamp.rowDetail)
                        }
                    }
                }
                .padding(Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: AppShape.mono)
            }
        }
    }

    private func publicAddressOption(_ option: AddressMode) -> some View {
        let isSelected = option == addressMode
        return Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                storedAddressMode = option.rawValue
            }
        } label: {
            HStack(alignment: .top, spacing: Space.s2) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : option.welcomeSymbol)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(option.welcomeTitle)
                        .font(TypeRamp.cardTitle)
                    Text(option.welcomeDetail)
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.4)),
                in: AppShape.card
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    /// The helper row would otherwise vanish the instant the install lands,
    /// leaving the work with no visible ending. It stays for the same beat the
    /// approval card lingers, showing "Cloudflare's helper is ready."
    private var showsHelperRow: Bool {
        appModel.tunnelStatus == .unavailable
            || appModel.cloudflaredHelperState.isWorking
            || installedHelperHere
    }

    private func handleHelperStateChange(
        from previous: CloudflaredHelperState,
        to current: CloudflaredHelperState
    ) {
        guard screen == .connection else { return }
        switch current {
        case .ready, .updateAvailable:
            guard previous.isWorking else { return }
            installedHelperHere = true
            // The status the hero and footer read from is derived, so refresh
            // it here rather than waiting for the next thing to touch it.
            appModel.refreshTunnelStatus()
            helperLingerTask?.cancel()
            helperLingerTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                installedHelperHere = false
            }
        default:
            helperLingerTask?.cancel()
            installedHelperHere = false
        }
    }

    /// D44 — the managed Cloudflare helper offer, shared verbatim with the
    /// Address card so onboarding and the Connection page can't disagree.
    private var cloudflaredMissingRow: some View {
        CloudflaredHelperSetup(disclosureID: "welcome.cloudflaredHelper")
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: AppShape.mono)
    }

    private var showsReadinessTicker: Bool {
        switch appModel.serverStatus {
        case .stopped: false
        case .starting, .running, .failed: true
        }
    }

    private var readinessTicker: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(appModel.connectionReadiness) { check in
                HStack(spacing: Space.s2) {
                    Image(systemName: readinessRole(check.status).symbolName)
                        .foregroundStyle(readinessRole(check.status).tint)
                        .accessibilityHidden(true)
                    Text(check.title)
                        .font(TypeRamp.rowDetail)
                    Spacer(minLength: Space.s3)
                    Text(check.detail)
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(check.title): \(check.status.title). \(check.detail)")
            }
        }
        .padding(Space.s3)
        .background(.quaternary.opacity(0.4), in: AppShape.card)
    }

    private func readinessRole(_ status: ReadinessStatus) -> StatusRole {
        switch status {
        case .ready: .ready
        case .checking: .working
        case .warning: .attention
        case .blocked: .error
        case .waiting: .off
        }
    }

    /// Canonical rewrite #1 (GUIDELINES §4.4) with real counts — the inline
    /// exposure summary that replaces the Go-public dialog on this screen only.
    private var exposureSummarySentence: String {
        "\(appModel.toolExposureSummary.publicLinkSentence) New apps must use the sign-in method you chose."
    }

    private var heroState: ConnectionHeroState {
        switch appModel.serverStatus {
        case .starting:
            return .starting
        case .failed(let message):
            return .failed(message: message)
        case .stopped:
            return appModel.toolExposureSummary.total == 0 ? .zeroTools : .off
        case .running:
            switch appModel.tunnelStatus {
            case .running(let url):
                return .publicRunning(
                    url: appModel.publicMCPURL(for: url).absoluteString,
                    captions: welcomePublicCaptions(url)
                )
            case .starting, .reconnecting:
                return .publicPending
            case .failed(let message):
                return .partialFailure(message: message)
            case .stopped, .ready, .unavailable:
                return .local(
                    localURL: appModel.localServerURL?.absoluteString ?? "",
                    canGoPublic: appModel.tunnelStatus != .unavailable
                )
            }
        }
    }

    private func welcomePublicCaptions(_ baseURL: URL) -> [String] {
        let addressLine: String
        if baseURL.host() == appModel.lastCloudflareDeployment?.hostname {
            addressLine = "Your Domain — stable address"
        } else {
            addressLine = "Instant Link — the address changes each time you go public"
        }
        return [
            addressLine,
            "Forwards only your shared tools — nothing else on this Mac"
        ]
    }

    private var heroActions: ConnectionHeroActions {
        var actions = ConnectionHeroActions()
        actions.startServer = { appModel.startLocalServer() }
        actions.stopServer = { appModel.stopLocalServer() }
        // The inline exposure summary on this screen replaces the dialog (SPEC §3 S4).
        actions.goPublic = { appModel.startTunnel() }
        actions.stopSharing = { appModel.stopTunnel() }
        actions.retry = {
            if case .failed = appModel.serverStatus {
                appModel.startLocalServer()
            } else {
                appModel.startTunnel()
            }
        }
        actions.openTools = { screen = .pickTools }
        actions.copyPublicURL = { appModel.copyPublicURL() }
        return actions
    }

    private func startAndGoPublic() {
        if appModel.serverStatus.isRunning {
            appModel.startTunnel()
        } else {
            goPublicAfterStart = true
            appModel.startLocalServer()
        }
    }

    private var canStartAndGoPublic: Bool {
        WelcomeToolChoices.canStartConnection(sharedToolCount: appModel.toolExposureSummary.total)
            && appModel.tunnelStatus != .unavailable
            && !appModel.tunnelStatus.isRunning
            && appModel.serverStatus != .starting
    }

    // MARK: - Screen 5 — Connect your app

    private var connectAppScreen: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(WelcomeScreen.connectApp.title)
                .font(TypeRamp.heroStatus)
            Text("Copy this link, paste it into an app, and approve the request MacRemote shows you. Risky tools may ask before they run.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if let url = appModel.currentPublicMCPURL {
                        urlCapsule(url)
                    } else {
                        notPublicYetRow
                    }

                    providerPicker
                    Text(providerInstruction)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    signInMethodRow

                    if let credentials = signInCredentialsValue {
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Button("Copy Sign-In Credentials") {
                                let pasteboard = NSPasteboard.general
                                pasteboard.clearContents()
                                pasteboard.setString(credentials, forType: .string)
                                appModel.appendLog(level: .info, "Copied sign-in credentials for \(appModel.connectorProvider.title).")
                            }
                            Text("\(appModel.connectorAuthMode.title) — paste these when the app asks to sign in.")
                                .font(TypeRamp.truthNote)
                                .foregroundStyle(.secondary)
                        }
                    }

                    firstRequestRegion
                }
                .padding(.vertical, Space.s1)
            }
        }
    }

    private func urlCapsule(_ url: URL) -> some View {
        HStack(spacing: Space.s2) {
            Text(url.absoluteString)
                .machineText(TypeRamp.heroMachine)
                .fixedSize(horizontal: false, vertical: true)
            CopyButton(value: url.absoluteString, help: "Copy Public URL") {
                appModel.appendLog(level: .info, "Copied the public link for this Mac.")
            }
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .background(.quaternary.opacity(0.4), in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private var notPublicYetRow: some View {
        HStack(spacing: Space.s2) {
            StateChip("Not public yet", systemImage: "circle.dotted", role: .off)
            Text("Go public first — your public link shows up here.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
            Button("Back to Start the Connection") {
                screen = .connection
            }
        }
    }

    private var providerPicker: some View {
        Picker("App", selection: Binding(
            get: { appModel.connectorProvider },
            set: { appModel.setConnectorProvider($0) }
        )) {
            ForEach(ConnectorProviderProfile.allCases) { provider in
                Text(provider.title).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 420)
    }

    /// D11 — onboarding states the method and points at the one editor; the
    /// app picker above no longer changes it (D43).
    private var signInMethodRow: some View {
        HStack(spacing: Space.s2) {
            // Same shape as Settings' own row, so the two never read as
            // different facts.
            Text("Sign-in method · \(appModel.connectorAuthMode.title)")
                .font(TypeRamp.rowDetail)
            if appModel.connectorAuthMode.isProductDefault {
                StateChip("Default", systemImage: "checkmark.seal.fill", tint: .green)
            } else {
                StateChip("Advanced", systemImage: "slider.horizontal.3", tint: .orange)
            }
            SettingsLink {
                Text("Change in Settings…")
            }
            .buttonStyle(.link)
        }
    }

    /// Advisory app instructions (D43) plus, when the picked app can't finish
    /// on the active method, the same blocked-pairing sentence Settings shows.
    private var providerInstruction: String {
        let instruction = baseProviderInstruction
        guard appModel.connectorProvider.status(for: appModel.connectorAuthMode) == .blocked else {
            return instruction
        }
        return "\(instruction)\n\n\(appModel.connectorProvider.setupLine(for: appModel.connectorAuthMode))"
    }

    private var baseProviderInstruction: String {
        switch appModel.connectorProvider {
        case .raycast:
            "In Raycast, add MacRemote as an MCP server and paste the URL when asked."
        case .claude:
            "In Claude, open Customize ▸ Connectors ▸ Add ▸ Add custom connector and paste the URL."
        case .chatGPT:
            "In ChatGPT, open chatgpt.com/plugins, choose + ▸ Add custom MCP server, paste the Public URL, choose OAuth, then approve the request in MacRemote."
        case .notion:
            "In Notion, open Settings ▸ Connections and paste the URL as a new connection."
        case .generic:
            "Paste the URL wherever your app asks for a remote MCP server."
        }
    }

    private var signInCredentialsValue: String? {
        switch appModel.connectorAuthMode {
        case .oauthClientSecret:
            appModel.oauthClientCredentials.first.flatMap {
                appModel.oauthClientCredentialsJSON(for: $0)
            }
        case .singleHeaderToken:
            appModel.connectorHeaderTokenJSON
        case .macRemoteOAuthOnly:
            nil
        }
    }

    /// The sticky moment: the waiting row flips in place into the real approval
    /// card, and after the first resolution the one-time D13 notifications row.
    @ViewBuilder
    private var firstRequestRegion: some View {
        if let interrupt = appModel.frontmostPendingInterrupt {
            ApprovalCard(
                interrupt: interrupt,
                variant: .inline,
                oauthConsequence: oauthConsequence(for: interrupt),
                onApprove: { resolve(interrupt, word: "Approved", role: .ready) { approve(interrupt) } },
                onDeny: { resolve(interrupt, word: "Denied", role: .error) { deny(interrupt) } },
                onAlwaysAllow: alwaysAllowAction(for: interrupt),
                alwaysAllowConsequence: appModel.alwaysAllowConsequence(for: interrupt),
                onCopyDetail: { row in
                    appModel.appendLog(level: .info, "Copied request detail: \(row.label).")
                },
                expandAll: $expandAll
            )
        } else if let lingeringInterrupt, let lingeringPhase {
            ApprovalCard(interrupt: lingeringInterrupt, variant: .inline, phase: lingeringPhase)
        } else if appModel.shouldOfferNotificationPrompt {
            NotificationOfferRow()
        } else if appModel.currentPublicMCPURL != nil, !hasResolvedRequestHere {
            HStack(spacing: Space.s2) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for the first request…")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }
            .padding(Space.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: AppShape.card)
        }
    }

    private func oauthConsequence(for interrupt: PendingInterrupt) -> String? {
        guard case .authorization(let request) = interrupt else { return nil }
        return appModel.signInConsequence(for: request)
    }

    private func approve(_ interrupt: PendingInterrupt) {
        switch interrupt {
        case .authorization(let request): appModel.approveAuthorizationRequest(request.id)
        case .toolCall(let request): appModel.approveToolCallRequest(request.id)
        }
    }

    private func deny(_ interrupt: PendingInterrupt) {
        switch interrupt {
        case .authorization(let request): appModel.denyAuthorizationRequest(request.id)
        case .toolCall(let request): appModel.denyToolCallRequest(request.id)
        }
    }

    /// Offered for every tool call from a known app. Tools that ask every time
    /// by default are not excluded — they carry a heavier consent line instead.
    private func alwaysAllowAction(for interrupt: PendingInterrupt) -> (() -> Void)? {
        guard case .toolCall(let request) = interrupt, request.clientID != nil else { return nil }
        return { resolve(interrupt, word: "Approved", role: .ready) { appModel.approveToolCallForever(request.id) } }
    }

    /// The card lingers on its resolved word for 1.2 s before the region moves
    /// on (ApprovalCard phase contract).
    private func resolve(_ interrupt: PendingInterrupt, word: String, role: StatusRole, action: () -> Void) {
        lingeringInterrupt = interrupt
        lingeringPhase = .resolved(word: word, role: role)
        hasResolvedRequestHere = true
        action()
        lingerTask?.cancel()
        lingerTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            lingeringInterrupt = nil
            lingeringPhase = nil
        }
    }

    // MARK: - Footer (progress dots + per-screen verbs)

    private var footer: some View {
        VStack(spacing: Space.s3) {
            progressDots
            HStack(spacing: Space.s3) {
                switch screen {
                case .welcome:
                    Button("Skip for Now", action: closeWelcome)
                    Spacer()
                    Button("Get Started") { advance(from: .welcome) }
                        .buttonStyle(.glassProminent)
                case .pickTools:
                    Button("Skip — I'll add my own") { advance(from: .pickTools) }
                    Spacer()
                    Button(addToolsButtonTitle, action: addSelectedTools)
                        .buttonStyle(.glassProminent)
                        .disabled(selectedPresets.isEmpty)
                case .permissions:
                    // The embedded Access Fixer carries its own verb row
                    // (Later = Do This Later); footer verbs only when it's absent.
                    if !needsFullDiskAccessPriming {
                        Spacer()
                        Button("Continue") { advance(from: .permissions) }
                            .buttonStyle(.glassProminent)
                    } else {
                        Spacer()
                    }
                case .connection:
                    Button(appModel.tunnelStatus.isRunning ? "Continue" : "Skip") { advance(from: .connection) }
                    Spacer()
                    connectionVerbs
                case .connectApp:
                    Button("Copy Public URL") { appModel.copyPublicURL() }
                        .disabled(appModel.currentPublicMCPURL == nil)
                    Spacer()
                    Button("Done", action: closeWelcome)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(.top, Space.s4)
    }

    /// S4's two verbs. With no Cloudflare helper there is no public link to
    /// start, so the local verb carries the emphasis instead of a disabled
    /// primary sitting where the eye goes first.
    @ViewBuilder
    private var connectionVerbs: some View {
        let localIsDisabled = appModel.serverStatus.isRunning
            || appModel.serverStatus == .starting
            || !WelcomeToolChoices.canStartConnection(
                sharedToolCount: appModel.toolExposureSummary.total
            )

        if addressMode == .yourDomain {
            Button("Just Start Locally") { appModel.startLocalServer() }
                .buttonStyle(.glass)
                .disabled(localIsDisabled)
            Button("Set Up Your Domain", action: openYourDomainSetup)
                .buttonStyle(.glassProminent)
        } else if appModel.tunnelStatus == .unavailable {
            Button("Just Start Locally") { appModel.startLocalServer() }
                .buttonStyle(.glassProminent)
                .disabled(localIsDisabled)
            Button("Start Instant Link", action: startAndGoPublic)
                .buttonStyle(.glass)
                .disabled(true)
        } else {
            Button("Just Start Locally") { appModel.startLocalServer() }
                .buttonStyle(.glass)
                .disabled(localIsDisabled)
            Button("Start Instant Link", action: startAndGoPublic)
                .buttonStyle(.glassProminent)
                .disabled(!canStartAndGoPublic)
        }
    }

    private func openYourDomainSetup() {
        storedAddressMode = AddressMode.yourDomain.rawValue
        appModel.completeWelcome()
        appModel.requestConnectionAddressSetup()
        dismiss()
    }

    /// Counts only tools that would actually be added — a returning user who
    /// already has everything selected sees "Continue", never a dead-end error.
    private var newSelectedCount: Int {
        appModel.newPresetCount(in: selectedPresets)
    }

    private var addToolsButtonTitle: String {
        WelcomeToolChoices.addButtonTitle(
            selectedCount: selectedPresets.count,
            newCount: newSelectedCount
        )
    }

    private var progressDots: some View {
        HStack(spacing: Space.s2) {
            ForEach(WelcomeScreen.allCases) { step in
                Button {
                    screen = step
                } label: {
                    Circle()
                        .fill(step == screen ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                        .frame(width: 8, height: 8)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Step \(step.rawValue + 1) of 5: \(step.title)")
                .accessibilityAddTraits(step == screen ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func advance(from current: WelcomeScreen) {
        guard screen == current else { return }
        switch current {
        case .welcome:
            screen = .pickTools
        case .pickTools:
            screen = needsPermissionScreen ? .permissions : .connection
        case .permissions:
            screen = .connection
        case .connection:
            screen = .connectApp
        case .connectApp:
            closeWelcome()
        }
    }

    /// SPEC §3 skip behavior: closing the flow lands on Connection, where the
    /// Setup checklist takes over (D16 mechanics live in the model/Connection).
    private func closeWelcome() {
        appModel.selection = .connection
        appModel.completeWelcome()
        dismiss()
    }
}

enum WelcomeInstallLocation {
    static func needsApplicationsMove(bundleURL: URL) -> Bool {
        bundleURL.deletingLastPathComponent().standardizedFileURL.path != "/Applications"
    }
}
