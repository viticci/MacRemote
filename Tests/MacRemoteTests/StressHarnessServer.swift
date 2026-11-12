import Foundation
import Testing
@testable import MacRemote

/// Long-running loopback MCP server for external stress drivers. Inert unless
/// `MR_STRESS_HARNESS=1` — normal `swift test` returns immediately.
@Suite(.serialized)
struct StressHarnessServerTests {
    @Test func stressHarnessServer() async throws {
        guard ProcessInfo.processInfo.environment["MR_STRESS_HARNESS"] == "1" else { return }

        let env = ProcessInfo.processInfo.environment
        let token = env["MR_STRESS_TOKEN"] ?? Self.randomHexToken()
        let endpointFile = URL(fileURLWithPath: env["MR_STRESS_ENDPOINT_FILE"] ?? "/tmp/mr_stress_harness/endpoint.json")
        let stopFile = URL(fileURLWithPath: env["MR_STRESS_STOP_FILE"] ?? "/tmp/mr_stress_harness/stop")
        let ttlSeconds = TimeInterval(Int(env["MR_STRESS_TTL_SECONDS"] ?? "900") ?? 900)

        try? FileManager.default.removeItem(at: stopFile)
        try FileManager.default.createDirectory(
            at: endpointFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let artifactRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-stress-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: artifactRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: artifactRoot) }

        let stressTools = Self.stressTools()
        let server = Self.makeServer(
            tools: stressTools,
            token: token,
            rootDirectory: artifactRoot
        )

        let port = try server.start()
        defer { server.stop() }

        let mcpPath = "/mcp/stress"
        let endpointPayload: [String: Any] = [
            "port": Int(port),
            "token": token,
            "instanceID": "stress",
            "mcpPath": mcpPath,
            "healthPath": "/health",
            "baseURL": "http://127.0.0.1:\(port)",
            "tools": stressTools.map { tool in
                [
                    "id": tool.id,
                    "mcpName": tool.id.replacingOccurrences(of: ".", with: "_")
                ]
            }
        ]
        let endpointData = try JSONSerialization.data(withJSONObject: endpointPayload, options: [.prettyPrinted, .sortedKeys])
        try endpointData.write(to: endpointFile, options: .atomic)

        let deadline = Date().addingTimeInterval(ttlSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: stopFile.path) {
                try? FileManager.default.removeItem(at: stopFile)
                break
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        await server.stop().value
    }

    private static func makeServer(
        tools: [ToolDefinition],
        token: String,
        rootDirectory: URL
    ) -> LocalMCPServer {
        let artifactStore = ArtifactStore(
            rootDirectory: rootDirectory.appendingPathComponent("store", isDirectory: true)
        )
        let executor = ConfiguredToolExecutor(
            tools: tools,
            environment: ExecutableLocator.toolEnvironment,
            artifactStore: artifactStore
        )
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(token, clientName: "Single Header Client")

        // The stress tools are Flexible Commands, which ask before running.
        // No owner is present here, so the harness client gets Always Allow
        // for them, the way an owner would grant it. The store is throwaway.
        let suiteName = "MacRemoteStressHarness.\(UUID().uuidString)"
        let permissions = ClientToolPermissionStore(
            userDefaults: UserDefaults(suiteName: suiteName) ?? .standard
        )
        _ = permissions.replaceAllowedTools(tools, clientTrustID: OAuthCoordinator.staticHeaderClientID)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)

        return LocalMCPServer(
            instanceID: "stress",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: executor,
            clientToolPermissionStore: permissions,
            artifactStore: artifactStore,
            eventHandler: nil
        )
    }

    private static func randomHexToken(byteCount: Int = 16) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func stressTools() -> [ToolDefinition] {
        [
            ToolDefinition(
                id: "stress_echo",
                name: "Stress Echo",
                summary: "Echo small argv for concurrency smoke tests.",
                executablePath: "/bin/echo",
                argumentPattern: ["{args}"],
                parameters: [
                    ToolParameter(
                        name: "args",
                        title: "Arguments",
                        kind: .stringArray,
                        required: false
                    )
                ],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 64 * 1024,
                origin: .builtIn,
                category: .utilities
            ),
            ToolDefinition(
                id: "stress_cat_stdin",
                name: "Stress Cat Stdin",
                summary: "Round-trip stdin through /bin/cat.",
                executablePath: "/bin/cat",
                argumentPattern: [],
                parameters: [
                    ToolParameter(
                        name: "stdin",
                        title: "Standard Input",
                        kind: .string,
                        required: false,
                        maximumLength: 64 * 1024
                    )
                ],
                capability: .readOnly,
                timeoutSeconds: 10,
                outputByteLimit: 5 * 1024 * 1024,
                origin: .builtIn,
                category: .utilities
            ),
            ToolDefinition(
                id: "stress_bigout",
                name: "Stress Big Output",
                summary: "Emit ~500 KB stdout to exercise MCP spill and artifact links.",
                executablePath: "/usr/bin/python3",
                argumentPattern: ["-c", "import sys; sys.stdout.write('x'*500000)"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 30,
                outputByteLimit: 5 * 1024 * 1024,
                origin: .builtIn,
                category: .utilities
            ),
            ToolDefinition(
                id: "stress_sleep",
                name: "Stress Sleep",
                summary: "Long-running sleep child; harness uses a short tool timeout.",
                executablePath: "/bin/sleep",
                argumentPattern: ["30"],
                parameters: [],
                capability: .readOnly,
                timeoutSeconds: 2,
                outputByteLimit: 1024,
                origin: .builtIn,
                category: .utilities
            ),
            ToolDefinition(
                id: "stress_typed",
                name: "Stress Typed",
                summary: "Integer parameter validation for bad-argument tests.",
                executablePath: "/bin/echo",
                argumentPattern: ["{count}"],
                parameters: [
                    ToolParameter(
                        name: "count",
                        title: "Count",
                        kind: .integer,
                        required: true,
                        integerRange: 1...100
                    )
                ],
                capability: .readOnly,
                timeoutSeconds: 5,
                outputByteLimit: 1024,
                origin: .builtIn,
                category: .utilities
            )
        ]
    }
}
