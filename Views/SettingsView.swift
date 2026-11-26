import AppKit
import SwiftUI

/// Settings — spec §5.6 (⌘,). Three toolbar-style panes: General,
/// Notifications, Security. Parity SE-1…SE-22 live here; SE-23…SE-39
/// (Full Disk Access + macOS privacy) moved to Connection ▸ Readiness
/// and the Access Fixer.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettingsPane()
            }
            Tab {
                NotificationSettingsPane()
            } label: {
                Label("Notifications", systemImage: "bell.badge")
                    .symbolRenderingMode(.hierarchical)
            }
            Tab("Security", systemImage: "lock.shield") {
                SecuritySettingsPane()
            }
        }
        .frame(width: 680, height: 580)
    }
}

// MARK: - General (SE-1…SE-3 + app behavior)

private struct GeneralSettingsPane: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var appModel = appModel

        Form {
            Section("Connect an App") {
                // D43: advisory only. Changing the app changes the instructions
                // below — it never touches the sign-in method or credentials.
                Picker("App", selection: Binding(
                    get: { appModel.connectorProvider },
                    set: { appModel.setConnectorProvider($0) }
                )) {
                    ForEach(ConnectorProviderProfile.allCases) { provider in
                        Label(provider.title, systemImage: provider.systemImage)
                            .tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                ConnectorSetupSteps()

                ConnectorSignInMethodRow()

                ConnectorAdvancedSignIn()
            }

            ResultCardsSettingsSection()
            StartupSettingsSection()

            Section("App Behavior") {
                Toggle("Show menu bar icon", isOn: $appModel.isMenuBarExtraEnabled)
                Toggle("Warn before quitting while sharing", isOn: $appModel.warnBeforeQuitWhileSharing)
                Toggle("Show setup checklist", isOn: $appModel.isSetupChecklistEnabled)

                Button("Show Welcome Window") {
                    openWindow(id: MacRemoteWindowID.welcome)
                }
            }

            CloudflareHelperSettingsSection()
        }
        .formStyle(.grouped)
    }
}

// MARK: - Connect an App (D42/D43)

/// The primary setup path: three numbered steps that work as written on a
/// fresh install, because a fresh install is already on Dynamic OAuth.
private struct ConnectorSetupSteps: View {
    @Environment(AppModel.self) private var appModel

    private var isPublic: Bool { appModel.currentPublicMCPURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            step(1, "Copy the public link") {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Button("Copy Public URL", systemImage: "doc.on.doc") {
                        appModel.copyPublicURL()
                    }
                    .disabled(!isPublic)

                    if !isPublic {
                        Text("Turn the public link on in Connection first — it appears here once it's live.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            step(2, "Paste it in \(appModel.connectorProvider.title)") {
                Text(appModel.connectorProvider.setupLine(for: appModel.connectorAuthMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            step(3, "Approve the request in MacRemote") {
                Text("MacRemote asks before the app is allowed in. Risky tools may ask again before they run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func step(
        _ number: Int,
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
            Image(systemName: "\(number).circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Space.s2) {
                Text(title)
                    .font(TypeRamp.rowDetail)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number). \(title)")
    }
}

/// D11 keeps one editor for the sign-in method. This row is not that editor —
/// it exists so a saved non-default method is impossible to miss.
private struct ConnectorSignInMethodRow: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        LabeledContent("Sign-in method") {
            HStack(spacing: Space.s2) {
                Text(appModel.connectorAuthMode.title)
                if appModel.connectorAuthMode.isProductDefault {
                    StateChip("Default", systemImage: "checkmark.seal.fill", tint: .green)
                } else {
                    StateChip("Advanced", systemImage: "slider.horizontal.3", tint: .orange)
                }
            }
        }
    }
}

/// The one place the sign-in method can be changed (falsifiable rule C5).
private struct ConnectorAdvancedSignIn: View {
    @Environment(AppModel.self) private var appModel
    /// What the last change of method signed out. Stated here, next to the
    /// control that did it, the way Sign Out All Apps states its result.
    @State private var signedOutSummary: String?
    /// A method the owner picked that would sign apps out, held until they
    /// confirm.
    @State private var methodAwaitingConfirmation: ConnectorAuthMode?

    private var compatibility: ConnectorCompatibility {
        appModel.connectorProvider.status(for: appModel.connectorAuthMode)
    }

    /// Changes the method at once when that signs nothing out, and asks
    /// first when it would.
    private func chooseMethod(_ mode: ConnectorAuthMode) {
        if appModel.connectedAppsSignedOut(bySwitchingTo: mode) > 0 {
            methodAwaitingConfirmation = mode
        } else {
            signedOutSummary = appModel.setConnectorAuthMode(mode)
        }
    }

    var body: some View {
        DetailsDisclosure(
            "Advanced sign-in methods",
            id: "settings.signIn.advanced",
            // A saved non-default method opens this section on its own, so the
            // choice is never hidden behind a closed disclosure.
            initiallyExpanded: !appModel.connectorAuthMode.isProductDefault
        ) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text("Most apps need nothing here. Change this only when an app asks you for a client ID and secret, or can only send one header.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Picker("Sign-in method", selection: Binding(
                    get: { appModel.connectorAuthMode },
                    set: { chooseMethod($0) }
                )) {
                    ForEach(ConnectorAuthMode.allCases) { mode in
                        Label(mode.pickerTitle, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }
                .confirmationDialog(
                    methodAwaitingConfirmation.map { mode in
                        let count = appModel.connectedAppsSignedOut(bySwitchingTo: mode)
                        return "Sign out \(count) connected app\(count == 1 ? "" : "s")?"
                    } ?? "",
                    isPresented: Binding(
                        get: { methodAwaitingConfirmation != nil },
                        set: { if !$0 { methodAwaitingConfirmation = nil } }
                    ),
                    presenting: methodAwaitingConfirmation
                ) { mode in
                    Button("Change and Sign Out", role: .destructive) {
                        signedOutSummary = appModel.setConnectorAuthMode(mode)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: { mode in
                    Text("\(mode.title) does not admit the apps connected now. They are signed out and their Always Allow settings are removed. Each one has to connect again and be approved on this Mac.")
                }

                Text(appModel.connectorAuthMode.tradeoffDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let signedOutSummary {
                    Text(signedOutSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                ConnectorCompatibilitySummary(
                    provider: appModel.connectorProvider,
                    authMode: appModel.connectorAuthMode
                )

                if compatibility == .blocked {
                    Button("Use \(appModel.connectorProvider.recommendedAuthMode.title)") {
                        chooseMethod(appModel.connectorProvider.recommendedAuthMode)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Text("Client IDs, secrets, and the header token live in Settings ▸ Security.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Startup (D76)

/// For a Mac that stays on with nobody at it: MacRemote can open at login
/// and bring a deployed Your Domain back by itself. Both start off.
private struct StartupSettingsSection: View {
    @Environment(AppModel.self) private var appModel
    /// Read so the section redraws when the Address card switches between
    /// Instant Link and Your Domain; AppModel reads the same key.
    @AppStorage("MacRemote.addressMode") private var storedAddressMode = AddressMode.instantLink.rawValue
    @State private var isConfirmingGoPublicAtLaunch = false

    private var openAtLoginIsOn: Bool {
        switch appModel.openAtLoginStatus {
        case .enabled, .requiresApproval: true
        default: false
        }
    }

    /// The deployed Your Domain the setting can be turned on for, if any.
    private var candidateHostname: String? {
        _ = storedAddressMode
        return appModel.goPublicAtLaunchCandidateHostname
    }

    var body: some View {
        Section("Startup") {
            VStack(alignment: .leading, spacing: Space.s1) {
                Toggle("Open at login", isOn: Binding(
                    get: { openAtLoginIsOn },
                    set: { appModel.setOpenAtLogin($0) }
                ))
                caption(openAtLoginCaption)
                if appModel.openAtLoginStatus == .requiresApproval {
                    Button("Open Login Items Settings") {
                        appModel.openLoginItemsSettings()
                    }
                }
                if let error = appModel.openAtLoginError {
                    caption("macOS refused the change: \(error)")
                }
            }

            VStack(alignment: .leading, spacing: Space.s1) {
                Toggle("Go public at launch", isOn: Binding(
                    get: { appModel.goPublicAtLaunchHostname != nil },
                    set: { isOn in
                        if isOn {
                            // The Go Public confirmation, given once here
                            // instead of at every launch.
                            isConfirmingGoPublicAtLaunch = true
                        } else {
                            appModel.turnOffGoPublicAtLaunch()
                        }
                    }
                ))
                // Off with nothing to turn on for; on, it stays usable so
                // the owner can always turn it off.
                .disabled(appModel.goPublicAtLaunchHostname == nil && candidateHostname == nil)
                caption(goPublicAtLaunchCaption)
            }
            .confirmationDialog(
                "Go public at launch?",
                isPresented: $isConfirmingGoPublicAtLaunch,
                presenting: candidateHostname
            ) { hostname in
                // The hostname this dialog shows, so a candidate that changed
                // while it was open is not saved.
                Button("Go Public at Launch") {
                    appModel.turnOnGoPublicAtLaunch(hostname: hostname)
                }
                Button("Cancel", role: .cancel) {}
            } message: { hostname in
                Text("\(appModel.goPublicConfirmationMessage) MacRemote makes \(hostname) public each time it opens, without asking again.")
            }
        }
        .task {
            appModel.refreshOpenAtLoginStatus()
        }
        // The owner can change the login item in System Settings while this
        // pane stays open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appModel.refreshOpenAtLoginStatus()
        }
    }

    private var openAtLoginCaption: String {
        switch appModel.openAtLoginStatus {
        case .requiresApproval:
            "macOS is waiting for you to allow MacRemote in System Settings › General › Login Items."
        case .notFound:
            "macOS can't find this copy of MacRemote. Move it to Applications, open it from there, and try again."
        default:
            "MacRemote opens when you log in to this Mac. After a restart, that needs someone to log in, or automatic login."
        }
    }

    private var goPublicAtLaunchCaption: String {
        guard let saved = appModel.goPublicAtLaunchHostname else {
            guard let candidateHostname else {
                return "Available after you deploy Your Domain."
            }
            return "When MacRemote opens, it starts the local server and makes \(candidateHostname) public without asking. An Instant Link never does this."
        }
        if saved == candidateHostname {
            return "When MacRemote opens, it starts the local server and makes \(saved) public. New apps still need your approval to connect."
        }
        if let candidateHostname {
            return "Turned on for \(saved), which isn't your address now. Turn it off and on again to use \(candidateHostname)."
        }
        return "Turned on for \(saved), which isn't your deployed address now, so MacRemote won't go public at launch."
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Cloudflare helper (D44)

/// Truthful source of the helper MacRemote would launch, plus the only place
/// its own copy can be updated or removed. A copy the user installed
/// themselves is reported, never touched.
private struct CloudflareHelperSettingsSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var isShowingRemoveConfirmation = false

    private var state: CloudflaredHelperState { appModel.cloudflaredHelperState }
    private var isTunnelRunning: Bool { appModel.tunnelStatus.isRunning }

    var body: some View {
        Section {
            LabeledContent("Helper") {
                Text(helperTitle)
                    .multilineTextAlignment(.trailing)
            }

            // The technical reason is secondary, selectable text — never the
            // Helper value itself.
            if case .failed(let failure) = state, let detail = failure.detail {
                LabeledContent("Reason") {
                    MonoValue(detail, font: TypeRamp.machineCaption) {
                        appModel.appendLog(level: .info, "Copied the Cloudflare helper failure detail.")
                    }
                    .foregroundStyle(.secondary)
                }
            }

            if let path = state.source?.path {
                LabeledContent("Location") {
                    MonoValue(path, font: TypeRamp.machineCaption) {
                        appModel.appendLog(level: .info, "Copied the Cloudflare helper location.")
                    }
                }
            }

            if case .downloading(let progress) = state {
                ProgressView(value: progress) {
                    Text("Downloading Cloudflare's helper…")
                }
                Button("Cancel") {
                    appModel.cancelCloudflaredHelperInstall()
                }
            }

            if case .updateAvailable(_, let available, _) = state {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Button("Update Helper") {
                        appModel.installCloudflaredHelper()
                    }
                    .disabled(isTunnelRunning || state.isWorking)
                    Text(isTunnelRunning
                        ? "Turn the public link off first — MacRemote keeps using the running helper until then."
                        : "MacRemote can replace its copy with version \(available).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if case .notInstalled = state {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Button("Install Helper") {
                        appModel.installCloudflaredHelper()
                    }
                    .disabled(state.isWorking)
                    Text("MacRemote downloads Cloudflare's helper \(CloudflaredManifest.version) and checks it against Cloudflare's published checksum and signature.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if state.source?.isManaged == true {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Button("Remove Helper…") {
                        isShowingRemoveConfirmation = true
                    }
                    .disabled(isTunnelRunning || state.isWorking)
                    Text(isTunnelRunning
                        ? "Turn the public link off before removing the helper it is running."
                        : "Removes only MacRemote's own copy. Anything you installed yourself stays where it is.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button("Check Again") {
                appModel.refreshCloudflaredHelper()
            }
            .disabled(state.isInstalling)
        } header: {
            Text("Cloudflare Helper")
        } footer: {
            VStack(alignment: .leading, spacing: Space.s1) {
                Text("Cloudflare Tunnel client by \(CloudflaredManifest.publisher), released \(CloudflaredManifest.releaseDate). MacRemote launches it only to open your public link.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s3) {
                    Link("Apache 2.0 license", destination: CloudflaredManifest.licenseURL)
                    Link("Source code", destination: CloudflaredManifest.sourceURL)
                }
            }
        }
        .confirmationDialog(
            "Remove MacRemote's copy of Cloudflare's helper?",
            isPresented: $isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                appModel.removeCloudflaredHelper()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes only the copy MacRemote downloaded. A helper you installed yourself is left alone, and MacRemote will use it instead.")
        }
    }

    private var helperTitle: String {
        switch state {
        case .checking:
            "Checking…"
        case .notInstalled:
            "Not installed"
        case .downloading:
            "Installing…"
        case .verifying:
            "Checking the download"
        case .ready(let version, let source):
            source.isManaged
                ? "\(source.title) · \(version ?? CloudflaredManifest.version)"
                : source.title
        case .updateAvailable(let installed, let available, let source):
            "\(source.title) · \(installed) · \(available) available"
        case .failed(let failure):
            failure.message
        }
    }
}

private struct ConnectorCompatibilitySummary: View {
    let provider: ConnectorProviderProfile
    let authMode: ConnectorAuthMode

    private var compatibility: ConnectorCompatibility {
        provider.status(for: authMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s1) {
                StateChip(provider.authLabel, systemImage: "person.badge.key", tint: .secondary)
                StateChip(provider.headerLabel, systemImage: "curlybraces", tint: .secondary)
                StateChip(authMode.shortTitle, systemImage: authMode.systemImage, tint: .secondary)
                StateChip(compatibility.title, systemImage: compatibility.systemImage, tint: compatibility.tint)
            }

            Text(provider.setupLine(for: authMode))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Notifications (macOS notifications status)

private struct NotificationSettingsPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Form {
            Section("Notifications") {
                LabeledContent("macOS Notifications") {
                    HStack(spacing: Space.s2) {
                        statusChip

                        switch appModel.notificationPermissionStatus {
                        case .notDetermined:
                            Button("Allow Notifications") {
                                appModel.requestNotificationPermission()
                            }
                        case .denied:
                            Button("Open Notification Settings") {
                                appModel.openNotificationSettings()
                            }
                        case .authorized, .unknown:
                            EmptyView()
                        }
                    }
                }

                if appModel.notificationPermissionStatus == .unknown {
                    Text("Notifications need the packaged MacRemote app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            appModel.refreshNotificationPermissionStatus()
        }
    }

    private var statusChip: StateChip {
        switch appModel.notificationPermissionStatus {
        case .authorized:
            StateChip("Allowed", systemImage: "checkmark.circle.fill", role: .ready)
        case .denied:
            StateChip("Denied", systemImage: "bell.slash", role: .attention)
        case .notDetermined:
            StateChip("Not Requested", systemImage: "bell", role: .off)
        case .unknown:
            StateChip("Unavailable", systemImage: "questionmark.circle", role: .off)
        }
    }
}

// MARK: - Security (SE-4…SE-14)

private struct SecuritySettingsPane: View {
    @Environment(AppModel.self) private var appModel

    @State private var isShowingResetAddressConfirmation = false
    @State private var isShowingSignOutAllConfirmation = false
    @State private var signOutAllSummary: String?
    @State private var isShowingReplaceCredentialsConfirmation = false
    @State private var isShowingDeleteCredentialsConfirmation = false
    @State private var pendingReplaceClientID: String?
    @State private var pendingDeleteClientID: String?
    @State private var isShowingDeleteHeaderTokenConfirmation = false
    @State private var fileTransferFolderProblem: String?
    @State private var isShowingWholeMacConfirmation = false

    var body: some View {
        Form {
            localServerSection
            appAccessSection
            fileTransferSection
            tokenLifetimeSection
            credentialsSection
            headerTokenSection
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Reset your private address?",
            isPresented: $isShowingResetAddressConfirmation,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) {
                appModel.rotateInstanceID()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sharing stops, every app is signed out, and your Mac gets a new private address. An Instant Link gets a new address the next time you go public; Your Domain keeps its address.")
        }
        .confirmationDialog(
            "Sign out every app?",
            isPresented: $isShowingSignOutAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out All", role: .destructive) {
                signOutAllSummary = appModel.signOutAllApps().summary
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every app's sign-in, tokens, waiting requests, and Always Allow settings are removed. Each app can ask to connect again anytime, and your public link doesn't change.")
        }
        .confirmationDialog(
            "Replace these credentials?",
            isPresented: $isShowingReplaceCredentialsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Replace", role: .destructive) {
                if let clientID = pendingReplaceClientID {
                    appModel.rotateOAuthClientCredentials(clientID: clientID)
                }
                pendingReplaceClientID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingReplaceClientID = nil
            }
        } message: {
            Text("The old ID and secret stop working immediately; paste the new ones into \(appModel.connectorProvider.title).")
        }
        .confirmationDialog(
            "Delete these credentials?",
            isPresented: $isShowingDeleteCredentialsConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let clientID = pendingDeleteClientID {
                    appModel.deleteOAuthClientCredentials(clientID: clientID)
                }
                pendingDeleteClientID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteClientID = nil
            }
        } message: {
            Text("The app using them is signed out and its Always Allow settings are cleared.")
        }
        .confirmationDialog(
            "Delete the Single Header token?",
            isPresented: $isShowingDeleteHeaderTokenConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                appModel.deleteConnectorHeaderToken()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any app still sending it is signed out. You can generate a new one here at any time.")
        }
    }

    // MARK: Local server

    private var localServerSection: some View {
        Section("Local Server") {
            LabeledContent("Address") {
                VStack(alignment: .trailing, spacing: Space.s1) {
                    Text("Only on this Mac")
                    Text(verbatim: "127.0.0.1")
                        .font(TypeRamp.machineCaption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            LabeledContent("Private address ID") {
                MonoValue(appModel.instanceID) {
                    appModel.appendLog(level: .info, "Copied the private address ID.")
                }
            }

            if let confirmation = appModel.instanceRotationConfirmation {
                HStack(spacing: Space.s2) {
                    Label {
                        Text(confirmation)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button {
                        appModel.dismissInstanceRotationConfirmation()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
                }
            }

            VStack(alignment: .leading, spacing: Space.s1) {
                Button("Reset Private Address…") {
                    isShowingResetAddressConfirmation = true
                }
                Text("Gives your Mac a new private address. Sharing stops and every app is signed out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: File Transfer folders

    private var fileTransferSection: some View {
        Section {
            ForEach(appModel.fileTransferFolders, id: \.self) { folder in
                let isWholeMac = folder == AppModel.wholeMacFolder
                HStack(spacing: Space.s2) {
                    Image(systemName: isWholeMac ? "desktopcomputer" : "folder")
                        .foregroundStyle(isWholeMac ? Color.orange : Color.secondary)
                    if isWholeMac {
                        Text("Whole Mac")
                    } else {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .font(TypeRamp.machineCallout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder)
                            // The other folders stay listed while the whole
                            // Mac is allowed, dimmed because it covers them.
                            .foregroundStyle(appModel.fileTransferReachesWholeMac ? .secondary : .primary)
                    }
                    Spacer()
                    Button("Remove", systemImage: "minus.circle") {
                        appModel.removeFileTransferFolder(folder)
                        fileTransferFolderProblem = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help(isWholeMac ? "Go back to the folders below" : "Stop sharing this folder")
                }
            }

            if appModel.fileTransferFolders.isEmpty {
                Text("No folders. The File Transfer tools can't reach any file.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Add Folder…", systemImage: "plus") {
                    chooseFileTransferFolder()
                }
                if !appModel.fileTransferReachesWholeMac {
                    Spacer()
                    Button("Allow Whole Mac…") {
                        isShowingWholeMacConfirmation = true
                    }
                }
            }
            .confirmationDialog(
                "Let connected apps read any file on this Mac?",
                isPresented: $isShowingWholeMacConfirmation
            ) {
                Button("Allow Whole Mac", role: .destructive) {
                    appModel.allowWholeMacForFileTransfer()
                    fileTransferFolderProblem = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every connected app will be able to find, list, and read any file your account can open, without asking you. That includes files that hold passwords or API keys, such as shell startup files and app settings. Writing a file still asks first. MacRemote keeps blocking SSH and cloud keys, keychains, and its own data.")
            }

            if let fileTransferFolderProblem {
                Label(fileTransferFolderProblem, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        } header: {
            Text("File Transfer Folders")
        } footer: {
            if appModel.fileTransferReachesWholeMac {
                Text("File Transfer, and any other tool that runs without asking, can read every file your account can open. Allow this only if you trust every connected app. Writing still asks first. SSH and cloud keys, keychains, and MacRemote's own data are never reachable.")
            } else {
                Text("The built-in File Transfer tools reach only these folders, and so does any other tool that runs without asking. Reading needs no approval, so add a folder only if an app may read everything in it. Keys, keychains, and MacRemote's own data are never reachable.")
            }
        }
    }

    private func chooseFileTransferFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder the File Transfer tools may reach."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileTransferFolderProblem = appModel.addFileTransferFolder(url)
    }

    // MARK: App access

    private var appAccessSection: some View {
        Section("App Access") {
            VStack(alignment: .leading, spacing: Space.s1) {
                Button("Sign Out All Apps…") {
                    isShowingSignOutAllConfirmation = true
                }
                Text("Signs out every connected app. Your public link stays the same — each app just asks for your approval again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // §2.4: the result is stated here rather than only in the log.
                if let signOutAllSummary {
                    Text(signOutAllSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Token lifetime

    private var tokenLifetimeSection: some View {
        Section {
            Picker("Access token", selection: Binding(
                get: { appModel.oauthAccessTokenTTLSeconds },
                set: { appModel.setOAuthAccessTokenTTLSeconds($0) }
            )) {
                Text("15 minutes").tag(900)
                Text("1 hour").tag(3_600)
                Text("8 hours").tag(28_800)
                Text("24 hours").tag(86_400)
            }

            Picker("Refresh token", selection: Binding(
                get: { appModel.oauthRefreshTokenTTLSeconds },
                set: { appModel.setOAuthRefreshTokenTTLSeconds($0) }
            )) {
                Text("24 hours").tag(86_400)
                Text("7 days").tag(604_800)
                Text("30 days").tag(2_592_000)
            }
        } header: {
            Text("Token lifetime")
        } footer: {
            Text("Shorter lifetimes are safer. Apps that can't refresh in the background may prefer a longer access token, or use the Single Header Token sign-in method instead.")
        }
    }

    // MARK: OAuth client credentials

    private var credentialsSection: some View {
        Section("OAuth Client Credentials") {
            Text("Use these when an app asks to sign in with a generated ID and secret. The secret lives in your Keychain. Replacing or deleting an entry signs out only the app that uses it.")
                .foregroundStyle(.secondary)

            // They are accepted under OAuth Client Secret only, so every
            // other method says so, as the header token does below.
            if !appModel.connectorAuthMode.requiresOAuthClientSecret {
                Label(
                    "Not in use — \(appModel.connectorAuthMode.title) is your sign-in method.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }

            if appModel.hasLockedOAuthCredentials {
                LabeledContent {
                    Button("Unlock…") {
                        appModel.unlockOAuthCredentials()
                    }
                    .buttonStyle(.borderedProminent)
                } label: {
                    Label {
                        Text("Saved credentials are locked by macOS")
                        Text("Unlocking shows a Keychain prompt — choose Always Allow so connected apps can keep signing in.")
                    } icon: {
                        Image(systemName: "lock.badge.clock")
                            .foregroundStyle(.orange)
                    }
                }
            }

            ForEach(appModel.oauthClientCredentials, id: \.clientID) { credential in
                OAuthCredentialPanel(
                    credential: credential,
                    credentialsJSON: appModel.oauthClientCredentialsJSON(for: credential),
                    copyAction: { value, auditLine in
                        copyValue(value, auditLine: auditLine)
                    },
                    auditAction: { auditLine in
                        appModel.appendLog(level: .info, auditLine)
                    },
                    replaceAction: {
                        pendingReplaceClientID = credential.clientID
                        isShowingReplaceCredentialsConfirmation = true
                    },
                    deleteAction: {
                        pendingDeleteClientID = credential.clientID
                        isShowingDeleteCredentialsConfirmation = true
                    }
                )

                if credential.clientID != appModel.oauthClientCredentials.last?.clientID {
                    Divider()
                }
            }

            if appModel.oauthClientCredentials.isEmpty && !appModel.hasLockedOAuthCredentials {
                Button(generateTitle, systemImage: "key.2.on.ring") {
                    appModel.generateOAuthClientCredentials()
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button(generateTitle, systemImage: "key.2.on.ring") {
                    appModel.generateOAuthClientCredentials()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var generateTitle: String {
        "Generate \(appModel.connectorProvider.title) Credentials"
    }

    // MARK: Single Header token (R4 — always visible, in every sign-in mode)

    private var headerTokenSection: some View {
        Section("Single Header Token") {
            Text("Apps in Single Header mode sign in by sending this as one Authorization header. Rotating it signs out any app that still sends the old one.")
                .foregroundStyle(.secondary)

            // A token generated once used to disappear with the section when
            // the sign-in method changed. It is stated and removable instead.
            if appModel.connectorAuthMode != .singleHeaderToken {
                Label(
                    "Not in use — \(appModel.connectorAuthMode.title) is your sign-in method.",
                    systemImage: "info.circle"
                )
                .foregroundStyle(.secondary)
            }

            if let token = appModel.connectorHeaderToken {
                KeyValueGrid(rows: [
                    KeyValueRow("Token", token.clientSecret, isSensitive: true),
                    KeyValueRow("Created", token.createdAt.formatted(date: .abbreviated, time: .shortened))
                ]) { row in
                    appModel.appendLog(level: .info, "Copied the Single Header \(row.label.lowercased()).")
                }

                HStack(spacing: Space.s2) {
                    Button("Copy Header", systemImage: "doc.on.doc") {
                        if let headerJSON = appModel.connectorHeaderTokenJSON {
                            copyValue(headerJSON, auditLine: "Copied the Single Header sign-in header.")
                        }
                    }
                    Button("Rotate Token", systemImage: "arrow.triangle.2.circlepath") {
                        appModel.rotateConnectorHeaderToken()
                    }
                    Button("Delete Token…", systemImage: "trash") {
                        isShowingDeleteHeaderTokenConfirmation = true
                    }
                }
            } else {
                // D43: making a token is not choosing it — the sign-in method
                // changes only in Settings ▸ General ▸ Advanced.
                Button("Generate Header Token", systemImage: "key.card") {
                    appModel.generateConnectorHeaderTokenIfNeeded()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func copyValue(_ value: String, auditLine: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        appModel.appendLog(level: .info, auditLine)
    }
}

private struct OAuthCredentialPanel: View {
    let credential: OAuthClientCredentials
    let credentialsJSON: String?
    /// Writes the pasteboard and the audit line (labeled Copy buttons).
    let copyAction: (String, String) -> Void
    /// Audit line only — the grid's hover `CopyButton` writes the pasteboard itself.
    let auditAction: (String) -> Void
    let replaceAction: () -> Void
    let deleteAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            Text(credential.label)
                .font(TypeRamp.cardTitle)

            KeyValueGrid(rows: [
                KeyValueRow("Client ID", credential.clientID),
                KeyValueRow("Client Secret", credential.clientSecret, isSensitive: true),
                KeyValueRow("Created", credential.createdAt.formatted(date: .abbreviated, time: .shortened))
            ]) { row in
                auditAction(auditLine(for: row.label))
            }

            HStack(spacing: Space.s2) {
                Button("Copy ID", systemImage: "doc.on.doc") {
                    copyAction(credential.clientID, "Copied OAuth client ID.")
                }

                Button("Copy Secret", systemImage: "key.fill") {
                    copyAction(credential.clientSecret, "Copied OAuth client secret.")
                }

                if let credentialsJSON {
                    Button("Copy JSON", systemImage: "curlybraces") {
                        copyAction(credentialsJSON, "Copied OAuth client credentials JSON.")
                    }
                }

                Spacer()

                Button("Replace…") {
                    replaceAction()
                }

                Button("Delete…", role: .destructive) {
                    deleteAction()
                }
            }
        }
    }

    private func auditLine(for label: String) -> String {
        switch label {
        case "Client ID": "Copied OAuth client ID."
        case "Client Secret": "Copied OAuth client secret."
        default: "Copied OAuth credential \(label.lowercased())."
        }
    }
}
