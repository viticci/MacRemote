// ConduitLight.metal — MacRemote "Liquid Light Conduit"
// Attached via .colorEffect to a white-filled Capsule layered between the URL
// pill's glassEffect and its text (ConnectionHero.urlPill, .publicRunning only).
// The source view is a plain white capsule: its premultiplied alpha gives us the
// capsule mask + antialiasing for free; the shader replaces the fill entirely.
//
// No SwiftUI_Metal.h include: this is a colorEffect (no SwiftUI::Layer), so the
// file compiles with the bare Metal stdlib — including the OS runtime compiler.
//
// All temporal frequencies are integer cycles per 120 s, so the CPU-side clock
// can wrap with truncatingRemainder(dividingBy: 120) — seamless loop, and the
// Float time uniform never accumulates precision drift.

#include <metal_stdlib>
using namespace metal;

// A fiber-optic tracer: soft bright head + exponential comet tail, wrapping
// along the tube. `u` and `head` are in tube fractions [0,1]; `tail` is the
// tail length in tube fractions.
static inline half tracer(float u, float head, float tail) {
    float d = fract(head - u);                       // distance behind the head
    half body = half(exp(-d * (6.0 / tail))) * half(step(d, tail));
    float hd = min(d, 1.0 - d);                      // wrapped distance to head
    half glow = half(exp(-hd * hd * 2200.0));        // ~2% of tube: soft head bloom
    return saturate(body * 0.85h + glow);
}

[[ stitchable ]]
half4 conduitLight(float2 position,
                   half4  color,      // source pixel: white capsule mask (premultiplied)
                   float4 bounds,     // pass .boundingRect
                   float  time,       // seconds, wrapped at 120 on the CPU side
                   half4  tint,       // semantic status color (.green for Public)
                   float  intensity,  // 0…1 master gain — animate to 0 before pausing
                   float  flow)       // 1 = currents animate; 0 = Reduce Motion (static tube only)
{
    if (intensity <= 0.001f || color.a <= 0.0h) { return half4(0.0h); }

    float2 uv = (position - bounds.xy) / max(bounds.zw, float2(1.0, 1.0));

    // ---- Static glass-tube depth (survives Reduce Motion) ----
    // Deliberately faint: a shadow of depth, not a painted second material.
    float yc = uv.y * 2.0 - 1.0;                     // -1 top wall … +1 bottom wall
    float nz = sqrt(max(1.0 - yc * yc, 0.0));        // fake cylinder normal.z
    half rimGather = half(smoothstep(0.55, 0.92, yc * yc)) * 0.06h; // light pooling at walls
    float m = (uv.y - 0.22) * 9.0;
    half meridian = half(exp(-m * m)) * 0.04h;       // upper specular line — "lit cylinder"

    // ---- Two counter-flowing currents in shallow lanes off-axis ----
    float lA = (uv.y - 0.38) * 5.5;                  // upper lane → left-to-right (outbound)
    float lB = (uv.y - 0.62) * 5.5;                  // lower lane → right-to-left (inbound)
    half laneA = half(exp(-lA * lA));
    half laneB = half(exp(-lB * lB));

    // Design-review concession knob: set to 0.0h for one tracer per direction.
    const half secondTracer = 0.7h;

    // Speeds in cycles/120 s: {14, 9} outbound, {12, 8} inbound — mutually
    // incommensurate enough that the ensemble never visibly repeats in-loop.
    half fwd = tracer(uv.x,       time * (14.0 / 120.0),        0.28)
             + tracer(uv.x,       time * ( 9.0 / 120.0) + 0.47, 0.20) * secondTracer;
    half rev = tracer(1.0 - uv.x, time * (12.0 / 120.0) + 0.21, 0.26)
             + tracer(1.0 - uv.x, time * ( 8.0 / 120.0) + 0.73, 0.18) * secondTracer;

    // Light enters/exits at the capsule ends instead of popping into being.
    half caps = half(smoothstep(0.0, 0.07, uv.x) * (1.0 - smoothstep(0.93, 1.0, uv.x)));

    // Currents live *inside* the glass: strongest through the thick core,
    // dimmed at the walls, with a slow refractive shimmer (32 cycles/120 s).
    half shimmer = 0.85h + 0.15h * half(sin(uv.x * 21.0 - time * (2.0 * M_PI_F * 32.0 / 120.0)));
    half currents = (fwd * laneA + rev * laneB) * caps * half(nz) * shimmer * half(flow);

    half I = (currents * 0.22h + rimGather + meridian) * half(intensity);

    // Hard luminance ceiling (GUIDELINES §5.1 defense): added light never
    // exceeds 0.25 alpha over the glass, even if gains are retuned later.
    half a = min(I, 0.25h) * color.a;                // capsule mask + AA from source alpha
    return half4(tint.rgb * a, a);                   // premultiplied
}
