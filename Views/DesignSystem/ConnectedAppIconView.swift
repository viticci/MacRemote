import AppKit
import SwiftUI

/// The three places an app's mark appears (GUIDELINES §1 tokens).
enum AppIconSize {
    /// Requests rows and the inline approval header.
    case compact
    /// Apps cards.
    case card
    /// The floating Approval window's countdown ring.
    case hero

    var points: CGFloat {
        switch self {
        case .compact: 24
        case .card: 28
        case .hero: 64
        }
    }

    var symbolFont: Font {
        switch self {
        case .compact, .card: .caption
        case .hero: .title2
        }
    }

    /// Smallest raster that still looks sharp here, at Retina scale. Used to
    /// reject a vendor's menu-bar-sized asset for the 64 pt ring while keeping
    /// it for the rows, where it is exactly right.
    var minimumPixelWidth: Int {
        Int(points) * 2
    }
}

/// Draws a connected app's mark. A *hint*, never identity — the brand is
/// resolved from strings the app supplied about itself (see the trust-boundary
/// note in `Models/ConnectedAppIdentity.swift`). Missing or unreadable artwork
/// silently falls back to the brand's SF Symbol; it is never an error state.
///
/// Three artwork tiers feed this one view, in the order defined by
/// `ConnectedAppArtworkTier`: a curated bundled asset, then the vendor's own
/// installed app, then a `data:` icon the app attached to its MCP handshake.
/// Which tier answered is never shown — an app gets a picture, not a rank.
struct ConnectedAppIconView: View {
    @Environment(\.colorScheme) private var colorScheme

    private let identity: ConnectedAppIdentity
    /// Icons the app supplied about itself, lowest precedence of the three.
    private let clientSuppliedIcons: ClientSuppliedIconSet?
    private let size: AppIconSize
    /// Expired sessions read as dimmed while staying recognizable.
    private let isDimmed: Bool

    init(
        identity: ConnectedAppIdentity,
        clientSuppliedIcons: ClientSuppliedIconSet? = nil,
        size: AppIconSize = .card,
        isDimmed: Bool = false
    ) {
        self.identity = identity
        self.clientSuppliedIcons = clientSuppliedIcons
        self.size = size
        self.isDimmed = isDimmed
    }

    /// Convenience for call sites that only hold the strings an app supplied.
    init(
        clientName: String?,
        redirectURIs: [String] = [],
        clientSuppliedIcons: ClientSuppliedIconSet? = nil,
        size: AppIconSize = .card,
        isDimmed: Bool = false
    ) {
        self.init(
            identity: ConnectedAppIdentity.resolve(name: clientName, redirectURIs: redirectURIs),
            clientSuppliedIcons: clientSuppliedIcons,
            size: size,
            isDimmed: isDimmed
        )
    }

    var body: some View {
        content
            .frame(width: size.points, height: size.points)
            .opacity(isDimmed ? 0.55 : 1)
            // The surrounding row already names the app.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let image = artwork {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            ZStack {
                Circle()
                    .fill(.quaternary.opacity(0.6))
                Image(systemName: identity.fallbackSymbol)
                    .font(size.symbolFont)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isDimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
            }
        }
    }

    /// Real artwork already carries its own contrast, so increased-contrast
    /// keeps the mark rather than dropping to a symbol (recognition wins).
    private var artwork: NSImage? {
        ConnectedAppArtworkResolver.shared.artwork(
            for: identity,
            clientSuppliedIcons: clientSuppliedIcons,
            isDarkAppearance: colorScheme == .dark,
            minimumPixelWidth: size.minimumPixelWidth
        )?.image
    }
}
