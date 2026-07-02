import Accessibility
import AppKit
import SwiftUI

// MARK: - StatusOrb (GUIDELINES §2 — replaces ad-hoc dots)

struct StatusOrb: View {
    enum OrbState: Equatable {
        case off
        case starting
        case local
        case `public`
        case failed

        var role: StatusRole {
            switch self {
            case .off: .off
            case .starting, .local: .working
            case .public: .ready
            case .failed: .error
            }
        }

        var symbolName: String {
            switch self {
            case .off: "circle.dotted"
            case .starting, .local: "dot.radiowaves.left.and.right"
            case .public: "globe"
            case .failed: "xmark.octagon.fill"
            }
        }

        var accessibilityDescription: String {
            switch self {
            case .off: "Off"
            case .starting: "Starting"
            case .local: "Local"
            case .public: "Public"
            case .failed: "Failed"
            }
        }
    }

    var state: OrbState
    var size: CGFloat = 28

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .fill(state.role.tint.opacity(0.16))
            Image(systemName: state.symbolName)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeat(.continuous),
                    isActive: state == .starting && !reduceMotion
                )
                .contentTransition(.symbolEffect(.replace))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.role.tint)
                .frame(width: size * 0.55, height: size * 0.55)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.accessibilityDescription)
    }
}

// MARK: - StatChip (GUIDELINES §2 — replaces MetricPill; tappable = filter/navigate)

struct StatChip: View {
    private let count: Int
    private let label: String
    private let isSelected: Bool
    private let action: (() -> Void)?

    /// Static variant.
    init(count: Int, label: String) {
        self.count = count
        self.label = label
        self.isSelected = false
        self.action = nil
    }

    /// Filter variant — tapping filters or navigates.
    init(count: Int, label: String, isSelected: Bool, action: @escaping () -> Void) {
        self.count = count
        self.label = label
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        if let action {
            Button(action: action) { chip }
                .buttonStyle(.plain)
        } else {
            chip
        }
    }

    private var chip: some View {
        HStack(spacing: Space.s1) {
            Text("\(count)")
                .font(TypeRamp.chip)
                .countText()
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1)
        .background(
            isSelected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.quaternary),
            in: Capsule()
        )
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(label)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - StateChip (GUIDELINES §2 — replaces StatusBadge; one severity scale)

struct StateChip: View {
    private let text: String
    private let systemImage: String?
    private let tint: Color

    init(_ text: String, systemImage: String? = nil, role: StatusRole) {
        self.text = text
        self.systemImage = systemImage
        self.tint = role.tint
    }

    init(_ text: String, systemImage: String? = nil, tint: Color) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
    }

    /// Capability variant — Read-only green · Write orange · Destructive red.
    init(capability: ToolCapability) {
        self.text = capability.title
        self.systemImage = capability.chipSymbolName
        self.tint = capability.chipTint
    }

    /// The per-call gating chip.
    static let asksFirst = StateChip("Asks First", systemImage: "hand.raised", role: .attention)

    var body: some View {
        HStack(spacing: Space.s1) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            Text(text)
                .font(TypeRamp.chip)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1)
        .background(tint.opacity(0.13), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
    }
}

// MARK: - Card (GUIDELINES §2 — replaces panelStyle(); no stroke, concentric 12)

struct Card<Summary: View, Content: View>: View {
    private let title: String?
    private let systemImage: String?
    private let isCollapsed: Binding<Bool>?
    private let summary: Summary
    private let content: Content

    fileprivate init(
        title: String?,
        systemImage: String?,
        isCollapsed: Binding<Bool>?,
        summary: Summary,
        content: Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isCollapsed = isCollapsed
        self.summary = summary
        self.content = content
    }

    /// Collapsible variant. The collapsed summary must state non-default values
    /// (GUIDELINES Rule 24 — e.g. "Your Domain · Deployed ✓").
    init(
        title: String,
        systemImage: String? = nil,
        isCollapsed: Binding<Bool>,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title: title,
            systemImage: systemImage,
            isCollapsed: isCollapsed,
            summary: summary(),
            content: content()
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            if title != nil {
                header
            }
            if let isCollapsed, isCollapsed.wrappedValue {
                summary
            } else {
                content
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: AppShape.card)
    }

    @ViewBuilder
    private var header: some View {
        if let isCollapsed {
            Button {
                withAnimation(.snappy) {
                    isCollapsed.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: Space.s2) {
                    headerTitle
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isCollapsed.wrappedValue ? 0 : 90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title ?? "Card")
            .accessibilityValue(isCollapsed.wrappedValue ? "Collapsed" : "Expanded")
        } else {
            HStack(spacing: Space.s2) {
                headerTitle
                Spacer()
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: Space.s2) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            if let title {
                Text(title)
                    .font(TypeRamp.cardTitle)
            }
        }
    }
}

extension Card where Summary == EmptyView {
    /// Plain content card.
    init(@ViewBuilder content: () -> Content) {
        self.init(title: nil, systemImage: nil, isCollapsed: nil, summary: EmptyView(), content: content())
    }

    /// Titled card.
    init(title: String, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, isCollapsed: nil, summary: EmptyView(), content: content())
    }
}

// MARK: - KeyValueGrid (GUIDELINES §2 — aligned label + mono value rows)

struct KeyValueRow: Identifiable, Equatable {
    let label: String
    let value: String
    let isSensitive: Bool

    var id: String { label }

    init(_ label: String, _ value: String, isSensitive: Bool = false) {
        self.label = label
        self.value = value
        self.isSensitive = isSensitive
    }
}

struct KeyValueGrid: View {
    private let rows: [KeyValueRow]
    private let onCopy: ((KeyValueRow) -> Void)?

    /// `onCopy` receives the copied row so the host can write the audit log line.
    init(rows: [KeyValueRow], onCopy: ((KeyValueRow) -> Void)? = nil) {
        self.rows = rows
        self.onCopy = onCopy
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.s3, verticalSpacing: Space.s2) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    KeyValueCell(row: row, onCopy: onCopy)
                }
            }
        }
    }
}

private struct KeyValueCell: View {
    let row: KeyValueRow
    let onCopy: ((KeyValueRow) -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Space.s1) {
            Text(displayValue)
                .font(TypeRamp.machineCallout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .privacySensitive(row.isSensitive)
            CopyButton(value: row.value) {
                onCopy?(row)
            }
            .controlSize(.small)
            .opacity(isHovering ? 1 : 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { isHovering = $0 }
    }

    private var displayValue: String {
        // Sensitive rows stay masked until hover; copy always carries the real value.
        if row.isSensitive && !isHovering {
            return String(repeating: "•", count: min(max(row.value.count, 6), 16))
        }
        return row.value
    }
}

// MARK: - CopyButton (GUIDELINES §2 — the one copy affordance app-wide)

struct CopyButton: View {
    private let makeValue: () -> String
    private let help: String
    private let onCopy: (() -> Void)?

    @State private var isConfirming = false
    @State private var confirmTask: Task<Void, Never>?

    /// Writes the pasteboard itself; `onCopy` is the hook for the audit log line.
    init(value: @autoclosure @escaping () -> String, help: String = "Copy", onCopy: (() -> Void)? = nil) {
        self.makeValue = value
        self.help = help
        self.onCopy = onCopy
    }

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(makeValue(), forType: .string)
            onCopy?()
            AccessibilityNotification.Announcement("Copied").post()
            withAnimation {
                isConfirming = true
            }
            confirmTask?.cancel()
            confirmTask = Task {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                withAnimation {
                    isConfirming = false
                }
            }
        } label: {
            Image(systemName: isConfirming ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - MonoValue (GUIDELINES §2 — machine text with hover-reveal copy)

struct MonoValue: View {
    private let text: String
    private let font: Font
    private let onCopy: (() -> Void)?

    @State private var isHovering = false

    init(_ text: String, font: Font = TypeRamp.machineCallout, onCopy: (() -> Void)? = nil) {
        self.text = text
        self.font = font
        self.onCopy = onCopy
    }

    var body: some View {
        HStack(spacing: Space.s1) {
            Text(text)
                .font(font)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            CopyButton(value: text, onCopy: onCopy)
                .controlSize(.small)
                .opacity(isHovering ? 1 : 0)
        }
        .onHover { isHovering = $0 }
    }
}

// MARK: - CountdownRing (GUIDELINES §2 — real fuse around a 64 pt icon)

struct CountdownRing<Icon: View>: View {
    private let endDate: Date
    private let duration: TimeInterval
    private let iconSize: CGFloat
    private let icon: Icon

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(endDate: Date, duration: TimeInterval, iconSize: CGFloat = 64, @ViewBuilder icon: () -> Icon) {
        self.endDate = endDate
        self.duration = duration
        self.iconSize = iconSize
        self.icon = icon()
    }

    var body: some View {
        // Still updates under Reduce Motion (information, not decoration) — just coarser.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 0.1)) { context in
            let remaining = max(0, endDate.timeIntervalSince(context.date))
            let progress = duration > 0 ? min(1, remaining / duration) : 0
            ZStack {
                icon
                    .frame(width: iconSize, height: iconSize)
                Circle()
                    .stroke(.quaternary, lineWidth: 4)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        remaining <= 30 ? Color.orange : Color.green,
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: iconSize + Space.s3, height: iconSize + Space.s3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Expires in \(Self.remainingDescription(remaining))")
        }
    }

    static func remainingDescription(_ remaining: TimeInterval) -> String {
        Duration.seconds(remaining).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}

// MARK: - ActivityLogRow (GUIDELINES §2 `LogRow`)

struct ActivityLogRow: View {
    enum Level {
        case info
        case warning
        case error

        var title: String {
            switch self {
            case .info: "Info"
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        var role: StatusRole {
            switch self {
            case .info: .working
            case .warning: .attention
            case .error: .error
            }
        }
    }

    private let time: Date
    private let level: Level
    private let message: String
    private let isSecurityEvent: Bool

    init(time: Date, level: Level, message: String, isSecurityEvent: Bool = false) {
        self.time = time
        self.level = level
        self.message = message
        self.isSecurityEvent = isSecurityEvent
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            if isSecurityEvent {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Security event")
            }
            Text(time, format: .dateTime.hour().minute().second())
                .font(TypeRamp.machineCaption)
                .foregroundStyle(.secondary)
            StateChip(level.title, role: level.role)
            Text(message)
                .font(.body)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

// MARK: - EmptyState (GUIDELINES §2 — "No X yet." + trigger + CTA)

struct EmptyState: View {
    private enum Mode {
        case standard(title: String, systemImage: String, message: String, actionTitle: String?, action: (() -> Void)?)
        case search(text: String)
    }

    private let mode: Mode

    init(
        _ title: String,
        systemImage: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.mode = .standard(
            title: title,
            systemImage: systemImage,
            message: message,
            actionTitle: actionTitle,
            action: action
        )
    }

    /// The `.search` variant.
    init(searchText: String) {
        self.mode = .search(text: searchText)
    }

    var body: some View {
        switch mode {
        case let .standard(title, systemImage, message, actionTitle, action):
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(message)
            } actions: {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                }
            }
        case let .search(text):
            ContentUnavailableView.search(text: text)
        }
    }
}

// MARK: - Details disclosure (GUIDELINES §2 — per-section persistence + ⌥-click expand-all)

/// Page-level expand-all command. Hold one `@State` per page and pass its binding
/// to every `DetailsDisclosure` on that page; ⌥-clicking any disclosure drives all.
struct DetailsExpandAll: Equatable {
    fileprivate var expand = true
    fileprivate var generation = 0

    init() {}

    mutating func command(expand: Bool) {
        self.expand = expand
        generation &+= 1
    }
}

struct DetailsDisclosure<Content: View>: View {
    private let label: String
    private let expandAll: Binding<DetailsExpandAll>?
    private let content: Content

    @SceneStorage private var isExpanded: Bool

    /// `id` keys the per-section `SceneStorage` persistence — keep it stable per page section.
    init(
        _ label: String = "Details",
        id: String,
        expandAll: Binding<DetailsExpandAll>? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.expandAll = expandAll
        self.content = content()
        self._isExpanded = SceneStorage(wrappedValue: false, "detailsDisclosure.\(id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Button {
                if let expandAll, NSEvent.modifierFlags.contains(.option) {
                    expandAll.wrappedValue.command(expand: !isExpanded)
                } else {
                    withAnimation(.snappy) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                HStack(spacing: Space.s1) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(label)
                        .font(TypeRamp.rowDetail)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Option-click expands every disclosure on this page")
            .accessibilityLabel(label)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            if isExpanded {
                content
            }
        }
        .onChange(of: expandAll?.wrappedValue) { _, newValue in
            guard let newValue else { return }
            withAnimation(.snappy) {
                isExpanded = newValue.expand
            }
        }
    }
}
