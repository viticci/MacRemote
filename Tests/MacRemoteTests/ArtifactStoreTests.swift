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

    @Test func oversizeArtifactIsRejected() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root, maxSizeBytes: 16)
        let source = root.appendingPathComponent("big.bin")
        try Data(repeating: 0xCD, count: 32).write(to: source)

        #expect(throws: ArtifactStoreError.artifactTooLarge) {
            _ = try store.register(fileURL: source, suggestedFilename: "big.bin")
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

    @Test func purgeAllRemovesStagedFiles() throws {
        let root = try makeTemporaryDirectory()
        let store = ArtifactStore(rootDirectory: root)
        let source = root.appendingPathComponent("purge.bin")
        try Data("purge".utf8).write(to: source)
        _ = try store.register(fileURL: source, suggestedFilename: "purge.bin")

        store.purgeAll()
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(entries.isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macremote-artifact-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
