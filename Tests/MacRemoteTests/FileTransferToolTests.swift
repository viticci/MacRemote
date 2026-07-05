import Foundation
import Testing
@testable import MacRemote

struct FileTransferToolTests {
    private let artifactStore = ArtifactStore(rootDirectory: FileTransferToolTests.makeArtifactRoot())
    private var executor: NativeToolExecutor { NativeToolExecutor(artifactStore: artifactStore) }

    private static func makeArtifactRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-file-transfer-artifacts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - read_file

    @Test func readFileBinaryRoundTripInChunks() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("bytes.bin")
        var original = Data()
        while original.count < 200_000 {
            for byte in UInt8.min...UInt8.max {
                original.append(byte)
            }
        }
        try original.write(to: fileURL)

        var offset = 0
        var reassembled = Data()
        while true {
            let outcome = try await execute(
                nativeToolID: .fsReadFile,
                parameters: [
                    "path": .string(fileURL.path),
                    "offset": .json(.number(Double(offset))),
                    "length": .json(.number(65_536))
                ]
            )
            #expect(outcome.exitCode == 0)
            let json = try decodeJSONObject(outcome.stdout)
            let chunk = try #require((json["data_base64"] as? String).flatMap { Data(base64Encoded: $0) })
            reassembled.append(chunk)
            let eof = try #require(json["eof"] as? Bool)
            let returnedLength = try #require(json["length_returned"] as? Int)
            #expect(returnedLength <= 65_536)
            if eof {
                break
            }
            offset += returnedLength
        }

        #expect(reassembled == original)
    }

    @Test func readFileOffsetPastEOFReturnsEmptyData() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("small.txt")
        try Data("hello".utf8).write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsReadFile,
            parameters: [
                "path": .string(fileURL.path),
                "offset": .json(.number(100))
            ]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["data_base64"] as? String == "")
        #expect(json["eof"] as? Bool == true)
        #expect(json["length_returned"] as? Int == 0)
    }

    @Test func readFileLengthIsClampedTo65536() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("big.bin")
        try Data(repeating: 0xAB, count: 120_000).write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsReadFile,
            parameters: [
                "path": .string(fileURL.path),
                "offset": .json(.number(0)),
                "length": .json(.number(200_000))
            ]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["length_returned"] as? Int == 65_536)
        let chunk = try #require((json["data_base64"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(chunk.count == 65_536)
    }

    // MARK: - write_file

    @Test func writeFileBase64CreateAndVerify() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("created.bin")
        let payload = Data([0, 1, 2, 255])

        let outcome = try await execute(
            nativeToolID: .fsWriteFile,
            parameters: [
                "path": .string(fileURL.path),
                "data": .string(payload.base64EncodedString()),
                "encoding": .string("base64"),
                "mode": .string("create")
            ]
        )
        #expect(outcome.exitCode == 0)
        #expect(try Data(contentsOf: fileURL) == payload)
    }

    @Test func writeFileCreateOnExistingFailsWithAlreadyExists() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("exists.txt")
        try Data("first".utf8).write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsWriteFile,
            parameters: [
                "path": .string(fileURL.path),
                "data": .string(Data("second".utf8).base64EncodedString()),
                "mode": .string("create")
            ]
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "already_exists")
        #expect(try Data(contentsOf: fileURL) == Data("first".utf8))
    }

    @Test func writeFileOverwriteAndAppend() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("mutable.txt")
        try Data("start".utf8).write(to: fileURL)

        let overwrite = try await execute(
            nativeToolID: .fsWriteFile,
            parameters: [
                "path": .string(fileURL.path),
                "data": .string(Data("next".utf8).base64EncodedString()),
                "mode": .string("overwrite")
            ]
        )
        #expect(overwrite.exitCode == 0)
        #expect(try Data(contentsOf: fileURL) == Data("next".utf8))

        let append = try await execute(
            nativeToolID: .fsWriteFile,
            parameters: [
                "path": .string(fileURL.path),
                "data": .string(Data("end".utf8).base64EncodedString()),
                "mode": .string("append")
            ]
        )
        #expect(append.exitCode == 0)
        #expect(try Data(contentsOf: fileURL) == Data("nextend".utf8))
    }

    @Test func writeFileUTF8Encoding() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("utf8.txt")

        let outcome = try await execute(
            nativeToolID: .fsWriteFile,
            parameters: [
                "path": .string(fileURL.path),
                "data": .string("café"),
                "encoding": .string("utf8"),
                "mode": .string("create")
            ]
        )
        #expect(outcome.exitCode == 0)
        #expect(String(data: try Data(contentsOf: fileURL), encoding: .utf8) == "café")
    }

    // MARK: - stat

    @Test func statReportsFileMetadata() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("note.txt")
        let payload = Data("metadata".utf8)
        try payload.write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsStat,
            parameters: ["path": .string(fileURL.path)]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["exists"] as? Bool == true)
        #expect(json["type"] as? String == "file")
        #expect(json["size_bytes"] as? Int64 == Int64(payload.count))
        #expect(json["modified_iso8601"] as? String != nil)
        #expect(json["is_readable"] as? Bool == true)
        #expect(json["is_writable"] as? Bool == true)
    }

    @Test func statReportsDirectory() async throws {
        let directory = try makeTemporaryDirectory()

        let outcome = try await execute(
            nativeToolID: .fsStat,
            parameters: ["path": .string(directory.path)]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["exists"] as? Bool == true)
        #expect(json["type"] as? String == "directory")
    }

    @Test func statMissingPathReturnsExistsFalse() async throws {
        let directory = try makeTemporaryDirectory()
        let missing = directory.appendingPathComponent("missing.txt").path

        let outcome = try await execute(
            nativeToolID: .fsStat,
            parameters: ["path": .string(missing)]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["exists"] as? Bool == false)
        #expect(json["type"] == nil)
    }

    // MARK: - list_tree

    @Test func listTreeRespectsDepthLimit() async throws {
        let root = try makeTemporaryDirectory()
        let level1 = root.appendingPathComponent("a", isDirectory: true)
        let level2 = level1.appendingPathComponent("b", isDirectory: true)
        let level3 = level2.appendingPathComponent("deep.txt")
        try FileManager.default.createDirectory(at: level1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: level2, withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: level3)

        let shallow = try await execute(
            nativeToolID: .fsListTree,
            parameters: [
                "path": .string(root.path),
                "depth": .json(.number(1))
            ]
        )
        let shallowJSON = try decodeJSONObject(shallow.stdout)
        let shallowEntries = try #require(shallowJSON["entries"] as? [[String: Any]])
        #expect(shallowEntries.contains { $0["relative_path"] as? String == "a" })
        #expect(!shallowEntries.contains { ($0["relative_path"] as? String)?.contains("deep.txt") == true })

        let deeper = try await execute(
            nativeToolID: .fsListTree,
            parameters: [
                "path": .string(root.path),
                "depth": .json(.number(3))
            ]
        )
        let deeperJSON = try decodeJSONObject(deeper.stdout)
        let deeperEntries = try #require(deeperJSON["entries"] as? [[String: Any]])
        #expect(deeperEntries.contains { $0["relative_path"] as? String == "a/b/deep.txt" })
    }

    @Test func listTreeCapsEntriesAndSetsTruncated() async throws {
        let root = try makeTemporaryDirectory()
        for index in 0..<2_005 {
            let fileURL = root.appendingPathComponent("file-\(index).txt")
            try Data("x".utf8).write(to: fileURL)
        }

        let outcome = try await execute(
            nativeToolID: .fsListTree,
            parameters: ["path": .string(root.path)]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.count == 2_000)
        #expect(json["truncated"] as? Bool == true)
    }

    @Test func listTreeDoesNotFollowSymlinkedDirectories() async throws {
        let root = try makeTemporaryDirectory()
        let secretContainer = try makeTemporaryDirectory()
        let hidden = secretContainer.appendingPathComponent("hidden.txt")
        let linkedDir = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDir, withDestinationURL: secretContainer)
        try Data("hidden".utf8).write(to: hidden)

        let outcome = try await execute(
            nativeToolID: .fsListTree,
            parameters: [
                "path": .string(root.path),
                "depth": .json(.number(3))
            ]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        let entries = try #require(json["entries"] as? [[String: Any]])
        #expect(entries.contains { $0["relative_path"] as? String == "linked" })
        #expect(!entries.contains { ($0["relative_path"] as? String)?.contains("hidden.txt") == true })
    }

    // MARK: - denylist

    @Test func denylistBlocksPathUnderFakeHomeSSH() async throws {
        let fakeHome = try makeTemporaryDirectory()
        let sshDir = fakeHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let idFile = sshDir.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: idFile)

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path)
        let nativeExecutor = NativeToolExecutor(pathPolicy: policy)
        let outcome = try await execute(
            nativeToolID: .fsReadFile,
            parameters: ["path": .string(idFile.path)],
            executor: nativeExecutor
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "path_denied")
    }

    @Test func denylistBlocksMacRemoteAppSupport() throws {
        let fakeHome = try makeTemporaryDirectory()
        let appSupport = fakeHome
            .appendingPathComponent("Library/Application Support/MacRemote", isDirectory: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        let secrets = appSupport.appendingPathComponent("tools.json")
        try Data("{}".utf8).write(to: secrets)

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path)
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath(secrets.path)
        }
    }

    @Test func denylistBlocksSymlinkIntoDeniedDirectory() async throws {
        let fakeHome = try makeTemporaryDirectory()
        let sshDir = fakeHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let secret = sshDir.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)

        let publicDir = fakeHome.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let link = publicDir.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path)
        let nativeExecutor = NativeToolExecutor(pathPolicy: policy)
        let outcome = try await execute(
            nativeToolID: .fsStat,
            parameters: ["path": .string(link.path)],
            executor: nativeExecutor
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "path_denied")
    }

    @Test func relativePathIsRejected() async throws {
        let outcome = try await execute(
            nativeToolID: .fsStat,
            parameters: ["path": .string("relative/path.txt")]
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "invalid_path")
    }

    // MARK: - Codable

    @Test func toolDefinitionNativeBackendRoundTrip() throws {
        let tool = FileTransferToolCatalog.statTool
        let data = try JSONEncoder().encode(tool)
        let decoded = try JSONDecoder().decode(ToolDefinition.self, from: data)
        #expect(decoded.backend == .native)
        #expect(decoded.nativeToolID == .fsStat)
        #expect(decoded.id == "builtin.fs.stat")
    }

    @Test func toolDefinitionDecodesLegacyJSONWithoutNativeFields() throws {
        let legacyJSON = """
        {
          "argumentPattern": ["echo", "{value}"],
          "backend": "process",
          "capability": "readOnly",
          "category": "utilities",
          "executablePath": "/bin/echo",
          "id": "custom.echo",
          "name": "Echo",
          "origin": "userDefined",
          "outputByteLimit": 1024,
          "parameters": [
            {
              "kind": "string",
              "name": "value",
              "required": true,
              "title": "Value"
            }
          ],
          "permissionRequirements": [],
          "summary": "Echo a value.",
          "timeoutSeconds": 5
        }
        """
        let tool = try JSONDecoder().decode(ToolDefinition.self, from: Data(legacyJSON.utf8))
        #expect(tool.backend == .process)
        #expect(tool.nativeToolID == nil)
    }

    @Test func fileTransferCatalogDefinesSixBuiltInTools() {
        #expect(FileTransferToolCatalog.builtInTools.count == 6)
        #expect(FileTransferToolCatalog.builtInTools.allSatisfy { $0.origin == .builtIn })
        #expect(FileTransferToolCatalog.builtInTools.allSatisfy { $0.backend == .native })
        #expect(FileTransferToolCatalog.builtInTools.allSatisfy { $0.category == .filesystem })
        #expect(FileTransferToolCatalog.writeFileTool.capability == .write)
        #expect(FileTransferToolCatalog.builtInTools.filter { $0.capability == .readOnly }.count == 5)
    }

    // MARK: - download_file

    @Test func downloadFileStagesMatchingCopy() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("payload.bin")
        let payload = Data([9, 8, 7, 6])
        try payload.write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsDownloadFile,
            parameters: ["path": .string(fileURL.path)]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        let token = try #require(json["artifact_token"] as? String)
        let consumed = try #require(artifactStore.consume(token: token))
        #expect(try Data(contentsOf: consumed.fileURL) == payload)
    }

    @Test func downloadFileRejectsDeniedPath() async throws {
        let fakeHome = try makeTemporaryDirectory()
        let sshDir = fakeHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let secret = sshDir.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: secret)

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path)
        let nativeExecutor = NativeToolExecutor(pathPolicy: policy, artifactStore: artifactStore)
        let outcome = try await execute(
            nativeToolID: .fsDownloadFile,
            parameters: ["path": .string(secret.path)],
            executor: nativeExecutor
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "path_denied")
    }

    // MARK: - download_zip

    @Test func downloadZipSingleDirectoryMatchesSourceTree() async throws {
        let root = try makeTemporaryDirectory()
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let fileURL = nested.appendingPathComponent("leaf.txt")
        let payload = Data("leaf-bytes".utf8)
        try payload.write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: ["path": .string(root.path)]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        let token = try #require(json["artifact_token"] as? String)
        let consumed = try #require(artifactStore.consume(token: token))

        let extracted = try makeTemporaryDirectory()
        try runDitto(arguments: ["-x", "-k", consumed.fileURL.path, extracted.path])
        #expect(try Data(contentsOf: extracted.appendingPathComponent("nested/leaf.txt")) == payload)
    }

    @Test func downloadZipMultiPathIncludesOnlySelectedEntries() async throws {
        let base = try makeTemporaryDirectory()
        let keep = base.appendingPathComponent("keep.txt")
        let skip = base.appendingPathComponent("skip.txt")
        try Data("keep".utf8).write(to: keep)
        try Data("skip".utf8).write(to: skip)

        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: [
                "base": .string(base.path),
                "paths": .stringArray(["keep.txt"])
            ]
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        let token = try #require(json["artifact_token"] as? String)
        let consumed = try #require(artifactStore.consume(token: token))

        let extracted = try makeTemporaryDirectory()
        try runDitto(arguments: ["-x", "-k", consumed.fileURL.path, extracted.path])
        #expect(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("keep.txt").path))
        #expect(!FileManager.default.fileExists(atPath: extracted.appendingPathComponent("skip.txt").path))
    }

    @Test func downloadZipRejectsDeniedPathInPaths() async throws {
        let fakeHome = try makeTemporaryDirectory()
        let sshDir = fakeHome.appendingPathComponent(".ssh", isDirectory: true)
        try FileManager.default.createDirectory(at: sshDir, withIntermediateDirectories: true)
        let secret = sshDir.appendingPathComponent("id_rsa")
        try Data("secret".utf8).write(to: secret)

        let publicDir = fakeHome.appendingPathComponent("public", isDirectory: true)
        try FileManager.default.createDirectory(at: publicDir, withIntermediateDirectories: true)
        let link = publicDir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path)
        let nativeExecutor = NativeToolExecutor(pathPolicy: policy, artifactStore: artifactStore)
        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: [
                "base": .string(publicDir.path),
                "paths": .stringArray(["link"])
            ],
            executor: nativeExecutor
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "path_denied")
    }

    @Test func downloadZipRejectsPathEscapingBase() async throws {
        let parent = try makeTemporaryDirectory()
        let base = parent.appendingPathComponent("base", isDirectory: true)
        let outsideFile = parent.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outsideFile)

        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: [
                "base": .string(base.path),
                "paths": .stringArray(["../outside.txt"])
            ]
        )
        #expect(outcome.exitCode == 1)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["code"] as? String == "invalid_path")
    }

    @Test @MainActor func builtInCatalogToolsStayOutOfUserRegistry() throws {
        let suiteName = "MacRemote.FileTransferRegistration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = temporaryDirectory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = AppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))

        #expect(model.tools.isEmpty)
        #expect(model.builtInCatalogTools.count == 6)
        #expect(model.allTools.count == 6)
        for tool in model.builtInCatalogTools {
            #expect(model.allTools.contains(where: { $0.id == tool.id }))
            #expect(!model.isToolExposed(tool))
            #expect(model.disabledToolIDs.contains(tool.id))
        }

        var draft = ToolDefinitionDraft()
        draft.name = "Echo"
        draft.summary = "Echo once."
        draft.executablePath = "/bin/echo"
        draft.argumentsText = "hello"
        #expect(model.addUserTool(from: draft) == nil)
        #expect(model.tools.count == 1)
        #expect(model.allTools.count == 7)
        #expect(model.tools.first?.name == "Echo")
    }

    // MARK: - Helpers

    private func execute(
        nativeToolID: NativeToolIdentifier,
        parameters: [String: ToolArgumentValue],
        executor: NativeToolExecutor? = nil
    ) async throws -> ToolExecutionOutcome {
        let tool = try #require(FileTransferToolCatalog.builtInTools.first { $0.nativeToolID == nativeToolID })
        return try await (executor ?? self.executor).execute(
            tool: tool,
            parameters: parameters,
            timeoutSeconds: tool.timeoutSeconds
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-file-transfer-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func decodeJSONObject(_ string: String) throws -> [String: Any] {
        let data = try #require(string.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
