import Foundation
import Testing
@testable import MacRemote

struct ToolSecurityFingerprintTests {
    @Test func fingerprintIgnoresCosmeticChanges() {
        let original = processTool(
            permissionEpoch: "epoch-1",
            name: "Run Echo",
            summary: "First summary",
            parameterTitle: "Arguments",
            timeoutSeconds: 10,
            outputByteLimit: 1_024,
            category: .utilities
        )
        let cosmeticEdit = processTool(
            permissionEpoch: "epoch-1",
            name: "Echo Renamed",
            summary: "Different human-facing copy",
            parameterTitle: "Input Arguments",
            timeoutSeconds: 10,
            outputByteLimit: 1_024,
            category: .developer
        )

        #expect(original.securityFingerprint == cosmeticEdit.securityFingerprint)
    }

    @Test func fingerprintChangesWithAuthorityAndValidationContract() {
        let original = processTool(permissionEpoch: "epoch-1")
        let variants = [
            processTool(id: "echo_other", permissionEpoch: "epoch-1"),
            processTool(permissionEpoch: "epoch-2"),
            processTool(permissionEpoch: "epoch-1", executablePath: "/usr/bin/printf"),
            processTool(permissionEpoch: "epoch-1", argumentPattern: ["prefix", "{args}"]),
            processTool(permissionEpoch: "epoch-1", maximumLength: 2_048),
            processTool(permissionEpoch: "epoch-1", capability: .destructive),
            processTool(permissionEpoch: "epoch-1", permissionRequirements: [.fullDiskAccess]),
            processTool(permissionEpoch: "epoch-1", timeoutSeconds: 45),
            processTool(permissionEpoch: "epoch-1", outputByteLimit: 8_192)
        ]

        for variant in variants {
            #expect(variant.securityFingerprint != original.securityFingerprint)
        }
    }

    @Test func stdioStartupTimeoutChangesFingerprint() {
        #expect(
            stdioBridgeTool(startupTimeoutSeconds: 5).securityFingerprint !=
                stdioBridgeTool(startupTimeoutSeconds: 30).securityFingerprint
        )
    }

    @Test func fingerprintChangesWithExecutableProvenance() {
        let first = processTool(
            permissionEpoch: "epoch-1",
            provenance: provenance(contentHash: "aaa")
        )
        let changed = processTool(
            permissionEpoch: "epoch-1",
            provenance: provenance(contentHash: "bbb")
        )

        #expect(first.securityFingerprint != changed.securityFingerprint)
    }

    @Test func canonicalBridgeSchemaIgnoresObjectKeyOrder() {
        let firstSchema: JSONValue = .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")])
            ])
        ])
        let secondSchema: JSONValue = .object([
            "properties": .object([
                "limit": .object(["type": .string("integer")]),
                "query": .object(["type": .string("string")])
            ]),
            "type": .string("object")
        ])

        #expect(httpBridgeTool(schema: firstSchema).securityFingerprint == httpBridgeTool(schema: secondSchema).securityFingerprint)
    }

    @Test func sourceBackedCredentialRotationIsStableButLiteralReplacementIsNot() {
        let source = MCPBridgeHeaderValueSource(
            kind: .jsonFile,
            filePath: "~/.config/service/auth.json",
            keyPath: ["oauth", "access_token"],
            prefix: "Bearer "
        )
        let sourceBackedA = httpBridgeTool(
            headers: [MCPBridgeHeader(name: "Authorization", valueSource: source)]
        )
        let sourceBackedB = httpBridgeTool(
            headers: [MCPBridgeHeader(name: "authorization", valueSource: source)]
        )
        let literalA = httpBridgeTool(
            headers: [MCPBridgeHeader(name: "Authorization", value: "Bearer token-a")]
        )
        let literalB = httpBridgeTool(
            headers: [MCPBridgeHeader(name: "Authorization", value: "Bearer token-b")]
        )

        #expect(sourceBackedA.securityFingerprint == sourceBackedB.securityFingerprint)
        #expect(literalA.securityFingerprint != literalB.securityFingerprint)
    }

    @Test func bridgeBindingOrderDoesNotChangeFingerprint() {
        let first = httpBridgeTool(headers: [
            MCPBridgeHeader(name: "X-Account", value: "one"),
            MCPBridgeHeader(name: "Authorization", value: "Bearer token")
        ])
        let second = httpBridgeTool(headers: [
            MCPBridgeHeader(name: "Authorization", value: "Bearer token"),
            MCPBridgeHeader(name: "X-Account", value: "one")
        ])
        #expect(first.securityFingerprint == second.securityFingerprint)

        let stdioFirst = stdioBridgeTool(
            startupTimeoutSeconds: 5,
            environment: [
                MCPStdioEnvironmentVariable(name: "ACCOUNT", value: "one"),
                MCPStdioEnvironmentVariable(name: "TOKEN", value: "two")
            ]
        )
        let stdioSecond = stdioBridgeTool(
            startupTimeoutSeconds: 5,
            environment: [
                MCPStdioEnvironmentVariable(name: "TOKEN", value: "two"),
                MCPStdioEnvironmentVariable(name: "ACCOUNT", value: "one")
            ]
        )
        #expect(stdioFirst.securityFingerprint == stdioSecond.securityFingerprint)
    }

    @Test func caseInsensitiveDuplicateHTTPHeadersAreRejectedBeforeExecution() {
        let ambiguous = httpBridgeTool(headers: [
            MCPBridgeHeader(name: "Authorization", value: "Bearer first"),
            MCPBridgeHeader(name: "authorization", value: "Bearer second")
        ])

        #expect(throws: ToolValidationError.invalidMCPBridge("duplicate header name authorization")) {
            try ToolArgumentResolver.validate(ambiguous)
        }
    }

    @Test func whitespacePaddedHTTPHeaderNamesAreRejectedBeforeExecution() {
        let invalid = httpBridgeTool(headers: [
            MCPBridgeHeader(name: " Authorization ", value: "Bearer token")
        ])

        #expect(throws: ToolValidationError.invalidMCPBridge("header names must use HTTP token syntax")) {
            try ToolArgumentResolver.validate(invalid)
        }
    }

    @Test func permissionEpochPersistsAndRecreationGetsANewEpoch() throws {
        let first = processTool(permissionEpoch: nil, origin: .userDefined)
        let encoded = try JSONEncoder().encode(first)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: encoded)
        let recreated = processTool(permissionEpoch: nil, origin: .userDefined)

        #expect(decoded.permissionEpoch == first.permissionEpoch)
        #expect(decoded.securityFingerprint == first.securityFingerprint)
        #expect(recreated.permissionEpoch != first.permissionEpoch)

        let builtInA = processTool(permissionEpoch: nil, origin: .builtIn)
        let builtInB = processTool(permissionEpoch: nil, origin: .builtIn)
        #expect(builtInA.permissionEpoch == builtInB.permissionEpoch)
    }

    @Test func permissionStoreKeysGrantsToTrustIdentityAndCurrentFingerprint() throws {
        let suiteName = "MacRemoteTests.ToolSecurity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(["ephemeral-client-id": ["echo_run"]], forKey: "MacRemote.clientToolPermissions")
        let tool = processTool(permissionEpoch: "installed-generation")
        let store = ClientToolPermissionStore(userDefaults: defaults)
        #expect(!store.isAllowed(clientTrustID: "trust-a", tool: tool))

        store.setAllowed(true, clientTrustID: "trust-a", tool: tool)
        #expect(store.isAllowed(clientTrustID: "trust-a", tool: tool))
        #expect(!store.isAllowed(clientTrustID: "trust-b", tool: tool))

        // A new OAuth client ID, access token, refresh token, or connection has
        // no input to this lookup. The stable trust ID is the complete client key.
        let reloaded = ClientToolPermissionStore(userDefaults: defaults)
        #expect(reloaded.isAllowed(clientTrustID: "trust-a", tool: tool))

        let changedContract = processTool(
            permissionEpoch: tool.permissionEpoch,
            argumentPattern: ["changed", "{args}"]
        )
        #expect(!reloaded.isAllowed(clientTrustID: "trust-a", tool: changedContract))
        #expect(reloaded.allowedToolIDs(for: "trust-a", matching: [changedContract]).isEmpty)
    }

    @Test func deletingGrantPreventsIdenticalSemanticToolFromInheritingIt() throws {
        let suiteName = "MacRemoteTests.ToolSecurity.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClientToolPermissionStore(userDefaults: defaults)
        let original = processTool(permissionEpoch: "generation-a")
        let recreated = processTool(permissionEpoch: "generation-b")

        store.setAllowed(true, clientTrustID: "trust-a", tool: original)
        #expect(!store.isAllowed(clientTrustID: "trust-a", tool: recreated))
        store.removeToolIDFromAllClients(original.id)
        #expect(store.snapshot().isEmpty)
    }

    @Test func approvalRequestCapturesExactToolFingerprint() async throws {
        let coordinator = ToolCallApprovalCoordinator(timeoutSeconds: 1)
        let tool = processTool(permissionEpoch: "epoch-approval", capability: .write)
        let task = Task {
            try await coordinator.requestApproval(tool: tool, parameters: [:])
        }

        let request = try await waitForApproval(in: coordinator)
        #expect(request.toolSecurityFingerprint == tool.securityFingerprint)
        #expect(coordinator.deny(requestID: request.id))
        #expect(try await task.value == false)
    }

    @Test func runtimeRejectsToolChangedAfterPermissionCheck() async throws {
        let original = processTool(permissionEpoch: "epoch-runtime")
        let changed = processTool(
            permissionEpoch: "epoch-runtime",
            argumentPattern: ["changed", "{args}"]
        )
        let runtime = ToolSurfaceRuntime(tools: [original], environment: [:])
        let approvedFingerprint = original.securityFingerprint
        runtime.update(tools: [changed])

        await #expect(throws: ToolSecurityFingerprintError.changed) {
            try await runtime.execute(
                toolID: changed.id,
                parameters: ["args": .stringArray([])],
                expectedSecurityFingerprint: approvedFingerprint
            )
        }
    }
}

private func processTool(
    id: String = "echo_run",
    permissionEpoch: String? = "epoch-1",
    name: String = "Run Echo",
    summary: String = "Run echo.",
    executablePath: String = "/bin/echo",
    argumentPattern: [String] = ["{args}"],
    parameterTitle: String = "Arguments",
    maximumLength: Int? = 4_096,
    capability: ToolCapability = .write,
    timeoutSeconds: TimeInterval = 10,
    outputByteLimit: Int = 1_024,
    origin: ToolOrigin = .userDefined,
    category: ToolCategory = .utilities,
    permissionRequirements: [ToolPermissionRequirement] = [],
    provenance: ToolProvenance? = nil
) -> ToolDefinition {
    ToolDefinition(
        id: id,
        permissionEpoch: permissionEpoch,
        name: name,
        summary: summary,
        executablePath: executablePath,
        argumentPattern: argumentPattern,
        parameters: [
            ToolParameter(
                name: "args",
                title: parameterTitle,
                kind: .stringArray,
                required: false,
                maximumLength: maximumLength
            )
        ],
        capability: capability,
        timeoutSeconds: timeoutSeconds,
        outputByteLimit: outputByteLimit,
        origin: origin,
        category: category,
        permissionRequirements: permissionRequirements,
        provenance: provenance
    )
}

private func httpBridgeTool(
    schema: JSONValue = .object(["type": .string("object")]),
    headers: [MCPBridgeHeader] = []
) -> ToolDefinition {
    ToolDefinition(
        id: "bridge_search",
        permissionEpoch: "bridge-epoch",
        name: "Search",
        summary: "Search upstream.",
        executablePath: "",
        argumentPattern: [],
        parameters: [],
        capability: .write,
        timeoutSeconds: 60,
        outputByteLimit: 1_024,
        origin: .userDefined,
        backend: .mcpHTTPBridge,
        mcpBridge: MCPBridgeConfiguration(
            serverName: "Service",
            serverURL: "https://service.example/mcp",
            toolName: "search",
            inputSchema: schema,
            protocolVersion: "2025-11-25",
            headers: headers
        )
    )
}

private func stdioBridgeTool(
    startupTimeoutSeconds: TimeInterval?,
    environment: [MCPStdioEnvironmentVariable] = []
) -> ToolDefinition {
    ToolDefinition(
        id: "bridge_stdio_search",
        permissionEpoch: "bridge-epoch",
        name: "Search",
        summary: "Search upstream.",
        executablePath: "",
        argumentPattern: [],
        parameters: [],
        capability: .write,
        timeoutSeconds: 60,
        outputByteLimit: 1_024,
        origin: .userDefined,
        backend: .mcpStdioBridge,
        mcpStdioBridge: MCPStdioBridgeConfiguration(
            serverName: "Service",
            command: "/usr/bin/true",
            startupTimeoutSeconds: startupTimeoutSeconds,
            toolName: "search",
            environment: environment
        )
    )
}

private func provenance(contentHash: String) -> ToolProvenance {
    ToolProvenance(
        sourceKind: .homebrewFormula,
        packageName: "echo",
        packageVersion: "1.0",
        addedDate: Date(timeIntervalSince1970: 1_000),
        resolvedPathAtAdd: "/bin/echo",
        signingIdentityAtAdd: "Developer ID: TEAM",
        contentSHA256AtAdd: contentHash,
        wasQuarantinedAtAdd: false,
        summaryIsHarvested: false,
        summaryOrigin: nil
    )
}

private func waitForApproval(
    in coordinator: ToolCallApprovalCoordinator
) async throws -> ToolCallApprovalRequest {
    for _ in 0..<100 {
        if let request = coordinator.approvalSnapshot().first(where: { $0.state == .pending }) {
            return request
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for tool approval")
    throw CancellationError()
}
