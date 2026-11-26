import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MacRemote

/// Upload File through the MCP files extension (SPEC D83), against a real
/// server on loopback: the owner approves once, the app sends the bytes to
/// the target it was given, and the call sent again saves them byte for
/// byte. Anything that does not match is refused without running the tool.
@Suite(.serialized)
struct FileUploadTests {
    private static let toolID = FileTransferToolCatalog.uploadFileTool.id
    /// JSON arguments handed to a task. Nothing changes them after they are built.
    private struct Arguments: @unchecked Sendable {
        let value: [String: Any]
    }

    private nonisolated(unsafe) static let filesDeclared: [String: Any] = [
        "extensions": [FileUploadStore.extensionIdentifier: ["upload": [String: Any](), "download": [String: Any]()]]
    ]

    /// A server sharing only Upload File. Its one allowed folder is a scratch
    /// home folder (with a protected `.ssh` inside), and it stages uploads in
    /// its own scratch folder.
    private final class Harness: @unchecked Sendable {
        let root: URL
        let home: URL
        let staging: URL
        let token = "file-upload-\(UUID().uuidString)"
        let coordinator = OAuthCoordinator()
        let approvals = ToolCallApprovalCoordinator(timeoutSeconds: 10)
        let server: LocalMCPServer
        let endpoint: URL
        let client: MCPTestClient

        init(
            lifetime: TimeInterval = FileUploadStore.defaultLifetime,
            maxTotalBytes: Int64 = FileUploadStore.defaultMaxTotalBytes,
            mode: MCPTestProtocolMode = .modern(clientCapabilities: FileUploadTests.filesDeclared)
        ) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("macremote-upload-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            staging = root.appendingPathComponent("staging", isDirectory: true)
            for folder in ["Documents", ".ssh"] {
                try FileManager.default.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            coordinator.updateStaticHeaderToken(token, clientName: "Upload Probe")
            let tool = FileTransferToolCatalog.uploadFileTool
            server = LocalMCPServer(
                instanceID: "files",
                tools: [tool],
                authCoordinator: coordinator,
                toolCallApprovalCoordinator: approvals,
                toolExecutor: ConfiguredToolExecutor(
                    tools: [tool],
                    environment: [:],
                    fileTransferPolicy: FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: [home.path])
                ),
                fileUploads: FileUploadStore(rootDirectory: staging, lifetime: lifetime, maxTotalBytes: maxTotalBytes)
            )
            let port = try server.start()
            endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp/files"))
            client = MCPTestClient(baseURL: endpoint, bearerToken: token, mode: mode)
        }

        deinit {
            server.stop()
            try? FileManager.default.removeItem(at: root)
        }

        func documents(_ name: String) -> URL {
            home.appendingPathComponent("Documents/\(name)")
        }

        /// What is staged now: nothing once every upload has ended.
        var stagedFiles: [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        }

        var pendingApproval: ToolCallApprovalRequest? {
            approvals.approvalSnapshot().first { $0.state == .pending }
        }

        /// Sends a first call and answers the approval prompt it raises, with
        /// what the owner was shown.
        func firstCall(
            _ arguments: [String: Any],
            approve: Bool = true,
            from client: MCPTestClient? = nil
        ) async throws -> (response: MCPTestHTTPResponse, shown: [String: String]) {
            let sender = client ?? self.client
            let params = Arguments(value: ["name": FileUploadTests.toolID, "arguments": arguments])
            let call = Task { try await sender.send(method: "tools/call", params: params.value) }
            var request: ToolCallApprovalRequest?
            for _ in 0..<250 where request == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
                request = pendingApproval
            }
            let approval = try #require(request)
            #expect(approve ? approvals.approve(requestID: approval.id) : approvals.deny(requestID: approval.id))
            let shown = Dictionary(uniqueKeysWithValues: approval.arguments.map { ($0.name, $0.value) })
            return (try await call.value, shown)
        }

        /// A first call refused before anyone is asked.
        func refusedCall(_ arguments: [String: Any], from client: MCPTestClient? = nil) async throws -> MCPTestHTTPResponse {
            let response = try await (client ?? self.client).send(method: "tools/call", params: [
                "name": FileUploadTests.toolID, "arguments": arguments
            ])
            #expect(pendingApproval == nil)
            return response
        }

        func secondCall(
            _ arguments: [String: Any],
            requestState: String,
            from client: MCPTestClient? = nil
        ) async throws -> MCPTestHTTPResponse {
            try await (client ?? self.client).send(method: "tools/call", params: [
                "name": FileUploadTests.toolID, "arguments": arguments, "requestState": requestState
            ])
        }

        /// Sends bytes to an upload target, as an app with the given bearer
        /// token would (`credentials: "include"`). Returns the HTTP status.
        func put(_ bytes: Data, to target: [String: Any], bearer: String?) async throws -> Int {
            let path = try #require(target["path"] as? String)
            var request = URLRequest(url: try #require(URL(string: endpoint.absoluteString + path)))
            request.httpMethod = "PUT"
            if let bearer {
                request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            }
            let (_, response) = try await URLSession.shared.upload(for: request, from: bytes)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        }

        /// The head of a PUT to an upload target, with one Content-Length
        /// header per entry in `contentLengths`, for a raw connection.
        func rawPut(to target: [String: Any], contentLengths: [Int]) throws -> Data {
            let path = try #require(target["path"] as? String)
            let port = try #require(endpoint.port)
            var head = "PUT \(endpoint.path)\(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer \(token)\r\n"
            for length in contentLengths {
                head += "Content-Length: \(length)\r\n"
            }
            return Data((head + "\r\n").utf8)
        }

        /// A first call approved, and the bytes sent: ready for its second.
        func uploaded(_ bytes: Data, as arguments: [String: Any]) async throws -> String {
            let (response, _) = try await firstCall(arguments)
            let requested = try FileUploadTests.uploadRequest(in: response)
            #expect(try await put(bytes, to: requested.target, bearer: token) == 204)
            return requested.requestState
        }
    }

    private static func fileArgument(_ bytes: Data, name: String = "Q3 report.pdf", digest: Data? = nil) -> [String: Any] {
        var file: [String: Any] = ["id": "file-1", "name": name, "mimeType": "application/pdf", "size": bytes.count]
        if let digest {
            file["digest"] = ["algorithm": "sha-256", "value": base64URL(digest)]
        }
        return file
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func uploadRequest(in response: MCPTestHTTPResponse) throws -> (target: [String: Any], requestState: String) {
        let result = try #require(response.result, "\(response.json)")
        #expect(result["resultType"] as? String == "upload_required")
        let uploads = try #require(result["uploads"] as? [[String: Any]])
        #expect(uploads.count == 1)
        return (try #require(uploads.first), try #require(result["requestState"] as? String))
    }

    private static func isToolError(_ response: MCPTestHTTPResponse, saying words: String) -> Bool {
        guard let result = response.result, result["isError"] as? Bool == true,
              let stderr = (result["structuredContent"] as? [String: Any])?["stderr"] as? String else { return false }
        return stderr.contains(words)
    }

    private static func rpcErrorCode(_ response: MCPTestHTTPResponse) -> Int? {
        response.error?["code"] as? Int
    }

    @Test func discoveryAdvertisesUploadsAndTheToolMarksItsFileArgument() async throws {
        let harness = try Harness()
        let capabilities = try #require(try await harness.client.discover().result?["capabilities"] as? [String: Any])
        let extensions = try #require(capabilities["extensions"] as? [String: Any])
        let files = try #require(extensions[FileUploadStore.extensionIdentifier] as? [String: Any])
        #expect(files.keys.sorted() == ["upload"])
        #expect((files["upload"] as? [String: Any])?.isEmpty == true)

        let tools = try #require(try await harness.client.listTools().result?["tools"] as? [[String: Any]])
        let tool = try #require(tools.first { $0["name"] as? String == Self.toolID })
        let annotations = try #require(tool["annotations"] as? [String: Any])
        #expect(annotations["readOnlyHint"] as? Bool == false)
        #expect(annotations["destructiveHint"] as? Bool == true)
        #expect((tool["description"] as? String)?.contains("filesystem_write_file") == true)
        let schema = try #require(tool["inputSchema"] as? [String: Any])
        #expect(schema["x-mcp-file"] == nil)
        let file = try #require((schema["properties"] as? [String: Any])?["file"] as? [String: Any])
        #expect((file["x-mcp-file"] as? [String: Any])?["maxSize"] as? Int == 512 * 1024 * 1024)
        #expect(file["required"] as? [String] == ["id", "mimeType", "size"])
        let properties = try #require(file["properties"] as? [String: Any])
        #expect(properties.keys.sorted() == ["data", "digest", "id", "mimeType", "name", "size"])
        #expect(schema["required"] as? [String] == ["path", "file"])
    }

    /// The whole flow with a file larger than any request the server reads
    /// whole: one approval that shows everything, a `path` target sent with
    /// the app's own credential, and the file in place, byte for byte, with
    /// nothing left in staging.
    @Test func aLargeFileArrivesByteForByteAfterOneApproval() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(300 * 1024)
        let destination = harness.documents("Q3 report.pdf")
        let arguments: [String: Any] = [
            "path": destination.path,
            "file": Self.fileArgument(bytes, digest: Data(SHA256.hash(data: bytes)))
        ]

        let (first, shown) = try await harness.firstCall(arguments)
        #expect(shown["path"] == destination.path)
        for detail in ["\"name\":\"Q3 report.pdf\"", "\"mimeType\":\"application/pdf\"", "\"size\":307200"] {
            #expect(shown["file"]?.contains(detail) == true, "\(shown)")
        }
        let requested = try Self.uploadRequest(in: first)
        #expect(requested.target["fileId"] as? String == "file-1")
        #expect(requested.target["method"] as? String == "PUT")
        #expect(requested.target["credentials"] as? String == "include")
        #expect(requested.target["url"] == nil)
        let path = try #require(requested.target["path"] as? String)
        #expect(path.hasPrefix("/uploads/") && !path.contains(requested.requestState))
        let expiresAt = try #require((requested.target["expiresAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) })
        #expect(expiresAt > Date().addingTimeInterval(20 * 60))
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        #expect(try await harness.put(bytes, to: requested.target, bearer: harness.token) == 204)
        let second = try await harness.secondCall(arguments, requestState: requested.requestState)

        let result = try #require(second.result, "\(second.json)")
        #expect(result["isError"] as? Bool == false)
        let saved = try #require((result["structuredContent"] as? [String: Any])?["stdout"] as? String)
        #expect(saved.contains("\"size_bytes\":307200") && saved.contains("\"overwritten\":false"))
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(harness.stagedFiles.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Q3 report.pdf"])
    }

    /// A second call that does not match its upload is -32602 and runs
    /// nothing: changed arguments, another app, one letter of requestState
    /// changed, the same call repeated after it succeeded, and an upload
    /// that expired. An upload's bytes go only to its own app's target.
    @Test func secondCallsThatDoNotMatchTheirUploadRunNothing() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(2048)
        let destination = harness.documents("notes.txt")
        let arguments: [String: Any] = ["path": destination.path, "file": Self.fileArgument(bytes, name: "notes.txt")]
        let otherApp = try dynamicOAuthTestClient(
            coordinator: harness.coordinator,
            baseURL: try #require(URL(string: harness.endpoint.absoluteString.replacingOccurrences(of: "/mcp/files", with: ""))),
            endpoint: harness.endpoint,
            mode: .modern(clientCapabilities: Self.filesDeclared)
        )

        let (first, _) = try await harness.firstCall(arguments)
        let requested = try Self.uploadRequest(in: first)
        #expect(try await harness.put(bytes, to: requested.target, bearer: otherApp.bearerToken) == 404)
        #expect(try await harness.put(bytes, to: requested.target, bearer: harness.token) == 204)

        var changed = arguments
        changed["path"] = harness.documents("elsewhere.txt").path
        let tampered = String(requested.requestState.dropLast()) + (requested.requestState.hasSuffix("0") ? "1" : "0")
        let refusals = [
            try await harness.secondCall(changed, requestState: requested.requestState),
            try await harness.secondCall(arguments, requestState: requested.requestState, from: otherApp),
            try await harness.secondCall(arguments, requestState: tampered)
        ]
        for refusal in refusals {
            #expect(Self.rpcErrorCode(refusal) == -32602, "\(refusal.json)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: harness.documents("elsewhere.txt").path))

        // Arguments compare as JSON values: member order and number spelling
        // do not matter.
        var respelled = arguments
        var file = try #require(arguments["file"] as? [String: Any])
        file["size"] = Double(bytes.count)
        respelled["file"] = file
        let saved = try await harness.secondCall(respelled, requestState: requested.requestState)
        #expect(saved.result?["isError"] as? Bool == false, "\(saved.json)")
        #expect(try Data(contentsOf: destination) == bytes)

        let repeated = try await harness.secondCall(arguments, requestState: requested.requestState)
        #expect(Self.rpcErrorCode(repeated) == -32602)
        #expect(harness.stagedFiles.isEmpty)

        let expiring = try Harness(lifetime: 1.5)
        let late = expiring.documents("late.txt")
        let lateArguments: [String: Any] = ["path": late.path, "file": Self.fileArgument(bytes, name: "late.txt")]
        let lateState = try await expiring.uploaded(bytes, as: lateArguments)
        #expect(expiring.stagedFiles.count == 1)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(expiring.stagedFiles.isEmpty)
        #expect(Self.rpcErrorCode(try await expiring.secondCall(lateArguments, requestState: lateState)) == -32602)
        #expect(!FileManager.default.fileExists(atPath: late.path))
    }

    /// Bytes that are missing, short, or not the declared digest are a tool
    /// error that changes nothing, and the upload stays: the app can send the
    /// right bytes and send the call again.
    @Test func missingOrWrongBytesAreToolErrorsTheAppCanRetry() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(4096)
        let destination = harness.documents("draft.md")
        let arguments: [String: Any] = [
            "path": destination.path,
            "file": Self.fileArgument(bytes, name: "draft.md", digest: Data(SHA256.hash(data: bytes)))
        ]
        let (first, _) = try await harness.firstCall(arguments)
        let requested = try Self.uploadRequest(in: first)

        let noBytes = try await harness.secondCall(arguments, requestState: requested.requestState)
        #expect(Self.isToolError(noBytes, saying: "have not arrived"), "\(noBytes.json)")

        #expect(try await harness.put(bytes.prefix(1000), to: requested.target, bearer: harness.token) == 204)
        let short = try await harness.secondCall(arguments, requestState: requested.requestState)
        #expect(Self.isToolError(short, saying: "received 1000 bytes"), "\(short.json)")

        var wrong = bytes
        wrong[0] ^= 0xFF
        #expect(try await harness.put(wrong, to: requested.target, bearer: harness.token) == 204)
        let mismatched = try await harness.secondCall(arguments, requestState: requested.requestState)
        #expect(Self.isToolError(mismatched, saying: "SHA-256"), "\(mismatched.json)")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(harness.stagedFiles.count == 1)

        #expect(try await harness.put(bytes, to: requested.target, bearer: harness.token) == 204)
        let saved = try await harness.secondCall(arguments, requestState: requested.requestState)
        #expect(saved.result?["isError"] as? Bool == false, "\(saved.json)")
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(harness.stagedFiles.isEmpty)
    }

    /// The transfer route needs the app's bearer token, and never takes more
    /// bytes than the owner approved.
    @Test func theTransferRouteNeedsTheTokenAndTheApprovedLength() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(1000)
        let (first, _) = try await harness.firstCall([
            "path": harness.documents("small.bin").path, "file": Self.fileArgument(bytes, name: "small.bin")
        ])
        let requested = try Self.uploadRequest(in: first)

        #expect(try await harness.put(bytes, to: requested.target, bearer: nil) == 401)
        #expect(try await harness.put(bytes, to: requested.target, bearer: "made-up-\(UUID().uuidString)") == 401)
        #expect(try await harness.put(bytes + bytes, to: requested.target, bearer: harness.token) == 413)
        #expect(try await harness.put(bytes, to: ["path": "/uploads/\(String(repeating: "0", count: 64))"], bearer: harness.token) == 404)
        #expect(harness.stagedFiles.isEmpty)
        #expect(try await harness.put(bytes, to: requested.target, bearer: harness.token) == 204)
        #expect(harness.stagedFiles.count == 1)
    }

    /// Two copies of the second call at once: the file is written once, and
    /// the other copy is refused.
    @Test func twoSecondCallsAtOnceWriteTheFileOnce() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(256 * 1024)
        let destination = harness.documents("once.bin")
        let arguments: [String: Any] = ["path": destination.path, "file": Self.fileArgument(bytes, name: "once.bin")]
        let requestState = try await harness.uploaded(bytes, as: arguments)

        let shared = Arguments(value: arguments)
        async let one = harness.secondCall(shared.value, requestState: requestState)
        async let two = harness.secondCall(shared.value, requestState: requestState)
        let answers = try await [one, two]

        let saved = answers.filter { $0.result?["isError"] as? Bool == false }
        let refused = answers.filter { Self.rpcErrorCode($0) == -32602 || $0.result?["isError"] as? Bool == true }
        #expect(saved.count == 1 && refused.count == 1, "\(answers.map(\.json))")
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(harness.stagedFiles.isEmpty)
    }

    /// Calls that cannot upload are refused before the owner is asked: an
    /// app that did not declare uploads (-32021, HTTP 400), a legacy session
    /// (a tool error naming Write File), a destination outside the allowed
    /// folders or in a protected one, an existing file without overwrite,
    /// bytes sent inline, and a file over the limit.
    @Test func callsThatCannotUploadAreRefusedBeforeApproval() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(100)
        let existing = harness.documents("existing.txt")
        try Data("keep me\n".utf8).write(to: existing)
        func arguments(_ path: String, _ file: [String: Any]? = nil) -> [String: Any] {
            ["path": path, "file": file ?? Self.fileArgument(bytes)]
        }

        let undeclared = MCPTestClient(baseURL: harness.endpoint, bearerToken: harness.token, mode: .modern())
        let notDeclared = try await harness.refusedCall(arguments(harness.documents("a.pdf").path), from: undeclared)
        #expect(notDeclared.statusCode == 400)
        #expect(Self.rpcErrorCode(notDeclared) == -32021)
        let required = (notDeclared.error?["data"] as? [String: Any])?["requiredCapabilities"] as? [String: Any]
        #expect(((required?["extensions"] as? [String: Any])?[FileUploadStore.extensionIdentifier] as? [String: Any])?["upload"] != nil)

        let legacy = MCPTestClient(baseURL: harness.endpoint, bearerToken: harness.token, mode: .legacy())
        try await legacy.initializeLegacy()
        let legacyAnswer = try await harness.refusedCall(arguments(harness.documents("a.pdf").path), from: legacy)
        #expect(Self.isToolError(legacyAnswer, saying: "filesystem_write_file"), "\(legacyAnswer.json)")

        var inline = Self.fileArgument(bytes)
        inline["data"] = bytes.base64EncodedString()
        var tooLarge = Self.fileArgument(bytes)
        tooLarge["size"] = 512 * 1024 * 1024 + 1
        let refused: [(arguments: [String: Any], says: String)] = [
            (arguments(harness.root.appendingPathComponent("outside.pdf").path), "File Transfer reaches only"),
            (arguments(harness.home.appendingPathComponent(".ssh/authorized_keys").path), "File Transfer reaches only"),
            (arguments(existing.path), "File already exists"),
            (arguments(harness.documents("missing/a.pdf").path), "folder in path does not exist"),
            (arguments(harness.documents("a.pdf").path, inline), "does not take file bytes inside the call"),
            (arguments(harness.documents("a.pdf").path, tooLarge), "at most 536870912 bytes")
        ]
        for item in refused {
            let answer = try await harness.refusedCall(item.arguments)
            #expect(Self.isToolError(answer, saying: item.says), "\(item.says): \(answer.json)")
        }
        #expect(try Data(contentsOf: existing) == Data("keep me\n".utf8))
        #expect(harness.stagedFiles.isEmpty)
    }

    /// Staging has caps, checked before the owner is asked: uploads one app
    /// may have waiting, and bytes all waiting uploads may hold.
    @Test func stagingCapsAreCheckedBeforeApproval() async throws {
        let harness = try Harness(maxTotalBytes: 10_000)
        let small = Self.randomBytes(10)
        for index in 0..<FileUploadStore.maximumWaitingPerApp {
            let (response, _) = try await harness.firstCall([
                "path": harness.documents("waiting-\(index).txt").path, "file": Self.fileArgument(small)
            ])
            _ = try Self.uploadRequest(in: response)
        }
        let oneTooMany = try await harness.refusedCall([
            "path": harness.documents("one-too-many.txt").path, "file": Self.fileArgument(small)
        ])
        #expect(Self.isToolError(oneTooMany, saying: "already has \(FileUploadStore.maximumWaitingPerApp) uploads waiting"), "\(oneTooMany.json)")

        let roomy = try Harness(maxTotalBytes: 10_000)
        let (response, _) = try await roomy.firstCall([
            "path": roomy.documents("big.bin").path, "file": Self.fileArgument(Self.randomBytes(6000))
        ])
        _ = try Self.uploadRequest(in: response)
        let noRoom = try await roomy.refusedCall([
            "path": roomy.documents("bigger.bin").path, "file": Self.fileArgument(Self.randomBytes(6000))
        ])
        #expect(Self.isToolError(noRoom, saying: "space set aside"), "\(noRoom.json)")
    }

    /// The other ways an upload ends: the owner says no (nothing is staged
    /// and no target exists), an empty file (created after approval, with
    /// nothing to send), overwriting a file the call names (it keeps its
    /// permissions), and the server stopping (staged bytes are deleted).
    @Test func deniedEmptyOverwrittenAndStoppedUploads() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(5000)

        let (denied, _) = try await harness.firstCall([
            "path": harness.documents("denied.bin").path, "file": Self.fileArgument(bytes)
        ], approve: false)
        #expect(Self.isToolError(denied, saying: "not approved"), "\(denied.json)")
        #expect(denied.result?["resultType"] as? String == "complete")
        #expect(harness.stagedFiles.isEmpty)

        let empty = harness.documents("empty.txt")
        let (created, _) = try await harness.firstCall(["path": empty.path, "file": Self.fileArgument(Data(), name: "empty.txt")])
        #expect(created.result?["isError"] as? Bool == false, "\(created.json)")
        #expect(created.result?["resultType"] as? String == "complete")
        #expect(try Data(contentsOf: empty).isEmpty)

        let existing = harness.documents("report.bin")
        try Data("old".utf8).write(to: existing)
        #expect(chmod(existing.path, 0o640) == 0)
        let overwriting: [String: Any] = ["path": existing.path, "overwrite": true, "file": Self.fileArgument(bytes)]
        let requestState = try await harness.uploaded(bytes, as: overwriting)
        let replaced = try await harness.secondCall(overwriting, requestState: requestState)
        let stdout = (replaced.result?["structuredContent"] as? [String: Any])?["stdout"] as? String
        #expect(stdout?.contains("\"overwritten\":true") == true, "\(replaced.json)")
        #expect(try Data(contentsOf: existing) == bytes)
        #expect((try FileManager.default.attributesOfItem(atPath: existing.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)

        _ = try await harness.uploaded(bytes, as: ["path": harness.documents("stopped.bin").path, "file": Self.fileArgument(bytes)])
        #expect(harness.stagedFiles.count == 1)
        harness.server.stop()
        #expect(harness.stagedFiles.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.documents("stopped.bin").path))
    }

    /// Bytes still arriving when the server stops, or when their upload
    /// expires, are cut off at once: the partial file is deleted and the
    /// connection closed, so nothing more is stored.
    @Test(arguments: ["stop", "expiry"])
    func aTransferInProgressEndsWithItsUpload(ending: String) async throws {
        let harness = try Harness(lifetime: ending == "expiry" ? 3 : FileUploadStore.defaultLifetime)
        let bytes = Self.randomBytes(50_000)
        let (first, _) = try await harness.firstCall([
            "path": harness.documents("partial.bin").path, "file": Self.fileArgument(bytes, name: "partial.bin")
        ])
        let requested = try Self.uploadRequest(in: first)
        let connection = try RawConnection(port: try #require(harness.endpoint.port))
        try connection.send(try harness.rawPut(to: requested.target, contentLengths: [bytes.count]) + bytes.prefix(1000))
        try await Self.waitUntil { harness.stagedFiles.count == 1 }

        if ending == "stop" {
            harness.server.stop()
        }
        try await Self.waitUntil(seconds: 6) { harness.stagedFiles.isEmpty }
        #expect(connection.serverClosed)
        try? connection.send(bytes.dropFirst(1000))
        try await Task.sleep(for: .milliseconds(200))
        #expect(harness.stagedFiles.isEmpty)
    }

    /// An empty file whose declared SHA-256 is not that of no bytes is
    /// refused before approval, as wrong bytes are for a file that has them.
    @Test func anEmptyFileMustMatchTheDigestOfNoBytes() async throws {
        let harness = try Harness()
        let empty = harness.documents("empty.txt")
        let wrong = try await harness.refusedCall([
            "path": empty.path,
            "file": Self.fileArgument(Data(), name: "empty.txt", digest: Data(SHA256.hash(data: Data("not empty".utf8))))
        ])
        #expect(Self.isToolError(wrong, saying: "SHA-256"), "\(wrong.json)")
        #expect(!FileManager.default.fileExists(atPath: empty.path))

        let (right, _) = try await harness.firstCall([
            "path": empty.path,
            "file": Self.fileArgument(Data(), name: "empty.txt", digest: Data(SHA256.hash(data: Data())))
        ])
        #expect(right.result?["isError"] as? Bool == false, "\(right.json)")
        #expect(try Data(contentsOf: empty).isEmpty)
    }

    /// The transfer route reads framing as every other route does: two
    /// Content-Length headers get 400 before a byte is stored.
    @Test func theTransferRouteRefusesTwoContentLengths() async throws {
        let harness = try Harness()
        let bytes = Self.randomBytes(1000)
        let (first, _) = try await harness.firstCall([
            "path": harness.documents("framed.bin").path, "file": Self.fileArgument(bytes, name: "framed.bin")
        ])
        let requested = try Self.uploadRequest(in: first)

        for lengths in [[5, 10], [9999, 10]] {
            let connection = try RawConnection(port: try #require(harness.endpoint.port))
            try connection.send(try harness.rawPut(to: requested.target, contentLengths: lengths) + bytes.prefix(10))
            let answer = connection.receive()
            #expect(answer.hasPrefix("HTTP/1.1 400"), "\(lengths): \(answer)")
        }
        #expect(harness.stagedFiles.isEmpty)
        #expect(try await harness.put(bytes, to: requested.target, bearer: harness.token) == 204)
    }

    /// The second call saves only where the first call's path led: a folder
    /// swapped for a link to another allowed folder is refused, nothing is
    /// written, and the upload is used up.
    @Test func aDestinationThatMovedSinceTheFirstCallIsNotWritten() async throws {
        let harness = try Harness()
        let inbox = harness.documents("Inbox")
        let archive = harness.documents("Archive")
        for (folder, text) in [(inbox, "keep Inbox"), (archive, "keep Archive")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: folder.appendingPathComponent("report.txt"))
        }
        let bytes = Self.randomBytes(10)
        let arguments: [String: Any] = [
            "path": inbox.appendingPathComponent("report.txt").path,
            "overwrite": true,
            "file": Self.fileArgument(bytes, name: "report.txt")
        ]
        let requestState = try await harness.uploaded(bytes, as: arguments)
        try FileManager.default.moveItem(at: inbox, to: harness.documents("Old Inbox"))
        try FileManager.default.createSymbolicLink(at: inbox, withDestinationURL: archive)

        let second = try await harness.secondCall(arguments, requestState: requestState)
        #expect(Self.isToolError(second, saying: "changed since"), "\(second.json)")
        #expect(try String(contentsOf: archive.appendingPathComponent("report.txt"), encoding: .utf8) == "keep Archive")
        #expect(try String(contentsOf: harness.documents("Old Inbox/report.txt"), encoding: .utf8) == "keep Inbox")
        let again = try await harness.secondCall(arguments, requestState: requestState)
        #expect(Self.rpcErrorCode(again) == -32602, "\(again.json)")
        #expect(harness.stagedFiles.isEmpty)
    }

    /// A `size` that is not a whole number is a tool error that says so,
    /// whether or not the app declared uploads; never -32021.
    @Test func aSizeThatIsNotAWholeNumberIsAToolError() async throws {
        let harness = try Harness()
        let undeclared = MCPTestClient(baseURL: harness.endpoint, bearerToken: harness.token, mode: .modern())
        for size: Any in [true, 10.5] {
            var file = Self.fileArgument(Self.randomBytes(10))
            file["size"] = size
            for client in [harness.client, undeclared] {
                let answer = try await harness.refusedCall(["path": harness.documents("a.pdf").path, "file": file], from: client)
                #expect(Self.isToolError(answer, saying: "file.size must be a whole number"), "\(size): \(answer.json)")
            }
        }
    }

    /// A `requestState` that is not a string is -32602 for Upload File too
    /// (SPEC D82): nobody is asked, so no upload starts.
    @Test func aRequestStateThatIsNotAStringStartsNoUpload() async throws {
        let harness = try Harness()
        let answer = try await harness.client.send(method: "tools/call", params: [
            "name": Self.toolID,
            "arguments": ["path": harness.documents("a.pdf").path, "file": Self.fileArgument(Self.randomBytes(100))],
            "requestState": 123
        ])
        #expect(Self.rpcErrorCode(answer) == -32602, "\(answer.json)")
        #expect(harness.approvals.approvalSnapshot().isEmpty)
        #expect(harness.stagedFiles.isEmpty)
    }

    private static func waitUntil(seconds: TimeInterval = 3, _ condition: () -> Bool) async throws {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !condition() {
            guard Date() < deadline else {
                Issue.record("Timed out waiting.")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// A TCP connection to the test server that sends bytes exactly as given,
/// for requests a well-behaved HTTP client never makes.
private final class RawConnection {
    private let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
    }

    deinit {
        close(descriptor)
    }

    func send(_ data: Data) throws {
        let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// The first bytes the server sends back, within five seconds.
    func receive() -> String {
        var bytes = [UInt8](repeating: 0, count: 4096)
        let received = recv(descriptor, &bytes, bytes.count, 0)
        return received > 0 ? String(decoding: bytes.prefix(received), as: UTF8.self) : ""
    }

    /// True when the server closed the connection within five seconds.
    var serverClosed: Bool {
        var byte: UInt8 = 0
        let received = recv(descriptor, &byte, 1, 0)
        return received == 0 || (received < 0 && errno != EAGAIN)
    }
}
