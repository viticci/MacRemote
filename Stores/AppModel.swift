import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    var selection: NavigationSection? = .dashboard
    var tools: [ToolDefinition] = RemCTLToolCatalog.readOnlyTools
    var logs: [AppLogEntry] = []
    var approvals: [ApprovalRequest] = []
    var serverStatus: ServerStatus = .stopped
    var tunnelStatus: TunnelStatus = .stopped
    var localServerURL: URL?
    var instanceID: String = AppModel.makeInstanceID()

    private let tunnelService = TunnelService()
    private let toolExecutor = RemCTLToolExecutor(environment: AppModel.toolEnvironment)
    private var authCoordinator: OAuthCoordinator!
    private var localServer: LocalMCPServer?

    init() {
        authCoordinator = OAuthCoordinator { [weak self] approvals in
            Task { @MainActor in
                self?.approvals = approvals
            }
        }
        tunnelStatus = tunnelService.status(localServerURL: nil)
        appendLog(level: .info, "MacRemote initialized with RemCTL read-only profile.")
    }

    func startLocalServer() {
        guard !serverStatus.isRunning else { return }
        serverStatus = .starting

        do {
            let server = LocalMCPServer(
                instanceID: instanceID,
                tools: tools,
                authCoordinator: authCoordinator,
                toolExecutor: toolExecutor
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
        serverStatus = .stopped
        tunnelStatus = tunnelService.status(localServerURL: nil)
        appendLog(level: .info, "Local MCP server stopped.")
    }

    func runRemCTLTodayTest() {
        Task {
            await runToolTest(toolID: "remctl.today")
        }
    }

    func runToolTest(toolID: String, parameters: [String: String] = [:]) async {
        do {
            let result = try await toolExecutor.execute(toolID: toolID, parameters: parameters)
            if result.succeeded {
                appendLog(level: .info, "\(result.toolName) completed in \(result.duration.formattedDuration) with \(result.outputByteCount) bytes.")
            } else {
                appendLog(level: .warning, "\(result.toolName) exited \(result.exitCode) in \(result.duration.formattedDuration). \(failureDetail(from: result))")
            }
        } catch {
            appendLog(level: .error, "Tool test failed: \(error.localizedDescription)")
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

    func appendLog(level: AppLogEntry.Level, _ message: String) {
        logs.insert(AppLogEntry(date: Date(), level: level, message: message), at: 0)
        if logs.count > 250 {
            logs.removeLast(logs.count - 250)
        }
    }

    private static func makeInstanceID() -> String {
        let bytes = (0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max) }
        return bytes.map { String(format: "%02x", $0) }.joined()
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
