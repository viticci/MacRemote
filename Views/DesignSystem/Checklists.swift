import SwiftUI

// MARK: - DeployStageList (SPEC §4.3 — five named stages, failure lands on its stage)

enum DeployStage: Int, CaseIterable, Identifiable {
    case checkAccess
    case createTunnel
    case configureDNS
    case protectEndpoint
    case start

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .checkAccess: "Check Cloudflare access"
        case .createTunnel: "Create tunnel"
        case .configureDNS: "Configure DNS"
        case .protectEndpoint: "Protect endpoint"
        case .start: "Start"
        }
    }
}

enum DeployStageState: Equatable {
    case pending
    case active
    case done
    /// `message` is the human sentence; `raw` is the API text shown in a copyable mono disclosure.
    case failed(message: String, raw: String?)
}

struct DeployStageList: View {
    private let states: [DeployStage: DeployStageState]
    private let onCopyRaw: ((String) -> Void)?

    /// Missing stages default to `.pending`. `onCopyRaw` is the audit-log hook for the raw-error copy.
    init(states: [DeployStage: DeployStageState], onCopyRaw: ((String) -> Void)? = nil) {
        self.states = states
        self.onCopyRaw = onCopyRaw
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            ForEach(DeployStage.allCases) { stage in
                DeployStageRow(
                    stage: stage,
                    state: states[stage] ?? .pending,
                    onCopyRaw: onCopyRaw
                )
            }
        }
    }
}

private struct DeployStageRow: View {
    let stage: DeployStage
    let state: DeployStageState
    let onCopyRaw: ((String) -> Void)?

    @State private var isRawExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            HStack(spacing: Space.s2) {
                glyph
                    .frame(width: 16)
                Text(stage.title)
                    .font(.body)
                    .foregroundStyle(state == .pending ? .secondary : .primary)
            }
            if case let .failed(message, raw) = state {
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(message)
                        .font(TypeRamp.rowDetail)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let raw {
                        rawDisclosure(raw)
                    }
                }
                .padding(.leading, Space.s6)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var glyph: some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Pending")
        case .active:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("In progress")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityLabel("Done")
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.red)
                .accessibilityLabel("Failed")
        }
    }

    private func rawDisclosure(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Button {
                withAnimation(.snappy) {
                    isRawExpanded.toggle()
                }
            } label: {
                HStack(spacing: Space.s1) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isRawExpanded ? 90 : 0))
                    Text("Details")
                        .font(TypeRamp.rowDetail)
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isRawExpanded {
                HStack(alignment: .firstTextBaseline, spacing: Space.s1) {
                    Text(raw)
                        .font(TypeRamp.machineCaption)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    CopyButton(value: raw) {
                        onCopyRaw?(raw)
                    }
                    .controlSize(.small)
                }
                .padding(Space.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: AppShape.mono)
            }
        }
    }
}

// MARK: - SetupChecklist (GUIDELINES §2, SPEC D16 — replaces ConnectionFlowPanel)

struct SetupStep: Identifiable {
    let id: String
    let title: String
    var detail: String?
    var isDone: Bool
    var jumpTitle: String?
    var jump: (() -> Void)?

    init(
        id: String,
        title: String,
        detail: String? = nil,
        isDone: Bool = false,
        jumpTitle: String? = nil,
        jump: (() -> Void)? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.isDone = isDone
        self.jumpTitle = jumpTitle
        self.jump = jump
    }
}

/// D16 mechanics live in the model: the model decides when to collapse (first
/// full pass), when to regress (30 s debounce, one-shot notification), and
/// passes the result here as display state.
enum SetupChecklistDisplay: Equatable {
    case expanded
    /// The graduation moment — "All set ✓" capsule.
    case capsule
    /// Re-expands only the failing row.
    case regression(failingStepID: String)
}

struct SetupChecklist: View {
    private let steps: [SetupStep]
    private let display: SetupChecklistDisplay
    private let onDismiss: (() -> Void)?

    init(steps: [SetupStep], display: SetupChecklistDisplay, onDismiss: (() -> Void)? = nil) {
        self.steps = steps
        self.display = display
        self.onDismiss = onDismiss
    }

    var body: some View {
        switch display {
        case .expanded:
            Card(title: "Setup") {
                VStack(alignment: .leading, spacing: Space.s3) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        SetupChecklistRow(number: index + 1, step: step, isRegressing: false)
                    }
                }
            }
        case .capsule:
            HStack(spacing: Space.s2) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                Text("All set")
                    .font(TypeRamp.chip)
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss setup checklist")
                }
            }
            .padding(.horizontal, Space.s3)
            .padding(.vertical, Space.s2)
            .background(.quaternary.opacity(0.4), in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Setup: all set")
        case let .regression(failingStepID):
            Card(title: "Setup") {
                if let index = steps.firstIndex(where: { $0.id == failingStepID }) {
                    SetupChecklistRow(number: index + 1, step: steps[index], isRegressing: true)
                }
            }
        }
    }
}

private struct SetupChecklistRow: View {
    let number: Int
    let step: SetupStep
    let isRegressing: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: glyphName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(glyphTint)
                .accessibilityLabel(glyphDescription)
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(step.title)
                    .font(.body)
                if let detail = step.detail {
                    Text(detail)
                        .font(TypeRamp.rowDetail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.s2)
            if let jumpTitle = step.jumpTitle, let jump = step.jump {
                Button(jumpTitle, action: jump)
                    .buttonStyle(.link)
            }
        }
    }

    private var glyphName: String {
        if isRegressing { return "exclamationmark.triangle.fill" }
        return step.isDone ? "checkmark.circle.fill" : "circle"
    }

    private var glyphTint: Color {
        if isRegressing { return .orange }
        return step.isDone ? .green : .secondary
    }

    private var glyphDescription: String {
        if isRegressing { return "Needs attention" }
        return step.isDone ? "Done" : "Not done"
    }
}
