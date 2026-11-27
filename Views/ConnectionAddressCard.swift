import AppKit
import SwiftUI

// MARK: - Address card (SPEC §4.3 — Instant Link / Your Domain, four-stage deploy)

enum AddressMode: String, CaseIterable, Identifiable {
    case instantLink
    case yourDomain

    var id: String { rawValue }

    var welcomeTitle: String {
        switch self {
        case .instantLink: "Instant Link"
        case .yourDomain: "Your Domain"
        }
    }

    var welcomeSymbol: String {
        switch self {
        case .instantLink: "sparkles"
        case .yourDomain: "globe"
        }
    }

    var welcomeDetail: String {
        switch self {
        case .instantLink:
            "Fastest. No Cloudflare account or domain. MacRemote creates a random temporary address that changes each time."
        case .yourDomain:
            "A stable address you choose, such as macremote.example.com. You need a Cloudflare account, a domain added to it, and either a signed-in Wrangler session or an API token."
        }
    }

    var welcomeRequirements: [String] {
        guard self == .yourDomain else { return [] }
        return [
            "Add a domain you own to your Cloudflare account.",
            "Sign in with wrangler login, or create an API token for that domain. MacRemote never saves the token.",
            "With Wrangler signed in or a token pasted, load your domains, choose the domain and subdomain, then select Deploy Your Domain."
        ]
    }
}

/// One truthful summary line shared by the collapsed card and the grid tile
/// (Rule 24 — states mode + hostname + deploy state).
@MainActor
private func addressSummaryLine(appModel: AppModel, mode: AddressMode) -> String {
    if appModel.cloudflaredHelperState.isInstalling {
        return appModel.cloudflaredHelperState.summary
    }
    if appModel.tunnelStatus == .unavailable {
        return "Cloudflare's helper isn't installed"
    }
    if case .running(let base) = appModel.tunnelStatus {
        if base.host() == appModel.lastCloudflareDeployment?.hostname {
            return "Your Domain · \(base.host() ?? base.absoluteString) · Deployed ✓"
        }
        return "Instant Link · \(base.host() ?? base.absoluteString) · changes when you go public again"
    }
    switch appModel.cloudflareCustomDomainState {
    case .deployed(let hostname):
        return "Your Domain · \(hostname) · deployed, link off"
    case .preparingLocalServer, .deploying, .loadingDomains:
        return "Your Domain · \(appModel.cloudflareCustomDomainState.title)"
    case .failed:
        return mode == .yourDomain ? "Your Domain · Failed" : "Instant Link · not created yet"
    case .idle, .ready:
        // A domain deployed before this launch is still deployed; Go Public
        // brings it up from its saved key.
        if mode == .yourDomain, let hostname = appModel.chosenDeployedHostname {
            return "Your Domain · \(hostname) · deployed, link off"
        }
        return mode == .yourDomain
            ? "Your Domain · not deployed yet"
            : "Instant Link · not created yet"
    }
}

struct ConnectionAddressTile: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("MacRemote.addressMode") private var storedMode = AddressMode.instantLink.rawValue
    let open: () -> Void

    var body: some View {
        StatusTile(title: "Address", systemImage: "link", open: open) {
            Text(addressSummaryLine(
                appModel: appModel,
                mode: AddressMode(rawValue: storedMode) ?? .instantLink
            ))
            .font(TypeRamp.rowDetail)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ConnectionAddressCard: View {

    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var isCollapsed: Bool

    @AppStorage("MacRemote.addressMode") private var storedMode = AddressMode.instantLink.rawValue
    @State private var isShowingWhyCloudflare = false
    @State private var isShowingTokenRequirements = false
    @State private var hasAttemptedDeploy = false

    private var mode: AddressMode {
        AddressMode(rawValue: storedMode) ?? .instantLink
    }

    var body: some View {
        Card(
            title: "Address",
            systemImage: "link",
            isCollapsed: $isCollapsed,
            summary: {
                Text(summaryLine)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            },
            content: {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if appModel.tunnelStatus == .unavailable || appModel.cloudflaredHelperState.isInstalling {
                        unavailableBanner
                    }
                    modeRadios
                    whyCloudflareRow
                    if mode == .instantLink {
                        instantLinkDetail
                    } else {
                        yourDomainForm
                    }
                }
            }
        )
    }

    // MARK: Summary (Rule 24 — states mode + hostname + deploy state)

    private var summaryLine: String {
        addressSummaryLine(appModel: appModel, mode: mode)
    }

    private func isRunningYourDomain(_ base: URL) -> Bool {
        guard let deployment = appModel.lastCloudflareDeployment else { return false }
        return base.host() == deployment.hostname
    }

    // MARK: cloudflared-missing banner (D44 managed helper, DA-11/TU-7 Check Again)

    private var unavailableBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            if needsHelperAttention {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
            }
            CloudflaredHelperSetup(disclosureID: "address.cloudflaredHelper")
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: AppShape.mono)
    }

    private var needsHelperAttention: Bool {
        switch appModel.cloudflaredHelperState {
        case .notInstalled, .failed: true
        default: false
        }
    }

    // MARK: Mode choice (D10 — Instant Link / Your Domain)

    private var modeRadios: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            modeRadio(
                .instantLink,
                title: "Instant Link",
                detail: "A temporary trycloudflare.com address; changes every time you go public"
            )
            modeRadio(
                .yourDomain,
                title: "Your Domain",
                detail: "A stable address on a domain you own"
            )
        }
    }

    private func modeRadio(_ target: AddressMode, title: String, detail: String) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy) {
                storedMode = target.rawValue
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Image(systemName: mode == target ? "inset.filled.circle" : "circle")
                    .foregroundStyle(mode == target ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Text(detail)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
    }

    private var whyCloudflareRow: some View {
        Button {
            isShowingWhyCloudflare.toggle()
        } label: {
            Label("Why Cloudflare", systemImage: "info.circle")
                .font(TypeRamp.rowDetail)
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $isShowingWhyCloudflare, arrowEdge: .bottom) {
            Text("Apps like Claude connect from the internet, so this Mac needs a public address. Cloudflare Tunnel creates one without opening any ports on your network — traffic forwards only to MacRemote's local server, and sign-in plus your approval still gate every tool call.")
                .font(TypeRamp.rowDetail)
                .padding(Space.s4)
                .frame(width: 340)
        }
    }

    // MARK: Instant Link

    @ViewBuilder
    private var instantLinkDetail: some View {
        if case .running(let base) = appModel.tunnelStatus, !isRunningYourDomain(base) {
            Text("This address changes when you go public again.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Your Domain form (TU-11…TU-21)

    private var yourDomainForm: some View {
        @Bindable var appModel = appModel

        return VStack(alignment: .leading, spacing: Space.s3) {
            Text("1. Sign in to Wrangler or paste an API token")
                .font(TypeRamp.cardTitle)
            Text("Run wrangler login once to use its saved sign-in. Or create a token in your Cloudflare dashboard and paste it here. A pasted token takes priority; MacRemote never saves it.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("What Your API Token Needs") {
                isShowingTokenRequirements.toggle()
            }
            .buttonStyle(.link)
            .popover(isPresented: $isShowingTokenRequirements, arrowEdge: .bottom) {
                tokenRequirementsPopover
            }
            CloudflareAPITokenField(text: $appModel.cloudflareDraft.apiToken)
                .frame(maxWidth: 280, alignment: .leading)

            Text("2. Load your domains")
                .font(TypeRamp.cardTitle)
            HStack(spacing: Space.s2) {
                Button("Load Domains") {
                    hasAttemptedDeploy = false
                    appModel.refreshCloudflareDomains()
                }
                .disabled(!appModel.canLoadCloudflareDomains)
                .help(loadDomainsHelp)

                if appModel.cloudflareCustomDomainState.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(appModel.cloudflareCustomDomainState.title)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }

            Text(loadDomainsHelp)
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = appModel.cloudflareCustomDomainState.domainLoadFailureMessage {
                Label {
                    Text(sanitized(message))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                }
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.orange)
            }
            if let detail = appModel.cloudflareCustomDomainState.domainLoadFailureTechnicalDetail {
                LabeledContent("Technical detail") {
                    MonoValue(detail, font: TypeRamp.machineCaption) {
                        appModel.appendLog(level: .info, "Copied the domain-loading error detail.")
                    }
                }
            }

            LabeledContent("3. Choose a domain") {
                Picker("Domain", selection: $appModel.cloudflareDraft.selectedZoneID) {
                    Text("Choose a domain").tag(String?.none)
                    ForEach(appModel.cloudflareZones) { zone in
                        Text(zone.name).tag(Optional(zone.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }

            LabeledContent("4. Choose a subdomain") {
                TextField("macremote", text: $appModel.cloudflareDraft.subdomain)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280, alignment: .leading)
            }

            LabeledContent("Hostname") {
                if let preview = appModel.customCloudflareHostnamePreview {
                    Text(preview)
                        .machineText()
                } else {
                    Text("Enter a valid subdomain")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }

            // D11 — the one Sign-in method picker lives in Settings; this row is read-only.
            LabeledContent("Sign-in method") {
                HStack(spacing: Space.s2) {
                    Text(appModel.connectorAuthMode.title)
                    SettingsLink {
                        Text("Change in Settings…")
                    }
                    .buttonStyle(.link)
                }
            }

            if appModel.cloudflareCustomDomainState.domainLoadFailureMessage == nil {
                deployHintRow
            }

            Text("5. Deploy")
                .font(TypeRamp.cardTitle)
            Button("Deploy Your Domain") {
                hasAttemptedDeploy = true
                appModel.deployCustomDomainTunnel()
            }
            .disabled(!appModel.canDeployCustomDomainTunnel)
            // GUIDELINES §4.1 rule 7: a saved secret says where it lives.
            Text("After a deploy, MacRemote keeps the key that runs this public link in your Keychain, so going public again needs no token and no Wrangler. The key can't change your DNS. Changing the domain or subdomain deletes it.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsDeployStages {
                DeployStageList(states: deployStageStates) { _ in
                    appModel.appendLog(level: .info, "Copied the deploy error detail.")
                }
            }

            if case .deployed = appModel.cloudflareCustomDomainState,
               let deployment = appModel.lastCloudflareDeployment {
                proofGrid(deployment)
            }
        }
    }

    private var loadDomainsHelp: String {
        if !appModel.cloudflareDraft.trimmedAPIToken.isEmpty {
            return "Load Domains uses the API token pasted above."
        }
        if appModel.hasWranglerForCloudflareSetup {
            return "No token pasted. Load Domains and Deploy use Wrangler if it is signed in on this Mac."
        }
        return "Paste an API token before loading domains. MacRemote couldn't find Wrangler on this Mac."
    }

    private var deployHintRow: some View {
        Text(sanitized(appModel.customDomainDeployHint))
            .font(TypeRamp.truthNote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Structured version of CloudflareServiceError.apiTokenPermissions.
    private var tokenRequirementsPopover: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("What your API token needs")
                .font(TypeRamp.cardTitle)
            ForEach(
                [
                    "Account · Cloudflare Tunnel · Edit",
                    "Zone · Zone · Read",
                    "Zone · DNS · Edit",
                    "Zone · Config Rules · Edit"
                ],
                id: \.self
            ) { requirement in
                HStack(spacing: Space.s2) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(requirement)
                        .font(.callout)
                }
            }
            Text("Create the token in the Cloudflare dashboard, scoped to the selected domain.")
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
        }
        .padding(Space.s4)
        .frame(width: 340)
    }

    private func proofGrid(_ deployment: CloudflareCustomDomainDeployment) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            KeyValueGrid(
                rows: [
                    KeyValueRow("Hostname", deployment.hostname),
                    KeyValueRow("Tunnel", deployment.tunnelName),
                    KeyValueRow("Sign-in", appModel.connectorAuthMode.protectionTitle)
                ],
                onCopy: { row in
                    appModel.appendLog(level: .info, "Copied \(row.label) from the last deploy.")
                }
            )
            if appModel.connectorAuthMode == .singleHeaderToken,
               let headerJSON = appModel.connectorHeaderTokenJSON {
                Button("Copy Header") {
                    copyToPasteboard(headerJSON)
                    appModel.appendLog(level: .info, "Copied the Single Header sign-in header for \(deployment.hostname).")
                }
            }
        }
    }

    // MARK: Deploy stages (SPEC §4.3 — failure lands on its stage)

    private var showsDeployStages: Bool {
        switch appModel.cloudflareCustomDomainState {
        case .preparingLocalServer, .deploying, .deployed: true
        case .failed(let failure): hasAttemptedDeploy && failure.deployStage != nil
        case .idle, .loadingDomains, .ready: false
        }
    }

    private var deployStageStates: [DeployStage: DeployStageState] {
        switch appModel.cloudflareCustomDomainState {
        case .idle, .loadingDomains, .ready, .preparingLocalServer:
            return [:]
        case .deploying(let current):
            return stageStates(active: DeployStage(current))
        case .deployed:
            return Dictionary(uniqueKeysWithValues: DeployStage.allCases.map { ($0, DeployStageState.done) })
        case .failed(let failure):
            guard let failedStage = failure.deployStage else { return [:] }
            let stage = DeployStage(failedStage)
            var states: [DeployStage: DeployStageState] = [:]
            for earlier in DeployStage.allCases where earlier.rawValue < stage.rawValue {
                states[earlier] = .done
            }
            states[stage] = .failed(
                message: sanitized(failure.message),
                raw: failure.technicalDetail
            )
            return states
        }
    }

    private func stageStates(active: DeployStage) -> [DeployStage: DeployStageState] {
        var states: [DeployStage: DeployStageState] = [:]
        for stage in DeployStage.allCases {
            if stage.rawValue < active.rawValue {
                states[stage] = .done
            } else if stage == active {
                states[stage] = .active
            }
        }
        return states
    }

    private func sanitized(_ text: String) -> String {
        // Model strings carry literal backticks; they never render in copy (§4.1.11).
        text.replacingOccurrences(of: "`", with: "")
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// Cloudflare tokens are opaque API credentials, not website passwords. On
/// macOS 27, focusing SwiftUI's `SecureField` can start password AutoFill's
/// recursive key-view search and wedge the main thread in a large hosting view.
/// Keep the value masked while opting this field out of text completion and
/// password classification at the AppKit layer.
private struct CloudflareAPITokenField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = "Paste API token"
        field.bezelStyle = .roundedBezel
        field.isAutomaticTextCompletionEnabled = false
        field.contentType = nil
        field.allowsWritingTools = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel("API Token")
        return field
    }

    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text {
            field.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

// MARK: - Cloudflare helper setup (D44)

/// The one place the managed Cloudflare helper is offered. The Address card
/// banner and the Welcome window's connection screen both render this, so the
/// consent copy, the progress states, and the Homebrew alternative can never
/// drift apart. Settings shows the same facts in its own row shape.
struct CloudflaredHelperSetup: View {
    @Environment(AppModel.self) private var appModel

    /// Keeps the two hosts' disclosure state separate.
    let disclosureID: String
    var showsCheckAgain = true

    private var artifact: CloudflaredArtifact? {
        appModel.cloudflaredManager.pinnedArtifact
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            switch appModel.cloudflaredHelperState {
            case .checking:
                Text("Checking Cloudflare's helper.")
                    .font(TypeRamp.rowDetail)
            case .downloading(let progress):
                ProgressView(value: progress) {
                    Text("Downloading Cloudflare's helper…")
                        .font(TypeRamp.rowDetail)
                }
                Button("Cancel") {
                    appModel.cancelCloudflaredHelperInstall()
                }
                .controlSize(.small)
            case .verifying:
                HStack(spacing: Space.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking the download.")
                        .font(TypeRamp.rowDetail)
                }
            case .ready, .updateAvailable:
                Text("Cloudflare's helper is ready.")
                    .font(TypeRamp.rowDetail)
            case .notInstalled:
                offer(
                    headline: "One-time setup: MacRemote can install Cloudflare's helper for you.",
                    actionTitle: "Install Helper"
                )
            case .failed(let failure):
                offer(headline: failure.message, detail: failure.detail, actionTitle: "Try Again")
            }

            // Every state that is not mid-install keeps a way out: no screen
            // ends without a verb the user can press.
            if showsCheckAgain, !appModel.cloudflaredHelperState.isInstalling {
                Button("Check Again") {
                    appModel.refreshCloudflaredHelper()
                }
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func offer(headline: String, detail: String? = nil, actionTitle: String) -> some View {
        Text(headline)
            .font(TypeRamp.rowDetail)
            .fixedSize(horizontal: false, vertical: true)

        if let detail {
            MonoValue(detail, font: TypeRamp.machineCaption) {
                appModel.appendLog(level: .info, "Copied the Cloudflare helper failure detail.")
            }
            .foregroundStyle(.secondary)
        }

        Button(actionTitle) {
            appModel.installCloudflaredHelper()
        }
        .buttonStyle(.borderedProminent)

        DetailsDisclosure("What gets installed", id: disclosureID) {
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(consentSentence)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let artifact {
                    LabeledContent("Download") {
                        MonoValue(artifact.downloadURL.absoluteString, font: TypeRamp.machineCaption) {
                            appModel.appendLog(level: .info, "Copied the Cloudflare helper download address.")
                        }
                    }
                    LabeledContent("SHA-256") {
                        MonoValue(artifact.executableSHA256, font: TypeRamp.machineCaption) {
                            appModel.appendLog(level: .info, "Copied the Cloudflare helper checksum.")
                        }
                    }
                }

                HStack(spacing: Space.s3) {
                    Link("Apache 2.0 license", destination: CloudflaredManifest.licenseURL)
                    Link("Source code", destination: CloudflaredManifest.sourceURL)
                    Link("Release notes", destination: CloudflaredManifest.releaseNotesURL)
                }
                .font(TypeRamp.truthNote)

                Divider()

                Text("Prefer to install it yourself? MacRemote uses your own copy when it finds one.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s2) {
                    Text(verbatim: "brew install cloudflared")
                        .machineText(TypeRamp.machineCaption)
                        .padding(.horizontal, Space.s2)
                        .padding(.vertical, Space.s1)
                        .background(.quaternary.opacity(0.4), in: AppShape.mono)
                    CopyButton(value: "brew install cloudflared", help: "Copy Command") {
                        appModel.appendLog(level: .info, "Copied the Homebrew command for Cloudflare's helper.")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private var consentSentence: String {
        let size = artifact?.approximateDownloadSize ?? "a small download"
        return """
        Cloudflare's tunnel helper \(CloudflaredManifest.version), published by \
        \(CloudflaredManifest.publisher) — about \(size). MacRemote checks the download against \
        Cloudflare's published checksum and signature, and stores it only for its own use — \
        your shared tools can't touch it. You can remove it any time in Settings ▸ General.
        """
    }
}
