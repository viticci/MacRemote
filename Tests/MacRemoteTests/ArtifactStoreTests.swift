import CryptoKit
import Foundation
import Testing
@testable import MacRemote

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(now: Date) { self.now = now }
}

struct ArtifactStoreTests {
    @Test func registerAndConsumeRoundTrip() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root)
        let source = root.appendingPathComponent("source.bin")
        let payload = Data([1, 2, 3, 4, 5])
        try payload.write(to: source)

        let handle = try store.register(fileURL: source, suggestedFilename: "source.bin")
        let consumed = try #require(store.consume(token: handle.token))
        #expect(consumed.filename == "source.bin")
        #expect(try Data(contentsOf: consumed.fileURL) == payload)
        #expect(consumed.remainingDownloads == 2)
    }

    @Test func unknownTokenReturnsNil() throws {
        let store = ArtifactStore(rootDirectory: try makeTemporaryDirectory())
        #expect(store.consume(token: "missing-token") == nil)
        #expect(store.resolve(token: "missing-token") == nil)
    }

    @Test func expiryIsHonored() throws {
        let root = try makeTemporaryDirectory()
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000_000))
        let store = ArtifactStore(
            rootDirectory: root,
            clock: { clock.now },
            expiryInterval: 30
        )
        let source = root.appendingPathComponent("expires.bin")
        try Data("soon".utf8).write(to: source)

        let handle = try store.register(fileURL: source, suggestedFilename: "expires.bin")
        clock.now = clock.now.addingTimeInterval(31)
        #expect(store.consume(token: handle.token) == nil)
    }

    @Test func downloadAllowanceDecrementsAndExhaustsAtThree() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root)
        let source = root.appendingPathComponent("limited.bin")
        try Data("limited".utf8).write(to: source)

        let handle = try store.register(fileURL: source, suggestedFilename: "limited.bin")
        #expect(store.consume(token: handle.token)?.remainingDownloads == 2)
        #expect(store.consume(token: handle.token)?.remainingDownloads == 1)
        #expect(store.consume(token: handle.token)?.remainingDownloads == 0)
        #expect(store.consume(token: handle.token) == nil)
    }

    @Test func sweepDeletesExhaustedArtifactsOnRegister() throws {
        let storeRoot = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: storeRoot)
        let sourceDir = try makeTemporaryDirectory()
        let source = sourceDir.appendingPathComponent("sweep.bin")
        try Data("sweep".utf8).write(to: source)

        let handle = try store.register(fileURL: source, suggestedFilename: "sweep.bin")
        _ = store.consume(token: handle.token)
        _ = store.consume(token: handle.token)
        _ = store.consume(token: handle.token)

        let nextSource = sourceDir.appendingPathComponent("next.bin")
        try Data("next".utf8).write(to: nextSource)
        _ = try store.register(fileURL: nextSource, suggestedFilename: "next.bin")

        let artifactDirectories = try FileManager.default.contentsOfDirectory(
            at: storeRoot,
            includingPropertiesForKeys: nil
        )
        #expect(artifactDirectories.count == 1)
    }

    @Test func registerFromDataRoundTrip() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root)
        let payload = Data("in-memory-artifact".utf8)

        let handle = try store.register(data: payload, suggestedFilename: "memory.bin")
        #expect(handle.filename == "memory.bin")
        #expect(handle.sizeBytes == Int64(payload.count))
        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        #expect(handle.sha256 == expected)
        #expect(!handle.token.isEmpty)

        let consumed = try #require(store.consume(token: handle.token))
        #expect(try Data(contentsOf: consumed.fileURL) == payload)
    }

    @Test func oversizeFileArtifactIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root, maxSizeBytes: 16)
        let source = root.appendingPathComponent("big.bin")
        try Data(repeating: 0xCD, count: 32).write(to: source)

        #expect(throws: ArtifactStoreError.artifactTooLarge) {
            _ = try store.register(fileURL: source, suggestedFilename: "big.bin")
        }
    }

    @Test func oversizeInMemoryArtifactIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root, maxSizeBytes: 16)
        let payload = Data(repeating: 0xCD, count: 32)

        #expect(throws: ArtifactStoreError.artifactTooLarge) {
            _ = try store.register(data: payload, suggestedFilename: "big.bin")
        }
    }

    @Test func sha256MatchesKnownBytes() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root)
        let source = root.appendingPathComponent("known.bin")
        let payload = Data("artifact-check".utf8)
        try payload.write(to: source)

        let expected = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let handle = try store.register(fileURL: source, suggestedFilename: "known.bin")
        #expect(handle.sha256 == expected)
        #expect(handle.sizeBytes == Int64(payload.count))
    }

    @Test func purgeAllDeletesItsFilesAndTheStoreKeepsWorking() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root)
        let handle = try store.register(data: Data("purge".utf8), suggestedFilename: "purge.bin")

        store.purgeAll()
        #expect(store.resolve(token: handle.token) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)

        let nextPayload = Data("after".utf8)
        let nextHandle = try store.register(data: nextPayload, suggestedFilename: "next.bin")
        let nextArtifact = try #require(store.resolve(token: nextHandle.token))
        #expect(try Data(contentsOf: nextArtifact.fileURL) == nextPayload)
    }

    /// Every store stages into the same folder in the app, so one server
    /// stopping must not delete what another store still serves.
    @Test func storesSharingAStagingFolderPurgeOnlyTheirOwnFiles() async throws {
        let sharedRoot = try makeTemporaryDirectory()
        let purgedStore = ArtifactStore(rootDirectory: sharedRoot)
        let activeStore = ArtifactStore(rootDirectory: sharedRoot)

        let stablePayload = Data("stable".utf8)
        let stableHandle = try activeStore.register(data: stablePayload, suggestedFilename: "stable.bin")
        let purgedHandle = try purgedStore.register(data: Data("purged".utf8), suggestedFilename: "purged.bin")

        let concurrentPayload = Data("concurrent".utf8)
        let concurrentHandle = try await withThrowingTaskGroup(of: ArtifactHandle?.self) { group in
            group.addTask {
                purgedStore.purgeAll()
                return nil
            }
            group.addTask {
                try activeStore.register(data: concurrentPayload, suggestedFilename: "concurrent.bin")
            }

            var registeredHandle: ArtifactHandle?
            for try await result in group {
                if let result {
                    registeredHandle = result
                }
            }
            return try #require(registeredHandle)
        }

        let stableArtifact = try #require(activeStore.resolve(token: stableHandle.token))
        let concurrentArtifact = try #require(activeStore.resolve(token: concurrentHandle.token))
        #expect(purgedStore.resolve(token: purgedHandle.token) == nil)
        #expect(try Data(contentsOf: stableArtifact.fileURL) == stablePayload)
        #expect(try Data(contentsOf: concurrentArtifact.fileURL) == concurrentPayload)
    }

    @Test func totalBudgetRefusesNewDownloadsUntilOldOnesExpire() throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000_000))
        let store = ArtifactStore(
            rootDirectory: try makeTemporaryDirectory(),
            clock: { clock.now },
            expiryInterval: 30,
            maxTotalBytes: 10
        )
        _ = try store.register(data: Data(repeating: 1, count: 6), suggestedFilename: "first.bin")

        #expect(throws: ArtifactStoreError.stagingFull) {
            _ = try store.register(data: Data(repeating: 2, count: 6), suggestedFilename: "second.bin")
        }

        clock.now = clock.now.addingTimeInterval(31)
        _ = try store.register(data: Data(repeating: 3, count: 6), suggestedFilename: "third.bin")
    }

    @Test func unfinishedDownloadCountsTowardTheTotalUntilItIsDiscarded() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root, maxTotalBytes: 10)
        let reservation = try store.reserve(suggestedFilename: "archive.zip", expectedBytes: 8)
        try Data(repeating: 7, count: 8).write(to: reservation.fileURL)

        #expect(throws: ArtifactStoreError.stagingFull) {
            _ = try store.register(data: Data(repeating: 1, count: 5), suggestedFilename: "other.bin")
        }

        store.discard(reservation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        _ = try store.register(data: Data(repeating: 1, count: 5), suggestedFilename: "other.bin")
    }

    @Test func commitRefusesAFileThatGrewPastTheLimit() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root, maxSizeBytes: 16)
        let reservation = try store.reserve(suggestedFilename: "archive.zip", expectedBytes: 4)
        try Data(repeating: 7, count: 32).write(to: reservation.fileURL)

        #expect(throws: ArtifactStoreError.artifactTooLarge) {
            _ = try store.commit(reservation)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func expiredDownloadIsDeletedWithoutAnotherCall() async throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root, expiryInterval: 0.05)
        _ = try store.register(data: Data("short-lived".utf8), suggestedFilename: "soon.bin")

        // The store checks one second after the expiry time.
        var remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        for _ in 0..<60 where !remaining.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        }
        #expect(remaining.isEmpty)
    }

    @Test func aStoreThatGoesAwayDeletesItsFiles() throws {
        let root = try makeTemporaryDirectory()
        do {
            let store = ArtifactStore(rootDirectory: root)
            _ = try store.register(data: Data("orphan".utf8), suggestedFilename: "orphan.bin")
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func emptyingTheStagingFolderRemovesWhatACrashLeftBehind() throws {
        let root = try makeTemporaryDirectory()
        let leftover = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: leftover.appendingPathComponent("stale.zip"))
        try Data("stale".utf8).write(to: root.appendingPathComponent("MacRemoteStdout-stale.tmp"))

        ArtifactStore.emptyStagingRoot(root)
        #expect(!FileManager.default.fileExists(atPath: root.path))

        // The folder comes back the first time something is staged.
        let store = ArtifactStore(rootDirectory: root)
        let handle = try store.register(data: Data("fresh".utf8), suggestedFilename: "fresh.bin")
        #expect(store.resolve(token: handle.token) != nil)
    }

    @Test func dotNamesCannotPointOutsideTheDownloadFolder() {
        #expect(ArtifactStore.sanitizedFilename("..") == "download")
        #expect(ArtifactStore.sanitizedFilename(".") == "download")
        #expect(ArtifactStore.sanitizedFilename("../notes.txt") == "notes.txt")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
