import Compression
import Foundation
import Testing
@testable import MacRemote

// The URLProtocol stub keeps its scripted response in class statics, and several
// tests write to isolated temporary directories, so the suite runs serially.
@Suite(.serialized)
struct CloudflaredManagerTests {
    /// Updating the app must not make the helper a user already installed
    /// look tampered with. The 1.0.x helper stays accepted as an older copy.
    @Test func helperInstalledByAnEarlierReleaseIsStillAccepted() {
        let accepted = CloudflaredInstallStore.pinnedExecutableDigests
        #expect(accepted.isSuperset(of: Set(CloudflaredManifest.artifacts.map(\.executableSHA256))))
        #expect(accepted.isSuperset(of: CloudflaredManifest.earlierExecutableSHA256))
        // cloudflared 2026.7.3 for Apple silicon, shipped with the earlier 1.0 and 1.0.1 betas.
        #expect(accepted.contains("f35c50089cd25f77a4cb5a2152036bc26db15aa31fbe11f7995d2e42a4ed6257"))
    }


    // MARK: - Manifest

    @Test func manifestPinsBothMacArchitecturesWithVerifiableFacts() {
        #expect(CloudflaredManifest.artifacts.count == 2)
        #expect(Set(CloudflaredManifest.artifacts.map(\.architecture)) == Set(CloudflaredArchitecture.allCases))

        for artifact in CloudflaredManifest.artifacts {
            #expect(artifact.downloadURL.scheme == "https")
            #expect(CloudflaredManifest.isAllowedDownloadURL(artifact.downloadURL))
            #expect(artifact.downloadURL.path.contains(CloudflaredManifest.version))
            #expect(isLowercaseSHA256(artifact.archiveSHA256))
            #expect(isLowercaseSHA256(artifact.executableSHA256))
            #expect(artifact.archiveSHA256 != artifact.executableSHA256)
            #expect(artifact.archiveByteCount > 0)
            #expect(artifact.archiveByteCount < CloudflaredManifest.maxDownloadByteCount)
            #expect(artifact.executableByteCount > 0)
            // Header block plus the payload, padded, plus the end-of-archive marker.
            #expect(artifact.uncompressedTarByteCount >= artifact.executableByteCount + 512)
            #expect(artifact.uncompressedTarByteCount % 512 == 0)
        }

        #expect(CloudflaredManifest.expectedTeamIdentifier == "68WVV388M8")
        #expect(CloudflaredManifest.expectedEntryName == "cloudflared")
        #expect(CloudflaredManifest.allowedDownloadHosts.contains("github.com"))
        #expect(CloudflaredManifest.allowedDownloadHosts.contains("release-assets.githubusercontent.com"))
        #expect(CloudflaredManifest.allowedDownloadHosts.contains("objects.githubusercontent.com"))
    }

    @Test func downloadSizeCopyIsRoundedMegabytes() throws {
        let arm = try #require(CloudflaredManifest.artifact(for: .arm64))
        let intel = try #require(CloudflaredManifest.artifact(for: .amd64))
        #expect(arm.approximateDownloadSize == "20 MB")
        #expect(intel.approximateDownloadSize == "22 MB")
    }

    @Test func hostArchitectureComesFromHardwareNotBuildFlags() {
        #expect(CloudflaredManifest.architecture(isARM64Hardware: true, machine: "x86_64") == .arm64)
        #expect(CloudflaredManifest.architecture(isARM64Hardware: false, machine: "x86_64") == .amd64)
        #expect(CloudflaredManifest.architecture(isARM64Hardware: false, machine: "arm64e") == .arm64)
        #expect(CloudflaredManifest.architecture(isARM64Hardware: false, machine: "riscv64") == nil)
        #expect(CloudflaredManifest.architecture(isARM64Hardware: false, machine: nil) == nil)
        // Every Mac this app can run on resolves to a pinned artifact.
        #expect(CloudflaredManifest.current != nil)
    }

    @Test func unknownArchitectureFailsWithAPlainLanguageReason() {
        let failure = CloudflaredInstallFailure.unsupportedHardware
        #expect(failure.message.contains("processor"))
        #expect(!failure.message.contains("arm64"))
    }

    // MARK: - Redirect allowlist

    @Test func onlyCloudflareReleaseHostsOverHTTPSAreFollowed() {
        #expect(CloudflaredManifest.isAllowedDownloadURL(URL(string: "https://github.com/x")!))
        #expect(CloudflaredManifest.isAllowedDownloadURL(URL(string: "https://release-assets.githubusercontent.com/x?token=redacted")!))
        #expect(CloudflaredManifest.isAllowedDownloadURL(URL(string: "https://objects.githubusercontent.com/x")!))
        #expect(CloudflaredManifest.isAllowedDownloadURL(URL(string: "HTTPS://GitHub.com/x")!))

        #expect(!CloudflaredManifest.isAllowedDownloadURL(URL(string: "http://github.com/x")!))
        #expect(!CloudflaredManifest.isAllowedDownloadURL(URL(string: "https://github.com.evil.test/x")!))
        #expect(!CloudflaredManifest.isAllowedDownloadURL(URL(string: "https://evil.test/github.com")!))
        #expect(!CloudflaredManifest.isAllowedDownloadURL(URL(string: "file:///etc/passwd")!))
        #expect(!CloudflaredManifest.isAllowedDownloadURL(nil))
    }

    // MARK: - Downloader

    @Test func downloadKeepsOnlyAnExactlySizedTransfer() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive))
        let progress = ProgressRecorder()
        try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
            .download(artifact: fixture.artifact, to: destination) { progress.record($0) }

        let downloaded = try Data(contentsOf: destination)
        #expect(downloaded == Data(fixture.archive))
        #expect(progress.highWaterMark == 1)
        #expect(CloudflaredDownloadProtocolMock.requestedURLs() == [fixture.artifact.downloadURL])
    }

    @Test func truncatedDownloadIsDiscarded() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive.dropLast(16)))
        await #expect(throws: CloudflaredDownloadError.sizeMismatch(
            expected: fixture.artifact.archiveByteCount,
            actual: fixture.artifact.archiveByteCount - 16
        )) {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func oversizeDownloadIsRefusedBeforeItIsKept() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive + [UInt8](repeating: 0, count: 4096)))
        var caught: (any Error)?
        do {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        } catch {
            caught = error
        }
        // Deterministic under this stub: a `URLProtocol`-backed download reports
        // no incremental `didWriteData`, so the delegate's streaming cap never
        // gets a chance to fire and the exact-size check is what refuses. Either
        // way, nothing oversized reaches the destination.
        #expect(
            try #require(caught as? CloudflaredDownloadError) == .sizeMismatch(
                expected: fixture.artifact.archiveByteCount,
                actual: fixture.artifact.archiveByteCount + 4096
            )
        )
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func downloadFromADisallowedHostNeverLeavesTheApp() async throws {
        let fixture = SyntheticRelease.good(host: "evil.test")
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive))
        await #expect(throws: CloudflaredDownloadError.blockedURL("evil.test")) {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        }
        #expect(CloudflaredDownloadProtocolMock.requestedURLs().isEmpty)
    }

    @Test func nonSuccessStatusIsReportedTruthfully() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(body: Data(), statusCode: 503)
        await #expect(throws: CloudflaredDownloadError.badStatus(503)) {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        }
    }

    @Test func interruptedTransferReportsTheTransportFailure() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(body: Data(), failure: URLError(.networkConnectionLost))
        var caught: (any Error)?
        do {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        } catch {
            caught = error
        }
        guard case .transport = try #require(caught as? CloudflaredDownloadError) else {
            Issue.record("Expected a transport failure.")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func cancellationIsNotReportedAsATamperedDownload() {
        #expect(CloudflaredManager.failure(for: CancellationError()) == .cancelled)
        #expect(CloudflaredManager.failure(for: CloudflaredDownloadError.cancelled) == .cancelled)
        #expect(
            CloudflaredManager.failure(for: CloudflaredArchiveError.archiveHashMismatch)
                == .notWhatCloudflarePublished(CloudflaredArchiveError.archiveHashMismatch.localizedDescription)
        )
    }

    // MARK: - Archive extraction

    @Test func aGoodArchiveUnpacksToAnOwnerOnlyExecutable() throws {
        let fixture = SyntheticRelease.good()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archiveURL = scratch.appendingPathComponent("cloudflared.tgz")
        try Data(fixture.archive).write(to: archiveURL)
        let destination = scratch.appendingPathComponent("cloudflared")

        try CloudflaredArchiveExtractor.extract(
            archiveAt: archiveURL,
            artifact: fixture.artifact,
            to: destination,
            signatureReader: StubSignatureReader.cloudflare
        )

        let unpacked = try Data(contentsOf: destination)
        #expect(unpacked == Data(fixture.payload))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o500)
    }

    @Test func everyRejectedArchiveShapeIsRefusedAndLeavesNothingBehind() throws {
        let payload = SyntheticRelease.defaultPayload
        let cases: [(String, [UInt8])] = [
            ("symlink entry", syntheticTar([SyntheticTarEntry(payload: payload, typeFlag: UInt8(ascii: "2"), linkName: "/usr/bin/env")])),
            ("hard link entry", syntheticTar([SyntheticTarEntry(payload: payload, typeFlag: UInt8(ascii: "1"), linkName: "cloudflared")])),
            ("directory entry", syntheticTar([SyntheticTarEntry(payload: [], typeFlag: UInt8(ascii: "5"))])),
            ("path traversal name", syntheticTar([SyntheticTarEntry(name: "../../cloudflared", payload: payload)])),
            ("prefixed path", syntheticTar([SyntheticTarEntry(payload: payload, prefix: "usr/local/bin")])),
            ("PAX extended header", syntheticTar([SyntheticTarEntry(payload: payload, typeFlag: UInt8(ascii: "x"))])),
            ("PAX global header", syntheticTar([SyntheticTarEntry(payload: payload, typeFlag: UInt8(ascii: "g"))])),
            ("GNU long name", syntheticTar([SyntheticTarEntry(payload: payload, typeFlag: UInt8(ascii: "L"))])),
            ("GNU long link", syntheticTar([SyntheticTarEntry(payload: payload, typeFlag: UInt8(ascii: "K"))])),
            ("GNU magic", syntheticTar([SyntheticTarEntry(payload: payload, magicTerminator: UInt8(ascii: " "), version: [0x20, 0x20])])),
            ("second entry", syntheticTar([
                SyntheticTarEntry(payload: payload),
                SyntheticTarEntry(name: "extra", payload: Array("gotcha".utf8))
            ])),
            ("wrong checksum", syntheticTar([SyntheticTarEntry(payload: payload, breakChecksum: true)])),
            ("declared size mismatch", syntheticTar([SyntheticTarEntry(payload: payload, declaredSize: payload.count - 8)]))
        ]

        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        for (label, tar) in cases {
            let archive = syntheticGzip(tar)
            // The manifest still describes the *good* release, which is the
            // point: only the published shape is accepted.
            let artifact = SyntheticRelease.artifact(
                archive: archive,
                payload: payload,
                tarByteCount: tar.count
            )
            let archiveURL = scratch.appendingPathComponent("\(UUID().uuidString).tgz")
            try Data(archive).write(to: archiveURL)
            let destination = scratch.appendingPathComponent("out-\(UUID().uuidString)")

            #expect(throws: (any Error).self, "\(label) must be rejected") {
                try CloudflaredArchiveExtractor.extract(
                    archiveAt: archiveURL,
                    artifact: artifact,
                    to: destination,
                    signatureReader: StubSignatureReader.cloudflare
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path), "\(label) left a file behind")
        }
    }

    @Test func archiveThatDoesNotMatchThePublishedChecksumIsNeverOpened() throws {
        let fixture = SyntheticRelease.good()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archiveURL = scratch.appendingPathComponent("cloudflared.tgz")
        try Data(fixture.archive).write(to: archiveURL)
        let destination = scratch.appendingPathComponent("cloudflared")

        var tampered = fixture.artifact
        tampered = CloudflaredArtifact(
            architecture: tampered.architecture,
            downloadURL: tampered.downloadURL,
            archiveSHA256: String(repeating: "a", count: 64),
            archiveByteCount: tampered.archiveByteCount,
            executableSHA256: tampered.executableSHA256,
            executableByteCount: tampered.executableByteCount,
            uncompressedTarByteCount: tampered.uncompressedTarByteCount
        )

        #expect(throws: CloudflaredArchiveError.archiveHashMismatch) {
            try CloudflaredArchiveExtractor.extract(
                archiveAt: archiveURL,
                artifact: tampered,
                to: destination,
                signatureReader: StubSignatureReader.cloudflare
            )
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func unpackedBinaryMustMatchThePublishedChecksumAndSignature() throws {
        let fixture = SyntheticRelease.good()
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let archiveURL = scratch.appendingPathComponent("cloudflared.tgz")
        try Data(fixture.archive).write(to: archiveURL)

        let wrongHash = CloudflaredArtifact(
            architecture: fixture.artifact.architecture,
            downloadURL: fixture.artifact.downloadURL,
            archiveSHA256: fixture.artifact.archiveSHA256,
            archiveByteCount: fixture.artifact.archiveByteCount,
            executableSHA256: String(repeating: "b", count: 64),
            executableByteCount: fixture.artifact.executableByteCount,
            uncompressedTarByteCount: fixture.artifact.uncompressedTarByteCount
        )
        let hashDestination = scratch.appendingPathComponent("hash-out")
        #expect(throws: CloudflaredArchiveError.executableHashMismatch) {
            try CloudflaredArchiveExtractor.extract(
                archiveAt: archiveURL,
                artifact: wrongHash,
                to: hashDestination,
                signatureReader: StubSignatureReader.cloudflare
            )
        }
        #expect(!FileManager.default.fileExists(atPath: hashDestination.path))

        for reader in [StubSignatureReader.unsigned, .adhoc, .otherDeveloper] {
            let destination = scratch.appendingPathComponent("sig-\(UUID().uuidString)")
            #expect(throws: (any Error).self) {
                try CloudflaredArchiveExtractor.extract(
                    archiveAt: archiveURL,
                    artifact: fixture.artifact,
                    to: destination,
                    signatureReader: reader
                )
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func inflateStopsAtThePublishedUncompressedSize() throws {
        let payload = [UInt8](repeating: 0x41, count: 40_000)
        let tar = syntheticTar([SyntheticTarEntry(payload: payload)])
        let archive = syntheticGzip(tar)
        // A compressed blob that claims to expand to far less than it does.
        #expect(throws: CloudflaredArchiveError.inflateOverflow) {
            _ = try CloudflaredArchiveExtractor.gunzip(archive, maxOutputByteCount: 2048)
        }
    }

    @Test func gzipTrailerAndContainerAreBothChecked() throws {
        let tar = syntheticTar([SyntheticTarEntry(payload: SyntheticRelease.defaultPayload)])
        var archive = syntheticGzip(tar)

        #expect(throws: CloudflaredArchiveError.notGzip) {
            _ = try CloudflaredArchiveExtractor.gunzip(Array("not a gzip file at all, not even close".utf8), maxOutputByteCount: 4096)
        }

        archive[archive.count - 8] ^= 0xFF   // corrupt the CRC-32
        #expect(throws: CloudflaredArchiveError.gzipTrailerMismatch("the CRC-32 does not match the archive")) {
            _ = try CloudflaredArchiveExtractor.gunzip(archive, maxOutputByteCount: tar.count)
        }
    }

    // MARK: - Install store

    @Test func commitPublishesOwnerOnlyFilesAndAProvableRecord() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        let record = try installFixture(into: store)

        #expect(mode(of: store.rootDirectory) == 0o700)
        #expect(mode(of: store.binaryDirectory) == 0o700)
        #expect(mode(of: store.binaryURL) == 0o500)
        #expect(mode(of: store.recordURL) == 0o600)
        #expect(store.installedRecord() == record)
        let verified = try store.verifyInstalledBinary(signatureReader: StubSignatureReader.cloudflare)
        #expect(verified == record)
    }

    @Test func aChangedBinaryIsQuarantinedInsteadOfLaunched() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.binaryURL.path)
        try Data("tampered".utf8).write(to: store.binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.binaryURL.path)

        #expect(throws: (any Error).self) {
            _ = try store.verifyInstalledBinary(signatureReader: StubSignatureReader.cloudflare)
        }
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
        #expect(store.installedRecord() == nil)
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: store.quarantineDirectory.path)
        #expect(quarantined.count == 1)
    }

    @Test func aBinaryWithLoosePermissionsIsQuarantined() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.binaryURL.path)

        #expect(throws: (any Error).self) {
            _ = try store.verifyInstalledBinary(signatureReader: StubSignatureReader.cloudflare)
        }
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
    }

    @Test func aFailedRecordWriteRollsTheInstallBack() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        // A directory where install.json belongs makes the record write fail.
        try FileManager.default.createDirectory(at: store.rootDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: store.recordURL, withIntermediateDirectories: true)

        let staging = try store.prepareStagingDirectory()
        let staged = staging.appendingPathComponent("cloudflared")
        try Data(SyntheticRelease.defaultPayload).write(to: staged)

        #expect(throws: (any Error).self) {
            try store.commit(stagedExecutable: staged, record: SyntheticRelease.record)
        }
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
        #expect(store.installedRecord() == nil)
    }

    @Test func removalTouchesOnlyMacRemotesOwnFolder() throws {
        let store = try makeIsolatedStore()
        let container = store.rootDirectory.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: container) }
        _ = try installFixture(into: store)

        let neighbour = container.appendingPathComponent("tools.json")
        try Data("[]".utf8).write(to: neighbour)
        let externalHelper = container.appendingPathComponent("brew-cloudflared")
        try Data("#!/bin/sh\n".utf8).write(to: externalHelper)

        try store.remove()

        #expect(!FileManager.default.fileExists(atPath: store.rootDirectory.path))
        #expect(FileManager.default.fileExists(atPath: neighbour.path))
        #expect(FileManager.default.fileExists(atPath: externalHelper.path))
    }

    @Test func removalRefusesAFolderItDoesNotOwn() throws {
        let container = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let store = CloudflaredInstallStore(rootDirectory: container)

        #expect(throws: (any Error).self) {
            try store.remove()
        }
        #expect(FileManager.default.fileExists(atPath: container.path))
    }

    @Test func staleStagingFromAnInterruptedInstallIsCleared() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        let first = try store.prepareStagingDirectory()
        try Data("half a download".utf8).write(to: first.appendingPathComponent("cloudflared.tgz"))

        let second = try store.prepareStagingDirectory()

        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        let staging = try FileManager.default.contentsOfDirectory(atPath: store.stagingRootDirectory.path)
        #expect(staging == [second.lastPathComponent])
    }

    @Test func integrityKeyChangesWhenTheFileDoes() throws {
        let scratch = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("cloudflared")
        try Data("one".utf8).write(to: file)
        let first = CloudflaredInstallStore.integrityKey(forFileAt: file)

        try Data("one and a bit more".utf8).write(to: file)
        let second = CloudflaredInstallStore.integrityKey(forFileAt: file)

        #expect(first != nil)
        #expect(first != second)
        #expect(CloudflaredInstallStore.integrityKey(forFileAt: scratch.appendingPathComponent("missing")) == nil)
    }

    // MARK: - Precedence

    @Test func aRunningTunnelPinsItsExecutableAheadOfEverythingElse() {
        #expect(
            TunnelService.resolvedExecutablePath(launched: "/pinned", session: "/session", external: { "/external" })
                == "/pinned"
        )
        #expect(
            TunnelService.resolvedExecutablePath(launched: nil, session: "/session", external: { "/external" })
                == "/session"
        )
        #expect(
            TunnelService.resolvedExecutablePath(launched: nil, session: nil, external: { "/external" })
                == "/external"
        )
        #expect(
            TunnelService.resolvedExecutablePath(launched: nil, session: nil, external: { nil }) == nil
        )
    }

    @Test func aSupervisedSessionKeepsRelaunchingTheSameExecutable() throws {
        let resolved = MutableBox("/usr/bin/true")
        let service = TunnelService(resolveCloudflared: { resolved.value })
        #expect(service.cloudflaredPath() == "/usr/bin/true")

        try service.startQuickTunnel(localServerURL: URL(string: "http://127.0.0.1:61234")!) { _ in }
        // A helper installed mid-session must not change the executable a
        // watchdog restart would relaunch.
        resolved.value = "/usr/bin/false"
        #expect(service.cloudflaredPath() == "/usr/bin/true")

        service.stop()
        #expect(service.cloudflaredPath() == "/usr/bin/true")

        service.clearSessionPin()
        #expect(service.cloudflaredPath() == "/usr/bin/false")
    }

    @MainActor
    @Test func managedHelperOutranksAnExternalOneAndRemovalFallsBack() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        let record = try installFixture(into: store)

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { "/opt/homebrew/bin/cloudflared" },
            signatureReader: StubSignatureReader.cloudflare
        )

        #expect(manager.resolvedExecutablePath() == store.binaryURL.path)
        manager.refresh()
        let ready = await waitForState(manager) { if case .ready = $0 { true } else { false } }
        #expect(ready == .ready(version: record.version, source: .managed(store.binaryURL.path)))

        #expect(manager.remove() == nil)
        #expect(manager.resolvedExecutablePath() == "/opt/homebrew/bin/cloudflared")
        let external = await waitForState(manager) { $0.source?.isManaged == false }
        #expect(external == .ready(version: nil, source: .external("/opt/homebrew/bin/cloudflared")))
    }

    @MainActor
    @Test func aTamperedManagedCopyFallsBackInsteadOfLaunching() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { "/opt/homebrew/bin/cloudflared" },
            signatureReader: StubSignatureReader.cloudflare
        )
        #expect(manager.resolvedExecutablePath() == store.binaryURL.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: store.binaryURL.path)
        try Data("tampered".utf8).write(to: store.binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.binaryURL.path)

        #expect(manager.resolvedExecutablePath() == "/opt/homebrew/bin/cloudflared")
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
    }

    @MainActor
    @Test func aFullInstallDownloadsVerifiesAndPublishesTheHelper() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        let fixture = SyntheticRelease.good()
        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive))

        let manager = CloudflaredManager(
            store: store,
            downloader: CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session()),
            externalResolver: { nil },
            artifactProvider: { fixture.artifact },
            signatureReader: StubSignatureReader.cloudflare
        )

        manager.install()
        // Single-flight: a second tap while one install runs does nothing.
        manager.install()

        let state = await waitForState(manager) { if case .ready = $0 { true } else { false } }
        #expect(state == .ready(version: CloudflaredManifest.version, source: .managed(store.binaryURL.path)))
        #expect(manager.resolvedExecutablePath() == store.binaryURL.path)
        let installed = try Data(contentsOf: store.binaryURL)
        #expect(installed == Data(fixture.payload))
        #expect(mode(of: store.binaryURL) == 0o500)
        #expect(CloudflaredDownloadProtocolMock.requestedURLs().count == 1)
        // Nothing is left in staging once the install lands.
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: store.stagingRootDirectory.path)) ?? []
        #expect(staging.isEmpty)
    }

    @MainActor
    @Test func anInstallThatDoesNotMatchTheReleaseKeepsNothing() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        let fixture = SyntheticRelease.good()
        var corrupted = fixture.archive
        corrupted[corrupted.count / 2] ^= 0xFF
        CloudflaredDownloadProtocolMock.install(body: Data(corrupted))

        let manager = CloudflaredManager(
            store: store,
            downloader: CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session()),
            externalResolver: { nil },
            artifactProvider: { fixture.artifact },
            signatureReader: StubSignatureReader.cloudflare
        )

        manager.install()
        let state = await waitForState(manager) { if case .failed = $0 { true } else { false } }
        guard case .failed(let failure) = state else {
            Issue.record("Expected a failed install, got \(state).")
            return
        }
        guard case .notWhatCloudflarePublished = failure else {
            Issue.record("Expected a mismatch failure, got \(failure).")
            return
        }
        #expect(failure.message.contains("discarded"))
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
        #expect(store.installedRecord() == nil)
        #expect(manager.resolvedExecutablePath() == nil)
    }

    @MainActor
    @Test func removalIsRefusedWhileTheTunnelIsRunning() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        manager.setTunnelRunningCheck { true }

        let refusal = manager.remove()
        #expect(refusal?.contains("public link") == true)
        #expect(FileManager.default.fileExists(atPath: store.binaryURL.path))
    }

    @MainActor
    @Test func aNewerPinnedVersionIsOfferedWithoutAnyNetworkCall() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store, version: "2026.1.1")

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        manager.refresh()

        let state = await waitForState(manager) { if case .updateAvailable = $0 { true } else { false } }
        #expect(state == .updateAvailable(
            installed: "2026.1.1",
            available: CloudflaredManifest.version,
            source: .managed(store.binaryURL.path)
        ))
    }

    @MainActor
    @Test func nothingInstalledAnywhereIsReportedAsNotInstalled() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        manager.refresh()

        let state = await waitForState(manager) { $0 == .notInstalled }
        #expect(state == .notInstalled)
        #expect(manager.resolvedExecutablePath() == nil)
    }

    // MARK: - AppModel wiring

    @MainActor
    @Test func aMissingHelperBlocksReadinessTruthfully() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        let model = try makeIsolatedAppModel(
            userDefaults: defaults,
            manager: CloudflaredManager(
                store: store,
                externalResolver: { nil },
                signatureReader: StubSignatureReader.cloudflare
            )
        )

        #expect(model.tunnelStatus == .unavailable)
        let check = try #require(model.connectionReadiness.first { $0.id == "public-tunnel" })
        #expect(check.status == .blocked)
        #expect(check.detail == "Cloudflare's helper isn't installed.")
    }

    @MainActor
    @Test func installingTheHelperClearsTheBlockWithoutAnotherButton() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        let model = try makeIsolatedAppModel(userDefaults: defaults, manager: manager)
        #expect(model.connectionReadiness.contains { $0.id == "public-tunnel" && $0.status == .blocked })

        _ = try installFixture(into: store)
        model.refreshCloudflaredHelper()

        #expect(model.tunnelStatus != .unavailable)
        let check = try #require(model.connectionReadiness.first { $0.id == "public-tunnel" })
        #expect(check.status == .waiting)
    }

    @MainActor
    @Test func theManagedHelperNeverEntersToolDiscovery() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        // App infrastructure, not a shareable tool: the managed folder must not
        // be on the executable search path, and no preset may point at it.
        #expect(!ExecutableLocator.searchDirectories.contains(store.binaryDirectory.path))
        #expect(!DefaultToolPresetCatalog.presets.contains {
            $0.executablePath.contains(CloudflaredInstallStore.directoryName)
        })
    }

    @MainActor
    @Test func theTunnelAndCloudflareServicesShareTheInjectedResolver() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        let model = try makeIsolatedAppModel(userDefaults: defaults, manager: manager)

        #expect(model.cloudflaredManager === manager)
        #expect(model.tunnelStatus != .unavailable)
    }

    @MainActor
    @Test func theCloudflareServiceLaunchesTheManagedHelper() throws {
        let defaults = try makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName(defaults)) }
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        let manager = CloudflaredManager(
            store: store,
            externalResolver: { "/opt/homebrew/bin/cloudflared" },
            signatureReader: StubSignatureReader.cloudflare
        )
        let model = try makeIsolatedAppModel(userDefaults: defaults, manager: manager)

        // Both launching services resolve through the injected manager, not
        // through PATH: the managed copy outranks the Homebrew one.
        #expect(model.cloudflareServiceHelperPathForTesting() == store.binaryURL.path)
        #expect(model.tunnelServiceHelperPathForTesting() == store.binaryURL.path)

        #expect(manager.remove() == nil)

        // MacRemote removed only its own copy, so both services fall back to the
        // one the user installed rather than reporting nothing.
        #expect(model.cloudflareServiceHelperPathForTesting() == "/opt/homebrew/bin/cloudflared")
        #expect(model.tunnelServiceHelperPathForTesting() == "/opt/homebrew/bin/cloudflared")
        #expect(!FileManager.default.fileExists(atPath: store.rootDirectory.path))
    }

    // MARK: - Pinned release facts

    /// The whole managed-helper design rests on these numbers. If a version bump
    /// ever lands without re-deriving them, this fails loudly instead of the app
    /// quietly trusting a different build.
    @Test func thePinnedManifestMatchesTheReviewedRelease() throws {
        #expect(CloudflaredManifest.version == "2026.10.3")
        #expect(CloudflaredManifest.releaseDate == "2026-10-21")

        let arm = try #require(CloudflaredManifest.artifact(for: .arm64))
        #expect(arm.archiveSHA256 == "1165d14b6f6360a3b8c283d7d1100024d6ec7cd9bc9e32519e96150645f3ec55")
        #expect(arm.archiveByteCount == 19_841_881)
        #expect(arm.executableSHA256 == "f249139e0541fa589c987397d867cc16c83ab1236d31eb6782f2e4552ee9cf80")
        #expect(arm.executableByteCount == 39_533_376)
        #expect(arm.uncompressedTarByteCount == 39_535_104)

        let intel = try #require(CloudflaredManifest.artifact(for: .amd64))
        #expect(intel.archiveSHA256 == "81b7b85f2376815c4f59b1aa323887b62e16ce8b67555c2e1577dc23f2a82000")
        #expect(intel.archiveByteCount == 21_823_395)
        #expect(intel.executableSHA256 == "947e2942d6a59922d80190d23b12f3ade8da16e23e3bd937182a48993b7c00db")
        #expect(intel.executableByteCount == 42_468_448)
        #expect(intel.uncompressedTarByteCount == 42_470_400)

        // Accepted executables are exactly these two plus the ones earlier
        // releases installed, and nothing else.
        #expect(CloudflaredInstallStore.pinnedExecutableDigests == Set([
            arm.executableSHA256,
            intel.executableSHA256
        ]).union(CloudflaredManifest.earlierExecutableSHA256))
    }

    // MARK: - Redirects

    @Test func aRedirectToADisallowedHostIsRefusedMidTransfer() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        CloudflaredDownloadProtocolMock.install(
            body: Data(fixture.archive),
            redirectTo: "https://evil.test/x.tgz"
        )
        await #expect(throws: CloudflaredDownloadError.blockedRedirect("evil.test")) {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        }
        // The move was never followed and nothing landed on disk.
        #expect(CloudflaredDownloadProtocolMock.requestedURLs() == [fixture.artifact.downloadURL])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func aRedirectToPlainHTTPIsRefused() async throws {
        let fixture = SyntheticRelease.good()
        let destination = try makeScratchFile()
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        // An allowlisted host is not enough: downgrading the scheme is refused.
        CloudflaredDownloadProtocolMock.install(
            body: Data(fixture.archive),
            redirectTo: "http://github.com/cloudflare/cloudflared/x.tgz"
        )
        await #expect(throws: CloudflaredDownloadError.blockedRedirect("github.com")) {
            try await CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session())
                .download(artifact: fixture.artifact, to: destination) { _ in }
        }
        #expect(CloudflaredDownloadProtocolMock.requestedURLs() == [fixture.artifact.downloadURL])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Cancel, fail, retry

    @MainActor
    @Test func cancellingAnInstallLeavesNothingBehindAndAllowsARetry() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        let fixture = SyntheticRelease.good()
        // The body is held back so Cancel lands while bytes are in flight.
        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive), bodyDelay: 5)

        let manager = CloudflaredManager(
            store: store,
            downloader: CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session()),
            externalResolver: { nil },
            artifactProvider: { fixture.artifact },
            signatureReader: StubSignatureReader.cloudflare
        )

        manager.install()
        try await waitUntil { !CloudflaredDownloadProtocolMock.requestedURLs().isEmpty }
        manager.cancelInstall()

        let cancelled = await waitForState(manager) { if case .failed = $0 { true } else { false } }
        #expect(cancelled == .failed(.cancelled))
        #expect(CloudflaredInstallFailure.cancelled.message.contains("Nothing was kept"))
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
        #expect(store.installedRecord() == nil)
        let staging = (try? FileManager.default.contentsOfDirectory(atPath: store.stagingRootDirectory.path)) ?? []
        #expect(staging.isEmpty)

        // Single-flight released: the very next attempt is allowed to run.
        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive))
        manager.install()
        let ready = await waitForState(manager) { if case .ready = $0 { true } else { false } }
        #expect(ready == .ready(version: CloudflaredManifest.version, source: .managed(store.binaryURL.path)))
        #expect(try Data(contentsOf: store.binaryURL) == Data(fixture.payload))
    }

    @MainActor
    @Test func aFailedInstallCanBeRetriedSuccessfully() async throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        let fixture = SyntheticRelease.good()
        var corrupted = fixture.archive
        corrupted[corrupted.count / 2] ^= 0xFF
        CloudflaredDownloadProtocolMock.install(body: Data(corrupted))

        let manager = CloudflaredManager(
            store: store,
            downloader: CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session()),
            externalResolver: { nil },
            artifactProvider: { fixture.artifact },
            signatureReader: StubSignatureReader.cloudflare
        )

        manager.install()
        let failed = await waitForState(manager) { if case .failed = $0 { true } else { false } }
        guard case .failed(.notWhatCloudflarePublished) = failed else {
            Issue.record("Expected a mismatch failure, got \(failed).")
            return
        }

        // A failure must not wedge the single-flight guard.
        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive))
        manager.install()
        let ready = await waitForState(manager) { if case .ready = $0 { true } else { false } }
        #expect(ready == .ready(version: CloudflaredManifest.version, source: .managed(store.binaryURL.path)))
        #expect(manager.resolvedExecutablePath() == store.binaryURL.path)
        #expect(CloudflaredDownloadProtocolMock.requestedURLs().count == 1)
    }

    @MainActor
    @Test func installIsRefusedWhileTheTunnelRuns() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        let fixture = SyntheticRelease.good()
        CloudflaredDownloadProtocolMock.install(body: Data(fixture.archive))

        let manager = CloudflaredManager(
            store: store,
            downloader: CloudflaredDownloader(session: CloudflaredDownloadProtocolMock.session()),
            externalResolver: { nil },
            artifactProvider: { fixture.artifact },
            signatureReader: StubSignatureReader.cloudflare
        )
        manager.setTunnelRunningCheck { true }

        manager.install()

        // Synchronous refusal: the state is already final, nothing was fetched,
        // and no staging folder was ever created.
        #expect(manager.state == .failed(.tunnelRunning))
        #expect(CloudflaredInstallFailure.tunnelRunning.message.contains("public link"))
        #expect(CloudflaredInstallFailure.tunnelRunning.detail == nil)
        #expect(CloudflaredDownloadProtocolMock.requestedURLs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.stagingRootDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
    }

    // MARK: - Downgrade to an unpinned build (M1)

    @MainActor
    @Test func aDowngradeToAnUnpinnedSignedBinaryIsQuarantined() async throws {
        let container = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let store = CloudflaredInstallStore(
            rootDirectory: container.appendingPathComponent(
                CloudflaredInstallStore.directoryName,
                isDirectory: true
            ),
            expectedExecutableDigests: [
                CloudflaredInstallStore.sha256(of: Data(SyntheticRelease.defaultPayload))
            ]
        )

        // An older, still validly signed cloudflared, with an install.json that
        // describes it perfectly: right size, right digest, right mode. The only
        // thing wrong with it is that this build never published that digest.
        let older = Array("an older, validly signed cloudflared build\n".utf8)
        let staging = try store.prepareStagingDirectory()
        let staged = staging.appendingPathComponent("cloudflared")
        try Data(older).write(to: staged)
        let record = CloudflaredInstallRecord(
            version: "2025.1.1",
            architecture: .arm64,
            executableSHA256: CloudflaredInstallStore.sha256(of: Data(older)),
            byteCount: older.count,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sourceURL: "https://github.com/cloudflare/cloudflared/releases/download/2025.1.1/cloudflared-darwin-arm64.tgz"
        )
        try store.commit(stagedExecutable: staged, record: record)
        store.discardStagingDirectory(staging)
        #expect(store.installedRecord() == record)

        var caught: (any Error)?
        do {
            _ = try store.verifyInstalledBinary(signatureReader: StubSignatureReader.cloudflare)
        } catch {
            caught = error
        }
        guard case .integrityMismatch(let detail) = try #require(caught as? CloudflaredInstallStoreError) else {
            Issue.record("Expected an integrity mismatch, got \(String(describing: caught)).")
            return
        }
        #expect(detail.contains("not one MacRemote published"))
        #expect(!FileManager.default.fileExists(atPath: store.binaryURL.path))
        #expect(store.installedRecord() == nil)

        let quarantined = try FileManager.default.contentsOfDirectory(atPath: store.quarantineDirectory.path)
        #expect(quarantined.count == 1)
        let reason = try String(
            contentsOf: store.quarantineDirectory
                .appendingPathComponent(try #require(quarantined.first), isDirectory: true)
                .appendingPathComponent("reason.txt"),
            encoding: .utf8
        )
        #expect(reason.contains("changed since it was installed"))

        // Recoverable, not bricked: the folder still accepts a pinned install.
        let manager = CloudflaredManager(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        #expect(manager.resolvedExecutablePath() == nil)
        manager.refresh()
        #expect(await waitForState(manager) { $0 == .notInstalled } == .notInstalled)

        let recovered = try installFixture(into: store)
        manager.refresh()
        let ready = await waitForState(manager) { if case .ready = $0 { true } else { false } }
        #expect(ready == .ready(version: recovered.version, source: .managed(store.binaryURL.path)))
    }

    // MARK: - Status is cheap, launch is proven

    @Test func statusResolutionNeverHashes() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: store)

        let reader = CountingSignatureReader()
        let core = CloudflaredResolutionCore(
            store: store,
            externalResolver: { "/opt/homebrew/bin/cloudflared" },
            signatureReader: reader
        )

        // Cold cache. The status answer is four stat-class calls, so the
        // signature reader is never consulted.
        #expect(core.cachedExecutablePath() == store.binaryURL.path)
        #expect(core.cachedExecutablePath() == store.binaryURL.path)
        #expect(reader.callCount == 0)

        // The launch answer proves the bytes, which does read the signature.
        #expect(core.resolvedExecutablePath() == store.binaryURL.path)
        #expect(reader.callCount == 1)

        // Second store, tampered so that only a real hash can tell: same length,
        // same mode, same recorded size — different bytes.
        let tamperedStore = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: tamperedStore.rootDirectory.deletingLastPathComponent()) }
        _ = try installFixture(into: tamperedStore)
        var swapped = SyntheticRelease.defaultPayload
        swapped[swapped.count / 2] ^= 0xFF
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tamperedStore.binaryURL.path)
        try Data(swapped).write(to: tamperedStore.binaryURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tamperedStore.binaryURL.path)

        let tamperedReader = CountingSignatureReader()
        let tamperedCore = CloudflaredResolutionCore(
            store: tamperedStore,
            externalResolver: { "/opt/homebrew/bin/cloudflared" },
            signatureReader: tamperedReader
        )
        // Status still reports the managed copy — proof that it did not hash.
        #expect(tamperedCore.cachedExecutablePath() == tamperedStore.binaryURL.path)
        #expect(tamperedReader.callCount == 0)
        // Launch hashes, refuses, quarantines, and falls back.
        #expect(tamperedCore.resolvedExecutablePath() == "/opt/homebrew/bin/cloudflared")
        #expect(!FileManager.default.fileExists(atPath: tamperedStore.binaryURL.path))
    }

    @Test func aSessionPinThatFailsVerificationAbortsTheRelaunch() throws {
        let verifies = MutableFlag(true)
        let resolved = MutableBox("/usr/bin/true")
        let launchLookups = CallCounter()
        let service = TunnelService(resolver: TunnelService.CloudflaredResolver(
            status: { resolved.value },
            launch: {
                launchLookups.increment()
                return resolved.value
            },
            verify: { _ in verifies.value }
        ))
        let localURL = URL(string: "http://127.0.0.1:61234")!

        try service.startQuickTunnel(localServerURL: localURL) { _ in }
        service.stop()
        #expect(service.sessionExecutablePin() == "/usr/bin/true")
        #expect(launchLookups.count == 1)

        // The managed copy stopped verifying mid-session, and a different
        // executable is now resolvable. Neither fact may start a tunnel.
        verifies.value = false
        resolved.value = "/usr/bin/false"

        var caught: (any Error)?
        do {
            try service.startQuickTunnel(localServerURL: localURL) { _ in }
        } catch {
            caught = error
        }
        guard case .helperNoLongerVerified = try #require(caught as? TunnelServiceError) else {
            Issue.record("Expected helperNoLongerVerified, got \(String(describing: caught)).")
            return
        }
        // No substitution: the launch resolver was never even asked for today's
        // answer, and the pin is still the copy the session started with.
        #expect(launchLookups.count == 1)
        #expect(service.sessionExecutablePin() == "/usr/bin/true")

        service.clearSessionPin()
        service.stop()
    }

    @Test func staleStagingIsClearedOnResolveButFreshStagingSurvives() throws {
        let store = try makeIsolatedStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory.deletingLastPathComponent()) }

        try FileManager.default.createDirectory(
            at: store.stagingRootDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let stale = store.stagingRootDirectory.appendingPathComponent("stale", isDirectory: true)
        let fresh = store.stagingRootDirectory.appendingPathComponent("fresh", isDirectory: true)
        for directory in [stale, fresh] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("half a download".utf8).write(to: directory.appendingPathComponent("cloudflared.tgz"))
        }
        let aged = Date().addingTimeInterval(-CloudflaredResolutionCore.staleStagingAge - 60)
        try FileManager.default.setAttributes(
            [.modificationDate: aged, .creationDate: aged],
            ofItemAtPath: stale.path
        )

        // The detached resolve path is the one that sweeps.
        let core = CloudflaredResolutionCore(
            store: store,
            externalResolver: { nil },
            signatureReader: StubSignatureReader.cloudflare
        )
        _ = core.resolve()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        // A transfer that is running right now is never touched.
        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(CloudflaredResolutionCore.staleStagingAge == 15 * 60)
    }

    // MARK: - Copy

    @Test func helperCopyStaysInPlainLanguage() {
        let strings = [
            TunnelServiceError.cloudflaredUnavailable.localizedDescription,
            CloudflareServiceError.cloudflaredUnavailable.localizedDescription,
            CloudflaredHelperState.notInstalled.summary,
            CloudflaredHelperState.downloading(progress: 0.4).summary,
            CloudflaredHelperState.verifying.summary
        ]
        for string in strings {
            #expect(!string.contains("PATH"))
            #expect(!string.contains("Homebrew"))
            #expect(!string.contains("tarball"))
            #expect(!string.contains("`"))
        }
        #expect(TunnelServiceError.cloudflaredUnavailable.localizedDescription.contains("Cloudflare's helper"))
    }
}

// MARK: - Fixtures

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
}

private func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacRemoteTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeScratchFile() throws -> URL {
    try makeScratchDirectory().appendingPathComponent("cloudflared.tgz")
}

/// Always nested under a throwaway container, so `remove()` sees the folder name
/// it requires and the real Application Support tree is never touched.
///
/// The pinned digest set is the fixture's own, because verification now demands
/// membership of a compile-time set that no `install.json` can extend — and a
/// synthetic payload is by definition not one of the shipped releases.
private func makeIsolatedStore(
    expectedExecutableDigests: Set<String> = [
        CloudflaredInstallStore.sha256(of: Data(SyntheticRelease.defaultPayload))
    ]
) throws -> CloudflaredInstallStore {
    let container = try makeScratchDirectory()
    return CloudflaredInstallStore(
        rootDirectory: container.appendingPathComponent(CloudflaredInstallStore.directoryName, isDirectory: true),
        expectedExecutableDigests: expectedExecutableDigests
    )
}

private func mode(of url: URL) -> Int16? {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.int16Value
}

@discardableResult
private func installFixture(
    into store: CloudflaredInstallStore,
    version: String = CloudflaredManifest.version
) throws -> CloudflaredInstallRecord {
    let staging = try store.prepareStagingDirectory()
    defer { store.discardStagingDirectory(staging) }
    let staged = staging.appendingPathComponent("cloudflared")
    try Data(SyntheticRelease.defaultPayload).write(to: staged)
    let record = CloudflaredInstallRecord(
        version: version,
        architecture: .arm64,
        executableSHA256: CloudflaredInstallStore.sha256(of: Data(SyntheticRelease.defaultPayload)),
        byteCount: SyntheticRelease.defaultPayload.count,
        installedAt: Date(timeIntervalSince1970: 1_800_000_000),
        sourceURL: "https://github.com/cloudflare/cloudflared/releases/download/\(version)/cloudflared-darwin-arm64.tgz"
    )
    try store.commit(stagedExecutable: staged, record: record)
    return record
}

@MainActor
private func waitForState(
    _ manager: CloudflaredManager,
    matching predicate: (CloudflaredHelperState) -> Bool
) async -> CloudflaredHelperState {
    for _ in 0..<400 {
        if predicate(manager.state) {
            return manager.state
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return manager.state
}

/// Polls a cheap condition. Used where the thing under test is a real
/// `URLSession` transfer, so there is no completion to await.
private func waitUntil(
    timeout: Duration = .seconds(4),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting for a condition.", sourceLocation: sourceLocation)
    throw NSError(domain: "MacRemoteTests", code: 1)
}

private struct StubSignatureReader: SignatureReading {
    let trust: DiscoveredCLICandidate.SignatureTrust

    func signatureTrust(atPath path: String) -> DiscoveredCLICandidate.SignatureTrust {
        trust
    }

    static let cloudflare = StubSignatureReader(
        trust: .developerID(team: CloudflaredManifest.expectedTeamIdentifier, name: "Cloudflare Inc.")
    )
    static let otherDeveloper = StubSignatureReader(trust: .developerID(team: "ZZZZZZZZZZ", name: "Someone Else"))
    static let unsigned = StubSignatureReader(trust: .unsigned)
    static let adhoc = StubSignatureReader(trust: .adhoc)
}

/// Reading a code signature is the one observable side effect of the expensive
/// path, so counting it is how "status never hashes" is falsifiable.
private final class CountingSignatureReader: SignatureReading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int { lock.withLock { calls } }

    func signatureTrust(atPath path: String) -> DiscoveredCLICandidate.SignatureTrust {
        lock.withLock { calls += 1 }
        return .developerID(team: CloudflaredManifest.expectedTeamIdentifier, name: "Cloudflare Inc.")
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func increment() {
        lock.withLock { calls += 1 }
    }
}

private final class MutableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ value: Bool) {
        storage = value
    }

    var value: Bool {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class MutableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    init(_ value: String?) {
        storage = value
    }

    var value: String? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Double = 0

    func record(_ value: Double) {
        lock.withLock { highest = max(highest, value) }
    }

    var highWaterMark: Double {
        lock.withLock { highest }
    }
}

// MARK: - Synthetic release archives

private struct SyntheticTarEntry {
    var name = "cloudflared"
    var payload: [UInt8]
    var typeFlag: UInt8 = UInt8(ascii: "0")
    var linkName = ""
    var prefix = ""
    var magic = "ustar"
    var magicTerminator: UInt8 = 0
    var version: [UInt8] = [0x30, 0x30]
    var declaredSize: Int?
    var breakChecksum = false
}

private func syntheticTar(_ entries: [SyntheticTarEntry], trailingBlocks: Int = 2) -> [UInt8] {
    var output: [UInt8] = []
    for entry in entries {
        var header = [UInt8](repeating: 0, count: 512)

        func put(_ value: String, at offset: Int, width: Int) {
            for (index, byte) in Array(value.utf8).prefix(width).enumerated() {
                header[offset + index] = byte
            }
        }
        func putOctal(_ value: Int, at offset: Int, width: Int) {
            let digits = String(value, radix: 8)
            let padded = String(repeating: "0", count: max(0, width - 1 - digits.count)) + digits
            put(padded, at: offset, width: width - 1)
            header[offset + width - 1] = 0
        }

        put(entry.name, at: 0, width: 100)
        putOctal(0o755, at: 100, width: 8)
        putOctal(0, at: 108, width: 8)
        putOctal(0, at: 116, width: 8)
        putOctal(entry.declaredSize ?? entry.payload.count, at: 124, width: 12)
        putOctal(0, at: 136, width: 12)
        header[156] = entry.typeFlag
        put(entry.linkName, at: 157, width: 100)
        put(entry.magic, at: 257, width: 6)
        header[257 + entry.magic.utf8.count] = entry.magicTerminator
        header[263] = entry.version[0]
        header[264] = entry.version[1]
        put(entry.prefix, at: 345, width: 155)

        for index in 148..<156 {
            header[index] = UInt8(ascii: " ")
        }
        let sum = header.reduce(0) { $0 + Int($1) } + (entry.breakChecksum ? 1 : 0)
        let digits = String(sum, radix: 8)
        put(String(repeating: "0", count: max(0, 6 - digits.count)) + digits, at: 148, width: 6)
        header[154] = 0
        header[155] = UInt8(ascii: " ")

        output += header
        output += entry.payload
        let remainder = entry.payload.count % 512
        if remainder != 0 {
            output += [UInt8](repeating: 0, count: 512 - remainder)
        }
    }
    output += [UInt8](repeating: 0, count: 512 * trailingBlocks)
    return output
}

private func syntheticGzip(_ bytes: [UInt8]) -> [UInt8] {
    var deflated = [UInt8](repeating: 0, count: bytes.count + 4096)
    let written = bytes.withUnsafeBufferPointer { source in
        deflated.withUnsafeMutableBufferPointer { destination in
            compression_encode_buffer(
                destination.baseAddress!,
                destination.count,
                source.baseAddress!,
                source.count,
                nil,
                COMPRESSION_ZLIB
            )
        }
    }
    var output: [UInt8] = [0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]
    output += deflated[0..<written]
    output += littleEndianBytes(CloudflaredArchiveExtractor.crc32(bytes))
    output += littleEndianBytes(UInt32(truncatingIfNeeded: bytes.count))
    return output
}

private func littleEndianBytes(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF)
    ]
}

private enum SyntheticRelease {
    static let defaultPayload: [UInt8] = Array(
        String(repeating: "MacRemote synthetic cloudflared payload.\n", count: 24).utf8
    )

    static let record = CloudflaredInstallRecord(
        version: CloudflaredManifest.version,
        architecture: .arm64,
        executableSHA256: CloudflaredInstallStore.sha256(of: Data(defaultPayload)),
        byteCount: defaultPayload.count,
        installedAt: Date(timeIntervalSince1970: 1_800_000_000),
        sourceURL: "https://github.com/cloudflare/cloudflared/releases/download/test/cloudflared-darwin-arm64.tgz"
    )

    struct Fixture {
        let artifact: CloudflaredArtifact
        let archive: [UInt8]
        let payload: [UInt8]
    }

    static func good(host: String = "github.com") -> Fixture {
        let payload = defaultPayload
        let tar = syntheticTar([SyntheticTarEntry(payload: payload)])
        let archive = syntheticGzip(tar)
        return Fixture(
            artifact: artifact(archive: archive, payload: payload, tarByteCount: tar.count, host: host),
            archive: archive,
            payload: payload
        )
    }

    static func artifact(
        archive: [UInt8],
        payload: [UInt8],
        tarByteCount: Int,
        host: String = "github.com"
    ) -> CloudflaredArtifact {
        CloudflaredArtifact(
            architecture: .arm64,
            downloadURL: URL(string: "https://\(host)/cloudflare/cloudflared/releases/download/test/cloudflared-darwin-arm64.tgz")!,
            archiveSHA256: CloudflaredInstallStore.sha256(of: Data(archive)),
            archiveByteCount: archive.count,
            executableSHA256: CloudflaredInstallStore.sha256(of: Data(payload)),
            executableByteCount: payload.count,
            uncompressedTarByteCount: tarByteCount
        )
    }
}

// MARK: - Download stub

private final class CloudflaredDownloadProtocolMock: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var statusCode = 200
    nonisolated(unsafe) private static var failure: (any Error)?
    nonisolated(unsafe) private static var requests: [URL] = []
    /// Consumed by the first request only, so a refused redirect cannot loop.
    nonisolated(unsafe) private static var redirectTarget: String?
    /// Holds the body back so a cancellation can land mid-transfer.
    nonisolated(unsafe) private static var bodyDelay: TimeInterval = 0

    private let stopLock = NSLock()
    private var isStopped = false

    static func install(
        body: Data,
        statusCode: Int = 200,
        failure: (any Error)? = nil,
        redirectTo: String? = nil,
        bodyDelay: TimeInterval = 0
    ) {
        lock.withLock {
            self.body = body
            self.statusCode = statusCode
            self.failure = failure
            self.redirectTarget = redirectTo
            self.bodyDelay = bodyDelay
            requests = []
        }
    }

    static func requestedURLs() -> [URL] {
        lock.withLock { requests }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudflaredDownloadProtocolMock.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix(".tgz") == true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (payload, status, failure, redirect, delay): (Data, Int, (any Error)?, String?, TimeInterval) =
            Self.lock.withLock {
                Self.requests.append(url)
                let redirect = Self.redirectTarget
                Self.redirectTarget = nil
                return (Self.body, Self.statusCode, Self.failure, redirect, Self.bodyDelay)
            }

        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }

        // Hands the move to the session, which asks the task delegate for a
        // policy decision — the exact path the allowlist guards.
        if let redirect, let redirectURL = URL(string: redirect) {
            let moved = HTTPURLResponse(
                url: url,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirect]
            )!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: redirectURL), redirectResponse: moved)
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/octet-stream",
                "Content-Length": "\(payload.count)"
            ]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        guard delay > 0 else {
            deliver(payload)
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopLock.withLock({ self.isStopped }) else { return }
            self.deliver(payload)
        }
    }

    private func deliver(_ payload: Data) {
        if !payload.isEmpty {
            client?.urlProtocol(self, didLoad: payload)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        stopLock.withLock { isStopped = true }
    }
}

// MARK: - Isolated AppModel

private func makeIsolatedDefaults(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> UserDefaults {
    let suiteName = "MacRemoteTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated UserDefaults suite.", sourceLocation: sourceLocation)
        throw NSError(domain: "MacRemoteTests", code: 1)
    }
    defaults.set(suiteName, forKey: "MacRemoteTests.suiteName")
    return defaults
}

@MainActor
private func makeIsolatedAppModel(
    userDefaults: UserDefaults,
    manager: CloudflaredManager
) throws -> AppModel {
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = ToolRegistryStore(fileURL: temporaryDirectory.appendingPathComponent("tools.json"))
    return makeTestAppModel(userDefaults: userDefaults, toolStore: store, cloudflaredManager: manager)
}

private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: "MacRemoteTests.suiteName") ?? ""
}
