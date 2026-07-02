import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Activity — spec §5.5 (parity LO-1/LO-2). The session-only event list:
/// level filter, Events | Everything scope (a display filter, never a purge),
/// search (⌘F), Copy All, Export… (.txt/.json), Clear, and the truth footer.
struct ActivityView: View {
    private enum LevelFilter: String, CaseIterable, Identifiable {
        case all
        case info
        case warning
        case error

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .info: "Info"
            case .warning: "Warning"
            case .error: "Error"
            }
        }

        var level: AppLogEntry.Level? {
            switch self {
            case .all: nil
            case .info: .info
            case .warning: .warning
            case .error: .error
            }
        }
    }

    private enum Scope: String, CaseIterable, Identifiable {
        case events
        case everything

        var id: String { rawValue }

        var title: String {
            switch self {
            case .events: "Events"
            case .everything: "Everything"
            }
        }
    }

    @Environment(AppModel.self) private var appModel

    @State private var levelFilter: LevelFilter = .all
    @State private var scope: Scope = .events
    @State private var searchText = ""
    @State private var exportDocument: ActivityExportDocument?
    @State private var isExporterPresented = false
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        content
            .navigationTitle("Activity")
            .navigationSubtitle("This session")
            .searchable(text: $searchText, prompt: "Search activity")
            .searchFocused($isSearchFocused)
            .toolbar { toolbarContent }
            .fileExporter(
                isPresented: $isExporterPresented,
                document: exportDocument,
                contentType: exportDocument?.contentType ?? .plainText,
                defaultFilename: "MacRemote Activity"
            ) { result in
                if case .success = result, let document = exportDocument {
                    appModel.appendLog(level: .info, "Exported \(document.entryCount) activity entries.")
                }
            }
            .onChange(of: appModel.searchFocusToken) {
                isSearchFocused = true
            }
            .pageContainerShape()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        Group {
            if appModel.logs.isEmpty {
                EmptyState(
                    "No activity yet this session.",
                    systemImage: "waveform.path.ecg",
                    message: "Server, connection, and approval events show up here as they happen."
                )
            } else if filteredEntries.isEmpty {
                EmptyState(searchText: searchText)
            } else {
                entryList
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            truthFooter
        }
    }

    private var entryList: some View {
        List(filteredEntries) { entry in
            ActivityLogRow(
                time: entry.date,
                level: rowLevel(for: entry.level),
                message: entry.message,
                isSecurityEvent: ActivityEventClassifier.isSecurityEvent(entry.message)
            )
        }
        .listStyle(.plain)
        .scrollEdgeEffectStyle(.hard, for: .top)
    }

    private var truthFooter: some View {
        Text("This session — up to 250 entries. Cleared when MacRemote quits.")
            .font(TypeRamp.truthNote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.s2)
            .background(.bar)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Picker("Level", selection: $levelFilter) {
                ForEach(LevelFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.menu)
            .help("Filter by level")

            Picker("Scope", selection: $scope) {
                ForEach(Scope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .help("Events foregrounds approvals, sign-ins, and tool runs")
        }

        ToolbarSpacer()

        ToolbarItemGroup {
            Button("Copy All", systemImage: "doc.on.doc") {
                copyAll()
            }
            .disabled(filteredEntries.isEmpty)

            Menu("Export…", systemImage: "square.and.arrow.up") {
                Button("Export as Text…") {
                    beginExport(as: .plainText)
                }
                Button("Export as JSON…") {
                    beginExport(as: .json)
                }
            }
            .disabled(filteredEntries.isEmpty)

            Button("Clear", systemImage: "trash") {
                appModel.clearActivity()
            }
            .disabled(appModel.logs.isEmpty)
        }
    }

    // MARK: - Filtering (display-only; the buffer is never mutated here)

    private var filteredEntries: [AppLogEntry] {
        appModel.logs.filter { entry in
            if let level = levelFilter.level, entry.level != level {
                return false
            }
            if scope == .events, ActivityEventClassifier.isProcessOutput(entry.message) {
                return false
            }
            if !searchText.isEmpty, !entry.message.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            return true
        }
    }

    private func rowLevel(for level: AppLogEntry.Level) -> ActivityLogRow.Level {
        switch level {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }

    // MARK: - Copy / Export

    private func copyAll() {
        let entries = filteredEntries
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(plainText(for: entries), forType: .string)
        appModel.appendLog(level: .info, "Copied \(entries.count) activity entries.")
    }

    private func beginExport(as contentType: UTType) {
        let entries = filteredEntries
        let text = contentType == .json ? jsonText(for: entries) : plainText(for: entries)
        exportDocument = ActivityExportDocument(text: text, contentType: contentType, entryCount: entries.count)
        isExporterPresented = true
    }

    private func plainText(for entries: [AppLogEntry]) -> String {
        // Exports read oldest → newest; the list displays newest first.
        entries.reversed().map { entry in
            "\(entry.date.formatted(date: .abbreviated, time: .standard))  \(entry.level.title)  \(entry.message)"
        }
        .joined(separator: "\n")
    }

    private func jsonText(for entries: [AppLogEntry]) -> String {
        let payload = entries.reversed().map { entry in
            [
                "time": entry.date.ISO8601Format(),
                "level": entry.level.rawValue,
                "message": entry.message
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            return "[]"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Event classification (spec §5.5 — prefix/marker matching, not a taxonomy)

enum ActivityEventClassifier {
    /// Lines the Events scope demotes: raw cloudflared stdout (which carries its
    /// own ISO timestamp + level token) and the app's own copy/reveal chatter.
    static func isProcessOutput(_ message: String) -> Bool {
        if message.hasPrefix("Copied ") || message.hasPrefix("Exported ") || message.hasPrefix("Revealed ") {
            return true
        }
        guard message.hasPrefix("20") else { return false }
        return [" INF ", " WRN ", " ERR ", " DBG "].contains(where: message.contains)
    }

    /// Security-relevant lines get the leading `lock.shield` glyph.
    static func isSecurityEvent(_ message: String) -> Bool {
        guard !isProcessOutput(message) else { return false }
        let lowered = message.lowercased()
        return securityMarkers.contains { lowered.contains($0) }
    }

    private static let securityMarkers = [
        "oauth", "approv", "denied", "deny", "token", "credential",
        "signed out", "sign out", "always allow", "always-allow",
        "without asking", "private address", "instance id", "client policy",
        "revoked", "rotated", "authorization"
    ]
}

// MARK: - Export document

struct ActivityExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText, .json]

    let text: String
    let contentType: UTType
    let entryCount: Int

    init(text: String, contentType: UTType, entryCount: Int) {
        self.text = text
        self.contentType = contentType
        self.entryCount = entryCount
    }

    init(configuration: ReadConfiguration) throws {
        // Export-only; reading back is never exercised by the app.
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
        contentType = .plainText
        entryCount = 0
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

// MARK: - Model access

extension AppModel {
    /// Spec §5.5 Clear — empties this session's buffer. Distinct from the
    /// Events | Everything scope, which only filters the display.
    func clearActivity() {
        logs.removeAll()
    }
}
