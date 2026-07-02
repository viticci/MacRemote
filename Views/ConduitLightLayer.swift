import AppKit
import SwiftUI

// MARK: - ConduitLightLayer (a color layer, NOT glass — the GUIDELINES §3 map is untouched)

/// "Liquid Light Conduit": counter-flowing fiber-optic tracers inside the hero
/// URL capsule while the tunnel is public — outbound above the axis, inbound
/// below, so the open tunnel visibly exchanges information both ways at once.
/// Rendered by `conduitLight` in `Shaders/default.metallib`; the metallib is
/// PREcompiled and committed (script/compile_shaders.sh — the CLT-only host
/// has no Metal compiler, the runtime compiler validated the source).
struct ConduitLightLayer: View {
    var tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hostWindow: NSWindow?
    @State private var isWindowVisible = true
    @State private var gain: Double = 0   // master intensity, animated 0→1 on entry

    /// A build without the committed metallib silently disables the ornament
    /// instead of failing at render time.
    private static let isAvailable =
        Bundle.module.url(forResource: "default", withExtension: "metallib") != nil

    /// No ticks while occluded or under Reduce Motion. The time base is the
    /// wrapped wall clock, so resuming lands tracers where live traffic
    /// "would be" — the conduit never visibly rewinds after an occlusion nap.
    private var paused: Bool { !isWindowVisible || reduceMotion }

    var body: some View {
        if Self.isAvailable, !reduceTransparency {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
                let t = Float(context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 120))        // seamless 120 s loop
                Capsule()
                    .fill(.white)   // alpha-only mask; the shader replaces the fill
                    .colorEffect(ShaderLibrary.bundle(.module).conduitLight(
                        .boundingRect,
                        .float(t),
                        .color(tint),
                        .float(Float(gain)),
                        .float(reduceMotion ? 0 : 1)   // Reduce Motion: static tube only
                    ))
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .background(WindowReader(window: $hostWindow))
            .onChange(of: hostWindow) { _, window in
                isWindowVisible = window?.occlusionState.contains(.visible) ?? true
            }
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didChangeOcclusionStateNotification)
            ) { note in
                guard let window = note.object as? NSWindow, window === hostWindow else { return }
                isWindowVisible = window.occlusionState.contains(.visible)
            }
            .task {
                // Let the glassEffectID morph into .publicRunning settle before
                // the light fades up (avoids mid-morph shader snapshots).
                try? await Task.sleep(for: .seconds(0.45))
                withAnimation(.easeInOut(duration: 0.6)) { gain = 1 }
            }
        }
    }
}

/// Hands the hosting NSWindow up to SwiftUI so occlusion can be observed.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> Probe {
        Probe { window = $0 }
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        private let onWindow: (NSWindow?) -> Void

        init(_ onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("unused") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // Defer: mutating SwiftUI state during layout is a runtime warning.
            Task { @MainActor in self.onWindow(window) }
        }
    }
}
