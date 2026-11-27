import Foundation
import Testing
@testable import MacRemote

struct ToolRegistryTests {
    @Test func toolEnvironmentPrefersUserAndHomebrewBinsBeforeSystemBins() throws {
        let directories = ExecutableLocator.searchDirectories
        let userBinIndex = try #require(directories.firstIndex(of: "\(ExecutableLocator.homeDirectory)/bin"))
        let homebrewIndex = try #require(directories.firstIndex(of: "/opt/homebrew/bin"))
        let systemIndex = try #require(directories.firstIndex(of: "/usr/bin"))

        #expect(userBinIndex < systemIndex)
        #expect(homebrewIndex < systemIndex)
        #expect(ExecutableLocator.toolEnvironment["PATH"] == directories.joined(separator: ":"))
    }

    /// Tools get this Mac's per-user temporary folder and user name, and
    /// nothing else from the app's own environment.
    @Test func toolEnvironmentAddsOnlyTheTemporaryFolderAndUserName() {
        let environment = ExecutableLocator.toolEnvironment

        #expect(environment["TMPDIR"] == NSTemporaryDirectory())
        #expect(environment["USER"] == NSUserName())
        #expect(environment["LOGNAME"] == NSUserName())
        #expect(Set(environment.keys) == [
            "HOME", "LANG", "LC_ALL", "PATH", "PAGER", "MANPAGER", "GIT_PAGER", "TERM",
            "TMPDIR", "USER", "LOGNAME"
        ])
    }

    /// Cloudflare's helper is launched by the app itself, so a file with the
    /// same name in a home folder must not be found before the Homebrew copy.
    @Test func helperLookupSearchesPackageManagerAndSystemFoldersBeforeHomeFolders() throws {
        let directories = ExecutableLocator.systemFirstSearchDirectories
        let home = ExecutableLocator.homeDirectory
        let firstHomeIndex = try #require(directories.firstIndex { $0.hasPrefix(home + "/") })
        for folder in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            #expect(try #require(directories.firstIndex(of: folder)) < firstHomeIndex)
        }
        #expect(directories.contains("\(home)/.local/bin"))
        #expect(directories.contains("\(home)/bin"))
    }

    /// #11: an app opened from Finder never gets the shell's PATH, so a CLI
    /// installed with `npm -g` into `~/.npm-global` (like Wrangler) looked
    /// missing.
    @Test func javaScriptGlobalFoldersAreSearched() {
        let directories = ExecutableLocator.searchDirectories
        let home = ExecutableLocator.homeDirectory
        for folder in [".npm-global/bin", ".volta/bin", "Library/pnpm", ".yarn/bin"] {
            #expect(directories.contains("\(home)/\(folder)"))
        }
    }

    @Test func npmPrefixIsReadFromCommonNPMRCForms() {
        func prefix(_ npmrc: String) -> String? {
            ExecutableLocator.npmPrefix(fromNPMRC: npmrc, homeDirectory: "/Users/example")
        }
        #expect(prefix("prefix=~/.npm-packages\n") == "/Users/example/.npm-packages")
        #expect(prefix("prefix = \"${HOME}/npm\"") == "/Users/example/npm")
        #expect(prefix("prefix=/opt/npm ; set by hand") == "/opt/npm")
        #expect(prefix("prefix=/opt/one\r\nprefix=/opt/two") == "/opt/two")
        #expect(prefix("registry=https://registry.npmjs.org/\n; prefix=/a\n#prefix=/b") == nil)
        #expect(prefix("[scope]\nprefix=/opt/npm") == nil)
        #expect(prefix("prefix=relative/npm") == nil)
        #expect(prefix("prefix=${NPM_ROOT}/npm") == nil)
        #expect(prefix("prefix=/tmp/npm:/opt/npm") == nil)
    }

    @Test func npmPrefixBinFolderComesFromTheHomeNPMRC() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteNPMRCTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let npmrc = home.appendingPathComponent(".npmrc")

        #expect(ExecutableLocator.npmPrefixBinDirectories(homeDirectory: home.path).isEmpty)

        try Data("prefix=~/custom-npm/\n".utf8).write(to: npmrc)
        #expect(ExecutableLocator.npmPrefixBinDirectories(homeDirectory: home.path)
            == [home.appendingPathComponent("custom-npm/bin").standardizedFileURL.path])

        // A prefix in a system folder must not move it ahead of Homebrew.
        try Data("prefix=/usr/local\n".utf8).write(to: npmrc)
        #expect(ExecutableLocator.npmPrefixBinDirectories(homeDirectory: home.path).isEmpty)

        // A named pipe is skipped instead of blocking the read.
        try FileManager.default.removeItem(at: npmrc)
        #expect(mkfifo(npmrc.path, 0o600) == 0)
        #expect(ExecutableLocator.npmPrefixBinDirectories(homeDirectory: home.path).isEmpty)
    }

    @Test func executableLookupReturnsTheFirstFolderThatHasTheName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteLocatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var folders: [String] = []
        for name in ["system", "home"] {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent("helper")
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            folders.append(folder.path)
        }

        #expect(ExecutableLocator.executablePath(named: "helper", in: folders) == "\(folders[0])/helper")
        #expect(ExecutableLocator.executablePath(named: "helper", in: folders.reversed()) == "\(folders[1])/helper")
        #expect(ExecutableLocator.executablePath(named: "missing", in: folders) == nil)
    }

    @Test func draftInfersStringParametersFromArgumentPlaceholders() throws {
        var draft = ToolDefinitionDraft()
        draft.mode = .commandTemplate
        draft.name = "Echo"
        draft.summary = "Echo a value."
        draft.executablePath = "/bin/echo"
        draft.argumentsText = """
        fixed
        {value}
        """

        let tool = try draft.makeTool(id: "custom.echo")
        #expect(tool.argumentPattern == ["fixed", "{value}"])
        #expect(tool.parameters.map(\.name) == ["value"])
        #expect(try ToolArgumentResolver.arguments(for: tool, stringParameters: ["value": "hello"]) == ["fixed", "hello"])
    }

    @Test func draftDefaultsToGenericCLIAdapterArguments() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Generic echo adapter."
        draft.executablePath = "/bin/echo"

        let tool = try draft.makeTool(id: "custom.echo")
        #expect(tool.argumentPattern == ["{args}"])
        #expect(tool.parameters.first?.name == "args")
        #expect(tool.parameters.first?.kind == .stringArray)
        #expect(tool.parameters.map(\.name) == ["args", "stdin"])
        #expect(
            try ToolArgumentResolver.arguments(
                for: tool,
                parameters: ["args": .stringArray(["hello", "world"])]
            ) ==
            ["hello", "world"]
        )
        #expect(tool.permissionRequirements == [])
    }

    @Test func draftCanRequireMacOSPrivacyServicesWithoutFullDiskAccess() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Screenshot"
        draft.summary = "Capture the screen."
        draft.executablePath = "/usr/sbin/screencapture"
        draft.permissionRequirements = [.screenRecording, .automation]

        let tool = try draft.makeTool(id: "custom.screencapture")

        #expect(tool.permissionRequirements == [.screenRecording, .automation])
    }

    @Test func draftUsesPracticalMaximumLengthsForCommonPlaceholders() throws {
        let parameters = try ToolDefinitionDraft.inferredParameters(from: [
            "{prompt}",
            "{path}",
            "{query}",
            "{value}"
        ])
        func maximumLength(for name: String) -> Int? {
            parameters.first { $0.name == name }?.maximumLength
        }

        #expect(maximumLength(for: "prompt") == 4096)
        #expect(maximumLength(for: "path") == 1024)
        #expect(maximumLength(for: "query") == 512)
        #expect(maximumLength(for: "value") == 256)
    }

    @Test func draftCanRequireFullDiskAccess() throws {
        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Generic echo adapter."
        draft.executablePath = "/bin/echo"
        draft.requiresFullDiskAccess = true

        let tool = try draft.makeTool(id: "custom.echo")

        #expect(tool.permissionRequirements == [.fullDiskAccess])
    }

    @Test func processToolTimeoutSupportsLongRunningCommandsUpToTwentyFourHours() throws {
        let maximum = ToolDefinition(
            id: "custom.long-running",
            name: "Long-running Tool",
            summary: "Exercises the maximum supported timeout.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 86_400,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        let tooLong = ToolDefinition(
            id: "custom.too-long",
            name: "Too-long Tool",
            summary: "Exceeds the maximum supported timeout.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 86_401,
            outputByteLimit: 1024,
            origin: .userDefined
        )

        #expect(throws: Never.self) { try ToolArgumentResolver.validate(maximum) }
        #expect(throws: ToolValidationError.invalidTimeout) { try ToolArgumentResolver.validate(tooLong) }
    }

    @Test func outputLimitSupportsLargeArtifactsUpToSixtyFourMiB() throws {
        let maximum = ToolDefinition(
            id: "custom.maximum-output",
            name: "Maximum-output Tool",
            summary: "Exercises the artifact store output ceiling.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: ToolArgumentResolver.maximumOutputByteLimit,
            origin: .userDefined
        )
        let tooLarge = ToolDefinition(
            id: "custom.excessive-output",
            name: "Excessive-output Tool",
            summary: "Exceeds the artifact store output ceiling.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: ToolArgumentResolver.maximumOutputByteLimit + 1,
            origin: .userDefined
        )

        #expect(ToolArgumentResolver.maximumOutputByteLimit == 64 * 1024 * 1024)
        #expect(throws: Never.self) { try ToolArgumentResolver.validate(maximum) }
        #expect(throws: ToolValidationError.invalidOutputLimit) { try ToolArgumentResolver.validate(tooLarge) }
    }

    @Test func shellExecutablesAreBlocked() throws {
        let tool = ToolDefinition(
            id: "custom.shell",
            name: "Shell",
            summary: "Blocked.",
            executablePath: "/bin/sh",
            argumentPattern: ["-c", "echo nope"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )

        #expect(throws: ToolValidationError.blockedExecutable("/bin/sh")) { try ToolArgumentResolver.validate(tool) }
    }

    // R6/G1 — `dash` and `ksh` are in /etc/shells and must be Ring 0 like the rest.
    @Test(arguments: ["/bin/dash", "/bin/ksh", "/usr/local/bin/DASH"])
    func dashAndKshShellsAreBlocked(path: String) {
        let tool = makeShellShapedTool(executablePath: path)
        #expect(throws: ToolValidationError.blockedExecutable(path)) { try ToolArgumentResolver.validate(tool) }
    }

    // R6/G2 — an innocently named symlink resolving to a shell must not validate.
    @Test func symlinkToShellIsBlockedByResolvedBasename() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let link = temporaryDirectory.appendingPathComponent("notes")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/zsh"))

        let tool = makeShellShapedTool(executablePath: link.path)
        #expect(throws: ToolValidationError.blockedExecutable(link.path)) { try ToolArgumentResolver.validate(tool) }
    }

    // R6 — the same Ring-0 check guards the stdio-bridge command path.
    @Test func stdioBridgeCommandSymlinkToShellIsBlocked() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let link = temporaryDirectory.appendingPathComponent("mcp-server")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/bin/bash"))

        let tool = ToolDefinition(
            id: "custom.bridge",
            name: "Bridge",
            summary: "Blocked stdio bridge.",
            executablePath: "/",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                serverName: "Test",
                command: link.path,
                toolName: "tool"
            )
        )

        #expect(throws: ToolValidationError.blockedExecutable(link.path)) { try ToolArgumentResolver.validate(tool) }
    }

    @Test func storePersistsOnlyUserDefinedTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let custom = ToolDefinition(
            id: "custom.echo",
            name: "Echo",
            summary: "Echo a value.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )

        try store.saveUserDefinedTools(FileTransferToolCatalog.builtInTools + [custom])
        let loaded = try store.loadUserDefinedTools()
        #expect(loaded == [custom])
    }

    @Test func startupLoadReportRetainsValidAndInvalidSavedTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = temporaryDirectory.appendingPathComponent("tools.json")
        let store = ToolRegistryStore(fileURL: storeURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let valid = ToolDefinition(
            id: "custom.valid",
            name: "Valid",
            summary: "Available executable.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        let missingPath = temporaryDirectory.appendingPathComponent("missing-cli").path
        let invalid = ToolDefinition(
            id: "custom.missing",
            name: "Missing",
            summary: "Executable was removed.",
            executablePath: missingPath,
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        try JSONEncoder().encode([valid, invalid]).write(to: storeURL)

        let report = try store.loadUserDefinedToolsReport()

        #expect(report.tools == [valid, invalid])
        #expect(report.issues == [
            ToolRegistryLoadIssue(
                toolID: invalid.id,
                toolName: invalid.name,
                problem: .validation(.executableUnavailable(missingPath)),
                requiresQuarantine: false,
                blocksWrites: false
            )
        ])
        #expect(report.issues.first?.requiresQuarantine == false)
        #expect(report.writesAllowed)
        #expect(throws: ToolValidationError.executableUnavailable(missingPath)) {
            try store.loadUserDefinedTools()
        }
    }

    @Test func startupLoadReportDecodesRowsIndependentlyAndBlocksWrites() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = temporaryDirectory.appendingPathComponent("tools.json")
        let store = ToolRegistryStore(fileURL: storeURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)

        let valid = ToolDefinition(
            id: "custom.valid",
            name: "Valid",
            summary: "Available executable.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 1024,
            origin: .userDefined
        )
        let validJSON = try #require(String(data: JSONEncoder().encode(valid), encoding: .utf8))
        let originalData = Data("""
        [
          \(validJSON),
          {"id":"custom.broken","name":"Broken"}
        ]

        """.utf8)
        try originalData.write(to: storeURL)

        let report = try store.loadUserDefinedToolsReport()

        #expect(report.tools == [valid])
        #expect(!report.writesAllowed)
        let issue = try #require(report.issues.first)
        #expect(issue.toolID == "custom.broken")
        #expect(issue.toolName == "Broken")
        #expect(issue.blocksWrites)
        guard case .decoding(let row, let reason) = issue.problem else {
            Issue.record("Expected a per-row decoding issue")
            return
        }
        #expect(row == 2)
        #expect(reason.contains("missing required field"))
        #expect(throws: (any Error).self) {
            try store.loadUserDefinedTools()
        }
        #expect(try Data(contentsOf: storeURL) == originalData)
    }

    @Test func legacyToolDefinitionDecodesWithDefaultOriginAndCategory() throws {
        let data = """
        {
          "id": "custom.legacy",
          "name": "Legacy",
          "summary": "Old saved tool.",
          "executablePath": "/bin/echo",
          "argumentPattern": ["hello"],
          "parameters": [],
          "capability": "readOnly",
          "timeoutSeconds": 5,
          "outputByteLimit": 1024
        }
        """.data(using: .utf8)!

        let tool = try JSONDecoder().decode(ToolDefinition.self, from: data)
        #expect(tool.origin == .userDefined)
        #expect(tool.category == .utilities)
        #expect(tool.permissionRequirements == [])
        #expect(tool.backend == .process)
        #expect(tool.mcpBridge == nil)
    }

    @Test func mcpBridgeToolValidationDoesNotRequireExecutable() throws {
        let tool = ToolDefinition(
            id: "mcp.paste.search",
            name: "Paste Search",
            summary: "Search Paste through its local MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            permissionRequirements: [.localNetwork],
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "paste",
                serverURL: "http://127.0.0.1:39725/mcp",
                toolName: "search",
                toolTitle: "Search",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object(["type": .string("string")])
                    ])
                ]),
                annotations: .object(["readOnlyHint": .bool(true)])
            )
        )

        #expect(throws: Never.self) { try ToolArgumentResolver.validate(tool) }
        #expect(tool.preview == "http://127.0.0.1:39725/mcp → search")
        #expect(tool.isMCPBridge)
    }

    @Test func startupQuarantinesOverBudgetHTTPAndStdioBridgeSchemas() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = temporaryDirectory.appendingPathComponent("tools.json")
        let store = ToolRegistryStore(fileURL: storeURL)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        var deepSchema: JSONValue = .object([
            "type": .string("string"),
            "x-mcp-header": .string("Deep")
        ])
        for index in 0..<70 {
            deepSchema = .object([
                "type": .string("object"),
                "properties": .object(["level\(index)": deepSchema])
            ])
        }
        let wideProperties = Dictionary(
            uniqueKeysWithValues: (0..<4_100).map {
                ("value\($0)", JSONValue.object(["type": .string("string")]))
            }
        )
        let wideSchema = JSONValue.object([
            "type": .string("object"),
            "properties": .object(wideProperties)
        ])
        let httpTool = ToolDefinition(
            id: "mcp.hostile.http",
            name: "Hostile HTTP",
            summary: "Over-depth saved bridge schema.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "hostile-http",
                serverURL: "http://127.0.0.1:4999/mcp",
                toolName: "deep",
                inputSchema: deepSchema
            )
        )
        let stdioTool = ToolDefinition(
            id: "mcp.hostile.stdio",
            name: "Hostile Stdio",
            summary: "Over-node saved bridge schema.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpStdioBridge,
            mcpStdioBridge: MCPStdioBridgeConfiguration(
                serverName: "hostile-stdio",
                command: "/bin/echo",
                toolName: "wide",
                inputSchema: wideSchema
            )
        )
        try JSONEncoder().encode([httpTool, stdioTool]).write(to: storeURL)

        let report = try store.loadUserDefinedToolsReport()

        #expect(report.tools == [httpTool, stdioTool])
        #expect(report.issues.count == 2)
        #expect(report.issues.allSatisfy { $0.requiresQuarantine })
        #expect(report.issues.allSatisfy { issue in
            guard case .validation(.invalidMCPBridge(let detail)) = issue.problem else {
                return false
            }
            return detail.contains("mirrored-header bounds")
        })
    }

    @Test func storePersistsMCPBridgeTools() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let tool = ToolDefinition(
            id: "mcp.local.search",
            name: "Local Search",
            summary: "Search a local MCP server.",
            executablePath: "",
            argumentPattern: [],
            parameters: [],
            capability: .readOnly,
            timeoutSeconds: 10,
            outputByteLimit: 1024 * 1024,
            origin: .userDefined,
            category: .developer,
            backend: .mcpHTTPBridge,
            mcpBridge: MCPBridgeConfiguration(
                serverName: "local",
                serverURL: "http://127.0.0.1:4999/mcp",
                toolName: "search",
                inputSchema: .object(["type": .string("object")]),
                headers: [
                    MCPBridgeHeader(
                        name: "Authorization",
                        valueSource: MCPBridgeHeaderValueSource(
                            kind: .environment,
                            environmentKey: "LOCAL_MCP_TOKEN",
                            prefix: "Bearer "
                        )
                    )
                ]
            )
        )

        try store.saveUserDefinedTools([tool])
        #expect(try store.loadUserDefinedTools() == [tool])
    }

    @Test func typedIntegerParameterRejectsInvalidValues() throws {
        let tool = ToolDefinition(
            id: "test.limit",
            name: "Limit Test",
            summary: "Bounded limit.",
            executablePath: "/bin/echo",
            argumentPattern: ["{limit}"],
            parameters: [
                ToolParameter(
                    name: "limit",
                    title: "Limit",
                    kind: .integer,
                    required: true,
                    integerRange: 1...100
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )

        #expect(throws: ToolValidationError.invalidInteger("limit")) {
            try ToolArgumentResolver.arguments(for: tool, stringParameters: ["limit": "banana"])
        }
        #expect(throws: ToolValidationError.integerOutOfRange("limit")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: ["limit": .json(.number(-1))])
        }
    }

    @Test(arguments: [
        (1e50, "positive out-of-range"),
        (-1e50, "negative out-of-range"),
        (Double.infinity, "infinity"),
        (-Double.infinity, "negative infinity"),
        (Double.nan, "NaN")
    ])
    func toolArgumentValueIntegerStringRejectsNonRepresentableNumbers(value: Double, _: String) {
        #expect(ToolArgumentValue.integerString(from: value) == nil)
        #expect(ToolArgumentValue.json(.number(value)).stringValue == nil)
    }

    @Test func toolArgumentValueIntegerStringAcceptsRepresentableIntegers() {
        #expect(ToolArgumentValue.integerString(from: 42) == "42")
        #expect(ToolArgumentValue.integerString(from: -1) == "-1")
        #expect(ToolArgumentValue.json(.number(42)).stringValue == "42")
    }

    @Test func toolArgumentValueFromJSONObjectDoesNotTrapOnOutOfRangeArrayIntegers() {
        let positive = ToolArgumentValue.fromJSONObject([1e50])
        #expect(positive?.stringArrayValue == nil)

        let negative = ToolArgumentValue.fromJSONObject([-1e50])
        #expect(negative?.stringArrayValue == nil)
    }

    @Test func typedIntegerParameterRejectsOutOfRangeJSONNumber() throws {
        let tool = ToolDefinition(
            id: "test.limit",
            name: "Limit Test",
            summary: "Bounded limit.",
            executablePath: "/bin/echo",
            argumentPattern: ["{limit}"],
            parameters: [
                ToolParameter(
                    name: "limit",
                    title: "Limit",
                    kind: .integer,
                    required: true,
                    integerRange: 1...100
                )
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )

        #expect(throws: ToolValidationError.invalidInteger("limit")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: ["limit": .json(.number(1e50))])
        }
        #expect(throws: ToolValidationError.invalidInteger("limit")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: ["limit": .json(.number(-1e50))])
        }
        #expect(throws: ToolValidationError.invalidInteger("limit")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: ["limit": .json(.number(.infinity))])
        }
    }

    @Test func stringArrayParameterRejectsNonArrayJSONValue() throws {
        let tool = ToolDefinition(
            id: "stress.echo",
            name: "Stress Echo",
            summary: "Echo argv.",
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
            outputByteLimit: 1024
        )

        let stringArgument = try #require(ToolArgumentValue.fromJSONObject("not_an_array"))
        #expect(throws: ToolValidationError.invalidArgument("args")) {
            try ToolArgumentResolver.arguments(for: tool, parameters: ["args": stringArgument])
        }
        #expect(
            try ToolArgumentResolver.arguments(
                for: tool,
                parameters: ["args": .stringArray(["hello", "world"])]
            ) == ["hello", "world"]
        )
    }

    @Test func toolArgumentValuePreservesJSONNumbersForBridgeArguments() throws {
        let value = try #require(ToolArgumentValue.fromJSONObject([
            "count": 2,
            "nested": ["enabled": true]
        ]))
        let object = try #require(value.jsonValue.objectValue)

        #expect(object["count"] == .number(2))
        #expect(object["nested"] == .object(["enabled": .bool(true)]))
    }

    @Test func resolverKeepsParsedZeroAndOneDistinctFromBooleans() throws {
        let rawArguments = try #require(
            JSONSerialization.jsonObject(
                with: Data(#"{"zero":0,"one":1,"disabled":false,"enabled":true}"#.utf8)
            ) as? [String: Any]
        )
        let tool = ToolDefinition(
            id: "test.number-boolean-distinction",
            name: "Number and Boolean Distinction",
            summary: "Preserve parsed JSON argument types.",
            executablePath: "/bin/echo",
            argumentPattern: ["{zero}", "{one}", "{disabled}", "{enabled}"],
            parameters: [
                ToolParameter(name: "zero", title: "Zero", kind: .integer),
                ToolParameter(name: "one", title: "One", kind: .integer),
                ToolParameter(name: "disabled", title: "Disabled", kind: .boolean),
                ToolParameter(name: "enabled", title: "Enabled", kind: .boolean)
            ],
            capability: .readOnly,
            timeoutSeconds: 2,
            outputByteLimit: 1024
        )
        let arguments = rawArguments.compactMapValues(ToolArgumentValue.fromJSONObject)

        #expect(
            try ToolArgumentResolver.arguments(for: tool, parameters: arguments) ==
                ["0", "1", "false", "true"]
        )
    }

    @Test func defaultPresetsCreateValidUserDefinedTools() throws {
        #expect(DefaultToolPresetCatalog.presets.isEmpty == false)

        for preset in DefaultToolPresetCatalog.presets {
            let tool = try preset.draft.makeTool(id: preset.id)
            #expect(tool.origin == .userDefined)
            #expect(tool.category == preset.category)
            #expect(tool.capability == preset.capability)
            #expect(tool.permissionRequirements == preset.permissionRequirements)
        }
    }

    @Test func presetSetsReferenceValidAvailablePresets() {
        let allPresetIDs = Set(DefaultToolPresetCatalog.presets.map(\.id))
        let allSystemSet = DefaultToolPresetCatalog.presetSets.first { $0.id == "set.all_system_presets" }

        #expect(Set(allSystemSet?.presets.map(\.id) ?? []) == allPresetIDs)
        #expect(DefaultToolPresetCatalog.presetSets.isEmpty == false)
        for presetSet in DefaultToolPresetCatalog.presetSets {
            #expect(presetSet.presets.isEmpty == false)
            #expect(presetSet.presets.map(\.id).allSatisfy { allPresetIDs.contains($0) })
        }
    }

    @Test(.enabled(if: DefaultToolPresetCatalog.codexExecutablePath != nil, "Codex is not installed on this Mac."))
    func codexPresetIsAvailableWhenExecutableIsInstalled() throws {
        let executablePath = try #require(DefaultToolPresetCatalog.codexExecutablePath)

        // F20/DL-12: the Codex presets live in the AI & Agents category.
        let presets = DefaultToolPresetCatalog.presets(in: .ai)
        let readOnlyExec = try #require(presets.first { $0.id == "preset.developer.codex_read_only_exec" })
        #expect(readOnlyExec.executablePath == executablePath)
        #expect(readOnlyExec.mode == .commandTemplate)
        let approvalFlagIndex = try #require(readOnlyExec.argumentPattern.firstIndex(of: "--ask-for-approval"))
        let execIndex = try #require(readOnlyExec.argumentPattern.firstIndex(of: "exec"))
        #expect(approvalFlagIndex < execIndex)
        // F1: the summary must not claim the tool itself is read-only —
        // capability stays `.destructive` and the copy explains why.
        #expect(readOnlyExec.capability == .destructive)
        #expect(readOnlyExec.summary.contains("read-only mode") == false)
        #expect(readOnlyExec.summary.contains("host approval"))

        #expect(presets.contains { preset in
            preset.id == "preset.developer.codex" &&
                preset.executablePath == executablePath &&
                preset.mode == .cliAdapter &&
                preset.capability == .destructive
        })
        #expect(DefaultToolPresetCatalog.preferredCategory == .ai)
        #expect(DefaultToolPresetCatalog.featuredPresets.contains { $0.id == "preset.developer.codex" })
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "claude") != nil, "Claude Code is not installed on this Mac."))
    func claudeCodePresetUsesClaudeCLIWhenInstalled() throws {
        let executablePath = try #require(ExecutableLocator.executablePath(named: "claude"))

        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.claude.run"))
        #expect(preset.name == "Claude Code")
        #expect(preset.executablePath == executablePath)
        #expect(preset.mode == .cliAdapter)
        #expect(preset.capability == .destructive)
        #expect(preset.timeoutSeconds == 3_600)
        #expect(preset.outputLimitKB == 5120)
        #expect(preset.summary.contains("--print"))
        #expect(preset.summary.contains("--output-format"))
        #expect(DefaultToolPresetCatalog.preset(id: "preset.claude_session.run") == nil)
    }

    @Test func detectedPopularCLIsAppearAsPresetsWhenInstalled() {
        let expected: [(String, String)] = [
            ("peekaboo", "preset.peekaboo.run"),
            ("spogo", "preset.spogo.run"),
            ("summarize", "preset.summarize.run"),
            ("gog", "preset.gog.run"),
            ("llm", "preset.llm.run"),
            ("gh", "preset.gh.run"),
            ("jq", "preset.jq.run"),
            ("rg", "preset.rg.run"),
            ("yt-dlp", "preset.ytdlp.run"),
            ("ffmpeg", "preset.ffmpeg.run"),
            ("cloudflared", "preset.cloudflared.run"),
            ("tailscale", "preset.tailscale.run"),
            ("uv", "preset.uv.run"),
            ("uvx", "preset.uvx.run"),
            ("deno", "preset.deno.run"),
            ("supabase", "preset.supabase.run"),
            ("xcodegen", "preset.xcodegen.run"),
            ("grok-session", "preset.grok_session.run"),
            ("monologue", "preset.monologue.run"),
            ("spark", "preset.spark.run"),
            ("frames", "preset.frames.run"),
            ("ollama", "preset.ollama.run"),
            ("whisper-cli", "preset.whisper.run"),
            ("pdftotext", "preset.pdftotext.extract"),
            ("pdfinfo", "preset.pdfinfo.info"),
            ("tesseract", "preset.tesseract.ocr"),
            ("trasher", "preset.trasher.trash")
        ]

        for (executable, presetID) in expected where ExecutableLocator.executablePath(named: executable) != nil {
            #expect(DefaultToolPresetCatalog.preset(id: presetID) != nil, "\(executable) should expose \(presetID)")
        }
    }

    @Test func detectedSystemCLIsAppearAsGenericAdaptersWhenInstalled() {
        let expected: [(String, String)] = [
            ("claude", "preset.claude.run"),
            ("grok", "preset.grok.run"),
            ("swift", "preset.swift.run"),
            ("xcodebuild", "preset.xcodebuild.run"),
            ("node", "preset.node.run"),
            ("npm", "preset.npm.run"),
            ("pnpm", "preset.pnpm.run"),
            ("python3", "preset.python3.run"),
            ("ruby", "preset.ruby.run"),
            ("perl", "preset.perl.run"),
            ("curl", "preset.curl.run"),
            ("rsync", "preset.rsync.run"),
            ("sqlite3", "preset.sqlite3.run"),
            ("shortcuts", "preset.shortcuts.run"),
            ("osascript", "preset.osascript.run"),
            ("automator", "preset.automator.run"),
            ("screencapture", "preset.screencapture.run"),
            ("mdfind", "preset.mdfind.run"),
            ("mdls", "preset.mdls.run"),
            ("qlmanage", "preset.qlmanage.run"),
            ("textutil", "preset.textutil.run"),
            ("openclaw", "preset.openclaw.run"),
            ("lms", "preset.lms.run"),
            ("git", "preset.git.run"),
            ("docker", "preset.docker.run"),
            ("ipsw", "preset.ipsw.run"),
            ("vercel", "preset.vercel.run"),
            ("wrangler", "preset.wrangler.run"),
            ("go", "preset.go.run"),
            ("cargo", "preset.cargo.run"),
            ("defuddle", "preset.defuddle.run"),
            ("ntn", "preset.ntn.run"),
            ("obsidian", "preset.obsidian.run"),
            ("pandoc", "preset.pandoc.run"),
            ("magick", "preset.magick.run"),
            ("exiftool", "preset.exiftool.run")
        ]

        for (executable, presetID) in expected where ExecutableLocator.executablePath(named: executable) != nil {
            let preset = DefaultToolPresetCatalog.preset(id: presetID)
            #expect(preset != nil, "\(executable) should expose \(presetID)")
            #expect(preset?.mode == .cliAdapter)
        }
    }

    @Test func detectedPrivacySensitiveCLIPresetsDeclareMacOSPermissions() throws {
        if ExecutableLocator.executablePath(named: "peekaboo") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.peekaboo.run"))
            #expect(preset.permissionRequirements == [.screenRecording, .accessibility])
        }
        if ExecutableLocator.executablePath(named: "osascript") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.osascript.run"))
            #expect(preset.permissionRequirements == [.accessibility, .automation])
        }
        if ExecutableLocator.executablePath(named: "screencapture") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.screencapture.run"))
            #expect(preset.permissionRequirements == [.screenRecording])
        }
    }

    @Test func buildScriptIncludesCommonMacOSPrivacyUsageDescriptions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = projectRoot.appendingPathComponent("script/build_and_run.sh")
        let contents = try String(contentsOf: buildScript, encoding: .utf8)
        let expectedKeys = [
            "NSAppleEventsUsageDescription",
            "NSCalendarsFullAccessUsageDescription",
            "NSContactsUsageDescription",
            "NSDesktopFolderUsageDescription",
            "NSDocumentsFolderUsageDescription",
            "NSDownloadsFolderUsageDescription",
            "NSLocalNetworkUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSPhotoLibraryUsageDescription",
            "NSRemindersUsageDescription",
            "NSScreenCaptureUsageDescription",
            "NSSpeechRecognitionUsageDescription"
        ]

        for key in expectedKeys {
            #expect(contents.contains("<key>\(key)</key>"), "\(key) should be included in generated Info.plist")
        }
    }

    @Test func presetInstallationIndexUsesStableIDOrSignatureAndDeduplicatesBatch() throws {
        let installedPreset = DefaultToolPreset(
            id: "preset.test.echo",
            name: "Echo Once",
            summary: "Echo a fixed value.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let existingTool = try installedPreset.draft.makeTool(id: installedPreset.toolID)
        let sameIDWithChangedRecipe = DefaultToolPreset(
            id: installedPreset.id,
            name: "Echo Revised",
            summary: "Use the revised catalog recipe.",
            executablePath: "/usr/bin/printf",
            argumentPattern: ["revised"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let sameSignatureWithDifferentID = DefaultToolPreset(
            id: "preset.test.echo_alias",
            name: "Echo Alias",
            summary: "An equivalent recipe under another semantic name.",
            executablePath: installedPreset.executablePath,
            argumentPattern: installedPreset.argumentPattern,
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let newPreset = DefaultToolPreset(
            id: "preset.test.print_new",
            name: "Print New",
            summary: "A genuinely new recipe.",
            executablePath: "/usr/bin/printf",
            argumentPattern: ["new"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let duplicateNewSignature = DefaultToolPreset(
            id: "preset.test.print_new_alias",
            name: "Print New Alias",
            summary: "The same new execution contract under another ID.",
            executablePath: newPreset.executablePath,
            argumentPattern: newPreset.argumentPattern,
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )

        let index = DefaultToolPresetInstallationIndex(tools: [existingTool])
        #expect(index.isInstalled(sameIDWithChangedRecipe))
        #expect(index.isInstalled(sameSignatureWithDifferentID))
        #expect(index.isInstalled(newPreset) == false)
        #expect(index.installedCount(in: [sameIDWithChangedRecipe, sameSignatureWithDifferentID, newPreset]) == 2)
        #expect(
            index.installablePresets(in: [
                sameIDWithChangedRecipe,
                sameSignatureWithDifferentID,
                newPreset,
                newPreset,
                duplicateNewSignature
            ]) == [newPreset]
        )
    }

    @MainActor
    @Test func appModelBulkPresetInstallSkipsMixedCollisionsAndTreatsAllExistingAsNoOp() throws {
        let suiteName = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = makeTestAppModel(userDefaults: defaults, toolStore: store)
        let installedPreset = DefaultToolPreset(
            id: "preset.test.echo",
            name: "Echo Once",
            summary: "Echo a fixed value.",
            executablePath: "/bin/echo",
            argumentPattern: ["hello"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let sameIDWithChangedRecipe = DefaultToolPreset(
            id: installedPreset.id,
            name: "Echo Revised",
            summary: "Use the revised catalog recipe.",
            executablePath: "/usr/bin/printf",
            argumentPattern: ["revised"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let sameSignatureWithDifferentID = DefaultToolPreset(
            id: "preset.test.echo_alias",
            name: "Echo Alias",
            summary: "An equivalent recipe under another semantic name.",
            executablePath: installedPreset.executablePath,
            argumentPattern: installedPreset.argumentPattern,
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )
        let newPreset = DefaultToolPreset(
            id: "preset.test.print_new",
            name: "Print New",
            summary: "A genuinely new recipe.",
            executablePath: "/usr/bin/printf",
            argumentPattern: ["new"],
            capability: .readOnly,
            category: .utilities,
            timeoutSeconds: 5,
            outputLimitKB: 64
        )

        #expect(model.addUserTools(from: [installedPreset], sourceName: "Test Set") == nil)
        #expect(model.tools.count == 1)
        #expect(model.tools.first?.name == "Echo Once")
        let originalTool = try #require(model.tools.first)

        let mixedSelection = [
            sameIDWithChangedRecipe,
            sameSignatureWithDifferentID,
            newPreset,
            newPreset
        ]
        #expect(model.newPresetCount(in: mixedSelection) == 1)
        #expect(model.addUserTools(from: mixedSelection, sourceName: "Mixed Test Set") == nil)
        #expect(model.tools.count == 2)
        #expect(model.tools.first { $0.id == installedPreset.toolID } == originalTool)
        #expect(model.tools.contains { $0.id == newPreset.toolID })

        let afterMixedInstall = model.tools
        #expect(model.newPresetCount(in: mixedSelection) == 0)
        #expect(model.addUserTools(from: mixedSelection, sourceName: "Mixed Test Set") == nil)
        #expect(model.tools == afterMixedInstall)
    }

    @Test func filesystemPresetsAvoidDestructiveCommands() {
        let destructiveBasenames: Set<String> = ["rm", "rmdir", "unlink", "trash"]
        let filesystemPresets = DefaultToolPresetCatalog.presets(in: .filesystem)

        #expect(filesystemPresets.isEmpty == false)
        for preset in filesystemPresets {
            #expect(destructiveBasenames.contains(URL(fileURLWithPath: preset.executablePath).lastPathComponent) == false)
            if preset.mode == .commandTemplate {
                // Move To Trash is the one deliberate `.write` template
                // (spec §6.1 #13 — it recoverably relocates, never deletes).
                let expected: ToolCapability = preset.id == "preset.trasher.trash" ? .write : .readOnly
                #expect(preset.capability == expected)
            } else {
                #expect(preset.mode == .cliAdapter)
                #expect(preset.argumentPattern == ["{args}"])
            }
            #expect((preset.argumentPattern.contains { argument in
                argument.localizedCaseInsensitiveContains("delete")
                    || argument.localizedCaseInsensitiveContains("remove")
            }) == false)
        }
    }

    // Owner decision: the unverifiable Cora preset and redundant filesystem
    // recipes never ship, regardless of what is installed.
    @Test func excludedPresetsNeverAppear() {
        #expect(DefaultToolPresetCatalog.preset(id: "preset.cora.run") == nil)
        #expect(DefaultToolPresetCatalog.preset(id: "preset.filesystem.file_info") == nil)
        #expect(DefaultToolPresetCatalog.preset(id: "preset.filesystem.read_head") == nil)
    }

    // DL-14: URL-fetching templates must not be read-only — read-only skips the
    // per-call approval that is the only exfiltration gate.
    @Test func networkFetchingTemplatesRequireApproval() throws {
        if ExecutableLocator.executablePath(named: "summarize") != nil {
            let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.summarize.input"))
            #expect(preset.capability == .write)
        }
        if ExecutableLocator.executablePath(named: "yt-dlp") != nil {
            let metadata = try #require(DefaultToolPresetCatalog.preset(id: "preset.ytdlp.metadata"))
            #expect(metadata.capability == .write)
            #expect(metadata.name == "yt-dlp Metadata")
            #expect(metadata.category == .imageProcessing)
            let adapter = try #require(DefaultToolPresetCatalog.preset(id: "preset.ytdlp.run"))
            #expect(adapter.name == "yt-dlp CLI")
            #expect(adapter.category == .imageProcessing)
        }
    }

    // F20/DL-12: the AI cluster presets carry the `.ai` category.
    @Test func aiClusterPresetsUseAICategory() {
        let aiExecutables = ["claude", "codex", "grok", "llm", "ollama", "lms", "whisper-cli"]
        let aiPresetPrefixes = [
            "preset.claude.", "preset.developer.codex", "preset.grok.",
            "preset.llm.", "preset.ollama.", "preset.lms.", "preset.whisper."
        ]

        let aiPresets = DefaultToolPresetCatalog.presets.filter { preset in
            aiPresetPrefixes.contains { preset.id.hasPrefix($0) }
        }
        for preset in aiPresets {
            #expect(preset.category == .ai, "\(preset.id) should be in AI & Agents")
        }

        if aiExecutables.contains(where: { ExecutableLocator.executablePath(named: $0) != nil }) {
            #expect(aiPresets.isEmpty == false)
            #expect(DefaultToolPresetCatalog.categories.contains(.ai))
            #expect(DefaultToolPresetCatalog.presetSets.contains { $0.id == "set.ai" })
        }
    }

    // §6.4 written policy: no preset may wrap a Ring-1 executable (secrets
    // managers, shells, privilege tools, package managers). The scanner and
    // the catalog share `CLIRecommendationBlocklist` as the denylist source.
    @Test func noPresetWrapsRingOneExecutable() {
        for preset in DefaultToolPresetCatalog.presets {
            let basename = URL(fileURLWithPath: preset.executablePath).lastPathComponent
            #expect(
                CLIRecommendationBlocklist.matches(
                    basename,
                    in: CLIRecommendationBlocklist.neverSuggestNames,
                    prefixes: CLIRecommendationBlocklist.neverSuggestPrefixes
                ) == false,
                "\(preset.id) wraps Ring-1 executable \(basename)"
            )
        }
    }

    // §6.3 — the scanner's preset fold pass resolves candidates back to presets.
    @Test func presetLookupsMatchExecutablePathAndBasename() throws {
        let preset = try #require(DefaultToolPresetCatalog.presets.first)

        let byPath = try #require(DefaultToolPresetCatalog.preset(matchingExecutablePath: preset.executablePath))
        #expect(byPath.executablePath == preset.executablePath)

        let basename = URL(fileURLWithPath: preset.executablePath).lastPathComponent
        let byBasename = try #require(DefaultToolPresetCatalog.preset(matchingBasename: basename.uppercased()))
        #expect(
            URL(fileURLWithPath: byBasename.executablePath).lastPathComponent
                .caseInsensitiveCompare(basename) == .orderedSame
        )

        #expect(DefaultToolPresetCatalog.preset(matchingExecutablePath: "/nonexistent/tool") == nil)
        #expect(DefaultToolPresetCatalog.preset(matchingBasename: "definitely-not-a-preset") == nil)
    }

    @Test func appGroupsAreCompleteDisjointAndDeterministic() throws {
        let expectedGroups: [(id: String, name: String, presets: [DefaultToolPreset])] = [
            ("provider.frames", "Apple Frames CLI", AppleFramesToolPresetCatalog.presets)
        ].filter { !$0.presets.isEmpty }
        let groups = DefaultToolPresetCatalog.appGroups(in: .imageProcessing)

        #expect(groups.map(\.id) == expectedGroups.map(\.id))
        #expect(groups.map(\.name) == expectedGroups.map(\.name))
        #expect(groups.allSatisfy { $0.category == .imageProcessing })
        #expect(groups.map(\.presets) == expectedGroups.map(\.presets))

        let groupedPresets = groups.flatMap(\.presets)
        #expect(Set(groupedPresets.map(\.id)).count == groupedPresets.count)

        for group in groups {
            let installedPreset = try #require(group.presets.first)
            let installedTool = try installedPreset.draft.makeTool(id: installedPreset.toolID)
            let index = DefaultToolPresetInstallationIndex(tools: [installedTool])

            #expect(index.installedCount(in: group.presets) == 1)
            #expect(
                index.installablePresets(in: group.presets).map(\.id) ==
                    Array(group.presets.dropFirst()).map(\.id)
            )
        }
    }

    @Test func catalogOwnershipExcludesMatterAndReadwise() {
        let ids = DefaultToolPresetCatalog.presets.map(\.id)
        #expect(ids.contains { $0.hasPrefix("preset.matter.") } == false)
        #expect(ids.contains { $0.hasPrefix("preset.readwise.") } == false)

        let federico = DefaultToolPresetCatalog.presets.filter {
            $0.publisher == .federicoViticci
        }
        #expect(federico.isEmpty == false)
        #expect(federico.allSatisfy { $0.id.hasPrefix("preset.frames.") })

        let federicoSet = DefaultToolPresetCatalog.presetSets.first {
            $0.id == "set.federico_viticci"
        }
        #expect(federicoSet?.presets == federico)
    }

    @Test func catalogInstallationIndexDistinguishesCurrentUpdatesAndEquivalentTools() throws {
        let preset = try #require(
            DefaultToolPresetCatalog.preset(id: "preset.utilities.current_date")
        )
        let current = try preset.draft.makeTool(
            id: preset.toolID,
            permissionEpoch: "catalog-epoch"
        )
        #expect(
            DefaultToolPresetInstallationIndex(tools: [current]).state(for: preset) == .current
        )

        var staleDraft = ToolDefinitionDraft(tool: current)
        staleDraft.summary = "An older catalog description."
        let stale = try staleDraft.makeTool(
            id: current.id,
            permissionEpoch: current.permissionEpoch
        )
        let staleIndex = DefaultToolPresetInstallationIndex(tools: [stale])
        #expect(staleIndex.state(for: preset) == .updateAvailable)
        #expect(staleIndex.updateablePresets(in: [preset]) == [preset])

        let equivalent = try preset.draft.makeTool(id: "custom_equivalent_date")
        let equivalentIndex = DefaultToolPresetInstallationIndex(tools: [equivalent])
        #expect(equivalentIndex.state(for: preset) == .equivalentTool)
        #expect(equivalentIndex.updateablePresets(in: [preset]).isEmpty)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "whisper-cli") != nil, "whisper.cpp is not installed on this Mac."))
    func whisperPresetsTranscribeLocally() throws {
        let transcribe = try #require(DefaultToolPresetCatalog.preset(id: "preset.whisper.transcribe"))
        #expect(transcribe.argumentPattern == ["-m", "{model}", "-f", "{audio}", "--no-prints"])
        #expect(transcribe.capability == .readOnly)
        #expect(transcribe.category == .ai)
        #expect(transcribe.timeoutSeconds == 60)
        #expect(transcribe.outputLimitKB == 2048)

        let adapter = try #require(DefaultToolPresetCatalog.preset(id: "preset.whisper.run"))
        #expect(adapter.mode == .cliAdapter)
        #expect(adapter.category == .ai)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "trasher") != nil, "trasher is not installed on this Mac."))
    func moveToTrashPresetIsRecoverableWrite() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.trasher.trash"))
        #expect(preset.name == "Move To Trash")
        #expect(preset.argumentPattern == ["{path}"])
        #expect(preset.capability == .write)
        #expect(preset.category == .filesystem)
        #expect(preset.timeoutSeconds == 10)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "pdftotext") != nil, "Poppler is not installed on this Mac."))
    func pdfReadPresetsAreReadOnlyTemplates() throws {
        let extract = try #require(DefaultToolPresetCatalog.preset(id: "preset.pdftotext.extract"))
        #expect(extract.argumentPattern == ["{path}", "-"])
        #expect(extract.capability == .readOnly)
        #expect(extract.category == .text)

        if ExecutableLocator.executablePath(named: "pdfinfo") != nil {
            let info = try #require(DefaultToolPresetCatalog.preset(id: "preset.pdfinfo.info"))
            #expect(info.argumentPattern == ["{path}"])
            #expect(info.capability == .readOnly)
        }
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "tesseract") != nil, "Tesseract is not installed on this Mac."))
    func ocrPresetIsReadOnlyMediaTemplate() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.tesseract.ocr"))
        #expect(preset.argumentPattern == ["{image}", "stdout"])
        #expect(preset.capability == .readOnly)
        #expect(preset.category == .imageProcessing)
    }

    @Test(.enabled(if: ExecutableLocator.executablePath(named: "openclaw") != nil, "OpenClaw is not installed on this Mac."))
    func steipeteSetIncludesOpenClaw() throws {
        let set = try #require(DefaultToolPresetCatalog.presetSets.first { $0.id == "set.steipete_openclaw" })
        #expect(set.presets.contains { $0.id == "preset.openclaw.run" })
    }

    // F2: the curl summary must not understate approval or reach.
    @Test(.enabled(if: ExecutableLocator.executablePath(named: "curl") != nil, "curl is not installed on this Mac."))
    func curlSummaryStatesApprovalAndReach() throws {
        let preset = try #require(DefaultToolPresetCatalog.preset(id: "preset.curl.run"))
        #expect(preset.capability == .destructive)
        #expect(preset.summary.contains("needs host approval unless"))
        #expect(preset.summary.contains("any host"))
        #expect(preset.permissionRequirements == [.localNetwork])
    }

    @Test func clientToolPermissionStoreUsesStableTrustIDAcrossClientIDChurn() throws {
        let suiteName = "MacRemoteTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ClientToolPermissionStore(userDefaults: defaults)
        let tool = ToolDefinition(
            id: "remctl_run",
            permissionEpoch: "remctl-installation",
            name: "Run RemCTL",
            summary: "Run RemCTL.",
            executablePath: "/bin/echo",
            argumentPattern: ["{args}"],
            parameters: [
                ToolParameter(name: "args", title: "Arguments", kind: .stringArray, required: false)
            ],
            capability: .destructive,
            timeoutSeconds: 5,
            outputByteLimit: 1_024,
            origin: .userDefined
        )

        _ = store.setAllowed(
            true,
            clientTrustID: "macremote-trust-codex",
            tool: tool
        )

        #expect(store.isAllowed(
            clientTrustID: "macremote-trust-codex",
            tool: tool
        ))
        #expect(store.isAllowed(
            clientTrustID: "macremote-trust-other",
            tool: tool
        ) == false)
    }
}

private func makeShellShapedTool(executablePath: String) -> ToolDefinition {
    ToolDefinition(
        id: "custom.shell-shaped",
        name: "Shell Shaped",
        summary: "Blocked.",
        executablePath: executablePath,
        argumentPattern: [],
        parameters: [],
        capability: .readOnly,
        timeoutSeconds: 5,
        outputByteLimit: 1024,
        origin: .userDefined
    )
}
