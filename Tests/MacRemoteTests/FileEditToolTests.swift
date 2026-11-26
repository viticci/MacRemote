import Darwin
import Foundation
import Testing
@testable import MacRemote

/// Append to File and Replace in File: small text edits that change only
/// what the call names, ask first, and never leave a file half written.
@Suite(.serialized)
struct FileEditToolTests {
    private static let temporaryFolderPolicy = FileTransferPathPolicy(
        allowedFolders: [FileManager.default.temporaryDirectory.path]
    )
    private let executor = NativeToolExecutor(pathPolicy: Self.temporaryFolderPolicy)

    /// CRLF line endings, no final newline, text past ASCII, 0640, and a
    /// Finder-style extended attribute: everything an edit must leave alone.
    private static let workLog = Data("# Work log\r\n\r\n## Monday\r\nShipped the café menu.\r\n\r\n## Tuesday\r\nReviewed notes".utf8)

    private func makeWorkLog() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-file-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("log.md")
        try Self.workLog.write(to: fileURL)
        #expect(chmod(fileURL.path, 0o640) == 0)
        #expect(setxattr(fileURL.path, "net.viticci.macremote.test", "kept", 4, 0, 0) == 0)
        return fileURL
    }

    private func expectMetadataSurvived(_ fileURL: URL, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640, sourceLocation: sourceLocation)
        #expect(getxattr(fileURL.path, "net.viticci.macremote.test", nil, 0, 0, 0) == 4, sourceLocation: sourceLocation)
        // No hidden copy is left beside the file.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: fileURL.deletingLastPathComponent().path)
        #expect(siblings == ["log.md"], sourceLocation: sourceLocation)
    }

    private func run(
        _ tool: ToolDefinition,
        _ parameters: [String: ToolArgumentValue],
        on executor: NativeToolExecutor? = nil
    ) async throws -> (exitCode: Int32, json: [String: Any]) {
        let outcome = try await (executor ?? self.executor)
            .execute(tool: tool, parameters: parameters, timeoutSeconds: tool.timeoutSeconds)
        let data = try #require(outcome.stdout.data(using: .utf8))
        return (outcome.exitCode, try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    /// An executor that runs `change` after an edit has read its file and
    /// before it saves: the moment another process could change things.
    private func executorChangingBeforeSave(_ change: @escaping @Sendable (String) -> Void) -> NativeToolExecutor {
        NativeToolExecutor(pathPolicy: Self.temporaryFolderPolicy, editWillSave: change)
    }

    /// Why `ConfiguredToolExecutor.validate`, which runs before the owner is
    /// asked, refuses a call, or nil when it accepts it.
    private func refusal(
        _ tool: ToolDefinition,
        _ arguments: [String: ToolArgumentValue],
        policy: FileTransferPathPolicy = Self.temporaryFolderPolicy
    ) -> String? {
        let executor = ConfiguredToolExecutor(tools: [tool], environment: [:], fileTransferPolicy: policy)
        do {
            try executor.validate(toolID: tool.id, parameters: arguments)
            return nil
        } catch let error as ToolValidationError {
            return error.callToolMessage(tool: tool, arguments: arguments)
        } catch {
            return "\(error)"
        }
    }

    @Test func appendAddsTextAtTheEndAndChangesNothingElse() async throws {
        let fileURL = try makeWorkLog()
        let entry = "\r\n\r\n## Wednesday\r\nWrote the D85 entry ✅"

        let result = try await run(FileTransferToolCatalog.appendFileTool, [
            "path": .string(fileURL.path),
            "text": .string(entry)
        ])

        #expect(result.exitCode == 0)
        #expect(try Data(contentsOf: fileURL) == Self.workLog + Data(entry.utf8))
        #expect(result.json["bytes_appended"] as? Int == Data(entry.utf8).count)
        #expect(result.json["size_bytes"] as? Int == Self.workLog.count + Data(entry.utf8).count)
        try expectMetadataSurvived(fileURL)
    }

    @Test func replaceChangesOnlyTheOnePassageAndCanDeleteIt() async throws {
        let fileURL = try makeWorkLog()

        let changed = try await run(FileTransferToolCatalog.replaceInFileTool, [
            "path": .string(fileURL.path),
            "find": .string("Shipped the café menu."),
            "replace": .string("Shipped the café menu and the bar menu.")
        ])
        #expect(changed.exitCode == 0)
        #expect(changed.json["replacements"] as? Int == 1)
        let expected = "# Work log\r\n\r\n## Monday\r\nShipped the café menu and the bar menu.\r\n\r\n## Tuesday\r\nReviewed notes"
        #expect(try Data(contentsOf: fileURL) == Data(expected.utf8))
        #expect(changed.json["size_bytes"] as? Int == Data(expected.utf8).count)

        // An empty replacement deletes the passage.
        let deleted = try await run(FileTransferToolCatalog.replaceInFileTool, [
            "path": .string(fileURL.path),
            "find": .string("\r\n\r\n## Tuesday\r\nReviewed notes"),
            "replace": .string("")
        ])
        #expect(deleted.exitCode == 0)
        #expect(try Data(contentsOf: fileURL) == Data("# Work log\r\n\r\n## Monday\r\nShipped the café menu and the bar menu.".utf8))
        try expectMetadataSurvived(fileURL)
    }

    @Test func replaceRefusesZeroOrSeveralMatchesAndSaysHowMany() async throws {
        let fileURL = try makeWorkLog()
        let cases: [(find: String, code: String, count: String)] = [
            ("\r\n\r\n", "multiple_matches", "appears 2 times"),
            // Case and line endings must match exactly.
            ("shipped the café menu.", "no_match", "appears 0 times"),
            ("## Monday\nShipped", "no_match", "appears 0 times")
        ]
        for item in cases {
            let result = try await run(FileTransferToolCatalog.replaceInFileTool, [
                "path": .string(fileURL.path),
                "find": .string(item.find),
                "replace": .string("x")
            ])
            #expect(result.exitCode == 1)
            #expect(result.json["code"] as? String == item.code)
            #expect((result.json["error"] as? String)?.contains(item.count) == true)
        }
        #expect(try Data(contentsOf: fileURL) == Self.workLog)

        // Overlapping appearances count: either "aa" in "aaa" could be meant.
        #expect(NativeToolExecutor.occurrences(of: Data("aa".utf8), in: Data("aaa".utf8)).count == 2)
    }

    @Test func aFailedSaveLeavesTheOriginalIntact() async throws {
        let fileURL = try makeWorkLog()
        let directory = fileURL.deletingLastPathComponent()
        defer { chmod(directory.path, 0o755) }
        // The folder turns read-only after the checks, so the new copy can't
        // be written beside the file.
        let executor = executorChangingBeforeSave { _ in chmod(directory.path, 0o555) }

        let result = try await run(FileTransferToolCatalog.appendFileTool, [
            "path": .string(fileURL.path),
            "text": .string("\r\nlost")
        ], on: executor)

        #expect(result.exitCode == 1)
        #expect(result.json["code"] as? String == "io_error")
        #expect(try Data(contentsOf: fileURL) == Self.workLog)
        try expectMetadataSurvived(fileURL)
    }

    /// A folder in the path swapped for a link to a folder outside the
    /// allowed ones, after the file was read: the save must not follow it.
    /// The edit fails and nothing changes on either side.
    @Test func aFolderSwappedForALinkBeforeTheSaveCannotSendItOutside() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-file-edit-swap-\(UUID().uuidString)", isDirectory: true)
        let allowed = root.appendingPathComponent("allowed", isDirectory: true)
        let notes = allowed.appendingPathComponent("notes", isDirectory: true)
        let movedNotes = allowed.appendingPathComponent("notes-moved", isDirectory: true)
        let outsideNotes = root.appendingPathComponent("outside/notes", isDirectory: true)
        let inside = Data("inside\n".utf8)
        let outside = Data("outside, never reachable\n".utf8)
        for (folder, contents) in [(notes, inside), (outsideNotes, outside)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try contents.write(to: folder.appendingPathComponent("log.md"))
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = FileTransferPathPolicy(homeDirectory: root.path, allowedFolders: [allowed.path])
        let executor = NativeToolExecutor(pathPolicy: policy, editWillSave: { _ in
            try? FileManager.default.moveItem(at: notes, to: movedNotes)
            try? FileManager.default.createSymbolicLink(at: notes, withDestinationURL: outsideNotes)
        })

        let result = try await run(FileTransferToolCatalog.appendFileTool, [
            "path": .string(notes.appendingPathComponent("log.md").path),
            "text": .string("appended\n")
        ], on: executor)

        #expect(result.exitCode == 1)
        #expect(result.json["code"] as? String == "file_changed")
        #expect(try Data(contentsOf: outsideNotes.appendingPathComponent("log.md")) == outside)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outsideNotes.path) == ["log.md"])
        #expect(try Data(contentsOf: movedNotes.appendingPathComponent("log.md")) == inside)
        #expect(try FileManager.default.contentsOfDirectory(atPath: movedNotes.path) == ["log.md"])
    }

    /// The file deleted, or replaced by a folder, after it was read: the
    /// edit fails and neither recreates the file nor replaces the folder.
    @Test func aTargetDeletedOrReplacedByAFolderBeforeTheSaveFails() async throws {
        let deletedURL = try makeWorkLog()
        let deleted = try await run(FileTransferToolCatalog.appendFileTool, [
            "path": .string(deletedURL.path),
            "text": .string("\r\nlost")
        ], on: executorChangingBeforeSave { path in unlink(path) })
        #expect(deleted.exitCode == 1)
        #expect(deleted.json["code"] as? String == "file_changed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: deletedURL.deletingLastPathComponent().path).isEmpty)

        let replacedURL = try makeWorkLog()
        let replaced = try await run(FileTransferToolCatalog.replaceInFileTool, [
            "path": .string(replacedURL.path),
            "find": .string("Reviewed notes"),
            "replace": .string("lost")
        ], on: executorChangingBeforeSave { path in
            unlink(path)
            mkdir(path, 0o755)
            FileManager.default.createFile(atPath: path + "/kept.txt", contents: Data("kept".utf8))
        })
        #expect(replaced.exitCode == 1)
        #expect(replaced.json["code"] as? String == "file_changed")
        #expect(try Data(contentsOf: replacedURL.appendingPathComponent("kept.txt")) == Data("kept".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: replacedURL.deletingLastPathComponent().path) == ["log.md"])
    }

    /// Many appends to one file at once: each one lands, none is lost.
    @Test func concurrentAppendsAllLand() async throws {
        let fileURL = try makeWorkLog()
        let executor = self.executor
        let entries = (0..<12).map { "\r\n[entry \($0)]" }

        let exitCodes = try await withThrowingTaskGroup(of: Int32.self) { group in
            for entry in entries {
                group.addTask {
                    let tool = FileTransferToolCatalog.appendFileTool
                    return try await executor.execute(tool: tool, parameters: [
                        "path": .string(fileURL.path),
                        "text": .string(entry)
                    ], timeoutSeconds: tool.timeoutSeconds).exitCode
                }
            }
            return try await group.reduce(into: [Int32]()) { $0.append($1) }
        }

        #expect(exitCodes == Array(repeating: 0, count: entries.count))
        let saved = try Data(contentsOf: fileURL)
        #expect(saved.starts(with: Self.workLog))
        #expect(saved.count == Self.workLog.count + entries.reduce(0) { $0 + $1.utf8.count })
        let text = String(decoding: saved, as: UTF8.self)
        for entry in entries {
            #expect(text.components(separatedBy: entry).count == 2, "\(entry) is not in the file exactly once")
        }
        try expectMetadataSurvived(fileURL)
    }

    /// Another app changes the file after the edit read it, in place or by
    /// saving a new copy: the edit fails and asks for a fresh read, rather
    /// than saving over the other change.
    @Test func aChangeByAnotherWriterBeforeTheSaveFailsTheEdit() async throws {
        let otherWriters: [@Sendable (String) -> Void] = [
            { path in
                let handle = FileHandle(forWritingAtPath: path)
                _ = try? handle?.seekToEnd()
                try? handle?.write(contentsOf: Data("\r\nother app".utf8))
                try? handle?.close()
            },
            { path in try? (Self.workLog + Data("\r\nother app".utf8)).write(to: URL(fileURLWithPath: path), options: .atomic) }
        ]
        for otherWriter in otherWriters {
            let fileURL = try makeWorkLog()
            let result = try await run(FileTransferToolCatalog.appendFileTool, [
                "path": .string(fileURL.path),
                "text": .string("\r\nlost")
            ], on: executorChangingBeforeSave(otherWriter))

            #expect(result.exitCode == 1)
            #expect(result.json["code"] as? String == "file_changed")
            #expect((result.json["error"] as? String)?.contains("Read the file again") == true)
            #expect(try Data(contentsOf: fileURL) == Self.workLog + Data("\r\nother app".utf8))
        }
    }

    /// A file the app could not save is refused before the owner is asked:
    /// read-only, locked, or in a read-only folder; and a file that can be
    /// written but not replaced, because an access rule forbids deleting it
    /// or its folder is append-only or forbids removing files. A refused
    /// call refused again after approval leaves no hidden copy behind.
    @Test func filesThatCannotBeSavedAreRefusedBeforeApproval() async throws {
        let readOnly = try makeWorkLog()
        #expect(chmod(readOnly.path, 0o444) == 0)
        let locked = try makeWorkLog()
        #expect(chflags(locked.path, UInt32(UF_IMMUTABLE)) == 0)
        let inReadOnlyFolder = try makeWorkLog()
        #expect(chmod(inReadOnlyFolder.deletingLastPathComponent().path, 0o555) == 0)
        let undeletable = try makeWorkLog()
        try addAccessRule("user:\(NSUserName()) deny delete", to: undeletable)
        let inAppendOnlyFolder = try makeWorkLog()
        #expect(chflags(inAppendOnlyFolder.deletingLastPathComponent().path, UInt32(UF_APPEND)) == 0)
        let inKeepingFolder = try makeWorkLog()
        try addAccessRule("user:\(NSUserName()) deny delete_child", to: inKeepingFolder.deletingLastPathComponent())
        defer {
            chflags(locked.path, 0)
            chmod(inReadOnlyFolder.deletingLastPathComponent().path, 0o755)
            chflags(inAppendOnlyFolder.deletingLastPathComponent().path, 0)
            try? removeAccessRules(from: undeletable)
            try? removeAccessRules(from: inKeepingFolder.deletingLastPathComponent())
        }

        let cases: [(file: URL, says: String)] = [
            (readOnly, "the file is read-only"),
            (locked, "the file is locked"),
            (inReadOnlyFolder, "its folder is read-only"),
            (undeletable, "an access rule forbids replacing the file"),
            (inAppendOnlyFolder, "its folder is append-only"),
            (inKeepingFolder, "an access rule on its folder forbids replacing files")
        ]
        for item in cases {
            let path = ToolArgumentValue.string(item.file.path)
            let append = refusal(FileTransferToolCatalog.appendFileTool, ["path": path, "text": .string("x")])
            let replace = refusal(FileTransferToolCatalog.replaceInFileTool, [
                "path": path, "find": .string("Reviewed notes"), "replace": .string("x")
            ])
            #expect(append?.contains(item.says) == true, "\(append ?? "accepted")")
            #expect(replace?.contains(item.says) == true, "\(replace ?? "accepted")")
            let executed = try await run(FileTransferToolCatalog.appendFileTool, ["path": path, "text": .string("x")])
            #expect(executed.json["code"] as? String == "not_writable")
            #expect(try Data(contentsOf: item.file) == Self.workLog)
            #expect(try FileManager.default.contentsOfDirectory(atPath: item.file.deletingLastPathComponent().path) == ["log.md"])
        }
    }

    /// An edit is a change, so the file gets a new modification time, and
    /// keeps everything else that says what it is: permissions, access
    /// rules, extended attributes, and creation date.
    @Test func anEditGivesTheFileANewModificationTimeAndKeepsTheRest() async throws {
        let fileURL = try makeWorkLog()
        try addAccessRule("group:staff allow read", to: fileURL)
        // Created in June 2020, last changed in June 2021.
        var created = timespec(tv_sec: 1_592_179_200, tv_nsec: 0)
        var attributes = attrlist(
            bitmapcount: u_short(ATTR_BIT_MAP_COUNT), reserved: 0, commonattr: attrgroup_t(ATTR_CMN_CRTIME),
            volattr: 0, dirattr: 0, fileattr: 0, forkattr: 0
        )
        #expect(setattrlist(fileURL.path, &attributes, &created, MemoryLayout<timespec>.size, 0) == 0)
        var times = [timespec(tv_sec: 1_623_715_200, tv_nsec: 0), timespec(tv_sec: 1_623_715_200, tv_nsec: 0)]
        #expect(utimensat(AT_FDCWD, fileURL.path, &times, 0) == 0)
        let rulesBefore = try accessRules(of: fileURL)
        let editStarted = Date()

        let result = try await run(FileTransferToolCatalog.replaceInFileTool, [
            "path": .string(fileURL.path),
            "find": .string("Reviewed notes"),
            "replace": .string("Reviewed the notes")
        ])

        #expect(result.exitCode == 0)
        var info = stat()
        #expect(stat(fileURL.path, &info) == 0)
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
        #expect(modified >= editStarted.addingTimeInterval(-2), "modified \(modified), edit started \(editStarted)")
        #expect(info.st_birthtimespec.tv_sec == created.tv_sec)
        #expect(try accessRules(of: fileURL) == rulesBefore)
        #expect(rulesBefore.contains("allow:read"))
        try expectMetadataSurvived(fileURL)
    }

    /// Something puts another file, or a link to a file outside the allowed
    /// folders, in place of the hidden copy after it is written and before
    /// it is renamed: the save sees that the name no longer names its copy,
    /// so the original stays, nothing outside changes, and the edit fails
    /// instead of reporting a save that did not happen.
    @Test func aHiddenCopyReplacedBeforeTheRenameNeverTakesTheFilesPlace() async throws {
        let outsideFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-file-edit-outside-\(UUID().uuidString).txt")
        let outside = Data("outside, never reachable\n".utf8)
        try outside.write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outsideFile) }
        let replacements: [@Sendable (String) -> Void] = [
            { copy in FileManager.default.createFile(atPath: copy, contents: Data("impostor\n".utf8)) },
            { copy in _ = symlink(outsideFile.path, copy) }
        ]
        for replace in replacements {
            let fileURL = try makeWorkLog()
            let executor = NativeToolExecutor(pathPolicy: Self.temporaryFolderPolicy, saveWillRename: { copy in
                unlink(copy)
                replace(copy)
            })

            let result = try await run(FileTransferToolCatalog.appendFileTool, [
                "path": .string(fileURL.path),
                "text": .string("\r\nlost")
            ], on: executor)

            #expect(result.exitCode == 1)
            #expect(result.json["code"] as? String == "file_changed")
            var info = stat()
            #expect(lstat(fileURL.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG)
            #expect(try Data(contentsOf: fileURL) == Self.workLog)
            #expect(try Data(contentsOf: outsideFile) == outside)
        }
    }

    /// A call that waited for another edit of the same folder until its
    /// deadline reports "timed out", and then never changes the file, even
    /// once the other edit is done.
    @Test func anEditThatTimedOutWaitingNeverSaves() async throws {
        let fileURL = try makeWorkLog()
        let holding = DispatchSemaphore(value: 0)
        let slowExecutor = executorChangingBeforeSave { _ in
            holding.signal()
            Thread.sleep(forTimeInterval: 0.6)
        }
        let first = Task {
            try await slowExecutor.execute(tool: FileTransferToolCatalog.appendFileTool, parameters: [
                "path": .string(fileURL.path), "text": .string("\r\nfirst")
            ], timeoutSeconds: 10).exitCode
        }
        // Until the first edit holds the folder's lock.
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                holding.wait()
                continuation.resume()
            }
        }

        let late = try await executor.execute(tool: FileTransferToolCatalog.appendFileTool, parameters: [
            "path": .string(fileURL.path), "text": .string("\r\nlate")
        ], timeoutSeconds: 0.1)
        #expect(late.timedOut)
        #expect(try await first.value == 0)
        // Time for the late call, still running, to reach its save.
        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(try Data(contentsOf: fileURL) == Self.workLog + Data("\r\nfirst".utf8))
        try expectMetadataSurvived(fileURL)
    }

    private func addAccessRule(_ rule: String, to url: URL) throws {
        try runChmod(["+a", rule, url.path])
    }

    private func removeAccessRules(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "chmod \(arguments)")
    }

    /// The file's access rules as text, or "" when it has none.
    private func accessRules(of url: URL) throws -> String {
        guard let rules = acl_get_file(url.path, ACL_TYPE_EXTENDED) else { return "" }
        defer { _ = acl_free(UnsafeMutableRawPointer(rules)) }
        guard let text = acl_to_text(rules, nil) else { return "" }
        defer { _ = acl_free(text) }
        // The text starts with a header; the entries follow, one per line.
        return String(cString: text)
    }

    /// A file with another hard link is refused by both tools: an edit saves
    /// a new copy in its place, which would split it from its other name.
    @Test func hardLinkedFilesAreRefused() async throws {
        let fileURL = try makeWorkLog()
        let otherName = fileURL.deletingLastPathComponent().appendingPathComponent("other-name.md")
        #expect(link(fileURL.path, otherName.path) == 0)

        for path in [fileURL.path, otherName.path] {
            let append = refusal(FileTransferToolCatalog.appendFileTool, ["path": .string(path), "text": .string("x")])
            let replace = refusal(FileTransferToolCatalog.replaceInFileTool, [
                "path": .string(path), "find": .string("Reviewed notes"), "replace": .string("x")
            ])
            #expect(append?.contains("2 hard links") == true, "\(append ?? "accepted")")
            #expect(replace?.contains("2 hard links") == true, "\(replace ?? "accepted")")
        }
        // Refused again after approval, if a link appears while the owner decides.
        let result = try await run(FileTransferToolCatalog.appendFileTool, [
            "path": .string(fileURL.path),
            "text": .string("x")
        ])
        #expect(result.json["code"] as? String == "hard_linked")
        #expect(try Data(contentsOf: otherName) == Self.workLog)
    }

    /// `replace` is declared required, so a client knows to send it, and an
    /// empty one is still accepted: it deletes the passage. No other
    /// required text starts accepting an empty value.
    @Test func replaceIsRequiredAndMayBeEmpty() throws {
        let replace = FileTransferToolCatalog.replaceInFileTool
        #expect(replace.parameters.filter(\.required).map(\.name) == ["path", "find", "replace"])

        let path = ToolArgumentValue.string("/tmp/notes.md")
        try ToolArgumentResolver.validateNativeArguments(for: replace, parameters: [
            "path": path, "find": .string("old"), "replace": .string("")
        ])
        #expect(throws: ToolValidationError.missingParameter("replace")) {
            try ToolArgumentResolver.validateNativeArguments(for: replace, parameters: ["path": path, "find": .string("old")])
        }
        #expect(throws: ToolValidationError.missingParameter("find")) {
            try ToolArgumentResolver.validateNativeArguments(for: replace, parameters: [
                "path": path, "find": .string(""), "replace": .string("new")
            ])
        }
        #expect(throws: ToolValidationError.missingParameter("text")) {
            try ToolArgumentResolver.validateNativeArguments(for: FileTransferToolCatalog.appendFileTool, parameters: [
                "path": path, "text": .string("")
            ])
        }
    }

    /// Each refusal happens in validation, which runs before the owner is
    /// asked, so none of these calls would ever reach an approval prompt.
    @Test func callsThatCannotRunAreRefusedBeforeApproval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-file-edit-home-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        for folder in ["Documents/folder", ".ssh"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(folder),
                withIntermediateDirectories: true
            )
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("outside"), withIntermediateDirectories: true)
        let text = home.appendingPathComponent("Documents/notes.txt")
        try Data("one two two".utf8).write(to: text)
        try Data([0x68, 0x69, 0xFF, 0xFE]).write(to: home.appendingPathComponent("Documents/latin1.txt"))
        try Data(repeating: 0x61, count: FileTransferToolCatalog.editFileByteLimit + 1)
            .write(to: home.appendingPathComponent("Documents/huge.txt"))
        try Data("key".utf8).write(to: home.appendingPathComponent(".ssh/config"))
        try Data("x".utf8).write(to: root.appendingPathComponent("outside/notes.txt"))

        let append = FileTransferToolCatalog.appendFileTool
        let replace = FileTransferToolCatalog.replaceInFileTool
        let executor = ConfiguredToolExecutor(
            tools: [append, replace],
            environment: [:],
            fileTransferPolicy: FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: [home.path])
        )
        func documents(_ name: String) -> ToolArgumentValue {
            .string(home.appendingPathComponent("Documents/\(name)").path)
        }

        let refused: [(tool: ToolDefinition, arguments: [String: ToolArgumentValue], says: String)] = [
            (append, ["path": documents("latin1.txt"), "text": .string("x")], "not UTF-8"),
            (replace, ["path": documents("latin1.txt"), "find": .string("hi"), "replace": .string("x")], "not UTF-8"),
            (append, ["path": documents("missing.txt"), "text": .string("x")], "does not exist"),
            (append, ["path": documents("folder"), "text": .string("x")], "not a regular file"),
            (append, ["path": documents("huge.txt"), "text": .string("x")], "larger than 10 MiB"),
            (append, ["path": .string(home.appendingPathComponent(".ssh/config").path), "text": .string("x")], "File Transfer reaches only"),
            (replace, ["path": .string(root.appendingPathComponent("outside/notes.txt").path), "find": .string("x"), "replace": .string("y")], "File Transfer reaches only"),
            (replace, ["path": .string(text.path), "find": .string("two"), "replace": .string("2")], "appears 2 times"),
            (replace, ["path": .string(text.path), "find": .string(""), "replace": .string("2")], "find"),
            (replace, ["path": .string(text.path), "find": .string("one")], "replace")
        ]
        for item in refused {
            do {
                try executor.validate(toolID: item.tool.id, parameters: item.arguments)
                Issue.record("\(item.tool.name) was not refused: \(item.arguments)")
            } catch let error as ToolValidationError {
                let message = error.callToolMessage(tool: item.tool, arguments: item.arguments)
                #expect(message.contains(item.says), "\(message)")
            }
        }
        #expect(try Data(contentsOf: text) == Data("one two two".utf8))

        try executor.validate(toolID: replace.id, parameters: ["path": .string(text.path), "find": .string("one"), "replace": .string("1")])
        try executor.validate(toolID: append.id, parameters: ["path": .string(text.path), "text": .string(" three")])
    }

    /// Through a real server on loopback: both tools are listed as writes,
    /// a call that cannot run gets no prompt, and a call that can waits for
    /// the owner, who sees every argument in full.
    @Test func bothToolsAskFirstOverMCP() async throws {
        let fileURL = try makeWorkLog()
        let append = FileTransferToolCatalog.appendFileTool
        let replace = FileTransferToolCatalog.replaceInFileTool
        let token = "file-edit-tools-\(UUID().uuidString)"
        let coordinator = OAuthCoordinator()
        coordinator.updateStaticHeaderToken(token, clientName: "File Edit Probe")
        let approvals = ToolCallApprovalCoordinator(timeoutSeconds: 10)
        let server = LocalMCPServer(
            instanceID: "file-edit",
            tools: [append, replace],
            authCoordinator: coordinator,
            toolCallApprovalCoordinator: approvals,
            toolExecutor: ConfiguredToolExecutor(
                tools: [append, replace],
                environment: [:],
                fileTransferPolicy: Self.temporaryFolderPolicy
            )
        )
        let port = try server.start()
        defer { server.stop() }
        let client = MCPTestClient(
            baseURL: try #require(URL(string: "http://127.0.0.1:\(port)/mcp/file-edit")),
            bearerToken: token,
            mode: .legacy()
        )
        #expect(try await client.initializeLegacy().statusCode == 200)

        let listed = try #require(try await client.listTools().result?["tools"] as? [[String: Any]])
        for id in [append.id, replace.id] {
            let annotations = try #require(listed.first { $0["name"] as? String == id }?["annotations"] as? [String: Any])
            #expect(annotations["readOnlyHint"] as? Bool == false)
            #expect(annotations["destructiveHint"] as? Bool == false)
            #expect(annotations["idempotentHint"] as? Bool == false)
        }
        let replaceSchema = listed.first { $0["name"] as? String == replace.id }?["inputSchema"] as? [String: Any]
        #expect(replaceSchema?["required"] as? [String] == ["path", "find", "replace"])

        let doomed = try #require(try await client.send(method: "tools/call", params: [
            "name": replace.id,
            "arguments": ["path": fileURL.path, "find": "\r\n\r\n", "replace": ""]
        ]).result)
        #expect(doomed["isError"] as? Bool == true)
        let doomedContent = try #require(doomed["structuredContent"] as? [String: Any])
        #expect(doomedContent["reason"] as? String == "invalid_argument")
        #expect((doomedContent["stderr"] as? String)?.contains("appears 2 times") == true)
        #expect(approvals.approvalSnapshot().isEmpty)

        let calls: [(tool: ToolDefinition, arguments: [String: String])] = [
            (append, ["path": fileURL.path, "text": "\r\nWednesday"]),
            (replace, ["path": fileURL.path, "find": "Reviewed notes", "replace": "Reviewed notes twice"])
        ]
        for call in calls {
            let pending = Task {
                try await client.send(method: "tools/call", params: ["name": call.tool.id, "arguments": call.arguments])
            }
            var request: ToolCallApprovalRequest?
            for _ in 0..<250 where request == nil {
                try await Task.sleep(nanoseconds: 20_000_000)
                request = approvals.approvalSnapshot().first { $0.toolID == call.tool.id && $0.state == .pending }
            }
            let approval = try #require(request)
            #expect(Dictionary(uniqueKeysWithValues: approval.arguments.map { ($0.name, $0.value) }) == call.arguments)
            #expect(approvals.approve(requestID: approval.id))
            let result = try #require(try await pending.value.result)
            #expect(result["isError"] as? Bool == false)
        }
        #expect(try Data(contentsOf: fileURL) == Data(
            "# Work log\r\n\r\n## Monday\r\nShipped the café menu.\r\n\r\n## Tuesday\r\nReviewed notes twice\r\nWednesday".utf8
        ))
    }
}
