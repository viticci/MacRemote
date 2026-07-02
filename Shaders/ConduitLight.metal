// ConduitLight.metal — MacRemote "Aurora Exchange"
// Attached via .colorEffect to a white-filled Capsule layered between the URL
// pill's glassEffect and its text (ConnectionHero.urlPill, .publicRunning only).
// The source view is a plain white capsule: its premultiplied alpha gives us the
// capsule mask + antialiasing for free; the shader replaces the fill entirely.
//
// Visual story: a living iridescent aurora fills the open tunnel — two hue
// bands drifting in opposite directions (outbound/inbound), two bright glints
// orbiting the capsule edge in opposite directions, and every few seconds a
// white-cored comet crosses the width, alternating direction. Loud enough to
// be unmistakably alive, glassy enough to belong to Liquid Glass.
//
// The core lives in auroraExchange() so the offscreen preview kernel
// (previewGrid, used by script/render_shader_preview.swift and the tests)
// renders EXACTLY what the app renders.
//
// All temporal frequencies are integer cycles per 120 s: the CPU clock wraps
// with truncatingRemainder(dividingBy: 120) for a seamless loop.

#include <metal_stdlib>
using namespace metal;

// Cheap smooth hue palette in the Apple-Intelligence family:
// t in [0,1] → mint → cyan → azure → soft violet → mint.
static inline half3 auroraPalette(float t) {
    float3 phase = float3(0.00, 0.10, 0.24);
    float3 c = 0.5 + 0.5 * cos(6.2831853 * (t + phase));
    // Remap toward mint/cyan/azure/violet: bias green+blue up, red down.
    return half3(half(0.30 + 0.45 * c.x), half(0.68 + 0.30 * c.y), half(0.75 + 0.25 * c.z));
}

// A traveling comet: bright head, exponential tail, wrapping in [0,1].
static inline half comet(float u, float head, float tail) {
    float d = fract(head - u);
    half body = half(exp(-d * (5.0 / tail))) * half(step(d, tail));
    float hd = min(d, 1.0 - d);
    half core = half(exp(-hd * hd * 1400.0));
    return saturate(body * 0.8h + core);
}

// Signed distance to a capsule of half-height r spanning [r, w-r] horizontally,
// in a space where the box is w×1 with the capsule filling it. uv is (x*aspect, y).
static inline float capsuleEdgeDistance(float2 p, float aspect) {
    float r = 0.5;
    float2 a = float2(r, 0.5);
    float2 b = float2(aspect - r, 0.5);
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h) - r;   // < 0 inside; 0 at the edge
}

// The shared core: everything the eye sees, mask applied by the caller.
// Returns premultiplied RGBA to composite over the glass.
static inline half4 auroraExchange(float2 uv,      // 0…1 inside the capsule's bbox
                                   float  aspect,  // width / height
                                   float  time,
                                   half4  tint,
                                   float  intensity,
                                   float  flow) {
    float2 p = float2(uv.x * aspect, uv.y);

    // ---- Interior aurora: two counter-drifting hue bands ----------------
    // Band phase = horizontal position ± time, with a slow vertical tilt so
    // the field feels volumetric rather than striped.
    float driftA = time * (10.0 / 120.0);            // outbound, L→R
    float driftB = time * ( 7.0 / 120.0);            // inbound,  R→L
    float tilt = 0.18 * sin(uv.y * 3.1415926 + time * (6.2831853 * 3.0 / 120.0));
    half3 bandA = auroraPalette(fract(uv.x * 1.4 - driftA + tilt));
    half3 bandB = auroraPalette(fract((1.0 - uv.x) * 1.1 - driftB - tilt) + 0.45);

    // Vertical envelope: aurora strongest above/below the text band; the
    // midline stays calmer so the URL keeps effortless contrast.
    float yc = uv.y * 2.0 - 1.0;                     // -1 … +1
    half midCalm = half(0.55 + 0.45 * smoothstep(0.05, 0.45, yc * yc));
    // Weights favor A on top, B below → counterflow is spatially legible.
    half wA = half(0.5) + half(0.5) * half(clamp(-yc * 1.6, -1.0, 1.0));
    half wB = 1.0h - wA;

    // Slow breath (4 cycles / 120 s): the whole field inhales/exhales.
    half breath = 0.82h + 0.18h * half(sin(time * (6.2831853 * 4.0 / 120.0)));

    half3 aurora = (bandA * wA + bandB * wB);
    half auroraA = 0.42h * midCalm * breath;         // wash alpha, calm at midline

    // Static fallback under Reduce Motion: frozen field, no drift terms.
    aurora = mix(auroraPalette(uv.x * 0.9) , aurora, half(flow));
    auroraA = mix(0.26h * midCalm, auroraA, half(flow));

    // ---- Edge runners: glints sweeping the top and bottom rims ----------
    // Angle-space orbits collapse on a capsule this elongated (aspect ≈ 7.6),
    // so the runners are parameterized by x directly: top rim runs L→R,
    // bottom rim runs R→L — the counterflow hugs the silhouette.
    float edge = capsuleEdgeDistance(p, aspect);
    half rim = half(exp(-edge * edge * 260.0));      // soft band hugging the rim
    half topSide = half(smoothstep(0.5, 0.35, uv.y));
    half bottomSide = half(smoothstep(0.5, 0.65, uv.y));
    half runTop = comet(uv.x,       time * (18.0 / 120.0),       0.22) * topSide;
    half runBottom = comet(1.0 - uv.x, time * (13.0 / 120.0) + 0.4, 0.18) * bottomSide;
    half edgeGlow = rim * (runTop + runBottom) * 1.15h * half(flow);

    // ---- Packet comets: a full-width crossing every ~5 s, alternating ---
    // 24 crossings / 120 s; parity flips direction each crossing.
    float crossing = time * (24.0 / 120.0);
    float dir = step(0.5, fract(floor(crossing) * 0.5));   // 0 → L→R, 1 → R→L
    float cu = mix(uv.x, 1.0 - uv.x, dir);
    half lane = half(exp(-pow((uv.y - mix(0.36, 0.64, dir)) * 9.0, 2.0)));
    half packet = comet(cu, fract(crossing), 0.22) * lane * 1.25h * half(flow);

    // ---- Composite --------------------------------------------------------
    half3 rgb = aurora * auroraA;
    half a = auroraA;

    // Edge + packet light runs hot: white core over tinted falloff.
    half hot = saturate(edgeGlow + packet);
    half3 hotColor = mix(mix(tint.rgb, auroraPalette(fract(uv.x + time * 0.05)), 0.5h),
                         half3(1.0h), saturate(hot * 0.75h));
    rgb += hotColor * hot * 0.62h;
    a = saturate(a + hot * 0.62h);

    // Ceiling: highlights may sing (≤ 0.72), but never white out the pill.
    a = min(a * half(intensity), 0.72h);
    return half4(rgb * half(intensity), a);
}

[[ stitchable ]]
half4 conduitLight(float2 position,
                   half4  color,      // source pixel: white capsule mask (premultiplied)
                   float4 bounds,     // pass .boundingRect
                   float  time,       // seconds, wrapped at 120 on the CPU side
                   half4  tint,       // semantic status color (.green for Public)
                   float  intensity,  // 0…1 master gain — animate to 0 before pausing
                   float  flow)       // 1 = animate; 0 = Reduce Motion (static aurora)
{
    if (intensity <= 0.001f || color.a <= 0.0h) { return half4(0.0h); }
    float2 size = max(bounds.zw, float2(1.0, 1.0));
    float2 uv = (position - bounds.xy) / size;
    half4 lit = auroraExchange(uv, size.x / size.y, time, tint, intensity, flow);
    return half4(lit.rgb * color.a, lit.a * color.a);   // capsule mask + AA
}

// Offscreen preview: renders the same core into a texture so the shader can
// be seen (and regression-tested) without launching the app. One thread per
// pixel; the capsule mask is computed analytically.
kernel void previewGrid(texture2d<half, access::write> out [[texture(0)]],
                        constant float& time [[buffer(0)]],
                        constant float4& tintIn [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    float2 size = float2(out.get_width(), out.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float aspect = size.x / size.y;
    float mask = 1.0 - smoothstep(-0.01, 0.01, capsuleEdgeDistance(float2(uv.x * aspect, uv.y), aspect));
    half4 tint = half4(half(tintIn.x), half(tintIn.y), half(tintIn.z), half(tintIn.w));
    half4 lit = auroraExchange(uv, aspect, time, tint, 1.0, 1.0);
    // Composite over a light glass-green proxy so the PNG resembles the pill.
    half3 bg = half3(0.86h, 0.93h, 0.87h);
    half3 rgb = bg * (1.0h - lit.a) + lit.rgb;
    half3 outside = half3(0.93h, 0.95h, 0.93h);
    out.write(half4(mix(outside, rgb, half(mask)), 1.0h), gid);
}
