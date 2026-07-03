import AppKit
import SwiftUI

// MARK: - Address card (SPEC §4.3 — Instant Link / Your Domain, five-stage deploy)

fileprivate enum AddressMode: String {
    case instantLink
    case yourDomain
}

/// One truthful summary line shared by the collapsed card and the grid tile
/// (Rule 24 — states mode + hostname + deploy state).
@MainActor
private func addressSummaryLine(appModel: AppModel, mode: AddressMode) -> String {
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
            .lineLimit(2)
            .truncationMode(.middle)
        }
    }
}

struct ConnectionAddressCard: View {

    @Environment(AppModel.self) private var appModel
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
                    .lineLimit(1)
                    .truncationMode(.middle)
            },
            content: {
                VStack(alignment: .leading, spacing: Space.s4) {
                    if appModel.tunnelStatus == .unavailable {
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

    // MARK: cloudflared-missing banner (canonical rewrite #8, DA-11/TU-7 Check Again)

    private var unavailableBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text("Cloudflare's helper isn't installed. Install it with \(Text("brew install cloudflared").font(TypeRamp.machineCallout)), then check again.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Space.s2) {
                    Button("Copy Command") {
                        copyToPasteboard("brew install cloudflared")
                        appModel.appendLog(level: .info, "Copied the cloudflared install command.")
                    }
                    Button("Check Again") {
                        appModel.refreshTunnelStatus()
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: AppShape.mono)
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
            withAnimation(.snappy) {
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
            HStack(spacing: Space.s2) {
                Button("Load Domains") {
                    appModel.refreshCloudflareDomains()
                }
                .disabled(appModel.cloudflareCustomDomainState.isWorking)

                if appModel.cloudflareCustomDomainState.isWorking {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(appModel.cloudflareCustomDomainState.title)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Domain") {
                Picker("Domain", selection: $appModel.cloudflareDraft.selectedZoneID) {
                    Text("Choose a domain").tag(String?.none)
                    ForEach(appModel.cloudflareZones) { zone in
                        Text(zone.name).tag(Optional(zone.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .leading)
            }

            LabeledContent("Subdomain") {
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

            LabeledContent("API Token") {
                VStack(alignment: .leading, spacing: Space.s1) {
                    SecureField("Required to deploy", text: $appModel.cloudflareDraft.apiToken)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280, alignment: .leading)
                    Text("MacRemote never stores this token — you'll paste it again next launch")
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                }
            }

            deployHintRow

            Button("Deploy Your Domain") {
                hasAttemptedDeploy = true
                appModel.deployCustomDomainTunnel()
            }
            .disabled(!appModel.canDeployCustomDomainTunnel || appModel.cloudflareDraft.trimmedAPIToken.isEmpty)

            if showsDeployStages {
                DeployStageList(states: deployStageStates) { _ in
                    appModel.appendLog(level: .info, "Copied the deploy error detail.")
                }
            }

            if let deployment = appModel.lastCloudflareDeployment {
                proofGrid(deployment)
            }
        }
    }

    private var deployHintRow: some View {
        HStack(spacing: Space.s1) {
            Text(sanitized(appModel.customDomainDeployHint))
                .font(TypeRamp.truthNote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if hintMentionsToken {
                tokenRequirementsButton
            }
        }
    }

    private var hintMentionsToken: Bool {
        let hint = appModel.customDomainDeployHint.lowercased()
        return hint.contains("api token") || hint.contains("required permissions")
    }

    private var tokenRequirementsButton: some View {
        Button {
            isShowingTokenRequirements.toggle()
        } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("What your API token needs")
        .accessibilityLabel("What your API token needs")
        .popover(isPresented: $isShowingTokenRequirements, arrowEdge: .bottom) {
            tokenRequirementsPopover
        }
    }

    // Structured version of CloudflareServiceError.apiTokenPermissions.
    private var tokenRequirementsPopover: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("What your API token needs")
                .font(TypeRamp.cardTitle)
            ForEach(
                [
                    "Account · Cloudflare Tunnel · Read and Write",
                    "Zone · Zone · Read",
                    "Zone · DNS · Read and Write"
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
        case .failed: hasAttemptedDeploy
        case .idle, .loadingDomains, .ready: false
        }
    }

    private var deployStageStates: [DeployStage: DeployStageState] {
        switch appModel.cloudflareCustomDomainState {
        case .idle, .loadingDomains, .ready, .preparingLocalServer:
            return [:]
        case .deploying:
            return [.checkAccess: .active]
        case .deployed:
            return Dictionary(uniqueKeysWithValues: DeployStage.allCases.map { ($0, DeployStageState.done) })
        case .failed(let message):
            let stage = Self.stage(forFailure: message)
            var states: [DeployStage: DeployStageState] = [:]
            for earlier in DeployStage.allCases where earlier.rawValue < stage.rawValue {
                states[earlier] = .done
            }
            states[stage] = .failed(message: humanLine(for: message), raw: rawDetail(for: message))
            return states
        }
    }

    /// The model reports one coarse failure string; attribute it to a stage by
    /// its vocabulary. Token/permission problems always land on stage 1.
    private static func stage(forFailure message: String) -> DeployStage {
        let lowered = message.lowercased()
        if lowered.contains("api token") || lowered.contains("required permissions") || lowered.contains("wrangler") {
            return .checkAccess
        }
        if lowered.contains("dns") {
            return .configureDNS
        }
        if lowered.contains("cloudflared") {
            return .start
        }
        if lowered.contains("tunnel") {
            return .createTunnel
        }
        return .checkAccess
    }

    private func humanLine(for message: String) -> String {
        if let range = message.range(of: "Required permissions:") {
            return sanitized(String(message[..<range.lowerBound]).trimmingCharacters(in: .whitespaces))
        }
        return sanitized(message)
    }

    private func rawDetail(for message: String) -> String? {
        message.contains("Required permissions:") ? message : nil
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
