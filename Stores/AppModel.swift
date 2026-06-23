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

    private let runner = ProcessRunner()
    private let tunnelService = TunnelService()
    private var localServer: LocalMCPServer?

    init() {
        tunnelStatus = tunnelService.status(localServerURL: nil)
        appendLog(level: .info, "MacRemote initialized with RemCTL read-only profile.")
    }

    func startLocalServer() {
        guard !serverStatus.isRunning else { return }
        serverStatus = .starting

        do {
            let server = LocalMCPServer(instanceID: instanceID, tools: tools)
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
        localServer?.stop()
        localServer = nil
        localServerURL = nil
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
        guard let tool = RemCTLToolCatalog.tool(id: toolID) else {
            appendLog(level: .error, "Unknown tool test requested: \(toolID)")
            return
        }

        do {
            let arguments = try RemCTLToolCatalog.arguments(for: toolID, parameters: parameters)
            let result = try await runner.run(
                executablePath: tool.executablePath,
                arguments: arguments,
                timeoutSeconds: tool.timeoutSeconds,
                outputByteLimit: tool.outputByteLimit,
                environment: toolEnvironment
            )
            let outputBytes = result.stdout.utf8.count
            if result.succeeded {
                appendLog(level: .info, "\(tool.name) completed in \(result.duration.formattedDuration) with \(outputBytes) bytes.")
            } else {
                appendLog(level: .warning, "\(tool.name) exited \(result.exitCode) in \(result.duration.formattedDuration). \(failureDetail(from: result))")
            }
        } catch {
            appendLog(level: .error, "\(tool.name) test failed: \(error.localizedDescription)")
        }
    }

    func refreshTunnelStatus() {
        tunnelStatus = tunnelService.status(localServerURL: localServerURL)
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

    private var toolEnvironment: [String: String] {
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

    private func failureDetail(from result: CommandRunResult) -> String {
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
}
