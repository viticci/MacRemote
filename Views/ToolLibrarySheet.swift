import SwiftUI

enum ToolLibraryTab: String, CaseIterable, Identifiable {
    case bundles
    case found
    case presets
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bundles: "Bundles"
        case .found: "Found on This Mac"
        case .presets: "Presets"
        case .custom: "Custom"
        }
    }

    var systemImage: String {
        switch self {
        case .bundles: "shippingbox"
        case .found: "sparkle.magnifyingglass"
        case .presets: "list.star"
        case .custom: "slider.horizontal.3"
        }
    }
}

// MARK: - Found-tab filtering and grouping (CLI-9/10/11)

private enum FoundToolsFilter: String, CaseIterable, Identifiable {
    case notYetAdded
    case added
    case new
    case signed
    case unsigned
    case quarantined
    case dependencies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notYetAdded: "Not Yet Added"
        case .added: "Added"
        case .new: "New"
        case .signed: "Signed"
        case .unsigned: "Unsigned"
        case .quarantined: "Quarantined"
        case .dependencies: "Dependencies"
        }
    }
}

private enum FoundToolsGrouping: String, CaseIterable, Identifiable {
    case source
    case category

    var id: String { rawValue }

    var title: String {
        switch self {
        case .source: "Source"
        case .category: "Category"
        }
    }
}

private struct FoundGroup: Identifiable {
    let id: String
    let title: String
    let candidates: [DiscoveredCLICandidate]
}

/// The Library sheet (spec §5.1 Add flow) — 720×560, left tabs
/// Bundles / Found on This Mac / Presets / Custom.
struct ToolLibrarySheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tab: ToolLibraryTab
    @State private var selectedSetID: String?
    @State private var draft = ToolDefinitionDraft()
    @State private var bundleError: String?
    @State private var rowErrors: [String: String] = [:]
    @State private var customError: String?
    @State private var presetCategory: ToolCategory = DefaultToolPresetCatalog.preferredCategory

    // Found on This Mac — the scan home (CLI-DISCOVERY-SPEC §5.2–§5.5)
    @State private var foundSearchText = ""
    @State private var foundFilter: FoundToolsFilter?
    @State private var foundGrouping: FoundToolsGrouping = .source
    @State private var selectedCandidateIDs: Set<String> = []
    @State private var selectedPresetIDs: Set<String> = []
    @State private var expandedCandidateIDs: Set<String> = []
    @State private var expandedPresetIDs: Set<String> = []
    @State private var categoryOverrides: [String: ToolCategory] = [:]
    @State private var isInterpretersGroupExpanded = false
    @State private var isScanInfoPresented = false
    @State private var candidateRowErrors: [String: String] = [:]
    @State private var foundCommitError: String?
    @State private var postAddSummary: String?
    @State private var addedFlashCount: Int?
    @State private var addedFlashTask: Task<Void, Never>?
    @State private var scanDisclosureExpandAll = DetailsExpandAll()
    /// Cached installed-tool signatures. Computing this inline was O(tools)
    /// string joins per call, and it is consulted once per candidate/preset row
    /// per render — O(rows × tools) per frame beachballed the sheet.
    @State private var installedSignatures: Set<String> = []
    @FocusState private var isFoundFilterFocused: Bool

    init(initialTab: ToolLibraryTab = .bundles) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar

            Divider()

            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Divider()

                footer
                    .padding(Space.s4)
            }
        }
        .frame(width: 720, height: 560)
        .task {
            if selectedSetID == nil {
                selectedSetID = DefaultToolPresetCatalog.presetSets.first?.id
            }
        }
        .onChange(of: appModel.tools, initial: true) {
            installedSignatures = Set(appModel.tools.map { ([$0.executablePath] + $0.argumentPattern).joined(separator: "\u{1f}") })
        }
        .onChange(of: appModel.searchFocusToken) {
            if tab == .found {
                isFoundFilterFocused = true
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: tabSelection) {
            ForEach(ToolLibraryTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 176)
    }

    private var tabSelection: Binding<ToolLibraryTab?> {
        Binding(
            get: { tab },
            set: { if let newTab = $0 { tab = newTab } }
        )
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .bundles:
            bundlesTab
        case .found:
            foundTab
        case .presets:
            presetsTab
        case .custom:
            customTab
        }
    }

    // MARK: Bundles (preview-then-confirm)

    private var bundlesTab: some View {
        HStack(spacing: 0) {
            List(selection: $selectedSetID) {
                ForEach(DefaultToolPresetCatalog.presetSets) { presetSet in
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(presetSet.name)
                        Text("\(presetSet.presets.count) tools")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .countText()
                    }
                    .tag(presetSet.id)
                }
            }
            .frame(width: 200)

            Divider()

            if let presetSet = selectedSet {
                bundlePreview(for: presetSet)
            } else {
                EmptyState(
                    "No bundle selected",
                    systemImage: "shippingbox",
                    message: "Pick a bundle to see every tool inside before you install anything."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func bundlePreview(for presetSet: DefaultToolPresetSet) -> some View {
        let installed = installedCount(in: presetSet)
        let total = presetSet.presets.count

        return VStack(alignment: .leading, spacing: Space.s3) {
            Text(presetSet.name)
                .font(TypeRamp.cardTitle)
            Text(presetSet.summary)
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(dedupeLine(installed: installed, total: total))
                .font(TypeRamp.rowDetail)
                .foregroundStyle(installed > 0 ? .primary : .secondary)

            if presetSet.id == "set.reminders", installed > 0 {
                // MO-2: the Bundles tab's Reminders share toggle.
                Toggle("Share Reminders tools", isOn: remindersProfileBinding)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s2) {
                    ForEach(presetSet.presets) { preset in
                        bundlePresetRow(preset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let bundleError {
                Text(bundleError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(Space.s4)
    }

    private func bundlePresetRow(_ preset: DefaultToolPreset) -> some View {
        HStack(spacing: Space.s2) {
            Image(systemName: preset.category.iconSystemImage)
                .foregroundStyle(preset.category.iconTint)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(preset.name)
                .lineLimit(1)
            Text(preset.mode.displayTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isInstalled(preset) {
                Text("Added ✓")
                    .font(TypeRamp.chip)
                    .foregroundStyle(.green)
            } else {
                StateChip(capability: preset.capability)
            }
        }
    }

    private func dedupeLine(installed: Int, total: Int) -> String {
        if installed == 0 {
            return "\(total) tools."
        }
        if installed < total {
            return "\(installed) of \(total) already installed — install the remaining \(total - installed)?"
        }
        return "All \(total) tools are already installed."
    }

    private var remindersProfileBinding: Binding<Bool> {
        Binding(
            get: { appModel.isRemCTLProfileEnabled },
            set: { bundleError = appModel.setRemCTLProfileEnabled($0) }
        )
    }

    // MARK: Found on This Mac — the scan home

    private var foundTab: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            foundHeader

            foundStatusBlock

            foundList

            if let postAddSummary {
                HStack(spacing: Space.s2) {
                    Text(postAddSummary)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .countText()
                    Button("Open Tools") { dismiss() }
                        .controlSize(.small)
                }
            }

            if let foundCommitError {
                Label(foundCommitError, systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(Space.s4)
    }

    private var foundHeader: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Text("Found on This Mac")
                    .font(TypeRamp.cardTitle)
                Spacer()
                Button {
                    isScanInfoPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("How scanning works")
                .accessibilityLabel("How scanning works")
                .popover(isPresented: $isScanInfoPresented, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("How scanning works")
                            .font(TypeRamp.cardTitle)
                        Text(Self.howScanningWorksCopy)
                            .font(TypeRamp.rowDetail)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Space.s4)
                    .frame(width: 400)
                }
            }
            Text("Command-line tools already installed on this Mac — curated presets plus everything a scan turns up.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let howScanningWorksCopy = """
    MacRemote reads install records — Homebrew receipts, npm package files, Python tool records, \
    folder listings, man pages, and code signatures — to learn each tool's name, version, and \
    description. It never runs what it finds, and nothing about this Mac leaves it. A found tool \
    isn't added until you choose it; an added tool isn't shared with any app until you turn \
    sharing on; and every added tool starts as Destructive, so each run asks you first. System, \
    shell, and privilege tools are never suggested — add those manually if you really need them.
    """

    // MARK: Found — status block (controls + progress/summary)

    @ViewBuilder
    private var foundStatusBlock: some View {
        if isScanning || hasScanResults {
            HStack(spacing: Space.s2) {
                TextField("Filter tools…", text: $foundSearchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFoundFilterFocused)
                    .frame(maxWidth: 200)

                Menu {
                    ForEach(FoundToolsFilter.allCases) { option in
                        Toggle(option.title, isOn: foundFilterBinding(for: option))
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .fixedSize()
                .help("Filter found tools")

                Menu {
                    Picker("Group By", selection: $foundGrouping) {
                        ForEach(FoundToolsGrouping.allCases) { grouping in
                            Text(grouping.title).tag(grouping)
                        }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Group", systemImage: "rectangle.3.group")
                }
                .fixedSize()
                .help("Group found tools by source or category")

                Spacer()

                if !isScanning {
                    Button("Scan Again") { startScan() }
                }
            }
        }

        if isScanning {
            HStack(spacing: Space.s2) {
                ProgressView()
                    .controlSize(.small)
                Text("Scanning…")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                Text(progressLedger)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .countText()
                    .lineLimit(1)
                    .accessibilityLabel("Scan progress")
                    .accessibilityValue(progressAccessibilityValue)
                Spacer()
                Button("Cancel") { appModel.cancelCLIScan() }
            }
        } else if hasScanResults {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                Text(foundSummaryLine)
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .countText()
                Spacer()
                if let lastScanDate = appModel.cliScanState.lastScanDate {
                    Text("Last scan: \(lastScanDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(TypeRamp.truthNote)
                        .foregroundStyle(.secondary)
                }
            }

            if case .canceled(_, let completed, _) = appModel.cliScanState, !completed.isEmpty {
                Text("Scan canceled — showing \(completed.map(\.displayName).formatted(.list(type: .and))). Scan again for the rest.")
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func foundFilterBinding(for target: FoundToolsFilter) -> Binding<Bool> {
        Binding(
            get: { foundFilter == target },
            set: { foundFilter = $0 ? target : nil }
        )
    }

    private var isScanning: Bool {
        appModel.cliScanState.isScanning
    }

    /// Results (or a completed scan's memory) exist — drives the controls row.
    private var hasScanResults: Bool {
        !scanCandidates.isEmpty || appModel.cliScanState.lastScanDate != nil
    }

    private var scanCandidates: [DiscoveredCLICandidate] {
        appModel.cliScanState.candidates
    }

    private var progressLedger: String {
        appModel.cliScanState.progress
            .map { progress in
                switch progress.phase {
                case .done(let count): "\(progress.source.displayName) ✓ \(count)"
                case .failed: "\(progress.source.displayName) ✕"
                case .pending, .enumerating: "\(progress.source.displayName) …"
                }
            }
            .joined(separator: " · ")
    }

    private var progressAccessibilityValue: String {
        appModel.cliScanState.progress
            .map { progress in
                switch progress.phase {
                case .done(let count): "\(progress.source.displayName) done, \(count) found"
                case .failed(let reason): "\(progress.source.displayName) failed: \(reason)"
                case .enumerating: "\(progress.source.displayName) scanning"
                case .pending: "\(progress.source.displayName) waiting"
                }
            }
            .joined(separator: ", ")
    }

    private var foundSummaryLine: String {
        let candidates = scanCandidates
        let newCount = candidates.count(where: \.isNewSinceLastScan)
        let addedCount = candidates.count { installedSignatures.contains($0.addedSignature) }
        var line = "\(candidates.count) found"
        if newCount > 0 {
            line += " · \(newCount) new since last scan"
        }
        line += " · \(addedCount) added"
        return line
    }

    // MARK: Found — list body

    private var foundList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.s2) {
                // Before the first scan the call-to-action leads — 59 preset
                // rows would otherwise bury it below the fold.
                if showsInvitationFirst {
                    invitationBlock
                }

                foundPresetsGroup

                switch appModel.cliScanState {
                case .idle:
                    EmptyView()
                case .scanning:
                    foundCandidateGroups
                case .loaded(let candidates, _):
                    if candidates.isEmpty {
                        foundNothingState
                    } else {
                        foundCandidateGroups
                    }
                case .canceled(let candidates, let completed, _):
                    if candidates.isEmpty && completed.isEmpty {
                        EmptyView()
                    } else if candidates.isEmpty {
                        foundNothingState
                    } else {
                        foundCandidateGroups
                    }
                case .failed(let message, let partial, _):
                    if !partial.isEmpty {
                        foundCandidateGroups
                    }
                    EmptyState(
                        "The scan couldn't finish",
                        systemImage: "exclamationmark.triangle.fill",
                        message: message,
                        actionTitle: "Retry",
                        action: { startScan() }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background {
            // ⌘A — visible rows minus Quarantined/Added/Interpreters (§5.7).
            // Disabled while the filter field is focused so text select-all wins.
            Button("Select All Found Tools") { selectAllVisible() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(isFoundFilterFocused)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private var showsInvitationFirst: Bool {
        switch appModel.cliScanState {
        case .idle:
            true
        case .canceled(let candidates, let completed, _):
            candidates.isEmpty && completed.isEmpty
        default:
            false
        }
    }

    private var invitationBlock: some View {
        VStack(spacing: Space.s3) {
            Image(systemName: "sparkle.magnifyingglass")
                .font(.title2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Find more tools on this Mac")
                .font(TypeRamp.cardTitle)
            Text("MacRemote reads names, versions, and install records from Homebrew, npm, Python tool folders, and the folders on your PATH. It never runs what it finds. Nothing leaves this Mac. Tools it finds aren't added — and never shared — until you choose them.")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Button("Scan This Mac") { startScan() }
                .buttonStyle(.glass)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s6)
    }

    private var foundNothingState: some View {
        EmptyState(
            "No command-line tools found",
            systemImage: "sparkle.magnifyingglass",
            message: "MacRemote looked in Homebrew, npm, Python tool folders, and the folders on your PATH. Install a tool, then scan again.",
            actionTitle: "Scan Again",
            action: { startScan() }
        )
        .frame(maxWidth: .infinity)
    }

    private func startScan() {
        postAddSummary = nil
        foundCommitError = nil
        candidateRowErrors = [:]
        appModel.scanInstalledCLIs()
    }

    // MARK: Found — presets group (pinned; absorbs preset-matched hits per R9)

    @ViewBuilder
    private var foundPresetsGroup: some View {
        let presets = visibleFoundPresets
        if !presets.isEmpty {
            foundGroupHeader(
                title: "Presets",
                count: presets.count,
                selectAll: { selectedPresetIDs.formUnion(presets.filter { !isInstalled($0) }.map(\.id)) },
                selectNone: { selectedPresetIDs.subtract(presets.map(\.id)) }
            )
            ForEach(presets) { preset in
                foundPresetRow(preset)
            }
        }
    }

    private var visibleFoundPresets: [DefaultToolPreset] {
        DefaultToolPresetCatalog.featuredPresets.filter { preset in
            guard !foundSearchText.isEmpty else { return true }
            return preset.name.localizedCaseInsensitiveContains(foundSearchText)
                || preset.summary.localizedCaseInsensitiveContains(foundSearchText)
                || preset.executablePath.localizedCaseInsensitiveContains(foundSearchText)
        }
    }

    private func foundPresetRow(_ preset: DefaultToolPreset) -> some View {
        let installed = isInstalled(preset)
        let isExpanded = expandedPresetIDs.contains(preset.id)

        return VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Toggle("", isOn: presetSelectionBinding(preset))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(installed)
                    .accessibilityLabel(presetAccessibilityLabel(preset, installed: installed))

                Image(systemName: preset.category.iconSystemImage)
                    .foregroundStyle(preset.category.iconTint)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text(preset.name)
                    .lineLimit(1)

                if installed {
                    Text("Added ✓")
                        .font(TypeRamp.chip)
                        .foregroundStyle(.green)
                }

                Spacer()

                StateChip(capability: preset.capability)

                disclosureChevron(isExpanded: isExpanded) {
                    toggleDisclosure(presetID: preset.id)
                }
            }

            Text(preset.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 1)
                .padding(.leading, Space.s6)

            if isExpanded {
                VStack(alignment: .leading, spacing: Space.s2) {
                    MonoValue(preset.executablePath, font: TypeRamp.machineCaption, onCopy: {
                        appModel.appendLog(level: .info, "Copied path for \(preset.name).")
                    })
                    .foregroundStyle(.secondary)

                    Text("Adds as \(preset.mode.displayTitle).")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Customize & Save…") {
                        draft = preset.draft
                        customError = nil
                        tab = .custom
                    }
                    .controlSize(.small)
                }
                .padding(.leading, Space.s6)
            }

            if let error = rowErrors[preset.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.leading, Space.s6)
            }
        }
    }

    private func presetSelectionBinding(_ preset: DefaultToolPreset) -> Binding<Bool> {
        Binding(
            get: { isInstalled(preset) || selectedPresetIDs.contains(preset.id) },
            set: { selected in
                if selected {
                    selectedPresetIDs.insert(preset.id)
                } else {
                    selectedPresetIDs.remove(preset.id)
                }
            }
        )
    }

    private func presetAccessibilityLabel(_ preset: DefaultToolPreset, installed: Bool) -> String {
        "\(preset.name), preset. \(preset.summary) \(installed ? "Added." : "Not added.")"
    }

    // MARK: Found — candidate groups

    @ViewBuilder
    private var foundCandidateGroups: some View {
        let groups = candidateGroups
        let interpreters = interpreterCandidates

        ForEach(groups) { group in
            foundGroupHeader(
                title: group.title,
                count: group.candidates.count,
                selectAll: { selectAllInGroup(group) },
                selectNone: { selectedCandidateIDs.subtract(group.candidates.map(\.id)) }
            )
            ForEach(group.candidates) { candidate in
                candidateRow(candidate)
            }
        }

        if !interpreters.isEmpty {
            interpretersGroup(interpreters)
        }

        if !isScanning {
            ForEach(failedSources, id: \.self) { source in
                sourceFailureRow(source)
            }
        }

        if visibleCandidates.isEmpty && !scanCandidates.isEmpty {
            if !foundSearchText.isEmpty {
                EmptyState(searchText: foundSearchText)
                    .frame(maxWidth: .infinity)
            } else {
                Text("No tools match this filter.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.s4)
            }
        }
    }

    private func foundGroupHeader(
        title: String,
        count: Int,
        selectAll: @escaping () -> Void,
        selectNone: @escaping () -> Void
    ) -> some View {
        HStack(spacing: Space.s2) {
            Text(title)
                .font(TypeRamp.cardTitle)
            Text("(\(count))")
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
                .countText()
            Spacer()
            Menu {
                Button("Select All in \(title)", action: selectAll)
                Button("Select None", action: selectNone)
            } label: {
                Text("Select")
            }
            .fixedSize()
            .help("Select or deselect every tool in \(title)")
        }
        .padding(.top, Space.s2)
    }

    private func interpretersGroup(_ interpreters: [DiscoveredCLICandidate]) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Button {
                withAnimation(.snappy) {
                    isInterpretersGroupExpanded.toggle()
                }
            } label: {
                HStack(spacing: Space.s2) {
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isInterpretersGroupExpanded ? 0 : -90))
                    Text("Interpreters — can run any code")
                        .font(TypeRamp.cardTitle)
                    Text("(\(interpreters.count))")
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .countText()
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Interpreters — can run any code, \(interpreters.count) tools")
            .accessibilityValue(isInterpretersGroupExpanded ? "Expanded" : "Collapsed")
            .padding(.top, Space.s2)

            if isInterpretersGroupExpanded {
                ForEach(interpreters) { candidate in
                    candidateRow(candidate)
                }
            }
        }
    }

    private func sourceFailureRow(_ source: CLIScanSource) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Label(sourceFailureLine(for: source), systemImage: "exclamationmark.triangle.fill")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Retry") { appModel.retryCLIScanSource(source) }
            }
            if let raw = appModel.cliScanSourceFailures[source] {
                DetailsDisclosure(id: "library.scanFailure.\(source.rawValue)", expandAll: $scanDisclosureExpandAll) {
                    MonoValue(raw, font: TypeRamp.machineCaption, onCopy: {
                        appModel.appendLog(level: .info, "Copied scan error for \(source.displayName).")
                    })
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, Space.s2)
    }

    private func sourceFailureLine(for source: CLIScanSource) -> String {
        let otherCount = scanCandidates.count { $0.source.scanSource != source }
        guard otherCount > 0 else {
            return "Couldn't read \(source.displayName)'s folder."
        }
        return "Couldn't read \(source.displayName)'s folder — \(otherCount) tools from other sources are shown."
    }

    private var failedSources: [CLIScanSource] {
        CLIScanSource.allCases.filter { appModel.cliScanSourceFailures[$0] != nil }
    }

    // MARK: Found — filtering, grouping, selection sets

    /// Dependency-only formulas stay behind Filter ▸ Dependencies (R17).
    private var visibleCandidates: [DiscoveredCLICandidate] {
        scanCandidates.filter { candidate in
            matchesFoundFilter(candidate) && matchesFoundSearch(candidate)
        }
    }

    private func matchesFoundFilter(_ candidate: DiscoveredCLICandidate) -> Bool {
        switch foundFilter {
        case nil:
            !candidate.isDependencyOnly
        case .notYetAdded:
            !candidate.isDependencyOnly && !isCandidateAdded(candidate)
        case .added:
            !candidate.isDependencyOnly && isCandidateAdded(candidate)
        case .new:
            !candidate.isDependencyOnly && candidate.isNewSinceLastScan
        case .signed:
            !candidate.isDependencyOnly && candidate.isSigned
        case .unsigned:
            !candidate.isDependencyOnly && !candidate.isSigned
        case .quarantined:
            !candidate.isDependencyOnly && candidate.isQuarantined
        case .dependencies:
            candidate.isDependencyOnly
        }
    }

    private func matchesFoundSearch(_ candidate: DiscoveredCLICandidate) -> Bool {
        guard !foundSearchText.isEmpty else { return true }
        let haystacks = [
            candidate.binaryName,
            candidate.stablePath,
            candidate.resolvedPath,
            candidate.summary ?? "",
            candidate.packageName ?? "",
            candidate.source.displayName,
            candidate.source.scanSource.displayName
        ]
        return haystacks.contains { $0.localizedCaseInsensitiveContains(foundSearchText) }
    }

    private var interpreterCandidates: [DiscoveredCLICandidate] {
        visibleCandidates.filter(\.isInterpreter)
    }

    private var candidateGroups: [FoundGroup] {
        let regular = visibleCandidates.filter { !$0.isInterpreter }
        switch foundGrouping {
        case .source:
            return CLIScanSource.allCases.compactMap { source in
                let members = regular.filter { $0.source.scanSource == source }
                guard !members.isEmpty else { return nil }
                return FoundGroup(id: "found.source.\(source.rawValue)", title: source.displayName, candidates: members)
            }
        case .category:
            let grouped = Dictionary(grouping: regular) { effectiveCategory(for: $0) }
            return grouped.keys
                .sorted { $0.title < $1.title }
                .compactMap { category in
                    guard let members = grouped[category] else { return nil }
                    return FoundGroup(id: "found.category.\(category.rawValue)", title: category.title, candidates: members)
                }
        }
    }

    /// Bulk selection skips Quarantined, Added, and Interpreter rows (CD-8/DL-8).
    private func selectAllInGroup(_ group: FoundGroup) {
        let eligible = group.candidates.filter { !$0.isQuarantined && !isCandidateAdded($0) && !$0.isInterpreter }
        selectedCandidateIDs.formUnion(eligible.map(\.id))
    }

    private func selectAllVisible() {
        for group in candidateGroups {
            selectAllInGroup(group)
        }
        selectedPresetIDs.formUnion(visibleFoundPresets.filter { !isInstalled($0) }.map(\.id))
    }

    private func effectiveCategory(for candidate: DiscoveredCLICandidate) -> ToolCategory {
        categoryOverrides[candidate.id] ?? candidate.suggestedCategory
    }

    private func isCandidateAdded(_ candidate: DiscoveredCLICandidate) -> Bool {
        installedSignatures.contains(candidate.addedSignature)
    }

    // MARK: Found — candidate row (§5.2 anatomy)

    private func candidateRow(_ candidate: DiscoveredCLICandidate) -> some View {
        let added = isCandidateAdded(candidate)
        let isExpanded = expandedCandidateIDs.contains(candidate.id)

        return VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                Toggle("", isOn: candidateSelectionBinding(candidate, added: added))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(added)
                    .accessibilityLabel(candidateAccessibilityLabel(candidate, added: added))

                Text(candidate.binaryName)

                Text(candidate.version ?? "—")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                if case .developerID(let team, let name) = candidate.signature {
                    Image(systemName: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Signed — Developer ID: \(name ?? team)")
                        .accessibilityLabel("Signed by \(name ?? team)")
                }

                if added {
                    Text("Added ✓")
                        .font(TypeRamp.chip)
                        .foregroundStyle(.green)
                }

                if candidate.isNewSinceLastScan {
                    StateChip("New", role: .working)
                }

                if candidate.isQuarantined {
                    StateChip("Quarantined", systemImage: "exclamationmark.triangle.fill", role: .attention)
                }

                Spacer()

                if !added {
                    categoryChip(for: candidate)
                }

                disclosureChevron(isExpanded: isExpanded) {
                    toggleDisclosure(candidateID: candidate.id)
                }
            }

            if !added {
                candidateDescriptionLine(candidate)
                    .padding(.leading, Space.s6)
            }

            if isExpanded {
                candidateDisclosure(candidate)
                    .padding(.leading, Space.s6)
            }

            if let error = candidateRowErrors[candidate.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.leading, Space.s6)
            }
        }
    }

    private func candidateSelectionBinding(_ candidate: DiscoveredCLICandidate, added: Bool) -> Binding<Bool> {
        Binding(
            get: { added || selectedCandidateIDs.contains(candidate.id) },
            set: { selected in
                if selected {
                    selectedCandidateIDs.insert(candidate.id)
                } else {
                    selectedCandidateIDs.remove(candidate.id)
                }
            }
        )
    }

    @ViewBuilder
    private func candidateDescriptionLine(_ candidate: DiscoveredCLICandidate) -> some View {
        if candidate.isInterpreter {
            Text("Runs arbitrary programs. Every call asks you first.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let summary = candidate.summary {
            // R11 — harvested text renders verbatim, attribution leads.
            attributedSummaryText(summary, origin: candidate.summaryOrigin)
                .font(.caption)
                .lineLimit(1)
        } else {
            Text("No description yet — add one when you customize it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func attributedSummaryText(_ summary: String, origin: String?) -> Text {
        // R11 — the harvested summary stays a `Text(verbatim:)` segment even
        // inside the interpolation (no Markdown parsing, no link detection).
        let quoted = Text(verbatim: "\u{201C}\(summary)\u{201D}")
        if let origin {
            let attribution = Text("From \(origin): ").foregroundStyle(.secondary)
            return Text("\(attribution)\(quoted)")
        }
        return Text(verbatim: summary)
    }

    private func categoryChip(for candidate: DiscoveredCLICandidate) -> some View {
        let isGuessed = categoryOverrides[candidate.id] == nil
        return Menu {
            ForEach(ToolCategory.allCases) { category in
                Button(category.title) {
                    categoryOverrides[candidate.id] = category
                }
            }
        } label: {
            HStack(spacing: Space.s1) {
                Text(effectiveCategory(for: candidate).title)
                    .font(TypeRamp.chip)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .overlay {
                if isGuessed {
                    Capsule().strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    Capsule().strokeBorder(.secondary.opacity(0.5))
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isGuessed ? "Guessed from its description — click to change." : "Category — click to change.")
        .accessibilityLabel("Category: \(effectiveCategory(for: candidate).title)")
    }

    private func disclosureChevron(isExpanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 0 : -90))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show details")
        .accessibilityLabel("Details")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    /// ⌥-click expands every row disclosure (app-wide disclosure rule, §5.7).
    private func toggleDisclosure(candidateID: String) {
        if NSEvent.modifierFlags.contains(.option) {
            let expand = !expandedCandidateIDs.contains(candidateID)
            withAnimation(.snappy) {
                expandedCandidateIDs = expand ? Set(scanCandidates.map(\.id)) : []
            }
            return
        }
        withAnimation(.snappy) {
            if expandedCandidateIDs.contains(candidateID) {
                expandedCandidateIDs.remove(candidateID)
            } else {
                expandedCandidateIDs.insert(candidateID)
            }
        }
    }

    private func toggleDisclosure(presetID: String) {
        withAnimation(.snappy) {
            if expandedPresetIDs.contains(presetID) {
                expandedPresetIDs.remove(presetID)
            } else {
                expandedPresetIDs.insert(presetID)
            }
        }
    }

    private func candidateAccessibilityLabel(_ candidate: DiscoveredCLICandidate, added: Bool) -> String {
        var parts = [candidate.binaryName]
        if let version = candidate.version {
            parts.append("version \(version)")
        }
        parts.append("from \(candidate.source.displayName)")
        if candidate.isSigned {
            parts.append("signed")
        }
        var label = parts.joined(separator: ", ") + "."
        if let summary = candidate.summary {
            label += " \(summary)."
        }
        label += added ? " Added." : " Not added."
        if candidate.isQuarantined {
            label += " Quarantined — downloaded from the web and not yet opened by macOS."
        }
        return label
    }

    // MARK: Found — row disclosure (R20 anatomy)

    private func candidateDisclosure(_ candidate: DiscoveredCLICandidate) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Image(systemName: candidate.source.badgeSystemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                MonoValue(candidate.resolutionChainDisplay, font: TypeRamp.machineCaption, onCopy: {
                    appModel.appendLog(level: .info, "Copied path for \(candidate.binaryName).")
                })
                .foregroundStyle(.secondary)
            }

            Text(candidate.signatureLine)
                .font(.caption)
                .foregroundStyle(.secondary)

            if case .script(let interpreter, let interpreterMissing) = candidate.fileKind {
                Text("Runs with \(interpreter)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if interpreterMissing {
                    Label("Its interpreter \(interpreter) is missing.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if candidate.isQuarantined {
                Text("Quarantined — downloaded from the web and not yet opened by macOS. Adding it won't change that; macOS may block its first run.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let facts = candidate.installFactsLine {
                Text(verbatim: facts)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let originDomain = candidate.originDomain {
                Text(verbatim: "Downloaded from \(originDomain)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let homepage = candidate.homepage {
                // Display-only — never a tappable link (§3.1).
                Text(verbatim: "Homepage: \(homepage)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Space.s2) {
                Text("Category")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                categoryChip(for: candidate)
            }

            Text("Adds as Flexible Command, treated as Destructive — every run asks you first. Not shared with any app until you turn sharing on.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help("Treated as Destructive — MacRemote doesn't know what this tool can do, so every call will ask you first. You can change this.")

            if !isCandidateAdded(candidate) {
                Button("Customize & Save…") {
                    var prefilled = appModel.scanToolDraft(for: candidate)
                    prefilled.category = effectiveCategory(for: candidate)
                    draft = prefilled
                    customError = nil
                    tab = .custom
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, Space.s1)
    }

    // MARK: Found — commit (§5.4, DL-2/R4)

    private var selectedFoundPresets: [DefaultToolPreset] {
        DefaultToolPresetCatalog.featuredPresets.filter {
            selectedPresetIDs.contains($0.id) && !isInstalled($0)
        }
    }

    private var selectedFoundCandidates: [DiscoveredCLICandidate] {
        scanCandidates.filter {
            selectedCandidateIDs.contains($0.id) && !isCandidateAdded($0)
        }
    }

    private var foundSelectionCount: Int {
        selectedFoundPresets.count + selectedFoundCandidates.count
    }

    private var foundFooterCaption: String {
        var caption = "\(foundSelectionCount) selected"
        if !selectedFoundCandidates.isEmpty {
            caption += " · new tools aren't shared until you turn sharing on"
            let quarantined = selectedFoundCandidates.count(where: \.isQuarantined)
            if quarantined > 0 {
                caption += " · includes \(quarantined) quarantined tool\(quarantined == 1 ? "" : "s")"
            }
        }
        return caption
    }

    private var addFoundButtonTitle: String {
        if let addedFlashCount {
            return "Added \(addedFlashCount) Tool\(addedFlashCount == 1 ? "" : "s") ✓"
        }
        let count = foundSelectionCount
        guard count > 0 else { return "Add Tools" }
        return "Add \(count) Tool\(count == 1 ? "" : "s")"
    }

    private func commitFoundSelection() {
        foundCommitError = nil
        postAddSummary = nil
        candidateRowErrors = [:]

        let presets = selectedFoundPresets
        let candidates = selectedFoundCandidates

        // Per-row pre-validation so failures land under their rows and the rest
        // of the batch still commits (§5.4). Uses the provenance-free draft —
        // validation fields are identical and this skips a content-hash read.
        var addable: [DiscoveredCLICandidate] = []
        for candidate in candidates {
            let withCategory = candidate.withSuggestedCategory(effectiveCategory(for: candidate))
            if let fieldError = withCategory.makeDraft().firstFieldError {
                candidateRowErrors[candidate.id] = fieldError.message
            } else {
                addable.append(withCategory)
            }
        }

        var addedCount = 0
        var scanAddSucceeded = false
        if !addable.isEmpty {
            if let error = appModel.addToolsFromScan(addable) {
                foundCommitError = error
            } else {
                scanAddSucceeded = true
                addedCount += addable.count
                selectedCandidateIDs.subtract(addable.map(\.id))
            }
        }

        if !presets.isEmpty {
            // Curated presets keep the existing add pipeline (G3 — enabling
            // curated presets by default is deliberate; scan adds are not).
            if let error = appModel.addUserTools(from: presets, sourceName: "Found on This Mac") {
                foundCommitError = foundCommitError.map { "\($0) \(error)" } ?? error
            } else {
                addedCount += presets.count
                selectedPresetIDs.subtract(presets.map(\.id))
            }
        }

        guard addedCount > 0 else { return }

        if scanAddSucceeded {
            postAddSummary = "Added \(addedCount) tool\(addedCount == 1 ? "" : "s") from this Mac — none shared yet."
        } else {
            postAddSummary = "Added \(addedCount) tool\(addedCount == 1 ? "" : "s") from this Mac."
        }

        // Success morph (plain swap under Reduce Motion — §5.7).
        if reduceMotion {
            addedFlashCount = addedCount
        } else {
            withAnimation { addedFlashCount = addedCount }
        }
        addedFlashTask?.cancel()
        addedFlashTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            if reduceMotion {
                addedFlashCount = nil
            } else {
                withAnimation { addedFlashCount = nil }
            }
        }
    }

    // MARK: Presets

    private var presetsTab: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            tabHeader(
                title: "Presets",
                caption: "Single-tool recipes — add one as-is, or customize it first."
            )

            Picker("Category", selection: $presetCategory) {
                ForEach(DefaultToolPresetCatalog.categories) { category in
                    Text(category.title).tag(category)
                }
            }
            .fixedSize()

            let presets = categoryPresets
            if presets.isEmpty {
                Text("No presets in this category.")
                    .font(TypeRamp.rowDetail)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                presetList(presets)
            }
        }
        .padding(Space.s4)
    }

    private var categoryPresets: [DefaultToolPreset] {
        let featuredIDs = Set(DefaultToolPresetCatalog.featuredPresets.map(\.id))
        return DefaultToolPresetCatalog
            .presets(in: presetCategory)
            .filter { !featuredIDs.contains($0.id) }
    }

    private func presetList(_ presets: [DefaultToolPreset]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s3) {
                ForEach(presets) { preset in
                    presetRow(preset)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func presetRow(_ preset: DefaultToolPreset) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: preset.category.iconSystemImage)
                    .foregroundStyle(preset.category.iconTint)
                    .frame(width: 20)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack(spacing: Space.s2) {
                        Text(preset.name)
                        Text(preset.mode.displayTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isInstalled(preset) {
                            Text("Added ✓")
                                .font(TypeRamp.chip)
                                .foregroundStyle(.green)
                        }
                    }
                    Text(preset.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Customize & Save") {
                    draft = preset.draft
                    customError = nil
                    tab = .custom
                }
                .controlSize(.small)

                Button("Just Add") {
                    rowErrors[preset.id] = appModel.addUserTool(from: preset.draft)
                }
                .controlSize(.small)
                .disabled(isInstalled(preset))
            }

            if let error = rowErrors[preset.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: Custom (the full editor form)

    private var customTab: some View {
        VStack(spacing: 0) {
            tabHeader(
                title: "Custom",
                caption: "Define one executable and exactly how apps can call it."
            )
            .padding(Space.s4)

            Divider()

            ToolDefinitionForm(draft: $draft)

            if let customError {
                Text(customError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s2)
            }
        }
    }

    private func tabHeader(title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(title)
                .font(TypeRamp.cardTitle)
            Text(caption)
                .font(TypeRamp.rowDetail)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button(tab == .custom ? "Cancel" : "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Spacer()

            switch tab {
            case .bundles:
                Button(installButtonTitle) { installSelectedSet() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canInstallSelectedSet)
            case .custom:
                Button("Save") { saveCustomTool() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            case .found:
                Text(foundFooterCaption)
                    .font(TypeRamp.truthNote)
                    .foregroundStyle(.secondary)
                    .countText()
                Button(addFoundButtonTitle) { commitFoundSelection() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(foundSelectionCount == 0 || addedFlashCount != nil)
            case .presets:
                EmptyView()
            }
        }
    }

    private var installButtonTitle: String {
        guard let presetSet = selectedSet else { return "Install Tools" }
        let remaining = presetSet.presets.count - installedCount(in: presetSet)
        guard remaining > 0 else { return "All Installed ✓" }
        return remaining == 1 ? "Install 1 Tool" : "Install \(remaining) Tools"
    }

    private var canInstallSelectedSet: Bool {
        guard let presetSet = selectedSet else { return false }
        return installedCount(in: presetSet) < presetSet.presets.count
    }

    private func installSelectedSet() {
        guard let presetSet = selectedSet else { return }
        bundleError = appModel.addUserTools(from: presetSet)
    }

    private func saveCustomTool() {
        let isScanSourced = draft.provenance != nil
        // R4 — a scan-sourced save arrives Not Shared in the same add
        // transaction; sharing stays a separate act in Tools.
        if let error = appModel.addUserTool(from: draft, shared: !isScanSourced) {
            customError = error
            return
        }
        if isScanSourced {
            // Back to the Found tab so the row flips to "Added ✓" (§5.3).
            draft = ToolDefinitionDraft()
            tab = .found
        } else {
            dismiss()
        }
    }

    // MARK: Dedupe helpers (same signature scheme the model uses)

    private var selectedSet: DefaultToolPresetSet? {
        DefaultToolPresetCatalog.presetSets.first { $0.id == selectedSetID }
    }

    private func isInstalled(_ preset: DefaultToolPreset) -> Bool {
        let signature = ([preset.executablePath] + preset.draft.argumentPattern).joined(separator: "\u{1f}")
        return installedSignatures.contains(signature)
    }

    private func installedCount(in presetSet: DefaultToolPresetSet) -> Int {
        presetSet.presets.count(where: isInstalled)
    }
}

// MARK: - Candidate display helpers (view-side only; no harvested text is altered)

private extension DiscoveredCLICandidate {
    var isSigned: Bool {
        switch signature {
        case .developerID, .adhoc: true
        case .unsigned, .invalid, .unchecked: false
        }
    }

    /// §5.3 signature line, glossary states: Signed / Not code-signed.
    var signatureLine: String {
        switch signature {
        case .developerID(let team, let name): "Signed — Developer ID: \(name ?? team)"
        case .adhoc: "Signed on this Mac (ad hoc)"
        case .unsigned: "Not code-signed. Common for scripts and tools built on this Mac."
        case .invalid: "Code signature invalid."
        case .unchecked: "Signature not checked yet."
        }
    }

    var resolutionChainDisplay: String {
        resolutionChain.count > 1 ? resolutionChain.joined(separator: " → ") : stablePath
    }

    /// "Installed Jun 12, 2026 · Homebrew formula yt-dlp · Also installs: x (1 more)"
    var installFactsLine: String? {
        var parts: [String] = []
        if let installDate {
            parts.append("Installed \(installDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let packageName {
            if source == .application {
                parts.append("CLI provided by \(packageName)")
            } else {
                parts.append("\(packageNoun) \(packageName)")
            }
        }
        if let first = siblingExecutables.first {
            let more = siblingExecutables.count - 1
            parts.append(more > 0 ? "Also installs: \(first) (\(more) more)" : "Also installs: \(first)")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }

    var packageNoun: String {
        switch source {
        case .homebrewFormula: "Homebrew formula"
        case .homebrewTap: "Homebrew tap formula"
        case .homebrewCask: "Homebrew cask"
        case .npmGlobal: "npm package"
        case .uvTool: "uv tool"
        case .pipx: "pipx package"
        case .pipUser: "pip package"
        case .cargo: "Cargo crate"
        case .goBinary: "Go module"
        case .application: "App"
        case .looseBinary: "File"
        }
    }

    func withSuggestedCategory(_ category: ToolCategory) -> DiscoveredCLICandidate {
        DiscoveredCLICandidate(
            id: id,
            source: source,
            binaryName: binaryName,
            stablePath: stablePath,
            resolvedPath: resolvedPath,
            resolutionChain: resolutionChain,
            aliases: aliases,
            packageName: packageName,
            version: version,
            summary: summary,
            summaryOrigin: summaryOrigin,
            homepage: homepage,
            siblingExecutables: siblingExecutables,
            installedOnRequest: installedOnRequest,
            installDate: installDate,
            fileKind: fileKind,
            signature: signature,
            isQuarantined: isQuarantined,
            originDomain: originDomain,
            isInterpreter: isInterpreter,
            isDependencyOnly: isDependencyOnly,
            suggestedCategory: category,
            isNewSinceLastScan: isNewSinceLastScan
        )
    }
}

extension DiscoveredCLICandidate.Source {
    /// N4 — reuse, don't invent: shippingbox = packages, folder = PATH folders,
    /// terminal = executables (toolExecutable's existing meaning).
    var badgeSystemImage: String {
        switch self {
        case .homebrewFormula, .homebrewTap, .homebrewCask, .npmGlobal,
             .uvTool, .pipx, .pipUser, .cargo, .goBinary:
            "shippingbox"
        case .application:
            "terminal"
        case .looseBinary:
            "folder"
        }
    }
}
