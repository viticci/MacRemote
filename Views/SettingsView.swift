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

                // D11: the singleton Sign-in method picker. The Address card
                // shows the chosen mode read-only and points back here.
                Picker("Sign-in method", selection: Binding(
                    get: { appModel.connectorAuthMode },
                    set: { appModel.setConnectorAuthMode($0) }
                )) {
                    ForEach(ConnectorAuthMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage)
                            .tag(mode)
                    }
                }

                ConnectorCompatibilitySummary(
                    provider: appModel.connectorProvider,
                    authMode: appModel.connectorAuthMode
                )
            }

            Section("App Behavior") {
                Toggle("Show menu bar icon", isOn: $appModel.isMenuBarExtraEnabled)
                Toggle("Warn before quitting while sharing", isOn: $appModel.warnBeforeQuitWhileSharing)
                Toggle("Show setup checklist", isOn: $appModel.isSetupChecklistEnabled)

                Button("Show Welcome Window") {
                    openWindow(id: MacRemoteWindowID.welcome)
                }
            }
        }
        .formStyle(.grouped)
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

// MARK: - Notifications (SE-15…SE-22 + macOS notifications status)

private struct NotificationSettingsPane: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

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

            Section {
                Toggle("Send Pushover notifications", isOn: $appModel.pushoverSettings.isEnabled)

                SecureField("User ID", text: $appModel.pushoverSettings.userKey, prompt: Text("Pushover user key"))
                    .disabled(!appModel.pushoverSettings.isEnabled)
                SecureField("API Key", text: $appModel.pushoverSettings.apiToken, prompt: Text("Pushover API token"))
                    .disabled(!appModel.pushoverSettings.isEnabled)

                Button("Send Test", systemImage: "paperplane") {
                    appModel.sendPushoverTestNotification()
                }
                .disabled(!appModel.pushoverSettings.isConfigured)
            } header: {
                Text("Pushover")
            } footer: {
                Text("Get notified when an app asks to connect, when your public link stops unexpectedly, or when MacRemote restarts while it was sharing.")
            }

            Section {
                Toggle("Send Brrr notifications", isOn: $appModel.brrrSettings.isEnabled)

                SecureField("Secret", text: $appModel.brrrSettings.webhookSecret, prompt: Text("Webhook secret"))
                    .disabled(!appModel.brrrSettings.isEnabled)

                Button("Send Test", systemImage: "paperplane") {
                    appModel.sendBrrrTestNotification()
                }
                .disabled(!appModel.brrrSettings.isConfigured)
            } header: {
                Text("Brrr")
            } footer: {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text("MacRemote sends notifications to your Brrr webhook, signed with the secret you paste here.")
                    Text("Notification keys are stored on this Mac.")
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
    @State private var isShowingReplaceCredentialsConfirmation = false
    @State private var isShowingDeleteCredentialsConfirmation = false
    @State private var pendingReplaceClientID: String?
    @State private var pendingDeleteClientID: String?

    var body: some View {
        Form {
            localServerSection
            appAccessSection
            tokenLifetimeSection
            credentialsSection
            if appModel.connectorAuthMode == .singleHeaderToken {
                headerTokenSection
            }
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
            Text("Sharing stops, every app is signed out, and your Mac gets a new private address. Your public link stays the same.")
        }
        .confirmationDialog(
            "Sign out every app?",
            isPresented: $isShowingSignOutAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Sign Out All", role: .destructive) {
                appModel.revokeOAuthGrants()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All connected apps must ask for your approval again. Your public link doesn't change.")
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

            if appModel.hasLockedOAuthCredentials {
                LabeledContent {
                    Button("Unlock…") {
                        appModel.unlockOAuthCredentials()
                    }
                    .buttonStyle(.borderedProminent)
                } label: {
                    Label {
                        Text("Saved credentials are locked by macOS")
                        Text("Unlocking shows a Keychain prompt — choose Always Allow so connected apps can keep signing in after rebuilds.")
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

    // MARK: Single Header token (shown only in that sign-in mode)

    private var headerTokenSection: some View {
        Section("Single Header Token") {
            Text("Apps in Single Header mode sign in by sending this as one Authorization header. Rotating it signs out any app that still sends the old one.")
                .foregroundStyle(.secondary)

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
                }
            } else {
                Button("Generate Header Token", systemImage: "key.card") {
                    appModel.setConnectorAuthMode(.singleHeaderToken)
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
