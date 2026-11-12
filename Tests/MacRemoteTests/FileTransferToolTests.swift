import Foundation
import Testing
@testable import MacRemote

struct FileTransferToolTests {
    private let artifactStore = ArtifactStore(rootDirectory: FileTransferToolTests.makeArtifactRoot())
    /// The tests work in the temporary directory, so that is the one folder
    /// their File Transfer policy allows.
    private static let temporaryFolderPolicy = FileTransferPathPolicy(
        allowedFolders: [FileManager.default.temporaryDirectory.path]
    )
    private var executor: NativeToolExecutor {
        NativeToolExecutor(pathPolicy: Self.temporaryFolderPolicy, artifactStore: artifactStore)
    }

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
                    "length": .json(.number(Double(FileTransferToolCatalog.readFileChunkByteLimit)))
                ]
            )
            #expect(outcome.exitCode == 0)
            let json = try decodeJSONObject(outcome.stdout)
            let chunk = try #require((json["data_base64"] as? String).flatMap { Data(base64Encoded: $0) })
            reassembled.append(chunk)
            let eof = try #require(json["eof"] as? Bool)
            let returnedLength = try #require(json["length_returned"] as? Int)
            #expect(returnedLength <= FileTransferToolCatalog.readFileChunkByteLimit)
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

    @Test func readFileLengthIsClampedToSafeChunkLimit() async throws {
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
        #expect(json["length_returned"] as? Int == FileTransferToolCatalog.readFileChunkByteLimit)
        let chunk = try #require((json["data_base64"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(chunk.count == FileTransferToolCatalog.readFileChunkByteLimit)
    }

    @Test func readFileDefaultUsesSafeChunkLimit() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("default-chunk.bin")
        try Data(repeating: 0xCD, count: 120_000).write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsReadFile,
            parameters: ["path": .string(fileURL.path)]
        )
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["length_returned"] as? Int == FileTransferToolCatalog.readFileChunkByteLimit)
    }

    @Test func readFileZeroLengthStillAdvances() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("zero-length-request.txt")
        try Data("hello".utf8).write(to: fileURL)

        let outcome = try await execute(
            nativeToolID: .fsReadFile,
            parameters: [
                "path": .string(fileURL.path),
                "offset": .json(.number(0)),
                "length": .json(.number(0))
            ]
        )
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["length_returned"] as? Int == 1)
        #expect(json["eof"] as? Bool == false)
        let chunk = try #require(
            (json["data_base64"] as? String).flatMap { Data(base64Encoded: $0) }
        )
        #expect(chunk == Data("h".utf8))
    }

    @Test func readFileEmptyReadTreatsStalePreReadSizeAsEOF() {
        #expect(
            NativeToolExecutor.readReachedEOF(
                bytesRead: 0,
                nextOffset: 1_024,
                preReadFileSize: 4_096
            )
        )
        #expect(
            !NativeToolExecutor.readReachedEOF(
                bytesRead: 1,
                nextOffset: 1_025,
                preReadFileSize: 4_096
            )
        )
    }

    @Test func readFileCatalogAdvertisesSharedSafeChunkLimit() throws {
        let length = try #require(
            FileTransferToolCatalog.readFileTool.parameters.first { $0.name == "length" }
        )
        #expect(length.defaultValue == String(FileTransferToolCatalog.readFileChunkByteLimit))
        #expect(length.integerRange == 1...FileTransferToolCatalog.readFileChunkByteLimit)
        #expect(
            FileTransferToolCatalog.readFileTool.summary.contains(
                "clamped to 1...\(FileTransferToolCatalog.readFileChunkByteLimit) bytes per call"
            )
        )
        #expect(
            FileTransferToolCatalog.readFileTool.summary.contains(
                "For a whole file, prefer filesystem_download_file"
            )
        )
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

    @Test func expiredWriteBudgetDoesNotCreateFile() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("completed.txt")
        let tool = try #require(FileTransferToolCatalog.tool(id: "filesystem_write_file"))

        let outcome = try await executor.execute(
            tool: tool,
            parameters: [
                "path": .string(fileURL.path),
                "data": .string("finished"),
                "encoding": .string("utf8")
            ],
            timeoutSeconds: 0
        )

        #expect(outcome.timedOut)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
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

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path, allowedFolders: [fakeHome.path])
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

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path, allowedFolders: [fakeHome.path])
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

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path, allowedFolders: [fakeHome.path])
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

    // MARK: - allowed folders and bypasses

    /// A fake home with `.ssh/id_rsa`, a `Documents` folder that is the only
    /// allowed folder, and a file outside it.
    private func makeHomeWithDocumentsAllowed() throws -> (home: URL, policy: FileTransferPathPolicy) {
        let home = try makeTemporaryDirectory()
        for folder in [".ssh", "Documents", "Projects"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("secret".utf8).write(to: home.appendingPathComponent(".ssh/id_rsa"))
        try Data("notes".utf8).write(to: home.appendingPathComponent("Documents/notes.txt"))
        try Data("source".utf8).write(to: home.appendingPathComponent("Projects/main.swift"))
        let policy = FileTransferPathPolicy(
            homeDirectory: home.path,
            allowedFolders: [home.appendingPathComponent("Documents").path]
        )
        return (home, policy)
    }

    @Test func onlyAllowedFoldersAreReachable() throws {
        let (home, policy) = try makeHomeWithDocumentsAllowed()

        #expect(try policy.resolveUserPath("~/Documents/notes.txt").hasSuffix("/Documents/notes.txt"))
        // A file that does not exist yet can be created inside an allowed folder.
        #expect(try policy.resolveUserPath("~/Documents/new/report.md").hasSuffix("/Documents/new/report.md"))
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath(home.appendingPathComponent("Projects/main.swift").path)
        }
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("/etc/hosts")
        }
    }

    /// Each of these named an existing protected file while slipping past the
    /// old spelling-based check.
    @Test func protectedFoldersCannotBeReachedBySpellingTricks() throws {
        let home = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".ssh", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: home.appendingPathComponent(".ssh/id_rsa"))
        // The whole fake home is allowed, so only the protection rule stands
        // between a caller and the key.
        let policy = FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: [home.path])

        // A missing component followed by ".." left the path unresolved.
        #expect(throws: FileTransferPathPolicy.PathError.invalidPath) {
            try policy.resolveUserPath("~/.SSH/missing/../id_rsa")
        }
        // Letter case: the default macOS file system treats these as ".ssh".
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/.SSH/id_rsa")
        }
        // A file that does not exist yet is not resolved by the system at all.
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/.SSH/authorized_keys")
        }
        // A protected folder that does not exist yet must not be creatable.
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/.AWS/credentials")
        }
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/Library/Application Support/macremote/tools.json")
        }
    }

    @Test func symlinkOutOfAnAllowedFolderIsDenied() throws {
        let (home, policy) = try makeHomeWithDocumentsAllowed()
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Documents/projects-link"),
            withDestinationURL: home.appendingPathComponent("Projects", isDirectory: true)
        )

        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/Documents/projects-link/main.swift")
        }
    }

    @Test func listingsAndArchivesLeaveProtectedFoldersOut() async throws {
        let home = try makeTemporaryDirectory()
        for folder in [".ssh", "Documents"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(folder, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("secret".utf8).write(to: home.appendingPathComponent(".ssh/id_rsa"))
        try Data("notes".utf8).write(to: home.appendingPathComponent("Documents/notes.txt"))
        let policy = FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: [home.path])
        let nativeExecutor = NativeToolExecutor(pathPolicy: policy, artifactStore: artifactStore)

        let listing = try await execute(
            nativeToolID: .fsListTree,
            parameters: ["path": .string(home.path), "depth": .string("3")],
            executor: nativeExecutor
        )
        let entries = try #require(try decodeJSONObject(listing.stdout)["entries"] as? [[String: Any]])
        let listed = entries.compactMap { $0["relative_path"] as? String }
        #expect(listed.contains("Documents/notes.txt"))
        #expect(!listed.contains { $0.hasPrefix(".ssh") })

        // Archiving the parent would carry the key out with everything else.
        let archive = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: ["path": .string(home.path)],
            executor: nativeExecutor
        )
        #expect(archive.exitCode == 1)
        #expect(try decodeJSONObject(archive.stdout)["code"] as? String == "path_denied")
    }

    /// How far File Transfer reaches is the owner's choice, up to the whole
    /// Mac. Only a protected location, or a folder that is not there, is
    /// refused.
    @Test func anyFolderCanBeAllowedExceptAProtectedOne() throws {
        let (home, policy) = try makeHomeWithDocumentsAllowed()

        #expect(policy.reasonFolderCannotBeAllowed(home.path) == nil)
        #expect(policy.reasonFolderCannotBeAllowed("/") == nil)
        #expect(policy.reasonFolderCannotBeAllowed(home.appendingPathComponent("Projects").path) == nil)
        #expect(policy.reasonFolderCannotBeAllowed(home.appendingPathComponent(".ssh").path) != nil)
        #expect(policy.reasonFolderCannotBeAllowed(home.appendingPathComponent("Missing").path) != nil)
    }

    /// A read-only Fixed Command runs without asking. Without this rule one
    /// such command that takes a path could read any file on the Mac unasked.
    @Test func aToolThatRunsUnaskedCanOnlyBePointedInsideAllowedFolders() async throws {
        let (home, policy) = try makeHomeWithDocumentsAllowed()
        let reader = ToolDefinition(
            id: "test.read",
            name: "Read Text",
            summary: "Prints a file.",
            executablePath: "/bin/cat",
            argumentPattern: ["{path}"],
            parameters: [ToolParameter(name: "path", title: "Path", kind: .string)],
            capability: .readOnly,
            timeoutSeconds: 5,
            outputByteLimit: 4096
        )
        let executor = ConfiguredToolExecutor(
            tools: [reader],
            environment: ExecutableLocator.toolEnvironment,
            fileTransferPolicy: policy
        )
        let notes = home.appendingPathComponent("Documents/notes.txt").path

        let allowed = try await executor.execute(toolID: reader.id, parameters: ["path": .string(notes)])
        #expect(allowed.stdout == "notes")

        for refused in [
            home.appendingPathComponent(".ssh/id_rsa").path,
            home.appendingPathComponent("Projects/main.swift").path,
            "../../etc/hosts"
        ] {
            #expect(throws: ToolValidationError.self) {
                try executor.validate(toolID: reader.id, parameters: ["path": .string(refused)])
            }
        }
        // A plain word is not a path and names nothing outside the empty
        // folder the tool starts in.
        try executor.validate(toolID: reader.id, parameters: ["path": .string("notes.txt")])
    }

    /// A tool that asks first is not confined: the owner sees the path on the
    /// approval card and decides.
    @Test func aToolThatAsksFirstIsNotConfinedToAllowedFolders() throws {
        let (home, policy) = try makeHomeWithDocumentsAllowed()
        let writer = ToolDefinition(
            id: "test.touch",
            name: "Touch",
            summary: "Creates a file.",
            executablePath: "/usr/bin/touch",
            argumentPattern: ["{path}"],
            parameters: [ToolParameter(name: "path", title: "Path", kind: .string)],
            capability: .write,
            timeoutSeconds: 5,
            outputByteLimit: 4096
        )
        let executor = ConfiguredToolExecutor(
            tools: [writer],
            environment: ExecutableLocator.toolEnvironment,
            fileTransferPolicy: policy
        )
        try executor.validate(
            toolID: writer.id,
            parameters: ["path": .string(home.appendingPathComponent("Projects/new.txt").path)]
        )
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
        #expect(decoded.id == "filesystem_stat")
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

    @Test func fileTransferCatalogDefinesSevenBuiltInTools() {
        #expect(FileTransferToolCatalog.builtInTools.count == 7)
        #expect(FileTransferToolCatalog.builtInTools.allSatisfy { $0.origin == .builtIn })
        #expect(FileTransferToolCatalog.builtInTools.allSatisfy { $0.backend == .native })
        #expect(FileTransferToolCatalog.builtInTools.allSatisfy { $0.category == .filesystem })
        #expect(FileTransferToolCatalog.writeFileTool.capability == .write)
        #expect(FileTransferToolCatalog.builtInTools.filter { $0.capability == .readOnly }.count == 6)
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

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path, allowedFolders: [fakeHome.path])
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

        let policy = FileTransferPathPolicy(homeDirectory: fakeHome.path, allowedFolders: [fakeHome.path])
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

    @Test func downloadZipStopsAtRunnerTimeoutWithoutRegisteringArtifact() async throws {
        let source = try makeTemporaryDirectory()
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let isolatedArtifactRoot = try makeTemporaryDirectory()
        let isolatedArtifactStore = ArtifactStore(rootDirectory: isolatedArtifactRoot)
        let nativeExecutor = NativeToolExecutor(
            pathPolicy: Self.temporaryFolderPolicy,
            artifactStore: isolatedArtifactStore,
            processRunner: TimedOutArchiveRunner()
        )
        let tool = try #require(FileTransferToolCatalog.tool(id: "filesystem_download_zip"))

        let outcome = try await nativeExecutor.execute(
            tool: tool,
            parameters: ["path": .string(source.path)],
            timeoutSeconds: 5
        )

        #expect(outcome.timedOut)
        #expect(outcome.exitCode == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: isolatedArtifactRoot.path).isEmpty)
    }

    @Test func downloadZipPropagatesCancellationWithoutRegisteringArtifact() async throws {
        let source = try makeTemporaryDirectory()
        try Data("payload".utf8).write(to: source.appendingPathComponent("payload.txt"))
        let isolatedArtifactRoot = try makeTemporaryDirectory()
        let nativeExecutor = NativeToolExecutor(
            pathPolicy: Self.temporaryFolderPolicy,
            artifactStore: ArtifactStore(rootDirectory: isolatedArtifactRoot),
            processRunner: CancelledArchiveRunner()
        )
        let tool = try #require(FileTransferToolCatalog.tool(id: "filesystem_download_zip"))

        await #expect(throws: CancellationError.self) {
            try await nativeExecutor.execute(
                tool: tool,
                parameters: ["path": .string(source.path)],
                timeoutSeconds: 5
            )
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: isolatedArtifactRoot.path).isEmpty)
    }

    /// The limit is on what goes in, checked before anything is written.
    /// The files are sparse: large by size, with nothing stored on disk.
    @Test func downloadZipAddsUpSizesAndRefusesBeforeArchiving() async throws {
        let base = try makeTemporaryDirectory()
        for name in ["first.bin", "second.bin"] {
            let url = base.appendingPathComponent(name)
            try Data().write(to: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 300 * 1024 * 1024)
            try handle.close()
        }
        let isolatedArtifactRoot = try makeTemporaryDirectory()
        let nativeExecutor = NativeToolExecutor(
            pathPolicy: Self.temporaryFolderPolicy,
            artifactStore: ArtifactStore(rootDirectory: isolatedArtifactRoot),
            processRunner: UnexpectedArchiveRunner()
        )

        // Each file fits alone; together they are over 512 MiB.
        for parameters: [String: ToolArgumentValue] in [
            ["path": .string(base.path)],
            ["base": .string(base.path), "paths": .stringArray(["first.bin", "second.bin"])]
        ] {
            let outcome = try await execute(
                nativeToolID: .fsDownloadZip,
                parameters: parameters,
                executor: nativeExecutor
            )
            #expect(outcome.exitCode == 1)
            #expect(try decodeJSONObject(outcome.stdout)["code"] as? String == "artifact_too_large")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: isolatedArtifactRoot.path).isEmpty)
    }

    /// A caller chooses the entry names, and tar gives some spellings a
    /// meaning: "-C" changes folder, "@" pulls in another archive.
    @Test func downloadZipTreatsOptionLikeNamesAsFiles() async throws {
        let base = try makeTemporaryDirectory()
        let outside = try makeTemporaryDirectory()
        try Data("outside".utf8).write(to: outside.appendingPathComponent("target.txt"))
        let optionFolder = base.appendingPathComponent("-C\(outside.path)", isDirectory: true)
        try FileManager.default.createDirectory(at: optionFolder, withIntermediateDirectories: true)
        try Data("inside".utf8).write(to: optionFolder.appendingPathComponent("target.txt"))
        try Data("at".utf8).write(to: base.appendingPathComponent("@list.txt"))

        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: [
                "base": .string(base.path),
                "paths": .stringArray(["-C\(outside.path)/target.txt", "@list.txt"])
            ]
        )
        #expect(outcome.exitCode == 0)
        let token = try #require(try decodeJSONObject(outcome.stdout)["artifact_token"] as? String)
        let consumed = try #require(artifactStore.consume(token: token))

        let extracted = try makeTemporaryDirectory()
        try runDitto(arguments: ["-x", "-k", consumed.fileURL.path, extracted.path])
        let entry = extracted.appendingPathComponent("-C\(outside.path)/target.txt")
        #expect(try Data(contentsOf: entry) == Data("inside".utf8))
        #expect(try Data(contentsOf: extracted.appendingPathComponent("@list.txt")) == Data("at".utf8))
    }

    @Test func downloadZipKeepsLinksInsideAFolderPointingWhereTheyDid() async throws {
        let root = try makeTemporaryDirectory()
        try Data("target".utf8).write(to: root.appendingPathComponent("target.txt"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("self").path, withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("near").path, withDestinationPath: "./target.txt")

        let outcome = try await execute(nativeToolID: .fsDownloadZip, parameters: ["path": .string(root.path)])
        #expect(outcome.exitCode == 0)
        let token = try #require(try decodeJSONObject(outcome.stdout)["artifact_token"] as? String)
        let consumed = try #require(artifactStore.consume(token: token))

        let extracted = try makeTemporaryDirectory()
        try runDitto(arguments: ["-x", "-k", consumed.fileURL.path, extracted.path])
        let fileManager = FileManager.default
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("self").path) == ".")
        #expect(try fileManager.destinationOfSymbolicLink(atPath: extracted.appendingPathComponent("near").path) == "./target.txt")
    }

    /// The owner can allow the whole disk, and then the root is a valid base.
    @Test func downloadZipAcceptsTheRootFolderAsBase() async throws {
        let directory = try makeTemporaryDirectory()
        let payload = Data("from-root".utf8)
        try payload.write(to: directory.appendingPathComponent("note.txt"))
        let home = try makeTemporaryDirectory()
        let nativeExecutor = NativeToolExecutor(
            pathPolicy: FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: ["/"]),
            artifactStore: artifactStore
        )

        let relativePath = String(directory.appendingPathComponent("note.txt").path.dropFirst())
        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: ["base": .string("/"), "paths": .stringArray([relativePath])],
            executor: nativeExecutor
        )
        #expect(outcome.exitCode == 0)
        let json = try decodeJSONObject(outcome.stdout)
        #expect(json["filename"] as? String == "archive.zip")
        let token = try #require(json["artifact_token"] as? String)
        let consumed = try #require(artifactStore.consume(token: token))

        let extracted = try makeTemporaryDirectory()
        try runDitto(arguments: ["-x", "-k", consumed.fileURL.path, extracted.path])
        #expect(try Data(contentsOf: extracted.appendingPathComponent(relativePath)) == payload)
    }

    @Test func downloadZipMultiPathRefusesAFolderThatHoldsAProtectedFolder() async throws {
        let parent = try makeTemporaryDirectory()
        let home = parent.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".ssh", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("secret".utf8).write(to: home.appendingPathComponent(".ssh/id_rsa"))
        let nativeExecutor = NativeToolExecutor(
            pathPolicy: FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: [parent.path]),
            artifactStore: artifactStore,
            processRunner: UnexpectedArchiveRunner()
        )

        let outcome = try await execute(
            nativeToolID: .fsDownloadZip,
            parameters: ["base": .string(parent.path), "paths": .stringArray(["home"])],
            executor: nativeExecutor
        )
        #expect(outcome.exitCode == 1)
        #expect(try decodeJSONObject(outcome.stdout)["code"] as? String == "path_denied")
    }

    @Test func downloadIsRefusedWhenStagedDownloadsAreAtTheirTotalLimit() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("payload.bin")
        try Data(repeating: 1, count: 6).write(to: fileURL)
        let nativeExecutor = NativeToolExecutor(
            pathPolicy: Self.temporaryFolderPolicy,
            artifactStore: ArtifactStore(rootDirectory: try makeTemporaryDirectory(), maxTotalBytes: 5)
        )

        for (toolID, parameters) in [
            (NativeToolIdentifier.fsDownloadFile, ["path": ToolArgumentValue.string(fileURL.path)]),
            (NativeToolIdentifier.fsDownloadZip, ["path": ToolArgumentValue.string(directory.path)])
        ] {
            let outcome = try await execute(nativeToolID: toolID, parameters: parameters, executor: nativeExecutor)
            #expect(outcome.exitCode == 1)
            #expect(try decodeJSONObject(outcome.stdout)["code"] as? String == "download_space_full")
        }
    }

    @Test @MainActor func builtInCatalogToolsStayOutOfUserRegistry() throws {
        let suiteName = "MacRemote.FileTransferRegistration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let storeURL = temporaryDirectory.appendingPathComponent("tools.json")
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let model = makeTestAppModel(userDefaults: defaults, toolStore: ToolRegistryStore(fileURL: storeURL))

        #expect(model.tools.isEmpty)
        let builtInCount = FileTransferToolCatalog.builtInTools.count
        #expect(model.builtInCatalogTools.count == builtInCount)
        #expect(model.allTools.count == builtInCount)
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
        #expect(model.allTools.count == builtInCount + 1)
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

private struct TimedOutArchiveRunner: ProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String],
        standardInput: String?
    ) async throws -> CommandRunResult {
        #expect(executablePath == "/usr/bin/tar")
        #expect(arguments.prefix(2) == ["--format", "zip"])
        #expect(timeoutSeconds > 0 && timeoutSeconds <= 5)
        #expect(outputByteLimit == 64 * 1024)
        #expect(standardInput == nil)
        return CommandRunResult(
            executablePath: executablePath,
            arguments: arguments,
            exitCode: 1,
            stdout: "",
            stderr: "",
            duration: timeoutSeconds,
            timedOut: true,
            truncatedStdout: false,
            truncatedStderr: false
        )
    }
}

/// For calls that must be refused before anything is archived.
private struct UnexpectedArchiveRunner: ProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String],
        standardInput: String?
    ) async throws -> CommandRunResult {
        Issue.record("The archiver ran for a call that should have been refused first.")
        throw CancellationError()
    }
}

private struct CancelledArchiveRunner: ProcessRunning {
    func run(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: TimeInterval,
        outputByteLimit: Int,
        environment: [String: String],
        standardInput: String?
    ) async throws -> CommandRunResult {
        throw CancellationError()
    }
}
