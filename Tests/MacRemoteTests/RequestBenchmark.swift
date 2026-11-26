import Foundation
import Testing
@testable import MacRemote

/// Times `tools/list` and `tools/call` against a real `LocalMCPServer` on
/// loopback, serving a saved catalog. Inert unless `MR_BENCH=1`, so a normal
/// `swift test` returns immediately. See `Tools/bench/README.md`.
///
/// - `MR_BENCH_TOOLS`: a copy of `tools.json` to serve (required).
/// - `MR_BENCH_DISABLED`: a JSON array of tool IDs that are not shared.
/// - `MR_BENCH_N`: requests per method (default 200).
/// - `MR_BENCH_OUT`: where to write the JSON summary.
@Suite(.serialized)
struct RequestBenchmarkTests {
    @Test func requestBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MR_BENCH"] == "1", let toolsPath = env["MR_BENCH_TOOLS"] else { return }
        let count = Int(env["MR_BENCH_N"] ?? "200") ?? 200

        var disabled = Set<String>()
        if let path = env["MR_BENCH_DISABLED"] {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            disabled = Set(try JSONDecoder().decode([String].self, from: data))
        }
        let saved = try ToolRegistryStore(fileURL: URL(fileURLWithPath: toolsPath))
            .loadUserDefinedToolsReport().tools
        let echo = ToolDefinition(
            id: "bench_echo",
            name: "Bench Echo",
            summary: "Prints a fixed word.",
            executablePath: "/bin/echo",
            argumentPattern: ["bench"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 65_536
        )
        let tools = saved.filter { !disabled.contains($0.id) }
            + FileTransferToolCatalog.builtInTools + [echo]

        let token = UUID().uuidString
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(token, clientName: "Bench Client")
        let artifactRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("mr-bench-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let artifactStore = ArtifactStore(rootDirectory: artifactRoot)
        let server = LocalMCPServer(
            instanceID: "bench",
            tools: tools,
            resultCardPreferences: { ResultCardPreferences() },
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: tools,
                environment: ExecutableLocator.toolEnvironment,
                artifactStore: artifactStore
            ),
            artifactStore: artifactStore,
            eventHandler: nil
        )
        let port = try server.start()
        defer { server.stop() }

        let client = BenchClient(
            url: URL(string: "http://127.0.0.1:\(port)/mcp/bench")!,
            token: token
        )
        try await client.initialize()
        let list: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]]
        let call: [String: Any] = [
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "bench_echo", "arguments": [:]]
        ]
        // Prove both requests work before timing them.
        let listed = try await client.send(list)
        let toolCount = ((listed.json["result"] as? [String: Any])?["tools"] as? [Any])?.count ?? 0
        #expect(toolCount == tools.count)
        let called = try await client.send(call)
        #expect((called.json["result"] as? [String: Any])?["isError"] as? Bool != true)

        var summary: [String: Any] = ["tools": toolCount, "requests": count]
        for (name, body) in [("toolsList", list), ("toolsCall", call)] {
            for _ in 0..<10 { _ = try await client.send(body) }
            var samples = [Double]()
            var bytes = 0
            let cpuStart = Self.processCPUSeconds()
            for _ in 0..<count {
                let start = ContinuousClock.now
                let response = try await client.send(body)
                samples.append(Self.milliseconds(ContinuousClock.now - start))
                bytes = response.bytes
            }
            let cpu = (Self.processCPUSeconds() - cpuStart) * 1000 / Double(count)
            samples.sort()
            summary[name] = [
                "medianMs": samples[samples.count / 2],
                "p10Ms": samples[samples.count / 10],
                "p90Ms": samples[samples.count * 9 / 10],
                "cpuMsPerRequest": cpu,
                "responseBytes": bytes
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        print("MR_BENCH_RESULT " + String(decoding: data, as: UTF8.self))
        if let out = env["MR_BENCH_OUT"] {
            try data.write(to: URL(fileURLWithPath: out))
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    /// User plus system CPU time of this whole process, client included.
    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}

/// A legacy (2025-06-18) MCP client with the MCP Apps extension, the shape
/// ChatGPT and Claude use today.
private final class BenchClient {
    let url: URL
    let token: String
    var sessionID: String?
    let session = URLSession(configuration: .ephemeral)

    init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    func initialize() async throws {
        let response = try await send([
            "jsonrpc": "2.0", "id": 0, "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [
                    "extensions": [
                        "io.modelcontextprotocol/ui": ["mimeTypes": ["text/html;profile=mcp-app"]]
                    ]
                ],
                "clientInfo": ["name": "Bench", "version": "1.0"]
            ]
        ])
        sessionID = response.headers["Mcp-Session-Id"]
    }

    func send(_ body: [String: Any]) async throws -> (json: [String: Any], bytes: Int, headers: [String: String]) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        var headers = [String: String]()
        for (key, value) in http?.allHeaderFields ?? [:] {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (json, data.count, headers)
    }
}
