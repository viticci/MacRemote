import SwiftUI

// MARK: - Spacing (GUIDELINES §1.1 — the only allowed values)

enum Space {
    /// 4 — intra-row, chip internals
    static let s1: CGFloat = 4
    /// 8 — control gaps, row internals
    static let s2: CGFloat = 8
    /// 12 — intra-card stacks
    static let s3: CGFloat = 12
    /// 16 — card padding
    static let s4: CGFloat = 16
    /// 20 — window content margins
    static let s5: CGFloat = 20
    /// 24 — section/card gaps, hero container spacing
    static let s6: CGFloat = 24
    /// 32 — hero breathing room
    static let s8: CGFloat = 32
}

// MARK: - List metrics (GUIDELINES §1.1)

enum ListMetrics {
    /// 32 — a Tools list row as drawn: the 24 pt tool icon plus the system
    /// row insets. The Tools list raises `defaultMinListRowHeight` to this
    /// (it never lowers it) so AppKit estimates the rows it has not drawn yet
    /// at their real height. With the system estimate (24) each row grew 8 pt
    /// as it came into view, the list jumped while scrolling, and a Share
    /// switch could slide out from under the pointer between two clicks.
    static let toolRowHeight: CGFloat = 32
}

// MARK: - Radii (GUIDELINES §1.2 — concentric, never constant)

enum Radii {
    /// Page container shape published on detail content.
    static let page: CGFloat = 16
    /// Cards (practical value of the concentric minimum).
    static let card: CGFloat = 12
    /// Code blocks / mono chips. Nothing below 8.
    static let mono: CGFloat = 8
}

enum AppShape {
    /// Card container shape — concentric with the page container.
    static var card: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Radii.card)), isUniform: true)
    }

    /// Code blocks / mono chips / inner rows.
    static var mono: ConcentricRectangle {
        ConcentricRectangle(corners: .concentric(minimum: .fixed(Radii.mono)), isUniform: true)
    }
}

extension View {
    /// Pages publish this on detail content so nested concentric shapes resolve.
    func pageContainerShape() -> some View {
        containerShape(.rect(cornerRadius: Radii.page))
    }
}

// MARK: - Type ramp (GUIDELINES §1.3 — SwiftUI text styles only)

enum TypeRamp {
    /// Welcome window title — the only `.largeTitle` in the app.
    static let welcomeTitle: Font = .largeTitle
    /// Hero status word; approval headline.
    static let heroStatus: Font = .title2.weight(.semibold)
    /// Hero public URL; masthead machine text.
    static let heroMachine: Font = .title3.monospaced()
    /// Card titles, section headers, row titles.
    static let cardTitle: Font = .headline
    /// The name of the selected source on the Tools page (one per page).
    static let sourceTitle: Font = .title3.weight(.semibold)
    /// Row detail, readiness detail lines (pair with `.secondary`).
    static let rowDetail: Font = .callout
    /// Group footers, truth notes ("This session…").
    static let truthNote: Font = .footnote
    /// Chips, badges (semibold).
    static let chip: Font = .caption.weight(.semibold)
    /// Machine text at row scale (URLs, argv, IDs, paths).
    static let machineCallout: Font = .callout.monospaced()
    /// Machine text at caption scale (timestamps, log payloads).
    static let machineCaption: Font = .caption.monospaced()
}

extension View {
    /// Machine-produced/consumed text: mono + selectable. Never decorates prose.
    func machineText(_ font: Font = TypeRamp.machineCallout) -> some View {
        self.font(font)
            .textSelection(.enabled)
    }

    /// Live counts: monospaced digits with numeric roll.
    func countText() -> some View {
        monospacedDigit()
            .contentTransition(.numericText())
    }
}

// MARK: - Color roles (GUIDELINES §1.4 — semantic only, always symbol/word-paired)

enum StatusRole {
    case off
    case working
    case ready
    case attention
    case error

    var tint: Color {
        switch self {
        case .off: .secondary
        case .working: .blue
        case .ready: .green
        case .attention: .orange
        case .error: .red
        }
    }

    var symbolName: String {
        switch self {
        case .off: "circle.dotted"
        case .working: "circle.dashed"
        case .ready: "checkmark.circle.fill"
        case .attention: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

/// One capability scale on every surface (Tools, Apps, Requests, Approval window).
extension ToolCapability {
    var chipTint: Color {
        switch self {
        case .readOnly: .green
        case .write: .orange
        case .destructive: .red
        }
    }

    var chipSymbolName: String {
        switch self {
        case .readOnly: "eye"
        case .write: "pencil"
        case .destructive: "exclamationmark.octagon.fill"
        }
    }
}

extension ShapeStyle where Self == Color {
    /// The one hairline app-wide.
    static var hairline: Color { Color(nsColor: .separatorColor) }
}
