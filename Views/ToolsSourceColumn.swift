import SwiftUI

/// What the Tools page is showing: everything, one command-line group, every
/// MCP server, one imported server, or one server found on this Mac that is
/// not imported yet. Persisted by raw value so the page reopens where it was.
enum ToolsSource: Hashable, RawRepresentable {
    enum CommandLineGroup: String, CaseIterable, Identifiable {
        case builtIn
        case federico
        case otherCatalog
        case added
        case found

        var id: String { rawValue }

        var title: String {
            switch self {
            case .builtIn: "Built-in"
            case .federico: DefaultToolPresetPublisher.federicoViticci.title
            case .otherCatalog: DefaultToolPresetPublisher.other.title
            case .added: "Added by You"
            case .found: "Found on This Mac"
            }
        }

        var systemImage: String {
            switch self {
            case .builtIn: "shippingbox"
            case .federico: "person.crop.circle"
            case .otherCatalog: "square.stack.3d.up"
            case .added: "pencil.and.list.clipboard"
            case .found: "sparkle.magnifyingglass"
            }
        }
    }

    case all
    case commandLine(CommandLineGroup)
    case allMCP
    case server(String)
    case candidate(String)

    var rawValue: String {
        switch self {
        case .all: "all"
        case .commandLine(let group): "cli.\(group.rawValue)"
        case .allMCP: "mcp.all"
        case .server(let identity): "server.\(identity)"
        case .candidate(let id): "candidate.\(id)"
        }
    }

    init?(rawValue: String) {
        if rawValue == "all" {
            self = .all
        } else if rawValue == "mcp.all" {
            self = .allMCP
        } else if rawValue.hasPrefix("cli."), let group = CommandLineGroup(rawValue: String(rawValue.dropFirst(4))) {
            self = .commandLine(group)
        } else if rawValue.hasPrefix("server.") {
            self = .server(String(rawValue.dropFirst(7)))
        } else if rawValue.hasPrefix("candidate.") {
            self = .candidate(String(rawValue.dropFirst(10)))
        } else {
            return nil
        }
    }

    var isMCP: Bool {
        switch self {
        case .allMCP, .server, .candidate: true
        case .all, .commandLine: false
        }
    }
}

/// One row of the source column.
struct ToolsSourceRow: Identifiable {
    enum Trailing: Equatable {
        case count(Int)
        case new
        case none
    }

    let source: ToolsSource
    let title: String
    let systemImage: String
    let tint: Color
    let trailing: Trailing
    /// A glyph after the title for a server that needs something from you.
    var attention: MCPServerStatus.Kind? = nil

    var id: String { source.rawValue }
}

/// The left column of the Tools page: command-line groups above, MCP servers
/// below, each one click away. Rendered as a source list, never as glass.
struct ToolsSourceColumn: View {
    let allCount: Int
    let commandLineRows: [ToolsSourceRow]
    let mcpCount: Int
    let serverRows: [ToolsSourceRow]
    let candidateRows: [ToolsSourceRow]
    let isScanning: Bool
    @Binding var selection: ToolsSource
    let scanAction: () -> Void

    var body: some View {
        List(selection: binding) {
            row(ToolsSourceRow(
                source: .all,
                title: "All Tools",
                systemImage: "square.grid.2x2",
                tint: .secondary,
                trailing: .count(allCount)
            ))

            Section("Command Line") {
                ForEach(commandLineRows, content: row)
            }

            Section("MCP Servers") {
                row(ToolsSourceRow(
                    source: .allMCP,
                    title: "All MCP Servers",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: .secondary,
                    trailing: .count(mcpCount)
                ))
                ForEach(serverRows, content: row)
                ForEach(candidateRows, content: row)
                if serverRows.isEmpty, candidateRows.isEmpty {
                    Button {
                        scanAction()
                    } label: {
                        Label(isScanning ? "Scanning…" : "Scan This Mac", systemImage: "sparkle.magnifyingglass")
                    }
                    .disabled(isScanning)
                    .help("Find the MCP servers your Mac's AI apps already use")
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityLabel("Tool sources")
    }

    private var binding: Binding<ToolsSource?> {
        Binding(
            get: { selection },
            set: { if let newValue = $0 { selection = newValue } }
        )
    }

    private func row(_ row: ToolsSourceRow) -> some View {
        Label {
            HStack(spacing: Space.s1) {
                Text(row.title)
                    .lineLimit(1)
                if let attention = row.attention, let glyph = attention.columnGlyph {
                    Image(systemName: glyph.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(glyph.tint)
                        .symbolRenderingMode(.hierarchical)
                        .help(glyph.help)
                        .accessibilityLabel(glyph.help)
                }
            }
        } icon: {
            Image(systemName: row.systemImage)
                .foregroundStyle(row.tint)
        }
        .modifier(SourceBadge(trailing: row.trailing))
        .tag(row.source)
    }
}

private struct SourceBadge: ViewModifier {
    let trailing: ToolsSourceRow.Trailing

    @ViewBuilder
    func body(content: Content) -> some View {
        switch trailing {
        case .count(let count):
            content.badge(count)
        case .new:
            content.badge(Text("New"))
        case .none:
            content
        }
    }
}

/// The state of one MCP server as the Tools page reports it.
struct MCPServerStatus: Equatable {
    enum Kind: Equatable {
        case signedIn
        case needsSignIn
        case signingIn
        case importing
        case checking
        case checkFailed
        case ready
        case viewOnly
        case unknown

        /// Only states that need something from you reach the column.
        var columnGlyph: (systemImage: String, tint: Color, help: String)? {
            switch self {
            case .needsSignIn: ("person.crop.circle.badge.exclamationmark", .orange, "Sign-in required")
            case .checkFailed: ("exclamationmark.triangle.fill", .orange, "The last check failed")
            case .signingIn: ("person.crop.circle.badge.clock", .blue, "Signing in")
            case .importing: ("arrow.down.circle.dotted", .blue, "Importing tools")
            case .checking, .signedIn, .ready, .viewOnly, .unknown: nil
            }
        }
    }

    let kind: Kind
    /// The human sentence for the server page (what happened, what to do).
    let detail: String?

    @MainActor @ViewBuilder
    var chip: some View {
        switch kind {
        case .signedIn:
            StateChip("Signed In", systemImage: "person.crop.circle.badge.checkmark", role: .ready)
        case .needsSignIn:
            StateChip("Sign-in Required", systemImage: "person.crop.circle.badge.exclamationmark", role: .attention)
        case .signingIn:
            StateChip("Signing In", systemImage: "person.crop.circle.badge.clock", role: .working)
        case .importing:
            StateChip("Importing", systemImage: "arrow.down.circle.dotted", role: .working)
        case .checking:
            StateChip("Checking", systemImage: "circle.dashed", role: .working)
        case .checkFailed:
            StateChip("Check Failed", systemImage: "exclamationmark.triangle.fill", role: .attention)
        case .ready:
            StateChip("Ready to Import", systemImage: "tray.and.arrow.down", role: .ready)
        case .viewOnly:
            StateChip("View Only", systemImage: "eye", role: .off)
        case .unknown:
            EmptyView()
        }
    }
}
