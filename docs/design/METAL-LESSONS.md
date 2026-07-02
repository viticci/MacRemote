# Metal + SwiftUI Shader Lessons — the Aurora Exchange Playbook

What we learned shipping the animated "Aurora Exchange" hero ornament
(`Shaders/ConduitLight.metal` + `Views/ConduitLightLayer.swift`, 2026-07-02).
Read this before building the next Metal thing in this repo — every lesson
here was paid for with a broken build or an invisible shader.

## Toolchain reality on this Mac

- **The CLT-only host has no Metal compiler.** `xcrun metal` fails under
  Command Line Tools. Xcode-beta at `/Applications/Xcode-beta.app` has it,
  but only after the MetalToolchain download component is installed
  (`xcodebuild -downloadComponent MetalToolchain`).
- **Commit the compiled `.metallib`.** Swift builds use the CLT + pinned
  26.5 SDK (see the build scripts), which cannot compile `.metal` sources.
  `script/compile_shaders.sh` finds a Metal toolchain across
  `DEVELOPER_DIR` / `xcode-select -p` / Xcode / Xcode-beta, compiles
  `Shaders/*.metal` to `Shaders/default.metallib`, and that binary is
  committed. Regular builds never need Xcode.
- **SwiftPM resource declaration is a trap.** The target must BOTH
  `.copy("Shaders/default.metallib")` AND exclude the `.metal` source.
  Declaring only one breaks the build two different ways: no `Bundle.module`
  accessor for the lib, or a duplicate-output collision on the source.

## Iterate offscreen, never sight-unseen

- **Never ship a shader you haven't rendered.** The single most useful tool
  was `script/render_shader_preview.swift`: it loads the `.metal` SOURCE at
  runtime (`device.makeLibrary(source:)` — no Metal toolchain needed!),
  runs a dedicated `previewGrid` compute kernel, and writes PNG frames at
  several timestamps. Look at the PNGs after every tweak.
- **Share the core function between the app shader and the preview
  kernel.** `auroraUnion()` is called by both the SwiftUI `colorEffect`
  entry point and `previewGrid`, so the preview renders exactly what the
  app renders. Without this the preview lies to you.
- **When the app looks wrong but the preview looks right, the bug is
  layering, not the shader.** An `ImageRenderer` reproduction of the exact
  SwiftUI stack (glass + shader layer + text) isolates "shader broken"
  from "app compositing broken" in one screenshot.

## Layering with Liquid Glass

- **Do not put a light layer under real Liquid Glass.** The frosted tint
  crushes it to invisibility. The romantic idea ("the glass refracts the
  light field") produced a shader nobody could see. The shipped layering:
  a `.colorEffect` color layer **between the glass and the text** — above
  the glass surface, below the content.
- **Never add a second glass surface.** The design guidelines' falsifiable
  rule stands: `glassEffect(` exists only inside `ConnectionHero`
  (DESIGN-GUIDELINES §3). A shader ornament is a color layer, not glass.
- **Cap the highlights and calm the text band.** Full-brightness effects
  behind text destroy legibility. Shipped values: 0.72 alpha ceiling on
  highlights, a dimmed midline band where the URL text sits, comet gain
  dropped from 0.8 to 0.34 inside the text band.

## Matching real UI geometry

- **Build the shader's shapes from measured frames, not constants.** The
  hero's two capsules are measured with `onGeometryChange` and passed as
  uniforms; the shader rebuilds the union silhouette as a smooth-min
  metaball of two capsule SDFs (`sdCapsuleRect` + `smin`), so the light
  field hugs the same weld the visible glass draws.
- **Piecewise parametric paths make "travel" cheap.** The packet comets
  follow `circuitPoint(s)`, a piecewise map from s ∈ [0,1) to points along
  capsule → neck → capsule → neck. One float animates the whole circuit.

## Animation and time

- **Loop by construction, not by luck.** Every temporal frequency is an
  integer number of cycles per 120 s, and the CPU clock wraps with
  `truncatingRemainder(dividingBy: 120)` — the loop point is seamless
  because the math can't drift.
- **Drive with TimelineView at a fixed rate (30 fps), pause when
  occluded.** Don't burn GPU on a hidden window.
- **Respect accessibility from day one:** Reduce Motion → static aurora
  (time frozen), Reduce Transparency → layer removed entirely.
- **Degrade silently without the metallib.** `ConduitLightLayer` checks
  `Bundle.module.url(forResource: "default", withExtension: "metallib")`
  and renders nothing if it's missing — a build without shaders is a
  quieter app, never a crash.

## Taste (the part that took the longest)

- Federico's verdict after several restrained iterations: **visibly alive
  and colorful beats judged-competition restraint.** White-hot comet
  cores, saturated aurora bands. Start bolder than feels safe, then dim
  only where text needs contrast.
- Palettes as cosine gradients (`0.5 + 0.5 * cos(2π(t + phase))`) stay
  harmonious under animation; the Aurora palette lives in the
  mint → cyan → azure → violet family.
- Tuning knobs belong as named constants at the top of the `.metal` file
  (wash strength, comet gain, circuit speeds) — every review round changed
  them, and hunting magic numbers mid-file wastes cycles.

## Checklist for the next Metal feature

1. Write the `.metal` with the visual core in a shared function; add a
   `previewGrid` kernel that calls it.
2. Iterate with `swift script/render_shader_preview.swift /tmp/frames` and
   look at the PNGs.
3. Compile with `script/compile_shaders.sh`; commit the updated
   `default.metallib`.
4. Wire it as a `.colorEffect`/`.layerEffect` color layer with the
   missing-metallib guard, TimelineView pacing, occlusion pause, and both
   accessibility fallbacks.
5. Verify layering with an `ImageRenderer` repro of the real view stack,
   then in the running app.
6. Show Federico moving frames early — tuning is a conversation, and the
   answer is usually "more alive."
