// ConduitLight.metal — MacRemote "Aurora Exchange" (union edition)
// One light layer UNDER the whole hero glass group (status pill + weld + URL
// capsule): the real Liquid Glass refracts this field, so the liquidity is
// optical, not painted. The union silhouette is rebuilt in-shader as a
// smooth-min metaball of the two capsules (the same math that shapes the
// visible weld), and packet comets ride a closed circuit: along the URL
// capsule, up through the neck into "Public", around it, and back down.
//
// The core lives in auroraUnion() so the offscreen preview kernel
// (previewGrid, driven by script/render_shader_preview.swift and the tests)
// renders EXACTLY what the app renders.
//
// Temporal frequencies are integer cycles per 120 s: the CPU clock wraps with
// truncatingRemainder(dividingBy: 120) for a seamless loop.

#include <metal_stdlib>
using namespace metal;

// Iridescent palette in the Apple-Intelligence family:
// t → mint → cyan → azure → soft violet → mint.
static inline half3 auroraPalette(float t) {
    float3 phase = float3(0.00, 0.10, 0.24);
    float3 c = 0.5 + 0.5 * cos(6.2831853 * (t + phase));
    return half3(half(0.30 + 0.45 * c.x), half(0.68 + 0.30 * c.y), half(0.75 + 0.25 * c.z));
}

// SDF of a horizontal capsule given its bounding rect.
static inline float sdCapsuleRect(float2 p, float2 origin, float2 size) {
    float r = size.y * 0.5;
    float2 a = origin + float2(r, r);
    float2 b = origin + float2(size.x - r, r);
    float2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-5), 0.0, 1.0);
    return length(pa - ba * h) - r;
}

// Polynomial smooth min — the metaball weld between the two capsules.
static inline float smin(float d1, float d2, float k) {
    float h = clamp(0.5 + 0.5 * (d2 - d1) / k, 0.0, 1.0);
    return mix(d2, d1, h) - k * h * (1.0 - h);
}

// Piecewise circuit through both shapes: s ∈ [0,1) → point.
// 0.00–0.42 along the URL capsule L→R · 0.42–0.54 up the neck ·
// 0.54–0.84 across "Public" R→L · 0.84–1.00 back down the neck.
static inline float2 circuitPoint(float s, float2 aC, float2 aHalf, float2 bC, float2 bHalf) {
    s = fract(s);
    float inset = 0.72;
    if (s < 0.42) {
        float t = s / 0.42;
        return float2(bC.x + mix(-bHalf.x, bHalf.x, t) * inset, bC.y);
    }
    if (s < 0.54) {
        float t = (s - 0.42) / 0.12;
        return float2(mix(bC.x + bHalf.x * inset, aC.x + aHalf.x * inset, t),
                      mix(bC.y, aC.y, t));
    }
    if (s < 0.84) {
        float t = (s - 0.54) / 0.30;
        return float2(aC.x + mix(aHalf.x, -aHalf.x, t) * inset, aC.y);
    }
    float t = (s - 0.84) / 0.16;
    return float2(mix(aC.x - aHalf.x * inset, bC.x - bHalf.x * inset, t),
                  mix(aC.y, bC.y, t));
}

// A comet at path position s with a fading 4-tap trail behind it.
static inline half circuitComet(float2 p, float s, float dir, float radius,
                                float2 aC, float2 aHalf, float2 bC, float2 bHalf) {
    half glow = 0.0h;
    for (int i = 0; i < 4; i++) {
        float lag = float(i) * 0.018 * dir;
        float2 c = circuitPoint(s - lag, aC, aHalf, bC, bHalf);
        float d2 = dot(p - c, p - c);
        half w = half(exp(-d2 / (radius * radius * (1.0 + float(i) * 0.5))));
        glow += w * half(1.0 - float(i) * 0.22);
    }
    return saturate(glow);
}

// The shared core. All coordinates in points within the layer's space.
// rectA = status "Public" pill, rectB = URL capsule (incl. copy button).
static inline half4 auroraUnion(float2 p, float time, half4 tint,
                                float intensity, float flow,
                                float2 aOrigin, float2 aSize,
                                float2 bOrigin, float2 bSize) {
    float2 aC = aOrigin + aSize * 0.5;
    float2 bC = bOrigin + bSize * 0.5;
    float2 aHalf = aSize * 0.5;
    float2 bHalf = bSize * 0.5;

    // ---- Union silhouette (metaball weld, shrunk 1.5pt to stay under glass)
    float dA = sdCapsuleRect(p, aOrigin, aSize);
    float dB = sdCapsuleRect(p, bOrigin, bSize);
    // Wide blend: a tight radius left concave cusps at the neck sides.
    float d = smin(dA, dB, aSize.y * 1.05);
    half mask = half(smoothstep(0.0, -1.5, d));             // 1 inside, soft edge

    if (mask <= 0.001h || intensity <= 0.001) { return half4(0.0h); }

    // ---- Liquid interior: domain-warped iridescence + depth glow ---------
    float scale = 1.0 / max(bSize.y, 1.0);                  // ~capsule heights
    float2 q = p * scale;
    float tphase = time * (6.2831853 / 120.0);
    // Two cheap warp octaves — the "liquid" curl.
    float2 warp = float2(sin(q.y * 2.3 + tphase * 9.0) + 0.6 * sin(q.y * 5.1 - tphase * 15.0),
                         sin(q.x * 1.7 - tphase * 7.0) + 0.6 * sin(q.x * 3.9 + tphase * 11.0));
    float2 qw = q + warp * 0.35 * flow;

    // Two counter-drifting hue fields, blended by depth. Small phase offset —
    // large shifts push into murky violet-blue over the pale glass.
    half3 fieldA = auroraPalette(fract(qw.x * 0.16 - time * (9.0 / 120.0)));
    half3 fieldB = auroraPalette(fract(0.5 - qw.x * 0.12 + time * (6.0 / 120.0)) + 0.15);
    half depth = half(clamp(-d * scale * 2.2, 0.0, 1.0));   // thick core glows most
    half3 liquid = mix(fieldA, fieldB, half(0.5 + 0.5 * sin(qw.y * 2.0 + tphase * 5.0)));

    // Caustic shimmer: interference of the warp octaves, sharpened.
    float ca = sin(qw.x * 6.0 + tphase * 13.0) + sin(qw.y * 5.0 - tphase * 8.0);
    half caustic = half(pow(clamp(0.5 + 0.5 * ca * 0.5, 0.0, 1.0), 6.0)) * 0.5h;

    half breath = 0.86h + 0.14h * half(sin(tphase * 4.0));
    half washA = (0.50h * depth + caustic * half(flow)) * breath;

    // ---- Circuit comets: light that travels the whole form ---------------
    float r = bSize.y * 0.18;
    half comets = 0.0h;
    comets += circuitComet(p, time * (10.0 / 120.0),         1.0, r, aC, aHalf, bC, bHalf);
    comets += circuitComet(p, -time * (7.0 / 120.0) + 0.37, -1.0, r, aC, aHalf, bC, bHalf);
    comets += circuitComet(p, time * (10.0 / 120.0) + 0.5,   1.0, r * 0.8, aC, aHalf, bC, bHalf) * 0.7h;
    comets = saturate(comets) * half(flow);

    // ---- Composite (premultiplied) ----------------------------------------
    half3 rgb = liquid * washA;
    half a = washA;

    // The layer now composites ABOVE the glass, so hot light is tempered in
    // the URL text band — the aurora wash stays, comet cores dim to keep the
    // address effortlessly readable.
    half inTextBand = half(smoothstep(bSize.y * 0.40, bSize.y * 0.24, abs(p.y - bC.y))) *
                      half(step(bOrigin.x + bSize.y * 0.6, p.x)) *
                      half(step(p.x, bOrigin.x + bSize.x - bSize.y * 1.3));
    half hotGain = mix(0.8h, 0.34h, inTextBand);

    half3 hotColor = mix(mix(tint.rgb, liquid, 0.55h), half3(1.0h), saturate(comets * 0.65h));
    rgb += hotColor * comets * hotGain;
    a = saturate(a + comets * hotGain);

    a = min(a * half(intensity), 0.85h) * mask;
    return half4(rgb * half(intensity) * mask, a);
}

[[ stitchable ]]
half4 conduitLight(float2 position,
                   half4  color,      // white full-bleed mask from the source view
                   float4 bounds,
                   float  time,       // wrapped at 120 s on the CPU side
                   half4  tint,
                   float  intensity,  // 0…1 master gain
                   float  flow,       // 1 = animate; 0 = Reduce Motion (static field)
                   float2 aOrigin, float2 aSize,   // status "Public" pill frame
                   float2 bOrigin, float2 bSize)   // URL capsule frame
{
    if (intensity <= 0.001f || color.a <= 0.0h) { return half4(0.0h); }
    float2 p = position - bounds.xy;
    // Geometry fallback: if the host failed to measure frames, approximate the
    // hero from the layer bounds (previewGrid proportions) — the ornament must
    // degrade to slightly-off geometry, never to nothing.
    if (aSize.x < 1.0f || bSize.x < 1.0f) {
        float2 size = bounds.zw;
        bSize = float2(size.x * 0.96, size.y * 0.34);
        aSize = float2(size.x * 0.30, size.y * 0.34);
        aOrigin = float2((size.x - aSize.x) * 0.5, size.y * 0.08);
        bOrigin = float2((size.x - bSize.x) * 0.5, aOrigin.y + aSize.y + size.y * 0.10);
    }
    half4 lit = auroraUnion(p, time, tint, intensity, flow, aOrigin, aSize, bOrigin, bSize);
    return half4(lit.rgb * color.a, lit.a * color.a);
}

// Offscreen preview: same core, synthetic hero geometry, PNG-able.
kernel void previewGrid(texture2d<half, access::write> out [[texture(0)]],
                        constant float& time [[buffer(0)]],
                        constant float4& tintIn [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    float2 size = float2(out.get_width(), out.get_height());
    float2 p = float2(gid) + 0.5;

    // Synthetic hero at preview scale: "Public" pill just above the URL bar
    // (gap ≈ the real hero's — close enough for the metaball weld to form).
    float2 bSize = float2(size.x * 0.86, size.y * 0.30);
    float2 aSize = float2(size.x * 0.28, size.y * 0.30);
    float2 aOrigin = float2((size.x - aSize.x) * 0.5, size.y * 0.14);
    float2 bOrigin = float2((size.x - bSize.x) * 0.5, aOrigin.y + aSize.y + size.y * 0.08);

    half4 tint = half4(half(tintIn.x), half(tintIn.y), half(tintIn.z), half(tintIn.w));
    half4 lit = auroraUnion(p, time, tint, 1.0, 1.0, aOrigin, aSize, bOrigin, bSize);

    // Show the union silhouette as pale glass so the PNG reads like the hero.
    float dA = sdCapsuleRect(p, aOrigin, aSize);
    float dB = sdCapsuleRect(p, bOrigin, bSize);
    float d = smin(dA, dB, aSize.y * 1.05);
    half glass = half(smoothstep(1.0, -1.0, d));
    half3 bg = mix(half3(0.93h, 0.95h, 0.93h), half3(0.85h, 0.92h, 0.86h), glass);
    half3 rgb = bg * (1.0h - lit.a) + lit.rgb;
    out.write(half4(rgb, 1.0h), gid);
}
