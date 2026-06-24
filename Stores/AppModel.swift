import AppKit
import Darwin
import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selection: NavigationSection? = .dashboard
    var tools: [ToolDefinition]
    var isRemCTLProfileEnabled: Bool
    var disabledToolIDs: Set<String>
    var logs: [AppLogEntry] = []
    var approvals: [ApprovalRequest] = []
    var toolCallApprovals: [ToolCallApprovalRequest] = []
    var connectedClients: [ConnectedClient] = []
    var clientToolPermissionSnapshot: [String: Set<String>] = [:]
    var serverStatus: ServerStatus = .stopped
    var tunnelStatus: TunnelStatus = .stopped
    var localServerURL: URL?
    var instanceID: String
    var fullDiskAccessReport = FullDiskAccessReport()
    var fullDiskAccessPrompt: FullDiskAccessPrompt?
    var macOSPrivacyAccessReport = MacOSPrivacyAccessReport()
    var smokeTestState: SmokeTestState = .idle
    var anthropicCredentialState: AnthropicCredentialState = .unknown
    var lastSmokeProof: SmokeProofRecord?

    private static let instanceIDKey = "MacRemote.instanceID"
    private static let remCTLProfileEnabledKey = "MacRemote.remCTLProfileEnabled"
    private static let disabledToolIDsKey = "MacRemote.disabledToolIDs"
    private static let confirmedFullDiskAccessSignatureKey = "MacRemote.confirmedFullDiskAccessSignature"

    private let userDefaults: UserDefaults
    private let tunnelService = TunnelService()
    private let toolStore: ToolRegistryStore
    private let clientToolPermissionStore: ClientToolPermissionStore
    private let toolSurfaceRuntime: ToolSurfaceRuntime
    private let fullDiskAccessService = FullDiskAccessService()
    private let macOSPrivacyAccessService = MacOSPrivacyAccessService()
    private let smokeTestService = SmokeTestService()
    private let processRunner = ProcessRunner()
    private var authCoordinator: OAuthCoordinator!
    private var toolCallApprovalCoordinator: ToolCallApprovalCoordinator!
    private var localServer: LocalMCPServer?
    private var approvalCoordinatorGeneration = 0

    init(userDefaults: UserDefaults = .standard, toolStore: ToolRegistryStore = ToolRegistryStore()) {
        self.userDefaults = userDefaults
        self.toolStore = toolStore
        self.clientToolPermissionStore = ClientToolPermissionStore(userDefaults: userDefaults)
        self.toolSurfaceRuntime = ToolSurfaceRuntime(environment: Self.toolEnvironment)
        self.instanceID = AppModel.makeInstanceID(userDefaults: userDefaults)
        let persistedDisabledToolIDs = Set(userDefaults.stringArray(forKey: Self.disabledToolIDsKey) ?? [])

        let loadedTools: [ToolDefinition]
        let startupError: String?
        do {
            loadedTools = try toolStore.loadUserDefinedTools()
            startupError = nil
        } catch {
            loadedTools = []
            startupError = "Could not load saved tools: \(error.localizedDescription)"
        }

        let disabledToolIDs = persistedDisabledToolIDs.intersection(Set(loadedTools.map(\.id)))
        self.tools = loadedTools
        self.disabledToolIDs = disabledToolIDs
        self.isRemCTLProfileEnabled = Self.remCTLToolsAreEnabled(in: loadedTools, disabledToolIDs: disabledToolIDs)
        self.clientToolPermissionSnapshot = clientToolPermissionStore.snapshot()
        self.toolSurfaceRuntime.update(tools: loadedTools.filter { !disabledToolIDs.contains($0.id) })

        installApprovalCoordinators()
        tunnelStatus = tunnelService.status(localServerURL: nil)
        if let startupError {
            logs.insert(AppLogEntry(date: Date(), level: .error, message: startupError), at: 0)
        }
        appendLog(
            level: .info,
            "MacRemote initialized with \(toolExposureSummary.total) exposed tools."
        )
    }

    private func installApprovalCoordinators() {
        approvalCoordinatorGeneration += 1
        let generation = approvalCoordinatorGeneration

        authCoordinator = OAuthCoordinator { [weak self] approvals in
            Task { @MainActor in
                guard self?.approvalCoordinatorGeneration == generation else { return }
                self?.approvals = approvals
                self?.connectedClients = self?.authCoordinator.connectedClientSnapshot() ?? []
            }
        }
        toolCallApprovalCoordinator = ToolCallApprovalCoordinator { [weak self] approvals in
            Task { @MainActor in
                guard self?.approvalCoordinatorGeneration == generation else { return }
                self?.toolCallApprovals = approvals
                if approvals.contains(where: { $0.state == .pending }) {
                    self?.selection = .approvals
                }
            }
        }
        approvals = []
        toolCallApprovals = []
        connectedClients = []
    }

    func startLocalServer() {
        switch serverStatus {
        case .running, .starting:
            return
        case .stopped, .failed:
            break
        }

        serverStatus = .starting
        Task {
            let accessReady = await refreshAccessStatusForServerStart()
            guard accessReady else {
                serverStatus = .failed("Required macOS access is missing for exposed tools.")
                tunnelStatus = tunnelService.status(localServerURL: localServerURL)
                return
            }

            startLocalServerAfterPermissionCheck()
        }
    }

    private func startLocalServerAfterPermissionCheck() {
        guard !serverStatus.isRunning else { return }
        let toolsToExpose = exposedTools
        guard !toolsToExpose.isEmpty else {
            serverStatus = .failed("Enable at least one tool before starting the local MCP server.")
            appendLog(level: .warning, "Blocked server start: no tools are currently exposed.")
            return
        }

        do {
            toolSurfaceRuntime.update(tools: toolsToExpose)
            let runtime = toolSurfaceRuntime
            let server = LocalMCPServer(
                instanceID: instanceID,
                toolProvider: {
                    runtime.toolsSnapshot()
                },
                authCoordinator: authCoordinator,
                toolCallApprovalCoordinator: toolCallApprovalCoordinator,
                toolExecutor: runtime,
                clientToolPermissionStore: clientToolPermissionStore
            ) { [weak self] event in
                Task { @MainActor in
                    self?.handleServerEvent(event)
                }
            }
            let port = try server.start()
            let url = URL(string: "http://127.0.0.1:\(port)")!
            localServer = server
            localServerURL = url
            serverStatus = .running(url)
            tunnelStatus = tunnelService.status(localServerURL: url)
            appendLog(level: .info, "Local MCP server started on \(url.absoluteString).")
        } catch {
            let message = error.localizedDescription
            serverStatus = .failed(message)
            appendLog(level: .error, "Local MCP server failed to start: \(message)")
        }
    }

    func stopLocalServer() {
        tunnelService.stop()
        localServer?.stop()
        localServer = nil
        localServerURL = nil
        approvals = authCoordinator.approvalSnapshot()
        toolCallApprovals = toolCallApprovalCoordinator.approvalSnapshot()
        connectedClients = authCoordinator.connectedClientSnapshot()
        serverStatus = .stopped
        tunnelStatus = tunnelService.status(localServerURL: nil)
        appendLog(level: .info, "Local MCP server stopped.")
    }

    func rotateInstanceID() {
        let previousInstanceID = instanceID

        stopExposureForInstanceRotation()

        var nextInstanceID = Self.newInstanceID()
        while nextInstanceID == previousInstanceID {
            nextInstanceID = Self.newInstanceID()
        }

        instanceID = nextInstanceID
        userDefaults.set(nextInstanceID, forKey: Self.instanceIDKey)
        installApprovalCoordinators()
        clientToolPermissionSnapshot = clientToolPermissionStore.clear()
        selection = .settings
        appendLog(
            level: .warning,
            "Rotated instance ID from \(Self.shortInstanceID(previousInstanceID)) to \(Self.shortInstanceID(nextInstanceID)); stopped exposure and cleared OAuth grants."
        )
    }

    func revokeOAuthGrants() {
        let summary = authCoordinator.revokeAllGrants()
        approvals = []
        connectedClients = []
        clientToolPermissionSnapshot = clientToolPermissionStore.clear()
        appendLog(
            level: .warning,
            "Revoked OAuth grants: \(summary.clients) clients, \(summary.authorizations) authorizations, \(summary.accessTokens) access tokens, \(summary.refreshTokens) refresh tokens."
        )
    }

    func runRemCTLTodayTest() {
        guard isToolIDExposed("remctl.today") else {
            appendLog(level: .warning, "Expose the Today tool before running the Reminders test.")
            return
        }

        Task {
            if toolRequiresFullDiskAccess(toolID: "remctl.today") {
                let report = await refreshFullDiskAccessStatus()
                guard report.isReady else {
                    presentFullDiskAccessPrompt(reason: .remCTLTest)
                    appendLog(level: .warning, "Blocked Reminders test: Full Disk Access is required for MacRemote's app-launched tool process.")
                    return
                }
            }

            await runToolTest(toolID: "remctl.today")
        }
    }

    func setRemCTLProfileEnabled(_ enabled: Bool) -> String? {
        isRemCTLProfileEnabled = enabled
        let remCTLToolIDs = Self.remCTLToolIDs(in: tools)
        guard !remCTLToolIDs.isEmpty else {
            return "No Reminders tools are installed."
        }
        if enabled {
            disabledToolIDs.subtract(Set(remCTLToolIDs))
        } else {
            disabledToolIDs.formUnion(remCTLToolIDs)
        }
        persistToolExposureState()
        if !enabled, !exposedToolsRequireFullDiskAccess {
            fullDiskAccessPrompt = nil
        }
        syncRunningToolSurface()
        appendLog(
            level: enabled ? .info : .warning,
            enabled ? "Exposed Reminders tools." : "Disabled Reminders tools."
        )
        return nil
    }

    func setToolEnabled(id: String, enabled: Bool) -> String? {
        guard let tool = tools.first(where: { $0.id == id }) else {
            return "Unknown tool."
        }

        let wasExposed = isToolExposed(tool)
        guard wasExposed != enabled else { return nil }

        if enabled,
           serverStatus.isRunning,
           tool.permissionRequirements.contains(.fullDiskAccess),
           !fullDiskAccessReport.isReady {
            presentFullDiskAccessPrompt(reason: .manualCheck)
            return "Run Check Access before exposing Full Disk Access-required tools while the server is running."
        }
        if enabled,
           serverStatus.isRunning,
           MacOSPrivacyAccessService.automaticallyCheckedRequirements(in: [tool]).isEmpty == false,
           !macOSPrivacyAccessReport.isReady {
            selection = .settings
            return "Run Check Access before exposing tools that need macOS privacy access while the server is running."
        }

        if enabled {
            disabledToolIDs.remove(id)
        } else {
            disabledToolIDs.insert(id)
        }
        persistToolExposureState()
        if !enabled, !exposedToolsRequireFullDiskAccess {
            fullDiskAccessPrompt = nil
        }
        syncRunningToolSurface()
        appendLog(level: enabled ? .info : .warning, "\(enabled ? "Exposed" : "Disabled") tool \(tool.name).")
        return nil
    }

    func isToolExposed(_ tool: ToolDefinition) -> Bool {
        !disabledToolIDs.contains(tool.id)
    }

    func isToolIDExposed(_ toolID: String) -> Bool {
        tools.first { $0.id == toolID }.map(isToolExposed) == true
    }

    func checkFullDiskAccess() {
        Task {
            let report = await refreshFullDiskAccessStatus()
            switch report.state {
            case .ready:
                fullDiskAccessPrompt = nil
                appendLog(level: .info, "Full Disk Access check passed for MacRemote.")
            case .required:
                presentFullDiskAccessPrompt(reason: .manualCheck)
                appendLog(level: .warning, "Full Disk Access required: \(singleLine(report.detail))")
            case .confirmationRequired:
                presentFullDiskAccessPrompt(reason: .manualCheck)
                appendLog(level: .warning, "Full Disk Access confirmation required: \(singleLine(report.detail))")
            case .failed(let message):
                presentFullDiskAccessPrompt(reason: .manualCheck)
                appendLog(level: .error, "Full Disk Access check failed: \(message)")
            default:
                break
            }

            let privacyReport = await refreshMacOSPrivacyAccessStatus()
            switch privacyReport.state {
            case .ready:
                appendLog(level: .info, "macOS privacy access check passed for MacRemote.")
            case .required:
                selection = .settings
                appendLog(level: .warning, "macOS privacy access required: \(singleLine(privacyReport.detail))")
            case .failed(let message):
                selection = .settings
                appendLog(level: .error, "macOS privacy access check failed: \(message)")
            default:
                break
            }
        }
    }

    func openFullDiskAccessHelper() {
        Task {
            fullDiskAccessReport = FullDiskAccessReport(
                state: .helperOpened,
                detail: "Opening the guided Full Disk Access setup. After changing System Settings, relaunch MacRemote before checking again.",
                targets: fullDiskAccessReport.targets
            )
            let report = await fullDiskAccessService.openHelper(
                environment: AppModel.toolEnvironment,
                tools: exposedTools
            )
            fullDiskAccessReport = report
            selection = .settings

            switch report.state {
            case .helperOpened:
                appendLog(level: .info, "Opened Full Disk Access helper.")
            case .failed(let message):
                appendLog(level: .error, "Could not open Full Disk Access helper: \(message)")
            default:
                appendLog(level: .warning, report.detail)
            }
        }
    }

    func resetMacRemoteFullDiskAccessGrant() {
        Task {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.macstories.MacRemote"
            do {
                let result = try await processRunner.run(
                    executablePath: "/usr/bin/tccutil",
                    arguments: ["reset", "SystemPolicyAllFiles", bundleID],
                    timeoutSeconds: 8,
                    outputByteLimit: 128 * 1024
                )

                guard result.succeeded else {
                    let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                    appendLog(level: .error, "Could not reset MacRemote Full Disk Access row: \(singleLine(detail))")
                    return
                }

                fullDiskAccessReport = FullDiskAccessReport(
                    state: .required,
                    detail: "Reset MacRemote's stale Full Disk Access row. Add the current MacRemote.app in System Settings, relaunch MacRemote, then check again.",
                    targets: fullDiskAccessReport.targets,
                    confirmationSignature: fullDiskAccessReport.confirmationSignature,
                    automaticChecksPassed: fullDiskAccessReport.automaticChecksPassed
                )
                appendLog(level: .warning, "Reset MacRemote Full Disk Access row for \(bundleID). Add the current app again in System Settings.")
            } catch {
                appendLog(level: .error, "Could not reset MacRemote Full Disk Access row: \(error.localizedDescription)")
            }
        }
    }

    func confirmFullDiskAccessSetup() {
        guard fullDiskAccessReport.requiresManualConfirmation,
              let signature = fullDiskAccessReport.confirmationSignature else {
            appendLog(level: .warning, "No manual Full Disk Access confirmation is currently required.")
            return
        }

        userDefaults.set(signature, forKey: Self.confirmedFullDiskAccessSignatureKey)
        fullDiskAccessReport = FullDiskAccessReport(
            state: .ready,
            detail: "Manual Full Disk Access confirmation recorded for the current FDA-required tool surface.",
            targets: fullDiskAccessReport.targets,
            confirmationSignature: signature,
            automaticChecksPassed: fullDiskAccessReport.automaticChecksPassed
        )
        fullDiskAccessPrompt = nil
        appendLog(level: .warning, "Recorded manual Full Disk Access confirmation for the current FDA-required tool surface.")
    }

    func runToolTest(toolID: String, parameters: [String: ToolArgumentValue] = [:]) async {
        do {
            let result = try await toolExecutorSnapshot().execute(toolID: toolID, parameters: parameters)
            if result.succeeded {
                appendLog(level: .info, "\(result.toolName) completed in \(result.duration.formattedDuration) with \(result.outputByteCount) bytes.")
            } else {
                appendLog(level: .warning, "\(result.toolName) exited \(result.exitCode) in \(result.duration.formattedDuration). \(failureDetail(from: result))")
            }
        } catch {
            appendLog(level: .error, "Tool test failed: \(error.localizedDescription)")
        }
    }

    func addUserTool(from draft: ToolDefinitionDraft) -> String? {
        do {
            let tool = try draft.makeTool()
            appendTool(tool)
            try persistUserDefinedTools()
            persistToolExposureState()
            syncRunningToolSurface()
            if isToolExposed(tool) {
                appendLog(level: .info, "Added tool \(tool.name).")
            } else {
                appendLog(level: .warning, "Added tool \(tool.name) disabled until Full Disk Access passes.")
            }
            return nil
        } catch {
            appendLog(level: .error, "Could not add tool: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func addUserTools(from presetSet: DefaultToolPresetSet) -> String? {
        addUserTools(from: presetSet.presets, sourceName: presetSet.name)
    }

    func addUserTools(from presets: [DefaultToolPreset], sourceName: String) -> String? {
        let existingSignatures = Set(tools.map(Self.toolSignature))
        let candidates = presets.filter { preset in
            let signature = Self.toolSignature(
                executablePath: preset.executablePath,
                argumentPattern: preset.draft.argumentPattern
            )
            return !existingSignatures.contains(signature)
        }

        guard !candidates.isEmpty else {
            appendLog(level: .warning, "No new tools to add from \(sourceName).")
            return "All tools in \(sourceName) are already installed."
        }

        let originalTools = tools
        let originalDisabledToolIDs = disabledToolIDs

        do {
            var addedDisabledForFDA = 0
            for preset in candidates {
                let tool = try preset.draft.makeTool()
                appendTool(tool)
                if !isToolExposed(tool) {
                    addedDisabledForFDA += 1
                }
            }

            try persistUserDefinedTools()
            persistToolExposureState()
            syncRunningToolSurface()

            let skipped = presets.count - candidates.count
            let disabledSuffix = addedDisabledForFDA > 0 ? " \(addedDisabledForFDA) disabled until Full Disk Access passes." : ""
            let skippedSuffix = skipped > 0 ? " Skipped \(skipped) already installed." : ""
            appendLog(level: .info, "Added \(candidates.count) tools from \(sourceName).\(skippedSuffix)\(disabledSuffix)")
            return nil
        } catch {
            tools = originalTools
            disabledToolIDs = originalDisabledToolIDs
            appendLog(level: .error, "Could not add tools from \(sourceName): \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func deleteUserTool(id: String) -> String? {
        guard let tool = tools.first(where: { $0.id == id && $0.isUserDefined }) else {
            return "Only tools you added can be deleted."
        }

        tools.removeAll { $0.id == id && $0.isUserDefined }
        disabledToolIDs.remove(id)
        do {
            persistToolExposureState()
            try persistUserDefinedTools()
            clientToolPermissionSnapshot = clientToolPermissionStore.removeToolIDFromAllClients(id)
            syncRunningToolSurface()
            appendLog(level: .warning, "Deleted tool \(tool.name).")
            return nil
        } catch {
            tools.append(tool)
            appendLog(level: .error, "Could not delete tool: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func approveAuthorizationRequest(_ id: UUID) {
        if localServer?.approveAuthorizationRequest(id: id) == true {
            appendLog(level: .info, "Authorization request approved on host Mac.")
        }
    }

    func denyAuthorizationRequest(_ id: UUID) {
        if localServer?.denyAuthorizationRequest(id: id) == true {
            appendLog(level: .warning, "Authorization request denied on host Mac.")
        }
    }

    func approveToolCallRequest(_ id: UUID) {
        if toolCallApprovalCoordinator.approve(requestID: id) {
            appendLog(level: .info, "Tool call approved on host Mac.")
        }
    }

    func approveToolCallForever(_ id: UUID) {
        guard let request = toolCallApprovals.first(where: { $0.id == id }),
              let clientID = request.clientID else {
            approveToolCallRequest(id)
            return
        }

        setToolAlwaysAllowed(true, toolID: request.toolID, clientID: clientID)
        if toolCallApprovalCoordinator.approve(requestID: id) {
            appendLog(level: .info, "\(request.toolName) approved forever for \(request.clientName ?? "this client").")
        }
    }

    func denyToolCallRequest(_ id: UUID) {
        if toolCallApprovalCoordinator.deny(requestID: id) {
            appendLog(level: .warning, "Tool call denied on host Mac.")
        }
    }

    func isToolAlwaysAllowed(toolID: String, clientID: String) -> Bool {
        clientToolPermissionSnapshot[clientID]?.contains(toolID) == true
    }

    func alwaysAllowedToolIDs(for clientID: String) -> Set<String> {
        clientToolPermissionSnapshot[clientID] ?? []
    }

    func setToolAlwaysAllowed(_ isAllowed: Bool, toolID: String, clientID: String) {
        clientToolPermissionSnapshot = clientToolPermissionStore.setAllowed(
            isAllowed,
            clientID: clientID,
            toolID: toolID
        )
        let toolName = tools.first { $0.id == toolID }?.name ?? toolID
        let clientName = connectedClients.first { $0.id == clientID }?.name ?? "client"
        appendLog(
            level: isAllowed ? .info : .warning,
            "\(isAllowed ? "Always allow" : "Removed always allow for") \(toolName) for \(clientName)."
        )
    }

    func allowAllCurrentTools(for clientID: String) {
        clientToolPermissionSnapshot = clientToolPermissionStore.replaceAllowedToolIDs(
            Set(tools.map(\.id)),
            clientID: clientID
        )
        let clientName = connectedClients.first { $0.id == clientID }?.name ?? "client"
        appendLog(level: .warning, "Always allow all current tools for \(clientName).")
    }

    func clearToolAllowances(for clientID: String) {
        clientToolPermissionSnapshot = clientToolPermissionStore.removeClient(clientID)
        let clientName = connectedClients.first { $0.id == clientID }?.name ?? "client"
        appendLog(level: .warning, "Cleared always-allow tools for \(clientName).")
    }

    func refreshTunnelStatus() {
        tunnelStatus = tunnelService.status(localServerURL: localServerURL)
    }

    func startTunnel() {
        guard let localServerURL else {
            tunnelStatus = .stopped
            appendLog(level: .warning, "Start the local MCP server before creating a tunnel.")
            return
        }

        tunnelStatus = .starting
        do {
            try tunnelService.startQuickTunnel(localServerURL: localServerURL) { [weak self] event in
                Task { @MainActor in
                    self?.handleTunnelEvent(event)
                }
            }
            appendLog(level: .info, "Starting Cloudflare Tunnel for \(localServerURL.absoluteString).")
        } catch {
            let message = error.localizedDescription
            tunnelStatus = .failed(message)
            appendLog(level: .error, "Cloudflare Tunnel failed to start: \(message)")
        }
    }

    func stopTunnel() {
        tunnelService.stop()
        tunnelStatus = localServerURL == nil ? .stopped : .ready
        appendLog(level: .info, "Cloudflare Tunnel stopped.")
    }

    func checkSmokeReadiness() {
        guard !smokeTestState.isRunning else {
            appendLog(level: .warning, "Wait for the current smoke test before checking readiness again.")
            return
        }

        anthropicCredentialState = .checking
        appendLog(level: .info, "Checking remote MCP smoke test readiness.")

        Task {
            let fdaRequired = exposedToolsRequireFullDiskAccess
            let fdaReport = fdaRequired ? await refreshFullDiskAccessStatus() : fullDiskAccessReport
            let fdaReady = !fdaRequired || fdaReport.isReady
            let privacyRequired = exposedToolsRequireCheckedMacOSPrivacyAccess
            let privacyReport = privacyRequired ? await refreshMacOSPrivacyAccessStatus() : macOSPrivacyAccessReport
            let privacyReady = !privacyRequired || privacyReport.isReady
            let credentialState = await smokeTestService.checkAnthropicAPIKey(environment: AppModel.toolEnvironment)
            anthropicCredentialState = credentialState

            let fdaMessage = fdaReady ? "Full Disk Access ready" : "Full Disk Access not ready"
            let privacyMessage = privacyReady ? "macOS privacy ready" : "macOS privacy not ready"
            let credentialMessage = credentialState.isReady ? "Anthropic key ready" : "Anthropic key not ready"
            if fdaRequired, !fdaReport.isReady {
                presentFullDiskAccessPrompt(reason: .remoteProof)
            }
            if privacyRequired, !privacyReport.isReady {
                selection = .settings
            }
            appendLog(
                level: credentialState.isReady && fdaReady && privacyReady ? .info : .warning,
                "\(fdaMessage); \(privacyMessage); \(credentialMessage)."
            )
        }
    }

    func runSmokeTest(mode: SmokeTestMode) {
        guard let mcpURL = currentPublicMCPURL else {
            appendLog(level: .warning, "Create a public MCP URL before running the \(mode.logTitle).")
            return
        }

        let readiness = smokeReadiness
        let canRun = mode == .preflight ? readiness.canRunPreflight : readiness.canRunAnthropicAPI
        guard canRun else {
            appendLog(level: .warning, "\(mode.logTitle) blocked: \(readiness.blockingDetails.first ?? "check readiness first").")
            return
        }

        guard !smokeTestState.isRunning else {
            appendLog(level: .warning, "A MacRemote smoke test is already running.")
            return
        }

        smokeTestState = .running(mode)
        appendLog(level: .info, "Started \(mode.logTitle).")
        let toolSurface = smokeProofToolSurfaceDescription
        let mcpURLString = mcpURL.absoluteString
        let smokeToolID = smokeToolID(for: mode)

        Task {
            do {
                let result = try await smokeTestService.run(
                    mode: mode,
                    mcpURL: mcpURL,
                    toolID: smokeToolID,
                    environment: AppModel.toolEnvironment
                )

                if result.succeeded {
                    smokeTestState = .passed(mode, "\(result.summary) in \(result.duration.formattedDuration).")
                    appendLog(level: .info, "\(mode.logTitle) passed in \(result.duration.formattedDuration).")
                } else {
                    smokeTestState = .failed(mode, result.summary)
                    appendLog(level: .warning, "\(mode.logTitle) failed: \(result.summary)")
                }
                lastSmokeProof = SmokeProofRecord(
                    date: Date(),
                    mode: mode,
                    mcpURL: mcpURLString,
                    toolSurface: toolSurface,
                    succeeded: result.succeeded,
                    resultSummary: result.summary,
                    exitCode: result.processResult.exitCode,
                    duration: result.duration,
                    markers: SmokeTestService.proofMarkers(for: result.processResult)
                )
            } catch {
                let message = error.localizedDescription
                smokeTestState = .failed(mode, message)
                lastSmokeProof = SmokeProofRecord(
                    date: Date(),
                    mode: mode,
                    mcpURL: mcpURLString,
                    toolSurface: toolSurface,
                    succeeded: false,
                    resultSummary: message,
                    exitCode: nil,
                    duration: nil,
                    markers: []
                )
                appendLog(level: .error, "\(mode.logTitle) failed: \(message)")
            }
        }
    }

    func publicMCPURL(for tunnelBaseURL: URL) -> URL {
        tunnelBaseURL
            .appendingPathComponent("mcp")
            .appendingPathComponent(instanceID)
    }

    func smokeTestCopyCommand(for mode: SmokeTestMode, mcpURL: URL) -> String {
        SmokeTestService.copyCommand(for: mode, mcpURL: mcpURL, toolID: smokeToolID(for: mode))
    }

    var currentPublicMCPURL: URL? {
        if case .running(let publicURL) = tunnelStatus {
            return self.publicMCPURL(for: publicURL)
        }
        return nil
    }

    var toolExposureSummary: ToolExposureSummary {
        ToolExposureSummary(tools: exposedTools)
    }

    var smokeReadiness: SmokeReadiness {
        let exposureSummary = toolExposureSummary
        let fdaRequired = exposedToolsRequireFullDiskAccess
        let fdaReady = !fdaRequired || fullDiskAccessReport.isReady || serverStatus.isRunning
        let privacyRequired = exposedToolsRequireCheckedMacOSPrivacyAccess
        let privacyReady = !privacyRequired || macOSPrivacyAccessReport.isReady || serverStatus.isRunning
        let preflightToolID = smokeToolID(for: .preflight)
        let anthropicToolID = smokeToolID(for: .anthropicAPI)
        let publicMCPURL = currentPublicMCPURL

        let checks = [
            fullDiskAccessReadinessCheck(isRequired: fdaRequired, isReady: fdaReady),
            macOSPrivacyReadinessCheck(isRequired: privacyRequired, isReady: privacyReady),
            localServerReadinessCheck(),
            tunnelReadinessCheck(publicMCPURL: publicMCPURL),
            toolSurfaceReadinessCheck(
                summary: exposureSummary,
                preflightToolID: preflightToolID,
                anthropicToolID: anthropicToolID
            ),
            anthropicCredentialReadinessCheck()
        ]

        let commonReady = fdaReady && privacyReady && serverStatus.isRunning && publicMCPURL != nil && preflightToolID != nil
        return SmokeReadiness(
            checks: checks,
            canRunPreflight: commonReady && !smokeTestState.isRunning,
            canRunAnthropicAPI: commonReady && anthropicToolID != nil && anthropicCredentialState.isReady && !smokeTestState.isRunning
        )
    }

    func dismissFullDiskAccessPrompt() {
        fullDiskAccessPrompt = nil
    }

    func relaunchMacRemote() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            appendLog(level: .error, "Cannot relaunch MacRemote because this process is not running from an app bundle.")
            return
        }

        appendLog(level: .info, "Relaunching MacRemote from \(bundleURL.path).")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", bundleURL.path]

        do {
            try process.run()
        } catch {
            appendLog(level: .error, "Could not relaunch MacRemote: \(error.localizedDescription)")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            NSApp.terminate(nil)

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                Darwin.exit(0)
            }
        }
    }

    func appendLog(level: AppLogEntry.Level, _ message: String) {
        logs.insert(AppLogEntry(date: Date(), level: level, message: message), at: 0)
        if logs.count > 250 {
            logs.removeLast(logs.count - 250)
        }
    }

    private static func makeInstanceID(userDefaults: UserDefaults) -> String {
        if let existing = userDefaults.string(forKey: instanceIDKey),
           existing.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil {
            return existing
        }

        let instanceID = newInstanceID()
        userDefaults.set(instanceID, forKey: instanceIDKey)
        return instanceID
    }

    private static func newInstanceID() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func shortInstanceID(_ value: String) -> String {
        "\(value.prefix(8))..."
    }

    private static func remCTLToolIDs(in tools: [ToolDefinition]) -> [String] {
        tools
            .filter { tool in
                tool.executablePath == RemCTLToolCatalog.executablePath || tool.id.hasPrefix("remctl.")
            }
            .map(\.id)
    }

    private static func remCTLToolsAreEnabled(in tools: [ToolDefinition], disabledToolIDs: Set<String>) -> Bool {
        let remCTLToolIDs = remCTLToolIDs(in: tools)
        return !remCTLToolIDs.isEmpty && remCTLToolIDs.allSatisfy { !disabledToolIDs.contains($0) }
    }

    private static var toolEnvironment: [String: String] {
        ExecutableLocator.toolEnvironment
    }

    private func appendTool(_ tool: ToolDefinition) {
        tools.append(tool)
        let canExposeImmediately = !serverStatus.isRunning ||
            !tool.permissionRequirements.contains(.fullDiskAccess) ||
            fullDiskAccessReport.isReady
        if canExposeImmediately {
            disabledToolIDs.remove(tool.id)
        } else {
            disabledToolIDs.insert(tool.id)
            presentFullDiskAccessPrompt(reason: .manualCheck)
        }
    }

    private static func toolSignature(_ tool: ToolDefinition) -> String {
        toolSignature(executablePath: tool.executablePath, argumentPattern: tool.argumentPattern)
    }

    private static func toolSignature(executablePath: String, argumentPattern: [String]) -> String {
        ([executablePath] + argumentPattern).joined(separator: "\u{1f}")
    }

    private func failureDetail(from result: ToolExecutionOutcome) -> String {
        let stderr = result.stderr
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let stderr, !stderr.isEmpty else {
            return "No stderr captured."
        }

        let capped = String(stderr.prefix(180))
        return "stderr: \(capped)"
    }

    private func persistUserDefinedTools() throws {
        try toolStore.saveUserDefinedTools(tools)
    }

    private func persistToolExposureState() {
        userDefaults.set(disabledToolIDs.sorted(), forKey: Self.disabledToolIDsKey)
        isRemCTLProfileEnabled = Self.remCTLToolsAreEnabled(in: tools, disabledToolIDs: disabledToolIDs)
        userDefaults.set(isRemCTLProfileEnabled, forKey: Self.remCTLProfileEnabledKey)
    }

    private func toolExecutorSnapshot() -> ConfiguredToolExecutor {
        ConfiguredToolExecutor(tools: exposedTools, environment: AppModel.toolEnvironment)
    }

    private func syncRunningToolSurface() {
        toolSurfaceRuntime.update(tools: exposedTools)
        if serverStatus.isRunning {
            appendLog(level: .info, "Updated exposed tools; connected clients can refresh tools/list.")
        }
    }

    private var smokeProofToolSurfaceDescription: String {
        let summary = toolExposureSummary
        return "\(summary.total) tools; \(summary.capabilityDescription); \(summary.genericAdapters) generic adapters"
    }

    private var exposedTools: [ToolDefinition] {
        tools.filter(isToolExposed)
    }

    private var exposedToolsRequireFullDiskAccess: Bool {
        exposedTools.contains { $0.permissionRequirements.contains(.fullDiskAccess) }
    }

    private var exposedToolsRequireCheckedMacOSPrivacyAccess: Bool {
        !MacOSPrivacyAccessService.automaticallyCheckedRequirements(in: exposedTools).isEmpty
    }

    private func toolRequiresFullDiskAccess(toolID: String) -> Bool {
        exposedTools.first { $0.id == toolID }?.permissionRequirements.contains(.fullDiskAccess) == true
    }

    private func presentFullDiskAccessPrompt(reason: FullDiskAccessPrompt.Reason) {
        fullDiskAccessPrompt = FullDiskAccessPrompt(reason: reason)
    }

    private func fullDiskAccessReadinessCheck(isRequired: Bool, isReady: Bool) -> SmokeReadinessCheck {
        guard isRequired else {
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .ready,
                detail: "No exposed tools currently require Full Disk Access."
            )
        }

        if isReady {
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .ready,
                detail: "Required protected-data tools can run from MacRemote."
            )
        }

        switch fullDiskAccessReport.state {
        case .checking:
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .checking,
                detail: "MacRemote is checking protected-data access."
            )
        case .required:
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .blocked,
                detail: "Grant FDA to every target shown in Settings, then relaunch MacRemote."
            )
        case .confirmationRequired:
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .blocked,
                detail: "Confirm the current Full Disk Access setup in Settings."
            )
        case .failed(let message):
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .blocked,
                detail: message
            )
        default:
            return SmokeReadinessCheck(
                id: "full-disk-access",
                title: "Full Disk Access",
                status: .blocked,
                detail: "Run Check Readiness or Check Access before exposing the MCP server."
            )
        }
    }

    private func macOSPrivacyReadinessCheck(isRequired: Bool, isReady: Bool) -> SmokeReadinessCheck {
        guard isRequired else {
            return SmokeReadinessCheck(
                id: "macos-privacy",
                title: "macOS Privacy",
                status: .ready,
                detail: "No exposed tools require automatically checked macOS privacy access."
            )
        }

        if isReady {
            return SmokeReadinessCheck(
                id: "macos-privacy",
                title: "macOS Privacy",
                status: .ready,
                detail: "Required macOS privacy services are ready for MacRemote."
            )
        }

        switch macOSPrivacyAccessReport.state {
        case .checking:
            return SmokeReadinessCheck(
                id: "macos-privacy",
                title: "macOS Privacy",
                status: .checking,
                detail: "MacRemote is checking protected app-service access."
            )
        case .required:
            return SmokeReadinessCheck(
                id: "macos-privacy",
                title: "macOS Privacy",
                status: .blocked,
                detail: macOSPrivacyAccessReport.detail
            )
        case .failed(let message):
            return SmokeReadinessCheck(
                id: "macos-privacy",
                title: "macOS Privacy",
                status: .blocked,
                detail: message
            )
        default:
            return SmokeReadinessCheck(
                id: "macos-privacy",
                title: "macOS Privacy",
                status: .blocked,
                detail: "Run Check Readiness or Check Access before exposing the MCP server."
            )
        }
    }

    private func localServerReadinessCheck() -> SmokeReadinessCheck {
        switch serverStatus {
        case .running(let url):
            return SmokeReadinessCheck(
                id: "local-server",
                title: "Local MCP Server",
                status: .ready,
                detail: "Listening on \(url.absoluteString)."
            )
        case .starting:
            return SmokeReadinessCheck(
                id: "local-server",
                title: "Local MCP Server",
                status: .checking,
                detail: "Server is starting."
            )
        case .failed(let message):
            return SmokeReadinessCheck(
                id: "local-server",
                title: "Local MCP Server",
                status: .blocked,
                detail: message
            )
        case .stopped:
            return SmokeReadinessCheck(
                id: "local-server",
                title: "Local MCP Server",
                status: .blocked,
                detail: "Start the local MCP server after required permission checks pass."
            )
        }
    }

    private func tunnelReadinessCheck(publicMCPURL: URL?) -> SmokeReadinessCheck {
        if let publicMCPURL {
            return SmokeReadinessCheck(
                id: "public-tunnel",
                title: "Public MCP URL",
                status: .ready,
                detail: publicMCPURL.absoluteString
            )
        }

        switch tunnelStatus {
        case .starting:
            return SmokeReadinessCheck(
                id: "public-tunnel",
                title: "Public MCP URL",
                status: .checking,
                detail: "Waiting for Cloudflare Tunnel."
            )
        case .failed(let message):
            return SmokeReadinessCheck(
                id: "public-tunnel",
                title: "Public MCP URL",
                status: .blocked,
                detail: message
            )
        default:
            return SmokeReadinessCheck(
                id: "public-tunnel",
                title: "Public MCP URL",
                status: .blocked,
                detail: "Start the public tunnel after the local server is running."
            )
        }
    }

    private func toolSurfaceReadinessCheck(
        summary: ToolExposureSummary,
        preflightToolID: String?,
        anthropicToolID: String?
    ) -> SmokeReadinessCheck {
        guard summary.total > 0, let preflightToolID else {
            return SmokeReadinessCheck(
                id: "tool-surface",
                title: "Tool Surface",
                status: .blocked,
                detail: "Enable at least one tool before running the remote proof."
            )
        }

        if let anthropicToolID {
            return SmokeReadinessCheck(
                id: "tool-surface",
                title: "Tool Surface",
                status: .ready,
                detail: "\(summary.total) tools exposed: \(summary.capabilityDescription). Smoke tool: \(anthropicToolID)."
            )
        }

        return SmokeReadinessCheck(
            id: "tool-surface",
            title: "Tool Surface",
            status: .warning,
            detail: "\(summary.total) tools exposed for preflight with \(preflightToolID); add a read-only tool for the full API smoke test."
        )
    }

    private func smokeToolID(for mode: SmokeTestMode) -> String? {
        switch mode {
        case .preflight:
            if exposedTools.contains(where: { $0.id == "remctl.today" }) {
                return "remctl.today"
            }
            return smokeReadOnlyTool?.id ?? exposedTools.sorted { $0.name < $1.name }.first?.id
        case .anthropicAPI:
            return smokeReadOnlyTool?.id
        }
    }

    private var smokeReadOnlyTool: ToolDefinition? {
        if let remCTLToday = exposedTools.first(where: { $0.id == "remctl.today" && $0.capability == .readOnly }) {
            return remCTLToday
        }
        return exposedTools
            .filter { $0.capability == .readOnly }
            .sorted { $0.name < $1.name }
            .first
    }

    private func anthropicCredentialReadinessCheck() -> SmokeReadinessCheck {
        switch anthropicCredentialState {
        case .ready:
            return SmokeReadinessCheck(
                id: "anthropic-key",
                title: "Anthropic API Key",
                status: .ready,
                detail: "A non-empty key is available."
            )
        case .checking:
            return SmokeReadinessCheck(
                id: "anthropic-key",
                title: "Anthropic API Key",
                status: .checking,
                detail: "Checking ANTHROPIC_API_KEY or op-get."
            )
        case .failed(let message):
            return SmokeReadinessCheck(
                id: "anthropic-key",
                title: "Anthropic API Key",
                status: .blocked,
                detail: message
            )
        case .unknown:
            return SmokeReadinessCheck(
                id: "anthropic-key",
                title: "Anthropic API Key",
                status: .blocked,
                detail: "Run Check Readiness before the full API smoke test."
            )
        }
    }

    private func stopExposureForInstanceRotation() {
        toolCallApprovalCoordinator.denyAllPending()
        tunnelService.stop()
        localServer?.stop()
        localServer = nil
        localServerURL = nil
        serverStatus = .stopped
        tunnelStatus = tunnelService.status(localServerURL: nil)
    }

    private func refreshFullDiskAccessStatus() async -> FullDiskAccessReport {
        fullDiskAccessReport = FullDiskAccessReport(
            state: .checking,
            detail: "Checking protected-data access from MacRemote.",
            targets: fullDiskAccessReport.targets
        )
        var report = await fullDiskAccessService.check(
            environment: AppModel.toolEnvironment,
            tools: exposedTools
        )

        if report.requiresManualConfirmation,
           let signature = report.confirmationSignature,
           userDefaults.string(forKey: Self.confirmedFullDiskAccessSignatureKey) == signature {
            report = FullDiskAccessReport(
                state: .ready,
                detail: "Manual Full Disk Access confirmation is recorded for the current FDA-required tool surface.",
                targets: report.targets,
                confirmationSignature: signature,
                automaticChecksPassed: report.automaticChecksPassed
            )
        }

        fullDiskAccessReport = report
        return report
    }

    private func refreshMacOSPrivacyAccessStatus() async -> MacOSPrivacyAccessReport {
        macOSPrivacyAccessReport = MacOSPrivacyAccessReport(
            state: .checking,
            detail: "Checking macOS privacy access from MacRemote.",
            checkedRequirements: macOSPrivacyAccessReport.checkedRequirements
        )
        let report = await macOSPrivacyAccessService.check(tools: exposedTools)
        macOSPrivacyAccessReport = report
        return report
    }

    private func refreshAccessStatusForServerStart() async -> Bool {
        if exposedToolsRequireFullDiskAccess {
            let report = await refreshFullDiskAccessStatus()
            guard report.isReady else {
                presentFullDiskAccessPrompt(reason: .serverStart)
                appendLog(level: .warning, "Blocked server start: grant Full Disk Access before exposing FDA-required tools.")
                return false
            }
        }

        if exposedToolsRequireCheckedMacOSPrivacyAccess {
            let report = await refreshMacOSPrivacyAccessStatus()
            guard report.isReady else {
                selection = .settings
                appendLog(level: .warning, "Blocked server start: \(singleLine(report.detail))")
                return false
            }
        }

        return true
    }

    private func singleLine(_ value: String) -> String {
        value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func handleServerEvent(_ event: LocalMCPServerEvent) {
        switch event {
        case .log(let level, let message):
            appendLog(level: level, message)
        case .approvalsChanged(let approvals):
            self.approvals = approvals
            connectedClients = authCoordinator.connectedClientSnapshot()
            if approvals.contains(where: { $0.state == .pending }) {
                selection = .approvals
            }
        case .clientsChanged(let clients):
            connectedClients = clients
        }
    }

    private func handleTunnelEvent(_ event: TunnelServiceEvent) {
        switch event {
        case .log(let message):
            appendLog(level: .info, message)
        case .started(let publicURL):
            tunnelStatus = .running(publicURL)
            appendLog(level: .info, "Cloudflare Tunnel ready at \(publicURL.absoluteString).")
        case .stopped:
            tunnelStatus = tunnelService.status(localServerURL: localServerURL)
            appendLog(level: .info, "Cloudflare Tunnel process exited.")
        case .failed(let message):
            tunnelStatus = .failed(message)
            appendLog(level: .error, message)
        }
    }
}
