import Foundation
import Testing
@testable import MacRemote

/// The owner may let File Transfer reach the whole Mac. These tests cover
/// what that opens, what stays closed, and the two tools an app needs to get
/// around a disk it does not know: Find Files and text reads.
struct WholeMacFileAccessTests {
    /// A fake home with a key, a credentials file, a hidden file, and a few
    /// documents, plus a folder outside the home.
    private func makeDisk() throws -> (home: URL, outside: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-whole-mac-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        for folder in [
            home.appendingPathComponent(".ssh"),
            home.appendingPathComponent("Documents/Taxes"),
            home.appendingPathComponent("Projects/app"),
            outside
        ] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let files = [
            ".ssh/report-key",
            ".netrc",
            "Documents/Taxes/Report 2025.pdf",
            "Documents/report-notes.txt",
            "Projects/app/.env",
            "Projects/app/main.swift"
        ]
        for file in files {
            try Data("x".utf8).write(to: home.appendingPathComponent(file))
        }
        try Data("x".utf8).write(to: outside.appendingPathComponent("report-outside.txt"))
        return (home, outside)
    }

    private func executor(
        home: URL,
        allowedFolders: [String],
        spotlight: @escaping FileNameSearch.SpotlightLookup = { _, _, _ in [] }
    ) -> NativeToolExecutor {
        NativeToolExecutor(
            pathPolicy: FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: allowedFolders),
            spotlight: spotlight
        )
    }

    private func run(
        _ nativeToolID: NativeToolIdentifier,
        _ parameters: [String: ToolArgumentValue],
        with executor: NativeToolExecutor
    ) async throws -> [String: Any] {
        let tool = try #require(FileTransferToolCatalog.builtInTools.first { $0.nativeToolID == nativeToolID })
        let outcome = try await executor.execute(tool: tool, parameters: parameters, timeoutSeconds: tool.timeoutSeconds)
        let data = try #require(outcome.stdout.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func matchedNames(_ result: [String: Any]) throws -> [String] {
        let matches = try #require(result["matches"] as? [[String: Any]])
        return matches.compactMap { ($0["path"] as? String).map { ($0 as NSString).lastPathComponent } }.sorted()
    }

    @Test func allowingTheWholeMacReachesEverythingExceptProtectedLocations() throws {
        let (home, outside) = try makeDisk()
        let policy = FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: ["/"])

        #expect(policy.reachesWholeMac)
        #expect(policy.allowedFoldersDescription == "the whole Mac")
        #expect(try policy.resolveUserPath(outside.appendingPathComponent("report-outside.txt").path)
            .hasSuffix("/outside/report-outside.txt"))
        #expect(try policy.resolveUserPath("/etc/hosts").hasSuffix("/etc/hosts"))
        #expect(try policy.resolveUserPath("~/Projects/app/.env").hasSuffix("/Projects/app/.env"))
        // A protected folder, a protected file, and one that does not exist yet.
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/.ssh/report-key")
        }
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/.netrc")
        }
        #expect(throws: FileTransferPathPolicy.PathError.pathDenied) {
            try policy.resolveUserPath("~/.config/gh/hosts.yml")
        }
        #expect(!FileTransferPathPolicy(homeDirectory: home.path, allowedFolders: [home.path]).reachesWholeMac)
    }

    /// The real home folder has a second name under the data volume. An
    /// archive of that volume would carry the protected locations out.
    @Test func theDataVolumeCountsAsContainingProtectedLocations() {
        let policy = FileTransferPathPolicy(allowedFolders: ["/"])

        #expect(policy.containsProtectedFolder("/"))
        #expect(policy.containsProtectedFolder("/System/Volumes/Data"))
        #expect(policy.containsProtectedFolder("/System/Volumes/Data/Users"))
        #expect(!policy.containsProtectedFolder("/usr/share/dict"))
    }

    @Test func findWalksAFolderExactlyAndSkipsProtectedLocations() async throws {
        let (home, outside) = try makeDisk()
        // A link out of the folder being searched must not be followed.
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent("Documents/elsewhere"),
            withDestinationURL: outside
        )
        let executor = executor(home: home, allowedFolders: [home.path])

        let byText = try await run(.fsFind, ["name": .string("REPORT"), "path": .string(home.path)], with: executor)
        #expect(byText["method"] as? String == "walk")
        #expect(byText["truncated"] as? Bool == false)
        // Not the key inside .ssh, and not the file behind the link.
        #expect(try matchedNames(byText) == ["Report 2025.pdf", "report-notes.txt"])

        // Hidden files are found, which Spotlight would miss.
        let hidden = try await run(.fsFind, ["name": .string(".env"), "path": .string(home.path)], with: executor)
        #expect(try matchedNames(hidden) == [".env"])

        // A wildcard must match the whole name.
        let wildcard = try await run(.fsFind, ["name": .string("*.TXT"), "path": .string(home.path)], with: executor)
        #expect(try matchedNames(wildcard) == ["report-notes.txt"])

        let folders = try await run(
            .fsFind,
            ["name": .string("a"), "path": .string(home.path), "type": .string("directory")],
            with: executor
        )
        #expect(try matchedNames(folders) == ["Taxes", "app"])

        let capped = try await run(
            .fsFind,
            ["name": .string("report"), "path": .string(home.path), "max_results": .string("1")],
            with: executor
        )
        #expect(try matchedNames(capped).count == 1)
        #expect(capped["truncated_reason"] as? String == "max_results")
    }

    @Test func findCannotSearchOutsideTheAllowedFolders() async throws {
        let (home, outside) = try makeDisk()
        let executor = executor(home: home, allowedFolders: [home.appendingPathComponent("Documents").path])

        let denied = try await run(.fsFind, ["name": .string("report"), "path": .string(outside.path)], with: executor)
        #expect(denied["code"] as? String == "path_denied")
    }

    /// Spotlight knows nothing about MacRemote's rules, so its answers are
    /// checked one by one before any of them is returned.
    @Test func findWithoutAFolderAsksSpotlightAndKeepsOnlyReachableResults() async throws {
        let (home, outside) = try makeDisk()
        let asked = SpotlightRecorder(answers: [
            home.appendingPathComponent("Documents/report-notes.txt").path,
            home.appendingPathComponent(".ssh/report-key").path,
            outside.appendingPathComponent("report-outside.txt").path,
            home.appendingPathComponent("Documents/missing-report.txt").path,
            // Spotlight's wildcard is looser than ours; the exact rule decides.
            home.appendingPathComponent("Projects/app/main.swift").path
        ])
        let documents = home.appendingPathComponent("Documents").path
        let executor = executor(home: home, allowedFolders: [documents, home.appendingPathComponent("Projects").path]) {
            asked.lookup(pattern: $0, folders: $1, limit: $2)
        }

        let result = try await run(.fsFind, ["name": .string("report")], with: executor)

        #expect(result["method"] as? String == "spotlight")
        #expect(try matchedNames(result) == ["report-notes.txt"])
        #expect(asked.pattern == "*report*")
        #expect(asked.folders == [documents, home.appendingPathComponent("Projects").path])
    }

    @Test func spotlightPatternsEscapeQuerySyntax() {
        #expect(FileNameSearch.spotlightPattern(for: "report", isWildcard: false) == "*report*")
        #expect(FileNameSearch.spotlightPattern(for: "a*b\"c", isWildcard: true) == "a*b\\\"c")
        #expect(FileNameSearch.spotlightPattern(for: "file-?.txt", isWildcard: true) == "file-*.txt")
        #expect(FileNameSearch.spotlightPattern(for: "it's\\here", isWildcard: false) == "*it\\'s\\\\here*")
    }

    /// Text comes back as text. A chunk boundary inside a character must not
    /// break it: the cut character is left for the next read.
    @Test func readFileReturnsTextAndNeverSplitsACharacter() async throws {
        let (home, _) = try makeDisk()
        let file = home.appendingPathComponent("Documents/notes.txt")
        let text = "caffè ☕️ 日本語 done"
        try Data(text.utf8).write(to: file)
        let executor = executor(home: home, allowedFolders: [home.path])

        var offset = 0
        var assembled = ""
        var reads = 0
        while reads < 100 {
            let chunk = try await run(
                .fsReadFile,
                [
                    "path": .string(file.path),
                    "offset": .string(String(offset)),
                    "length": .string("5"),
                    "encoding": .string("utf8")
                ],
                with: executor
            )
            #expect(chunk["data_base64"] == nil)
            assembled += try #require(chunk["text"] as? String)
            offset += try #require(chunk["length_returned"] as? Int)
            reads += 1
            if chunk["eof"] as? Bool == true { break }
        }
        #expect(assembled == text)
        #expect(offset == text.utf8.count)
    }

    @Test func readFileAsTextRefusesBinaryData() async throws {
        let (home, _) = try makeDisk()
        let file = home.appendingPathComponent("Documents/image.bin")
        try Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]).write(to: file)
        let executor = executor(home: home, allowedFolders: [home.path])

        let result = try await run(.fsReadFile, ["path": .string(file.path), "encoding": .string("utf8")], with: executor)
        #expect(result["code"] as? String == "not_text")
    }
}

/// Stands in for Spotlight and records what it was asked.
private final class SpotlightRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let answers: [String]
    private var askedPattern: String?
    private var askedFolders: [String] = []

    init(answers: [String]) {
        self.answers = answers
    }

    var pattern: String? { lock.withLock { askedPattern } }
    var folders: [String] { lock.withLock { askedFolders } }

    func lookup(pattern: String, folders: [String], limit: Int) -> [String] {
        lock.withLock {
            askedPattern = pattern
            askedFolders = folders
        }
        return answers
    }
}
