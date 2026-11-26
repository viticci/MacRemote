import AppKit
import Foundation

/// Where a drawn mark came from. The order is the precedence order (D46): a
/// tier may only be used when every tier above it produced nothing.
///
/// None of these is evidence of anything. A curated asset is not proof the app
/// is who it says it is, a mark read out of an installed app bundle is not
/// *stronger* proof, and an icon the app handed us is not proof at all. The tier
/// exists so the precedence rule can be asserted in a test, not so the UI can
/// grade trust — nothing in the app may render a tier as a badge.
enum ConnectedAppArtworkTier: Int, Comparable, Sendable {
    /// Committed to `Resources/ConnectedAppIcons`, redistribution documented.
    case bundled = 0
    /// Read at display time out of the vendor's own installed macOS app.
    case installedApp = 1
    /// A `data:` icon the app attached to its MCP `clientInfo`.
    case clientSupplied = 2

    static func < (lhs: ConnectedAppArtworkTier, rhs: ConnectedAppArtworkTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ConnectedAppArtwork {
    let image: NSImage
    let tier: ConnectedAppArtworkTier
}

/// Reads a mark out of a locally installed application bundle. Behind a
/// protocol so the precedence rules can be tested without depending on which
/// apps happen to be installed on the machine running the tests.
protocol ConnectedAppInstalledArtworkProviding: Sendable {
    /// `resource` is a base name inside `Contents/Resources`; `nil` means "use
    /// the app icon". `minimumPixelWidth` is the smallest raster that would
    /// still look sharp where the mark is about to be drawn. Returns `nil` when
    /// the app is not installed.
    func image(bundleIdentifier: String, resource: String?, minimumPixelWidth: Int) -> NSImage?
}

/// The real one: `NSWorkspace` plus a Retina-aware file probe.
struct SystemInstalledArtworkProvider: ConnectedAppInstalledArtworkProviding {
    func image(bundleIdentifier: String, resource: String?, minimumPixelWidth: Int) -> NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return nil
        }
        if let resource,
           let named = Self.namedResource(resource, in: appURL, minimumPixelWidth: minimumPixelWidth) {
            return named
        }
        // `icon(forFile:)` answers for any bundle and carries representations up
        // to 512 pt, so this is the tier's floor rather than another thing that
        // can fail — and the right answer when a vendor's named variant is a
        // menu-bar asset too small for a 64 pt hero.
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        return icon.size.width > 0 ? icon : nil
    }

    /// Densest variant the vendor shipped, but only if it can actually fill the
    /// space. Claude's tray art tops out at 72 px: fine for a 24 pt row, soft in
    /// a 64 pt ring, so the ring gets the app icon instead.
    private static func namedResource(
        _ resource: String,
        in appURL: URL,
        minimumPixelWidth: Int
    ) -> NSImage? {
        let resources = appURL.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        for suffix in ["@3x", "@2x", ""] {
            let candidate = resources.appending(path: "\(resource)\(suffix).png")
            guard FileManager.default.fileExists(atPath: candidate.path),
                  let image = NSImage(contentsOf: candidate),
                  image.size.width > 0 else {
                continue
            }
            let pixels = image.representations.map(\.pixelsWide).max() ?? 0
            guard pixels >= minimumPixelWidth else { continue }
            return image
        }
        return nil
    }
}

/// Resolves the mark for one app across all three artwork tiers, memoizing each
/// so a SwiftUI body evaluation never decodes a PNG or hits the filesystem
/// twice. Misses are memoized too — a missing file must stay cheap.
final class ConnectedAppArtworkResolver: @unchecked Sendable {
    static let shared = ConnectedAppArtworkResolver()

    /// How long a "that app is not installed" answer is trusted. Bounded so
    /// installing Claude while MacRemote is running starts showing its mark
    /// without a relaunch, and unbounded lookups still cost nothing.
    private static let missTTL: TimeInterval = 300
    /// Client-supplied icons are attacker-sized input, so their decode cache is
    /// capped rather than allowed to grow with connection churn.
    private static let clientSuppliedCacheLimit = 32

    private let installedArtwork: ConnectedAppInstalledArtworkProviding
    private let lock = NSLock()
    private var bundledCache: [String: NSImage?] = [:]
    private var installedCache: [String: (image: NSImage?, recordedAt: Date)] = [:]
    private var clientSuppliedCache: [ClientSuppliedIcon: NSImage?] = [:]

    init(installedArtwork: ConnectedAppInstalledArtworkProviding = SystemInstalledArtworkProvider()) {
        self.installedArtwork = installedArtwork
    }

    /// Curated asset, then the installed app, then whatever the app sent, then
    /// nothing (the caller draws the SF Symbol). Appearance is honored at every
    /// tier — no tier is allowed to be the reason a dark UI gets a light mark.
    func artwork(
        for identity: ConnectedAppIdentity,
        clientSuppliedIcons: ClientSuppliedIconSet? = nil,
        isDarkAppearance: Bool,
        minimumPixelWidth: Int = 0
    ) -> ConnectedAppArtwork? {
        if let resource = identity.artworkResource(forDarkAppearance: isDarkAppearance),
           let image = bundledImage(named: resource) {
            return ConnectedAppArtwork(image: image, tier: .bundled)
        }
        let resource = identity.localResource(forDarkAppearance: isDarkAppearance)
        for bundleIdentifier in identity.bundleIdentifiers.sorted() {
            if let image = installedImage(
                bundleIdentifier: bundleIdentifier,
                resource: resource,
                minimumPixelWidth: minimumPixelWidth
            ) {
                return ConnectedAppArtwork(image: image, tier: .installedApp)
            }
        }
        if let supplied = clientSuppliedIcons?.icon(forDarkAppearance: isDarkAppearance),
           let image = clientSuppliedImage(supplied) {
            return ConnectedAppArtwork(image: image, tier: .clientSupplied)
        }
        return nil
    }

    // MARK: - Tiers

    private func bundledImage(named resource: String) -> NSImage? {
        lock.withLock {
            if let cached = bundledCache[resource] {
                return cached
            }
            let loaded = ConnectedAppIdentity.iconURL(named: resource)
                .flatMap { NSImage(contentsOf: $0) }
            bundledCache[resource] = loaded
            return loaded
        }
    }

    private func installedImage(
        bundleIdentifier: String,
        resource: String?,
        minimumPixelWidth: Int
    ) -> NSImage? {
        let key = "\(bundleIdentifier)#\(resource ?? "")#\(minimumPixelWidth)"
        let cached: NSImage?? = lock.withLock {
            guard let entry = installedCache[key] else { return nil }
            if entry.image == nil, Date().timeIntervalSince(entry.recordedAt) > Self.missTTL {
                installedCache[key] = nil
                return nil
            }
            return .some(entry.image)
        }
        if let cached {
            return cached
        }
        let loaded = installedArtwork.image(
            bundleIdentifier: bundleIdentifier,
            resource: resource,
            minimumPixelWidth: minimumPixelWidth
        )
        lock.withLock {
            installedCache[key] = (loaded, Date())
        }
        return loaded
    }

    private func clientSuppliedImage(_ icon: ClientSuppliedIcon) -> NSImage? {
        lock.withLock {
            if let cached = clientSuppliedCache[icon] {
                return cached
            }
            if clientSuppliedCache.count >= Self.clientSuppliedCacheLimit {
                clientSuppliedCache.removeAll()
            }
            // The bytes were format-checked at intake, but AppKit is still the
            // one that decides whether they decode; a refusal falls through to
            // the SF Symbol like any other missing artwork.
            let loaded = NSImage(data: icon.imageData)
                .flatMap { $0.size.width > 0 ? $0 : nil }
            clientSuppliedCache[icon] = loaded
            return loaded
        }
    }
}
