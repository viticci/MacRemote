import Foundation
import Testing
@testable import MacRemote

/// Every process-backed catalog command must fail before launch, with a
/// path-free message, when its CLI is missing or disappears after the tool
/// was created. One suite covers the first-party process provider (Apple
/// Frames) and the system presets.
@Suite("Process adapter availability")
struct FirstPartyAdapterAvailabilityTests {
    private static let providers: [(name: String, expectedCount: Int, presets: [DefaultToolPreset])] = [
        ("Apple Frames", 6, AppleFramesToolPresetCatalog.presets(executablePath: "/bin/echo"))
    ]

    @Test("Missing CLIs do not produce provider presets")
    func missingCLIsStayOutOfDiscovery() {
        #expect(AppleFramesToolPresetCatalog.presets(executablePath: nil).isEmpty)
    }

    @Test("Every first-party process command fails cleanly without its CLI")
    func providerCommandsAreUnavailable() async throws {
        for provider in Self.providers {
            #expect(provider.presets.count == provider.expectedCount, "\(provider.name)")
            let tools = try provider.presets.map { try $0.draft.makeTool(id: $0.toolID) }
            try await expectUnavailable(tools, provider: provider.name)
        }
    }

    @Test("Every available system preset fails cleanly if its command disappears")
    func systemPresetCommandsAreUnavailable() async throws {
        let presets = DefaultToolPresetCatalog.presets.filter { $0.publisher == .other }
        #expect(presets.isEmpty == false)
        let tools = try presets.map { try $0.draft.makeTool(id: $0.toolID) }
        try await expectUnavailable(tools, provider: "system presets")
    }

    @Test(
        "Missing first-party CLIs return structured unavailable MCP results without path or argv leaks",
        .timeLimit(.minutes(1))
    )
    func missingCLIMapsToStructuredMCPResult() async throws {
        let unavailablePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-private-cli-path-\(UUID().uuidString)")
            .appendingPathComponent("private-cli-path-sentinel")
            .path
        let rawArgumentSentinel = "raw-argv-sentinel-\(UUID().uuidString)"
        let framesPresets = AppleFramesToolPresetCatalog.presets(executablePath: "/bin/echo")
        let sourceTools = try ["frames_devices", "frames_info"].map { toolID in
            let preset = try #require(framesPresets.first { $0.toolID == toolID })
            return try preset.draft.makeTool(id: toolID)
        }
        let tools = sourceTools.map { replacingExecutablePath(in: $0, with: unavailablePath) }
        let argumentsByToolID: [String: [String: Any]] = [
            "frames_devices": [:],
            "frames_info": ["paths": ["/\(rawArgumentSentinel)"]]
        ]

        let coordinator = OAuthCoordinator()
        let server = LocalMCPServer(
            instanceID: "test-instance",
            tools: tools,
            authCoordinator: coordinator,
            toolExecutor: ConfiguredToolExecutor(
                tools: tools,
                environment: [:],
                runner: NeverRunProcessRunner()
            )
        )
        let port = try server.start()
        defer { server.stop() }

        let base = try #require(URL(string: "http://127.0.0.1:\(port)"))
        try await waitForServer(base: base)
        let resource = base.appendingPathComponent("mcp/test-instance").absoluteString
        let accessToken = try makeAccessToken(coordinator: coordinator, issuer: base.absoluteString, resource: resource)

        for tool in tools {
            let response = try await postJSON(
                url: try #require(URL(string: resource)),
                accessToken: accessToken,
                body: [
                    "jsonrpc": "2.0",
                    "id": tool.id,
                    "method": "tools/call",
                    "params": ["name": tool.id, "arguments": argumentsByToolID[tool.id] ?? [:]]
                ]
            )

            #expect(response.statusCode == 200)
            #expect(response.json["error"] == nil)
            let result = try #require(response.json["result"] as? [String: Any])
            #expect(result["isError"] as? Bool == true)
            let structured = try #require(result["structuredContent"] as? [String: Any])
            #expect(structured["reason"] as? String == "unavailable")
            #expect(structured["succeeded"] as? Bool == false)
            let stderr = try #require(structured["stderr"] as? String)
            #expect(stderr.localizedCaseInsensitiveContains("not installed or is no longer available"))

            let responseText = String(decoding: response.data, as: UTF8.self)
            #expect(responseText.contains(unavailablePath) == false)
            #expect(responseText.contains(rawArgumentSentinel) == false)
            #expect(responseText.contains("NSCocoaErrorDomain") == false)
        }
    }

    // MARK: - Helpers

    /// Checks two scenarios: the executable never existed, and it was removed
    /// after the executor was built. Neither may launch anything.
    private func expectUnavailable(_ tools: [ToolDefinition], provider: String) async throws {
        let runner = CountingProcessRunner()
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-missing-\(UUID().uuidString)")
            .appendingPathComponent(provider.lowercased())
            .path
        await verifyUnavailable(
            tools.map { replacingExecutablePath(in: $0, with: missingPath) },
            missingPath: missingPath,
            runner: runner,
            provider: provider
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-removed-\(UUID().uuidString)", isDirectory: true)
        let removedURL = directory.appendingPathComponent("command")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: removedURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: removedURL.path)
        let staleTools = tools.map { replacingExecutablePath(in: $0, with: removedURL.path) }
        let staleExecutor = ConfiguredToolExecutor(tools: staleTools, environment: [:], runner: runner)
        try FileManager.default.removeItem(at: removedURL)
        await verifyUnavailable(
            staleTools,
            missingPath: removedURL.path,
            runner: runner,
            provider: provider,
            executor: staleExecutor
        )

        #expect(await runner.invocationCount == 0, "\(provider) launched a command after its executable disappeared")
    }

    private func verifyUnavailable(
        _ tools: [ToolDefinition],
        missingPath: String,
        runner: CountingProcessRunner,
        provider: String,
        executor suppliedExecutor: ConfiguredToolExecutor? = nil
    ) async {
        let executor = suppliedExecutor ?? ConfiguredToolExecutor(tools: tools, environment: [:], runner: runner)
        let secretArgument = "--private-terminal-argument"

        for tool in tools {
            do {
                _ = try await executor.execute(toolID: tool.id)
                Issue.record("\(tool.id) attempted to run after \(provider) disappeared")
            } catch let error as ToolValidationError {
                #expect(error == .executableUnavailable(missingPath), "\(tool.id)")
                #expect(error.callToolReason == "unavailable", "\(tool.id)")
                let message = error.callToolMessage(
                    tool: tool,
                    arguments: ["args": .stringArray([secretArgument])]
                )
                #expect(message.contains("not installed or is no longer available"), "\(tool.id)")
                #expect(message.contains(missingPath) == false, "\(tool.id) leaked its executable path")
                #expect(message.contains(secretArgument) == false, "\(tool.id) leaked an argument")
                #expect(message.localizedCaseInsensitiveContains("argv") == false, "\(tool.id) leaked argv jargon")
                #expect(error.localizedDescription.contains(missingPath) == false, "\(tool.id) leaked its path in diagnostics")
            } catch {
                Issue.record("\(tool.id) returned the wrong error: \(error)")
            }
        }
    }

    private func replacingExecutablePath(in tool: ToolDefinition, with executablePath: String) -> ToolDefinition {
        ToolDefinition(
            id: tool.id,
            permissionEpoch: tool.permissionEpoch,
            name: tool.name,
            summary: tool.summary,
            executablePath: executablePath,
            argumentPattern: tool.argumentPattern,
            parameters: tool.parameters,
            processInvocation: tool.processInvocation,
            capability: tool.capability,
            timeoutSeconds: tool.timeoutSeconds,
            outputByteLimit: tool.outputByteLimit,
            origin: tool.origin,
            category: tool.category,
            permissionRequirements: tool.permissionRequirements,
            backend: tool.backend,
            mcpBridge: tool.mcpBridge,
            mcpStdioBridge: tool.mcpStdioBridge,
            nativeToolID: tool.nativeToolID,
            approvalPolicy: tool.approvalPolicy,
            annotationOverrides: tool.annotationOverrides,
            provenance: tool.provenance,
            uiActions: tool.uiActions,
            widgetPresentation: tool.widgetPresentation
        )
    }

    private func makeAccessToken(coordinator: OAuthCoordinator, issuer: String, resource: String) throws -> String {
        let redirectURI = "http://127.0.0.1/callback"
        let verifier = "availability-verifier-0123456789-ABCDEFGHIJKLMNO"
        let registration = try coordinator.registerClient(from: [
            "client_name": "CLI Availability Test",
            "redirect_uris": [redirectURI],
            "scope": "mcp:tools"
        ])
        let clientID = try #require(registration["client_id"] as? String)
        let requestID = try coordinator.beginAuthorization(
            queryItems: [
                "response_type": "code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "scope": "mcp:tools",
                "state": "availability-test",
                "code_challenge": OAuthCoordinator.pkceChallenge(for: verifier),
                "code_challenge_method": "S256",
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        #expect(coordinator.approve(requestID: requestID))
        let status = coordinator.authorizationStatus(requestID: requestID)
        let approvedRedirect = try #require(status["redirect_uri"] as? String)
        let code = try #require(
            URLComponents(string: approvedRedirect)?.queryItems?.first(where: { $0.name == "code" })?.value
        )
        let token = try coordinator.exchangeToken(
            form: [
                "grant_type": "authorization_code",
                "client_id": clientID,
                "redirect_uri": redirectURI,
                "code": code,
                "code_verifier": verifier,
                "resource": resource
            ],
            issuer: issuer,
            resource: resource
        )
        return try #require(token["access_token"] as? String)
    }

    private func waitForServer(base: URL) async throws {
        let health = base.appendingPathComponent("health")
        for _ in 0..<40 {
            if let (_, response) = try? await URLSession.shared.data(from: health),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for the local MCP availability test server")
        throw AvailabilityTestError.serverNotReady
    }

    private func postJSON(
        url: URL,
        accessToken: String,
        body: [String: Any]
    ) async throws -> (statusCode: Int, json: [String: Any], data: Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (http.statusCode, object, data)
    }
}

private enum AvailabilityTestError: Error {
    case serverNotReady
}

private actor CountingProcessRunner: ProcessRunning {
    private(set) var invocationCount = 0

    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds _: TimeInterval,
        outputByteLimit _: Int,
        environment _: [String: String],
        standardInput _: String?
    ) async throws -> CommandRunResult {
        invocationCount += 1
        return CommandRunResult(
            executablePath: executablePath,
            arguments: arguments,
            exitCode: 0,
            stdout: "",
            stderr: "",
            duration: 0,
            timedOut: false,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

private struct NeverRunProcessRunner: ProcessRunning {
    struct Launched: Error {}

    func run(
        executablePath _: String,
        arguments _: [String],
        timeoutSeconds _: TimeInterval,
        outputByteLimit _: Int,
        environment _: [String: String],
        standardInput _: String?
    ) async throws -> CommandRunResult {
        throw Launched()
    }
}
