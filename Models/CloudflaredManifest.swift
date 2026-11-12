import Darwin
import Foundation

/// CPU family MacRemote can install a Cloudflare helper for. Cloudflare ships
/// thin (per-architecture) macOS binaries, never a universal one, so the choice
/// is made from the running hardware rather than a compile-time `#if arch`.
enum CloudflaredArchitecture: String, Codable, Equatable, Sendable, CaseIterable {
    case arm64
    case amd64

    /// Plain-language name for logs and Settings.
    var displayName: String {
        switch self {
        case .arm64: "Apple silicon"
        case .amd64: "Intel"
        }
    }
}

/// One pinned, fully verified release artifact. Every number here is exact:
/// a download that differs by a single byte is discarded.
struct CloudflaredArtifact: Equatable, Sendable {
    let architecture: CloudflaredArchitecture
    let downloadURL: URL
    let archiveSHA256: String
    let archiveByteCount: Int
    let executableSHA256: String
    let executableByteCount: Int
    /// Exact length of the tar stream inside the gzip container. Doubles as the
    /// inflate cap, so a crafted archive cannot expand without bound.
    let uncompressedTarByteCount: Int

    /// Rounded decimal megabytes for consent copy ("about 19 MB").
    var approximateDownloadSize: String {
        "\(Int((Double(archiveByteCount) / 1_000_000).rounded())) MB"
    }
}

/// Compile-time pin of the Cloudflare Tunnel client MacRemote is willing to
/// install. Checksums were computed from the published release archives and
/// cross-checked against GitHub asset digests (archives), release-note checksums
/// (executables), and Cloudflare's Developer ID signatures for both architectures.
/// Release 2026.10.3 is the macOS direct-download minimum for Cloudflare's
/// October 2026 certificate security update. No release metadata is fetched at
/// runtime, because a pinned build must not be able to change under the user.
enum CloudflaredManifest {
    static let version = "2026.10.3"
    static let releaseDate = "2026-10-21"
    static let publisher = "Cloudflare Inc."
    /// Developer ID team of `Developer ID Application: Cloudflare Inc.`
    static let expectedTeamIdentifier = "68WVV388M8"
    /// The archive must contain exactly this one entry.
    static let expectedEntryName = "cloudflared"

    static let licenseURL = URL(string: "https://github.com/cloudflare/cloudflared/blob/2026.10.3/LICENSE")!
    static let sourceURL = URL(string: "https://github.com/cloudflare/cloudflared")!
    static let releaseNotesURL = URL(string: "https://github.com/cloudflare/cloudflared/releases/tag/2026.10.3")!

    /// GitHub serves release assets from a redirect chain; nothing outside
    /// these hosts is ever followed.
    static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "release-assets.githubusercontent.com",
        "objects.githubusercontent.com"
    ]

    static let maxRedirectCount = 5
    /// Streaming guard: the transfer is aborted well before anything close to
    /// this, since the exact archive size is known.
    static let maxDownloadByteCount = 64 * 1024 * 1024

    static let artifacts: [CloudflaredArtifact] = [
        CloudflaredArtifact(
            architecture: .arm64,
            downloadURL: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/2026.10.3/cloudflared-darwin-arm64.tgz")!,
            archiveSHA256: "1165d14b6f6360a3b8c283d7d1100024d6ec7cd9bc9e32519e96150645f3ec55",
            archiveByteCount: 19_841_881,
            executableSHA256: "f249139e0541fa589c987397d867cc16c83ab1236d31eb6782f2e4552ee9cf80",
            executableByteCount: 39_533_376,
            uncompressedTarByteCount: 39_535_104
        ),
        CloudflaredArtifact(
            architecture: .amd64,
            downloadURL: URL(string: "https://github.com/cloudflare/cloudflared/releases/download/2026.10.3/cloudflared-darwin-amd64.tgz")!,
            archiveSHA256: "81b7b85f2376815c4f59b1aa323887b62e16ce8b67555c2e1577dc23f2a82000",
            archiveByteCount: 21_823_395,
            executableSHA256: "947e2942d6a59922d80190d23b12f3ade8da16e23e3bd937182a48993b7c00db",
            executableByteCount: 42_468_448,
            uncompressedTarByteCount: 42_470_400
        )
    ]

    /// Executables from earlier MacRemote releases. A copy installed by one of
    /// them is still a genuine helper, only an older one: it keeps working and
    /// the app offers the update. Without this list, every new pin made the
    /// helper already on a user's Mac look tampered with, and the app set it
    /// aside and left the public link unavailable until a manual reinstall.
    /// Add the outgoing pin's digests here whenever `artifacts` changes.
    static let earlierExecutableSHA256: Set<String> = [
        // 2026.7.3 (the earlier 1.0 and 1.0.1 betas)
        "f35c50089cd25f77a4cb5a2152036bc26db15aa31fbe11f7995d2e42a4ed6257",
        "e88fe5874d42a94f49a7ea59cabc3722d2962d0449232b0f3b1a426a712e275c"
    ]

    static func artifact(for architecture: CloudflaredArchitecture) -> CloudflaredArtifact? {
        artifacts.first { $0.architecture == architecture }
    }

    /// The artifact for this Mac, or `nil` on hardware MacRemote has no pinned
    /// build for (callers turn that into a plain-language error).
    static var current: CloudflaredArtifact? {
        guard let hostArchitecture else { return nil }
        return artifact(for: hostArchitecture)
    }

    static var hostArchitecture: CloudflaredArchitecture? {
        architecture(isARM64Hardware: sysctlInteger("hw.optional.arm64") == 1, machine: sysctlString("hw.machine"))
    }

    /// Pure so the mapping is testable without the host it runs on.
    static func architecture(isARM64Hardware: Bool, machine: String?) -> CloudflaredArchitecture? {
        if isARM64Hardware {
            return .arm64
        }
        guard let machine = machine?.lowercased(), !machine.isEmpty else {
            return nil
        }
        if machine.hasPrefix("arm64") {
            return .arm64
        }
        if machine == "x86_64" || machine == "i386" {
            return .amd64
        }
        return nil
    }

    /// The only URLs the downloader may request or follow: https, and one of
    /// the three known release hosts.
    static func isAllowedDownloadURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host()?.lowercased(),
              !host.isEmpty else {
            return false
        }
        return allowedDownloadHosts.contains(host)
    }

    // MARK: - sysctl

    private static func sysctlInteger(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
