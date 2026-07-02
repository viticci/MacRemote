import AppKit
import SwiftUI

// MARK: - AuroraExchangeUnderlay (a color layer, NOT glass — GUIDELINES §3 untouched)

/// "Aurora Exchange": one liquid light field under the WHOLE hero glass group.
/// The union silhouette (status pill + weld + URL capsule) is rebuilt in-shader
/// as a smooth-min metaball from the two measured frames, and packet comets
/// ride a closed circuit — along the URL capsule, up through the neck into
/// "Public", around it, and back. The layer sits BEHIND the GlassEffectContainer,
/// so the real Liquid Glass refracts the light: the liquidity is optical.
/// Shader: `conduitLight` in the committed `Shaders/default.metallib`
/// (script/compile_shaders.sh; script/render_shader_preview.swift previews it
/// offscreen without launching the app).
struct AuroraExchangeUnderlay: View {
    var tint: Color
    /// Frames of the status pill and URL capsule in this layer's coordinate space.
    var statusFrame: CGRect
    var urlFrame: CGRect

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
    /// wrapped wall clock, so resuming lands the field where live traffic
    /// "would be" — it never visibly rewinds after an occlusion nap.
    private var paused: Bool { !isWindowVisible || reduceMotion }

    var body: some View {
        if Self.isAvailable, !reduceTransparency, statusFrame.width > 1, urlFrame.width > 1 {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
                let t = Float(context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 120))        // seamless 120 s loop
                Rectangle()
                    .fill(.white)   // alpha carrier; the shader masks to the union SDF
                    .colorEffect(ShaderLibrary.bundle(.module).conduitLight(
                        .boundingRect,
                        .float(t),
                        .color(tint),
                        .float(Float(gain)),
                        .float(reduceMotion ? 0 : 1),  // Reduce Motion: static field
                        .float2(Float(statusFrame.minX), Float(statusFrame.minY)),
                        .float2(Float(statusFrame.width), Float(statusFrame.height)),
                        .float2(Float(urlFrame.minX), Float(urlFrame.minY)),
                        .float2(Float(urlFrame.width), Float(urlFrame.height))
                    ))
            }
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
            // Outermost: covers the WindowReader background too, so the
            // ornament (in an .overlay above the glass) never swallows taps
            // meant for the copy button beneath it.
            .allowsHitTesting(false)
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

        // Belt-and-braces with SwiftUI's allowsHitTesting: this AppKit probe
        // is purely an occlusion sensor and must never intercept a click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            // Defer: mutating SwiftUI state during layout is a runtime warning.
            Task { @MainActor in self.onWindow(window) }
        }
    }
}
