import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selection: NavigationSection? = .dashboard
    var tools: [ToolDefinition]
    var logs: [AppLogEntry] = []
    var approvals: [ApprovalRequest] = []
    var toolCallApprovals: [ToolCallApprovalRequest] = []
    var serverStatus: ServerStatus = .stopped
    var tunnelStatus: TunnelStatus = .stopped
    var localServerURL: URL?
    var instanceID: String
    var fullDiskAccessReport = FullDiskAccessReport()
    var smokeTestState: SmokeTestState = .idle

    private static let instanceIDKey = "MacRemote.instanceID"

    private let userDefaults: UserDefaults
    private let tunnelService = TunnelService()
    private let toolStore = ToolRegistryStore()
    private let fullDiskAccessService = FullDiskAccessService()
    private let smokeTestService = SmokeTestService()
    private var authCoordinator: OAuthCoordinator!
    private var toolCallApprovalCoordinator: ToolCallApprovalCoordinator!
    private var localServer: LocalMCPServer?
    private var approvalCoordinatorGeneration = 0

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.instanceID = AppModel.makeInstanceID(userDefaults: userDefaults)

        do {
            let customTools = try toolStore.loadUserDefinedTools()
            tools = RemCTLToolCatalog.builtInTools + customTools
        } catch {
            tools = RemCTLToolCatalog.builtInTools
            logs.insert(AppLogEntry(date: Date(), level: .error, message: "Could not load custom tools: \(error.localizedDescription)"), at: 0)
        }

        installApprovalCoordinators()
        tunnelStatus = tunnelService.status(localServerURL: nil)
        appendLog(level: .info, "MacRemote initialized with full RemCTL CLI profile.")
    }

    private func installApprovalCoordinators() {
        approvalCoordinatorGeneration += 1
        let generation = approvalCoordinatorGeneration

        authCoordinator = OAuthCoordinator { [weak self] approvals in
            Task { @MainActor in
                guard self?.approvalCoordinatorGeneration == generation else { return }
                self?.approvals = approvals
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
            let report = await refreshFullDiskAccessStatus()
            guard report.isReady else {
                serverStatus = .failed("Full Disk Access required for full RemCTL.")
                tunnelStatus = tunnelService.status(localServerURL: localServerURL)
                selection = .settings
                appendLog(level: .warning, "Blocked server start: grant Full Disk Access to MacRemote before exposing the full RemCTL CLI.")
                return
            }

            startLocalServerAfterPermissionCheck()
        }
    }

    private func startLocalServerAfterPermissionCheck() {
        guard !serverStatus.isRunning else { return }

        do {
            let server = LocalMCPServer(
                instanceID: instanceID,
                tools: tools,
                authCoordinator: authCoordinator,
                toolCallApprovalCoordinator: toolCallApprovalCoordinator,
                toolExecutor: toolExecutorSnapshot()
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
        selection = .settings
        appendLog(
            level: .warning,
            "Rotated instance ID from \(Self.shortInstanceID(previousInstanceID)) to \(Self.shortInstanceID(nextInstanceID)); stopped exposure and cleared OAuth grants."
        )
    }

    func revokeOAuthGrants() {
        let summary = authCoordinator.revokeAllGrants()
        approvals = []
        appendLog(
            level: .warning,
            "Revoked OAuth grants: \(summary.clients) clients, \(summary.authorizations) authorizations, \(summary.accessTokens) access tokens, \(summary.refreshTokens) refresh tokens."
        )
    }

    func runRemCTLTodayTest() {
        Task {
            let report = await refreshFullDiskAccessStatus()
            guard report.isReady else {
                selection = .settings
                appendLog(level: .warning, "Blocked RemCTL test: Full Disk Access is required for MacRemote's app-launched RemCTL process.")
                return
            }

            await runToolTest(toolID: "remctl.today")
        }
    }

    func checkFullDiskAccess() {
        Task {
            let report = await refreshFullDiskAccessStatus()
            switch report.state {
            case .ready:
                appendLog(level: .info, "Full Disk Access check passed for MacRemote.")
            case .required:
                appendLog(level: .warning, "Full Disk Access required: \(singleLine(report.detail))")
            case .failed(let message):
                appendLog(level: .error, "Full Disk Access check failed: \(message)")
            default:
                break
            }
        }
    }

    func openFullDiskAccessHelper() {
        Task {
            fullDiskAccessReport = FullDiskAccessReport(
                state: .checking,
                detail: "Opening RemCTL's guided Full Disk Access setup.",
                targets: fullDiskAccessReport.targets
            )
            let report = await fullDiskAccessService.openHelper(environment: AppModel.toolEnvironment)
            fullDiskAccessReport = report
            selection = .settings

            switch report.state {
            case .helperOpened:
                appendLog(level: .info, "Opened RemCTL Full Disk Access helper.")
            case .failed(let message):
                appendLog(level: .error, "Could not open Full Disk Access helper: \(message)")
            default:
                appendLog(level: .warning, report.detail)
            }
        }
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
        guard !serverStatus.isRunning else {
            return "Stop the local server before changing exposed tools."
        }

        do {
            let tool = try draft.makeTool()
            tools.append(tool)
            try persistUserDefinedTools()
            appendLog(level: .info, "Added custom tool \(tool.name).")
            return nil
        } catch {
            appendLog(level: .error, "Could not add custom tool: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func deleteUserTool(id: String) -> String? {
        guard !serverStatus.isRunning else {
            return "Stop the local server before changing exposed tools."
        }

        guard let tool = tools.first(where: { $0.id == id && $0.isUserDefined }) else {
            return "Only custom tools can be deleted."
        }

        tools.removeAll { $0.id == id && $0.isUserDefined }
        do {
            try persistUserDefinedTools()
            appendLog(level: .warning, "Deleted custom tool \(tool.name).")
            return nil
        } catch {
            tools.append(tool)
            appendLog(level: .error, "Could not delete custom tool: \(error.localizedDescription)")
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

    func denyToolCallRequest(_ id: UUID) {
        if toolCallApprovalCoordinator.deny(requestID: id) {
            appendLog(level: .warning, "Tool call denied on host Mac.")
        }
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

    func runSmokeTest(mode: SmokeTestMode) {
        guard let mcpURL = currentPublicMCPURL else {
            appendLog(level: .warning, "Create a public MCP URL before running the \(mode.logTitle).")
            return
        }

        guard !smokeTestState.isRunning else {
            appendLog(level: .warning, "A MacRemote smoke test is already running.")
            return
        }

        smokeTestState = .running(mode)
        appendLog(level: .info, "Started \(mode.logTitle).")

        Task {
            do {
                let result = try await smokeTestService.run(
                    mode: mode,
                    mcpURL: mcpURL,
                    environment: AppModel.toolEnvironment
                )

                if result.succeeded {
                    smokeTestState = .passed(mode, "\(result.summary) in \(result.duration.formattedDuration).")
                    appendLog(level: .info, "\(mode.logTitle) passed in \(result.duration.formattedDuration).")
                } else {
                    smokeTestState = .failed(mode, result.summary)
                    appendLog(level: .warning, "\(mode.logTitle) failed: \(result.summary)")
                }
            } catch {
                let message = error.localizedDescription
                smokeTestState = .failed(mode, message)
                appendLog(level: .error, "\(mode.logTitle) failed: \(message)")
            }
        }
    }

    func publicMCPURL(for tunnelBaseURL: URL) -> URL {
        tunnelBaseURL
            .appendingPathComponent("mcp")
            .appendingPathComponent(instanceID)
    }

    var currentPublicMCPURL: URL? {
        if case .running(let publicURL) = tunnelStatus {
            return self.publicMCPURL(for: publicURL)
        }
        return nil
    }

    var toolExposureSummary: ToolExposureSummary {
        ToolExposureSummary(tools: tools)
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

    private static var toolEnvironment: [String: String] {
        [
            "HOME": "/Users/viticci",
            "LANG": "C.UTF-8",
            "LC_ALL": "C.UTF-8",
            "PATH": [
                "/Library/Frameworks/Python.framework/Versions/3.13/bin",
                "/opt/homebrew/bin",
                "/opt/homebrew/sbin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
                "/Users/viticci/bin"
            ].joined(separator: ":")
        ]
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

    private func toolExecutorSnapshot() -> ConfiguredToolExecutor {
        ConfiguredToolExecutor(tools: tools, environment: AppModel.toolEnvironment)
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
            detail: "Running `remctl doctor --for-agent --json` from MacRemote.",
            targets: fullDiskAccessReport.targets
        )
        let report = await fullDiskAccessService.check(environment: AppModel.toolEnvironment)
        fullDiskAccessReport = report
        return report
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
            if approvals.contains(where: { $0.state == .pending }) {
                selection = .approvals
            }
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
