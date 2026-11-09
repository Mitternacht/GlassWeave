#include <metal_stdlib>
#include "../../GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"

using namespace metal;

// The shader's view of the shared record must match the host layout asserted
// in GlassWeaveShaderTypes.c.
static_assert(sizeof(GWGlassUniforms) == 1440, "GWGlassUniforms size");
static_assert(sizeof(GWGroundingUniforms) == 128, "GWGroundingUniforms size");
static_assert(alignof(GWGroundingUniforms) == 16, "GWGroundingUniforms alignment");
static_assert(sizeof(GWLightingUniforms) == 160, "GWLightingUniforms size");
static_assert(alignof(GWLightingUniforms) == 16, "GWLightingUniforms alignment");
static_assert(sizeof(GWLensInlay) == 48, "GWLensInlay size");
static_assert(alignof(GWLensInlay) == 16, "GWLensInlay alignment");
static_assert(sizeof(GWLightEmitter) == 112, "GWLightEmitter size");
static_assert(alignof(GWLightEmitter) == 16, "GWLightEmitter alignment");
static_assert(alignof(GWGlassUniforms) == 16, "GWGlassUniforms alignment");

// The optical model below is mirrored on the CPU by `GlassPanelGeometry`
// (GlassPanelGeometry.swift); tests compare the two pixel by pixel. Change
// both together.

/// Light direction for edge illumination, in target pixels (y down): light
/// arrives from the upper left.
constant float2 gw_light_direction = float2(-0.70710678, -0.70710678);

struct GWGlassVertexOut {
    float4 position [[position]];
};

/// A quad covering the panel rectangle grown by one pixel on every side, so
/// the antialiased outline (half a pixel either side of the edge) is inside
/// it, and by the halo radius when there is a halo (GW-18; zero otherwise,
/// which leaves the quad exactly as before). The rasterizer clips it to the
/// target, so a halo never reaches past the surface. Pixels outside the quad
/// keep the background pass's output.
vertex GWGlassVertexOut gw_glass_vertex(
    uint vertexID [[vertex_id]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + 1.0 + uniforms.glowHaloRadius);
    // Target pixels (y down) to clip space (y up).
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWGlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// sRGB transfer function, linear light to encoded. Same as the background
/// pass: the output target is non-sRGB `bgra8Unorm` holding encoded values.
static float3 gw_glass_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// Samples the source, in linear light, at a position in target pixels.
/// Uses the background pass's mapping and clamps half a texel inside the
/// valid rectangle, so a displaced sample never reads outside it.
static float3 gw_glass_sample(
    float2 pixel, constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    const float2 destinationUV = pixel / uniforms.targetSize;
    float2 uv = uniforms.background.uvFromDestinationX * destinationUV.x
              + uniforms.background.uvFromDestinationY * destinationUV.y
              + uniforms.background.uvOrigin;
    uv = clamp(uv, uniforms.background.sampleClampMin, uniforms.background.sampleClampMax);
    return source.sample(linearClamp, uv).rgb;
}

static float gw_sign(float x) {
    return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
}

/// Signed distance in pixels to a rounded rectangle centered at the origin:
/// negative inside, zero on the outline, positive outside.
static float gw_rounded_rect_distance(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

/// Outward unit normal of a rounded rectangle with corner radius `radius`:
/// radial in the corner regions, axis-aligned along the straight edges.
static float2 gw_rounded_rect_normal(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    if (d.x > 0.0 && d.y > 0.0) {
        return normalize(d) * float2(gw_sign(q.x), gw_sign(q.y));
    }
    if (d.x > d.y) {
        return float2(gw_sign(q.x), 0.0);
    }
    return float2(0.0, gw_sign(q.y));
}

/// The 4 x 4 ordered-dither (Bayer) matrix, row by row.
constant float gw_bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

/// The glow color at an angle in turns (0 at the top, clockwise), in linear
/// light: linear interpolation between the neighbouring stops around the
/// circle, which wraps from the last stop back to the first. Stops are
/// ordered by angle; one stop is a solid color.
static float3 gw_glow_color(float turn, constant GWGlassUniforms &uniforms) {
    const float3 colors[4] = {
        uniforms.glowColor0.xyz, uniforms.glowColor1.xyz,
        uniforms.glowColor2.xyz, uniforms.glowColor3.xyz,
    };
    const uint count = min(uniforms.glowStopCount, 4u);
    if (count <= 1u) {
        return colors[0];
    }
    // `following` stops lie at or before `turn`.
    uint following = 0u;
    for (uint i = 0u; i < count; ++i) {
        if (uniforms.glowStopTurns[i] <= turn) {
            following = i + 1u;
        }
    }
    const uint previous = (following + count - 1u) % count;
    const uint next = following % count;
    const float start = following == 0u ? uniforms.glowStopTurns[previous] - 1.0 : uniforms.glowStopTurns[previous];
    const float end = following == count ? uniforms.glowStopTurns[next] + 1.0 : uniforms.glowStopTurns[next];
    const float fraction = saturate((turn - start) / max(end - start, 1e-6));
    return mix(colors[previous], colors[next], fraction);
}

/// The glow color and light factor at a pixel, inside or outside the
/// panel: the color at the pixel's angle around the center, in `xyz`, and
/// the light factor, in `w`.
static float4 gw_glow_shade(float2 q, constant GWGlassUniforms &uniforms) {
    // The angle around the center with the panel scaled to a square. The
    // precise atan2: on the axis through the center `-p.y` is a signed
    // zero, which the fast-math atan2 puts in the wrong half-plane. One
    // color needs no angle.
    const float2 p = q / uniforms.panelHalfSize;
    float turn = 0.0;
    if (uniforms.glowStopCount > 1u && (p.x != 0.0 || p.y != 0.0)) {
        turn = precise::atan2(p.x, -p.y) * (0.5 / M_PI_F);
        turn = turn - floor(turn);
    }
    const float3 color = gw_glow_color(turn, uniforms);

    // The same normal field inside and outside the outline, so the light is
    // continuous across it.
    const float2 normal = gw_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.glowNormalRadius);
    const float facing = (1.0 + dot(normal, uniforms.glowLightDirection)) * 0.5;
    const float light = (1.0 - uniforms.glowDirectionality) + uniforms.glowDirectionality * facing * facing;
    return float4(color, light);
}

/// The glow layer's opacity and color at a pixel inside the panel
/// (docs/glow.md): a rim band, an inner glow falling off as (1 - t)^2, and
/// a center fill, all in one color, with the rim and inner glow lit from
/// one side. Returns the opacity in `w`.
static float4 gw_glow(float2 q, float depth, constant GWGlassUniforms &uniforms) {
    const float4 shade = gw_glow_shade(q, uniforms);
    const float3 color = shade.xyz;
    const float light = shade.w;

    float rim = 0.0;
    if (uniforms.glowRimIntensity > 0.0) {
        rim = uniforms.glowRimIntensity * light
            * (1.0 - smoothstep(uniforms.glowRimWidth, uniforms.glowRimWidth + uniforms.glowRimFeather, depth));
    }
    float inner = 0.0;
    if (uniforms.glowInnerRadius > 0.0) {
        const float t = saturate(depth / uniforms.glowInnerRadius);
        inner = uniforms.glowInnerIntensity * (1.0 - t) * (1.0 - t) * light;
    }
    const float alpha = 1.0 - (1.0 - uniforms.glowCenterOpacity) * (1.0 - inner) * (1.0 - rim);
    return float4(color, alpha);
}


// MARK: Interiors (GW-19)
//
// Mirrored on the CPU by `GlassPanelGeometry`'s interior model
// (GlassInteriorModel.swift), which tests compare with this shader. The
// hashes are integer arithmetic, exact on both sides; everything else is the
// same arithmetic in float here and double there. Every pattern repeats after
// 64 s of interior time (`interiorPhase` is reduced into [0, 64) on the CPU):
// time enters only through lattice axes whose period is the number of cells
// the pattern moves in 64 s, through turns that complete a whole number of
// times in 64 s, and through sparks that rise a whole number of times in 64 s
// (their positions are computed on the CPU and uploaded).

/// The lowbias32 integer hash (C. Wellons): a well-mixed 32-bit value.
static uint gw_hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

/// The top 24 bits of a hash as a float in [0, 1), exact in float.
static float gw_unit(uint h) {
    return float(h >> 8u) * (1.0 / 16777216.0);
}

/// A lattice coordinate wrapped into [0, period).
static int gw_wrap(int i, int period) {
    const int r = i % period;
    return r < 0 ? r + period : r;
}

/// A lattice coordinate wrapped into [0, period) for a power-of-two
/// period, by a mask (no integer division), or unchanged for period 0.
static int gw_wrap_pow2(int i, int period) {
    return period == 0 ? i : (i & (period - 1));
}

/// The value at a 3D lattice point, in [0, 1). The x axis does not wrap;
/// y and z wrap with the power-of-two periods in `period` (0 for none).
static float gw_lattice3(int3 cell, int2 period, uint seed) {
    const uint x = uint(cell.x);
    const uint y = uint(gw_wrap_pow2(cell.y, period.x));
    const uint z = uint(gw_wrap_pow2(cell.z, period.y));
    return gw_unit(gw_hash(x * 0x8da6b343u + y * 0xd8163841u + z * 0xcb1ab31fu + seed));
}

/// The value at a 2D lattice point, in [0, 1), periodic per axis with the
/// power-of-two periods in `period` (0 for none).
static float gw_lattice2(int2 cell, int2 period, uint seed) {
    const uint x = uint(gw_wrap_pow2(cell.x, period.x));
    const uint y = uint(gw_wrap_pow2(cell.y, period.y));
    return gw_unit(gw_hash(x * 0x8da6b343u + y * 0xd8163841u + seed));
}

/// 2D value noise with smoothstep interpolation, in [0, 1), periodic per
/// axis with the power-of-two periods in `period` (0 for none).
static float gw_noise2(float2 p, int2 period, uint seed) {
    const float2 base = floor(p);
    const int2 c = int2(base);
    const float2 f = p - base;
    const float2 s = f * f * (3.0 - 2.0 * f);
    const float v00 = gw_lattice2(c, period, seed);
    const float v10 = gw_lattice2(c + int2(1, 0), period, seed);
    const float v01 = gw_lattice2(c + int2(0, 1), period, seed);
    const float v11 = gw_lattice2(c + int2(1, 1), period, seed);
    const float x0 = v00 + (v10 - v00) * s.x;
    const float x1 = v01 + (v11 - v01) * s.x;
    return x0 + (x1 - x0) * s.y;
}

/// 3D value noise with smoothstep interpolation, in [0, 1), periodic in y
/// and z with the power-of-two periods in `period` (0 for none).
static float gw_noise3(float3 p, int2 period, uint seed) {
    const float3 base = floor(p);
    const int3 c = int3(base);
    const float3 f = p - base;
    const float3 s = f * f * (3.0 - 2.0 * f);
    const float v000 = gw_lattice3(c, period, seed);
    const float v100 = gw_lattice3(c + int3(1, 0, 0), period, seed);
    const float v010 = gw_lattice3(c + int3(0, 1, 0), period, seed);
    const float v110 = gw_lattice3(c + int3(1, 1, 0), period, seed);
    const float v001 = gw_lattice3(c + int3(0, 0, 1), period, seed);
    const float v101 = gw_lattice3(c + int3(1, 0, 1), period, seed);
    const float v011 = gw_lattice3(c + int3(0, 1, 1), period, seed);
    const float v111 = gw_lattice3(c + int3(1, 1, 1), period, seed);
    const float x00 = v000 + (v100 - v000) * s.x;
    const float x10 = v010 + (v110 - v010) * s.x;
    const float x01 = v001 + (v101 - v001) * s.x;
    const float x11 = v011 + (v111 - v011) * s.x;
    const float y0 = x00 + (x10 - x00) * s.y;
    const float y1 = x01 + (x11 - x01) * s.y;
    return y0 + (y1 - y0) * s.z;
}

/// Three octaves of 3D value noise (amplitudes 1/2, 1/4, 1/8, normalized),
/// each at twice the frequency and twice the period of the one before, so
/// the sum keeps the first octave's period. In [0, 1).
static float gw_fbm3(float3 p, int2 period, uint seed) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (uint octave = 0u; octave < 3u; ++octave) {
        sum += amplitude * gw_noise3(p, period, seed + octave * 0x9e3779b9u);
        p *= 2.0;
        period *= 2;
        amplitude *= 0.5;
    }
    return sum / 0.875;
}

/// The length the energy and rays patterns scale with: half the panel's
/// shorter side, but at least 12 points, so a small or thin panel never gets
/// filaments or bands finer than the pixels that show them.
static float gw_interior_size(float2 halfSize) {
    return max(min(halfSize.x, halfSize.y), 12.0);
}

/// Energy: filaments where noise, warped by two more noise fields, crosses
/// one half, with a faint haze around them, turning once per 64 s around the center (twisted
/// by up to 0.9 rad out to `size` from it) and evolving with time, brighter
/// toward the rim. `u` in points from the center (y down), `size` from
/// `gw_interior_size`, `w` the depth fraction (0 at the outline).
static float gw_interior_energy(float2 u, float size, float w, float phase, uint seed) {
    const float2 p0 = u / size;
    const float angle = (2.0 * M_PI_F) * (phase / 64.0) + 0.9 * min(length(p0), 1.0);
    const float c = precise::cos(angle);
    const float s = precise::sin(angle);
    const float2 p = float2(c * p0.x - s * p0.y, s * p0.x + c * p0.y) * 2.2;
    const float z = phase * 0.5;
    const int2 period = int2(0, 32);
    const float wx = gw_noise3(float3(p, z), period, seed);
    const float wy = gw_noise3(float3(p.x + 19.0, p.y + 7.0, z), period, seed + 0x51ed270bu);
    const float2 warped = p + 1.4 * (float2(wx, wy) - 0.5);
    const float n = gw_fbm3(float3(warped, z + 11.0), period, seed + 0xa3c59ac3u);
    const float offset = abs(n - 0.5);
    const float core = 1.0 - smoothstep(0.0, 0.045, offset);
    const float haze = 1.0 - smoothstep(0.0, 0.16, offset);
    return saturate(0.85 * core * core + 0.3 * haze * haze) * (0.45 + 0.55 * (1.0 - w));
}

/// One layer of rays: `count` rays per turn, one per angular cell at a
/// random offset, with a random half-width between `minWidth` and
/// `maxWidth` of its cell (at most 0.28, so a ray never crosses its cell)
/// and a brightness that twinkles over time. A ray is drawn at least 0.75
/// points wide and dimmed by the same factor, so thin rays near the center
/// fade instead of aliasing. `r` is the distance from the center in points.
static float gw_ray_layer(float turn, float r, int count, float minWidth, float maxWidth, float z, uint seed) {
    const float x = turn * float(count);
    const float base = floor(x);
    const int cell = gw_wrap(int(base), count);
    const float f = x - base;
    const uint h = gw_hash(uint(cell) * 0x8da6b343u + seed);
    const float center = 0.3 + 0.4 * gw_unit(gw_hash(h + 1u));
    const float width = minWidth + (maxWidth - minWidth) * gw_unit(gw_hash(h + 2u));
    const float cellPoints = max(r * (2.0 * M_PI_F) / float(count), 0.001);
    const float drawn = min(max(width, 0.75 / cellPoints), 0.28);
    const float profile = 1.0 - smoothstep(0.0, drawn, abs(f - center));
    // The ray's own brightness over time: 1D value noise in z, period 32.
    const float zBase = floor(z);
    const int zCell = int(zBase);
    const float zf = z - zBase;
    const uint key = uint(cell) * 0x8da6b343u + seed + 0x3c6ef372u;
    const float t0 = gw_unit(gw_hash(key + uint(zCell & 31) * 0xd8163841u));
    const float t1 = gw_unit(gw_hash(key + uint((zCell + 1) & 31) * 0xd8163841u));
    const float twinkle = t0 + (t1 - t0) * (zf * zf * (3.0 - 2.0 * zf));
    return profile * profile * (width / drawn) * (0.35 + 0.65 * twinkle);
}

/// Rays: 13 soft beams and 29 thin rays per turn from the center, turning
/// in opposite directions (two turns and one turn per 64 s), twinkling, with
/// brightness flowing outward; they fade in from the center where the thin
/// rays' spacing reaches 1.5 points.
static float gw_interior_rays(float2 u, float size, float phase, uint seed) {
    const float r = length(u);
    if (r <= 0.0) {
        return 0.0;
    }
    float turn = precise::atan2(u.x, -u.y) * (0.5 / M_PI_F);
    turn = turn - floor(turn);
    const float z = phase * 0.5;
    const float beams = gw_ray_layer(turn + 2.0 * phase / 64.0, r, 13, 0.1, 0.28, z, seed);
    const float rays = gw_ray_layer(turn - phase / 64.0, r, 29, 0.03, 0.09, z + 7.0, seed + 0x68e31da4u);
    const float flow = gw_noise2(float2(turn * 8.0, r / size * 2.5 - phase * 0.5), int2(8, 32), seed + 0xb5297a4du);
    const float resolved = smoothstep(1.5, 4.5, r * (2.0 * M_PI_F / 29.0));
    return saturate((0.55 * beams + rays) * (0.4 + 0.6 * flow)) * resolved;
}

/// Embers: flame tongues rising from the bottom edge, as heat 0...1: rising
/// turbulence (tall cells, 0.5 cells a second upward) shapes the top of a
/// flame whose height varies along the bottom edge; heat is highest at the
/// base and falls to 0 at a tongue's ragged top. Above 1.4 times a tongue's
/// height the turbulence cannot lift the flame, so it is not evaluated
/// there (the heat is exactly 0 either way). `halfSize` in points.
static float gw_interior_flames(float2 u, float2 halfSize, float phase, uint seed) {
    const float above = halfSize.y - u.y;
    const float y = above / (1.3 * halfSize.y);
    const float top = 0.45 + 0.9 * gw_noise2(float2(u.x / 16.0, phase * 0.25), int2(0, 16), seed + 0x2545f491u);
    if (y >= 1.4 * top) {
        return 0.0;
    }
    const float n = gw_fbm3(float3(u.x / 9.0, above / 30.0 - phase * 0.5, phase * 0.5), int2(32, 32), seed);
    const float v = (1.0 - y / top) + (n - 0.5) * 0.8;
    return smoothstep(0.0, 1.25, v);
}

/// Embers: the brightest of the twelve uploaded sparks at a point `u` in
/// points from the panel's center, 0...1. Each is a bright core
/// `(1 - d^2 / r^2)^2` with a faint glow three times its radius,
/// `0.45 (1 - d^2 / 9 r^2)^2`, times its brightness. The sparks' paths (they
/// rise from near the bottom edge to the halo's radius above the top edge, a
/// whole number of times per 64 s, swaying, and fade over the last 30 % of
/// their rise) are computed on the CPU, once per draw.
static float gw_interior_sparks(float2 u, constant GWGlassUniforms &uniforms) {
    float spark = 0.0;
    for (uint i = 0u; i < 12u; ++i) {
        const float4 s = uniforms.interiorSparks[i];
        if (s.w <= 0.0) {
            continue;
        }
        const float2 d = u - s.xy;
        const float dd = dot(d, d) / (s.z * s.z);
        if (dd < 9.0) {
            const float core = dd < 1.0 ? (1.0 - dd) * (1.0 - dd) : 0.0;
            const float glow = (1.0 - dd / 9.0) * (1.0 - dd / 9.0);
            spark = max(spark, max(core, 0.45 * glow) * s.w);
        }
    }
    return spark;
}

/// The interior's value (0...1) at a pixel inside the panel.
static float gw_interior_value(float2 q, float w, constant GWGlassUniforms &uniforms) {
    const float scale = uniforms.interiorPixelsPerPoint;
    const float2 u = q / scale;
    const float2 halfSize = uniforms.panelHalfSize / scale;
    const float phase = uniforms.interiorPhase;
    const uint seed = uniforms.interiorSeed;
    switch (uniforms.interiorEffect) {
    case GWInteriorEffectEnergy:
        return gw_interior_energy(u, gw_interior_size(halfSize), w, phase, seed);
    case GWInteriorEffectRays:
        return gw_interior_rays(u, gw_interior_size(halfSize), phase, seed);
    case GWInteriorEffectEmbers:
        return max(gw_interior_flames(u, halfSize, phase, seed), gw_interior_sparks(u, uniforms));
    default:
        return 0.0;
    }
}

/// The interior's ramp color at value `e`, in linear light: one color, or
/// two or three spread evenly from 0 to 1.
static float3 gw_interior_ramp(float e, constant GWGlassUniforms &uniforms) {
    const float3 c0 = uniforms.interiorColor0.xyz;
    const float3 c1 = uniforms.interiorColor1.xyz;
    const float3 c2 = uniforms.interiorColor2.xyz;
    if (uniforms.interiorColorCount <= 1u) {
        return c0;
    }
    if (uniforms.interiorColorCount == 2u) {
        return c0 + (c1 - c0) * e;
    }
    return e < 0.5 ? c0 + (c1 - c0) * (e * 2.0) : c1 + (c2 - c1) * (e * 2.0 - 1.0);
}

// MARK: Inner light (GW-21)
//
// Colored light inside the glass (docs/glass-optics.md). The CPU resolves
// every emitter for the draw (`GlassPanelGeometry.Light`): directions,
// pixel lengths, the palette's flow and hue drift, and the drift offset, all
// at the draw's effect time, so the shader sees no time. Every emitter is
// evaluated in panel unit space, `u = q / panelHalfSize` (the panel scaled
// to a square), so a band or an arc means the same for any panel shape. With
// no emitters (`lightEmitterCount` 0) none of this runs and the output is
// the output without light.

/// The most opacity `.paint` light gives one emitter.
constant float gw_light_paint_cap = 0.85;

/// The emitter's palette at position `x`, in linear light. The palette
/// folds back and forth (period 2: stop 0 to the last stop and back), so
/// shifting `x` by 2 is the identity and a flowing palette never jumps. Stops
/// are spread evenly over 0 to 1 and interpolate linearly.
static float3 gw_light_palette(float x, constant GWLightEmitter &emitter) {
    const uint count = emitter.colorCount;
    if (count <= 1u) {
        return emitter.color0.xyz;
    }
    const float folded = x - 2.0 * floor(x * 0.5);
    const float m = folded <= 1.0 ? folded : 2.0 - folded;
    const float position = m * float(count - 1u);
    const uint index = min(uint(position), count - 2u);
    const float3 colors[4] = {emitter.color0.xyz, emitter.color1.xyz, emitter.color2.xyz, emitter.color3.xyz};
    return mix(colors[index], colors[index + 1u], position - float(index));
}

/// A quick profile, 1 at `x` 0 and exactly 0 from `x` 1 on: (1 - x)^2. The
/// piping uses it.
static float gw_light_falloff(float x) {
    const float t = 1.0 - saturate(x);
    return t * t;
}

/// A pooled profile, 1 at `x` 0 and exactly 0 from `x` 1 on, falling slowly
/// near 0 and near 1: 1 - smoothstep(0, 1, x). Never rises with `x`. The
/// bands, arcs, and fields use it for their body light.
static float gw_light_pool(float x) {
    return 1.0 - smoothstep(0.0, 1.0, x);
}

/// One emitter's color (`xyz`) and body light (`w`, before intensity and
/// center fade) at pixel offset `q` from the panel's center, `depth` pixels
/// inside the outline and `w` of the way to the deepest point. `pipe`
/// receives the weight of its piping, 0...1: the falloff with the Euclidean
/// distance, in pixels, from the emitter's source.
static float4 gw_light_emitter(
    float2 q, float depth, float w, constant GWLightEmitter &emitter,
    constant GWGlassUniforms &uniforms, thread float &pipe)
{
    const float2 halfSize = uniforms.panelHalfSize;
    const float2 u = q / halfSize;
    const float4 shape = emitter.shape;
    const float4 motion = emitter.motion;
    const float pipeReach = motion.w;
    float3 color = emitter.color0.xyz;
    float body = 0.0;
    pipe = 0.0;
    switch (emitter.kind) {
    case GWLightKindBand: {
        // The half-plane toward the lit edge: `edge` is the unit-space
        // distance from it, never negative (the corners of a rectangle lie
        // past it and get the full light).
        const float2 direction = shape.xy;
        const float edge = max(1.0 - dot(u, direction), 0.0);
        const float reach = max(shape.z * (1.0 + 0.3 * motion.z), 1e-4);
        body = gw_light_pool(edge / reach);
        const float tau = saturate(0.5 + 0.5 * dot(u, float2(direction.y, -direction.x)));
        color = gw_light_palette(tau + motion.x, emitter);
        if (pipeReach > 0.0) {
            pipe = gw_light_falloff(edge * shape.w / pipeReach);
        }
        break;
    }
    case GWLightKindArc: {
        float turn = 0.0;
        if (u.x != 0.0 || u.y != 0.0) {
            turn = precise::atan2(u.x, -u.y) * (0.5 / M_PI_F);
            turn = turn - floor(turn);
        }
        float delta = turn - (shape.x + 0.12 * motion.y);
        delta = delta - round(delta);
        const float halfSpan = max(shape.y, 1e-4);
        const float along = 1.0 - smoothstep(0.4 * halfSpan, halfSpan, abs(delta));
        body = along * gw_light_pool(depth / max(shape.z, 1e-4));
        color = gw_light_palette(saturate(0.5 + delta / (2.0 * halfSpan)) + motion.x, emitter);
        if (pipeReach > 0.0) {
            // Euclidean distance to the arc: the depth, and the way along
            // the outline past the arc's end.
            const float beyond = max(abs(delta) - halfSpan, 0.0) * (2.0 * M_PI_F) * length(q);
            pipe = gw_light_falloff(length(float2(depth, beyond)) / pipeReach);
        }
        break;
    }
    case GWLightKindPoint: {
        const float2 center = (shape.xy + motion.yz * 0.25) * halfSize;
        const float2 offset = q - center;
        const float2 radii = float2(shape.w, 1.0) * max(shape.z, 1e-3);
        const float2 scaled = offset / radii;
        const float d2 = dot(scaled, scaled);
        const float t = 1.0 - saturate(d2);
        body = t * t;
        color = gw_light_palette(sqrt(min(d2, 1.0)) + motion.x, emitter);
        if (pipeReach > 0.0) {
            pipe = gw_light_falloff(length(offset) / pipeReach);
        }
        break;
    }
    case GWLightKindField: {
        // Four corner colors, bilinear, warped by one octave of noise that
        // moves around a loop (`shape.yz`) and wanders with the drift.
        const float2 uv = saturate(u * 0.5 + 0.5);
        const float2 noiseAt = uv * 2.5 + shape.yz + motion.yz * 3.0;
        const float2 noise = float2(
            gw_noise2(noiseAt, int2(0), emitter.seed),
            gw_noise2(noiseAt + float2(17.3, 5.1), int2(0), emitter.seed + 0x51ed270bu));
        const float2 warped = saturate(uv + shape.x * 0.9 * (noise - 0.5));
        const float3 top = mix(emitter.color0.xyz, emitter.color1.xyz, warped.x);
        const float3 bottom = mix(emitter.color2.xyz, emitter.color3.xyz, warped.x);
        color = mix(top, bottom, warped.y);
        body = gw_light_pool(w);
        pipe = 1.0;
        break;
    }
    default:
        break;
    }
    return float4(color, body);
}

// MARK: Shape field and thick lens (GW-22)
//
// The thick-lens code exists only in the `optics` pipeline variant: the host
// builds this function with `gw_optics_constant` true for a panel whose
// `GlassLens` draws something, and with it unset otherwise, in which case
// everything below is compiled out and the shader is the one of GW-21, byte
// for byte (a frozen copy in the tests proves it). The model is mirrored on
// the CPU by `GlassLensModel` (GlassLensModel.swift).

constant bool gw_optics_constant [[function_constant(0)]];
constant bool gw_optics = is_function_constant_defined(gw_optics_constant) ? gw_optics_constant : false;

/// What the optics ask of a panel's shape (GlassShapeField.swift documents
/// the interface; a later shape kind returns the same four things).
struct GWShapeSample {
    /// Signed distance to the outline in pixels: negative inside.
    float distance;
    /// The unit direction in which `lensDepth` falls (outward).
    float2 normal;
    /// Pixels inside the shape, 0 at and outside the outline. C1: the inward
    /// distance of the rounded rectangle of `lensFieldRadius`, whose
    /// iso-contours keep a corner radius of at least the bevel width.
    float lensDepth;
    /// Radius of the largest circle inside the shape, in pixels.
    float inscribedRadius;
};

/// The rounded-rectangle shape field.
static GWShapeSample gw_shape_rounded_rect(float2 q, constant GWGlassUniforms &uniforms) {
    GWShapeSample shape;
    shape.distance = gw_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    shape.normal = gw_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.lensFieldRadius);
    shape.lensDepth = max(-gw_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.lensFieldRadius), 0.0);
    shape.inscribedRadius = min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y);
    return shape;
}

/// The steepest surface slope the optics use (rise over run).
constant float gw_lens_max_slope = 12.0;

/// A height profile `s(t)` (x) and its slope `s'(t)` (y), `t` in 0...1 the
/// depth into the bevel over the bevel width: 0 at the outline. `a` and `b`
/// are the profile's parameters (`GWLensProfile`).
static float2 gw_lens_profile(uint profile, float t, float a, float b) {
    t = saturate(t);
    switch (profile) {
    case GWLensProfileCircular:
    case GWLensProfileDome: {
        const float s = sqrt(max(t * (2.0 - t), 0.0));
        return float2(s, s > 1e-6 ? (1.0 - t) / s : gw_lens_max_slope * 100.0);
    }
    case GWLensProfileSquircle: {
        const float n = max(a, 1.0);
        const float u = 1.0 - t;
        const float inner = max(1.0 - pow(u, n), 0.0);
        const float s = pow(inner, 1.0 / n);
        return float2(s, inner > 1e-9 ? pow(u, n - 1.0) * pow(inner, 1.0 / n - 1.0) : gw_lens_max_slope * 100.0);
    }
    case GWLensProfileChamfer: {
        const float knee = 0.7;
        const float norm = (1.0 + knee) * 0.5;
        if (t < knee) {
            return float2(t / norm, 1.0 / norm);
        }
        const float u = t - knee;
        return float2((knee + u - u * u / (2.0 * (1.0 - knee))) / norm, (1.0 - u / (1.0 - knee)) / norm);
    }
    case GWLensProfileRing: {
        const float x = (t - a) / max(b, 1e-6);
        if (abs(x) >= 1.0) {
            return float2(0.0);
        }
        const float s = sqrt(1.0 - x * x);
        return float2(s, s > 1e-6 ? -x / (b * s) : (x < 0.0 ? 1.0 : -1.0) * gw_lens_max_slope * 100.0);
    }
    default:
        return float2(0.0);
    }
}

/// The glass surface at a pixel: its height in pixels and the gradient of
/// the height (pixels per pixel, pointing toward the interior).
struct GWLensField {
    float height;
    float2 gradient;
};

/// The host panel's height field: `h = H * s(lensDepth / bevel)`.
static GWLensField gw_lens_host(GWShapeSample shape, constant GWGlassUniforms &uniforms) {
    GWLensField field;
    field.height = 0.0;
    field.gradient = float2(0.0);
    if (uniforms.lensProfile == GWLensProfileRim) {
        return field;
    }
    const float t = uniforms.lensBevel > 0.0 ? saturate(shape.lensDepth / uniforms.lensBevel) : 1.0;
    const float2 profile = gw_lens_profile(uniforms.lensProfile, t, uniforms.lensProfileA, uniforms.lensProfileB);
    field.height = uniforms.lensThickness * profile.x;
    if (t < 1.0) {
        // The depth falls toward the outline, so the height rises along the
        // inward direction: against the outward normal.
        const float rise = clamp(uniforms.lensThickness * profile.y / uniforms.lensBevel, -gw_lens_max_slope, gw_lens_max_slope);
        field.gradient = -shape.normal * rise;
    }
    return field;
}

/// Where the glass sends the sample for a pixel, as an offset in pixels
/// (toward the interior for a convex edge): the surface normal
/// `N = normalize(-gradient, 1)` bends the downward ray with Snell's law,
/// `T = refract(-z, N, 1 / ior)`, and the ray travels the glass height to the
/// background: `T.xy / (-T.z) * h`, scaled by `lensOffsetScale` and at most
/// `lensMaximumOffset` long.
static float2 gw_lens_offset(GWLensField field, float ior, constant GWGlassUniforms &uniforms) {
    if (field.height <= 0.0 || all(field.gradient == float2(0.0))) {
        return float2(0.0);
    }
    const float3 normal = normalize(float3(-field.gradient, 1.0));
    const float3 ray = refract(float3(0.0, 0.0, -1.0), normal, 1.0 / ior);
    float2 offset = ray.xy / max(-ray.z, 1e-3) * (field.height * uniforms.lensOffsetScale);
    const float length2 = dot(offset, offset);
    if (length2 > uniforms.lensMaximumOffset * uniforms.lensMaximumOffset) {
        offset *= uniforms.lensMaximumOffset * rsqrt(length2);
    }
    return offset;
}

/// Adds the inlays' bumps to the height field: each is a profile over the
/// depth into the inlay from its base, `t = (radius - r) / bevel`, so the
/// height is 0 on the base (C0 with the panel) and nothing is added beyond
/// it. The gradient points toward the inlay's center.
static void gw_lens_add_inlays(float2 q, constant GWGlassUniforms &uniforms, thread GWLensField &field) {
    for (uint i = 0u; i < min(uniforms.lensInlayCount, 2u); ++i) {
        constant GWLensInlay &inlay = uniforms.lensInlays[i];
        const float2 offset = q - inlay.geometry.xy;
        const float radius = inlay.geometry.z;
        const float r = length(offset);
        if (r >= radius || inlay.shape.x <= 0.0) {
            continue;
        }
        const float t = saturate((radius - r) / inlay.shape.x);
        const float2 profile = gw_lens_profile(inlay.profile, t, inlay.shape.y, inlay.shape.z);
        field.height += inlay.geometry.w * profile.x;
        if (t < 1.0 && r > 1e-4) {
            const float rise = clamp(inlay.geometry.w * profile.y / inlay.shape.x, -gw_lens_max_slope, gw_lens_max_slope);
            field.gradient -= offset / r * rise;
        }
    }
}

/// The inlays' rim light, as a fraction of the way to white: a thin line at
/// the base and a brighter bevel inside it, both lit from the direction of the
/// panel's edge light (`lightDirection`, the upper left, or the key light's
/// azimuth with the light model). Exactly 0 beyond half a pixel outside every
/// base.
static float gw_lens_inlay_highlight(float2 q, float2 lightDirection, constant GWGlassUniforms &uniforms) {
    float light = 0.0;
    for (uint i = 0u; i < min(uniforms.lensInlayCount, 2u); ++i) {
        constant GWLensInlay &inlay = uniforms.lensInlays[i];
        const float2 offset = q - inlay.geometry.xy;
        const float radius = inlay.geometry.z;
        const float r = length(offset);
        if (r >= radius + 0.5 || inlay.shape.w <= 0.0 || inlay.shape.x <= 0.0) {
            continue;
        }
        const float facing = r > 1e-4 ? saturate(dot(offset / r, lightDirection)) : 0.0;
        const float lit = 0.35 + 0.65 * facing;
        // A line about 1.5 pixels wide at the base, antialiased on both sides.
        const float line = saturate(1.0 - abs(r - (radius - 0.75)) / 1.25);
        const float bevel = saturate((radius - r) / inlay.shape.x);
        const float rim = (1.0 - bevel) * (1.0 - bevel) * (1.0 - bevel);
        light = max(light, inlay.shape.w * (0.85 * line * lit + 0.35 * rim * lit));
    }
    return saturate(light);
}

/// How far the index of refraction of red and blue light differs from the
/// base index at dispersion 1.
constant float gw_lens_ior_spread = 0.12;
/// How far the original rim's displacement differs between red and blue
/// light at dispersion 1, as a fraction of it.
constant float gw_lens_rim_spread = 0.35;
/// The smallest red-to-blue separation, in pixels, that is worth separate
/// samples; below it the colors are not split.
constant float gw_lens_min_separation = 0.25;
/// The six wavelengths of the six-tap spectrum, -1 (red) to 1 (blue).
constant float gw_lens_tap_x[6] = {-1.0, -0.6, -0.2, 0.2, 0.6, 1.0};
/// Each tap's weights in red, green, and blue: triangles centered on
/// -1, 0, and 1, normalized so every channel's weights sum to 1 (a white
/// source stays white).
constant float3 gw_lens_tap_weight[6] = {
    float3(11.0 / 21.0, 0.0, 0.0),
    float3(7.0 / 21.0, 0.15, 0.0),
    float3(3.0 / 21.0, 0.35, 0.0),
    float3(0.0, 0.35, 3.0 / 21.0),
    float3(0.0, 0.15, 7.0 / 21.0),
    float3(0.0, 0.0, 11.0 / 21.0),
};

/// Whether the thick-lens path draws the panel: a lens profile, dispersion
/// on the original rim, or an inlay.
static bool gw_lens_active(constant GWGlassUniforms &uniforms) {
    return uniforms.lensProfile != GWLensProfileRim || uniforms.lensTapCount > 0u || uniforms.lensInlayCount > 0u;
}

/// The glass color at a pixel under a lens, in linear light. `rimNormal` and
/// `rimDisplacement` are the original rim's, used when the host profile is
/// the rim (with dispersion).
///
/// Dispersion: a wavelength `x` (-1 red, 0 green, 1 blue) sees the index
/// `ior + x * dispersion * 0.12`, and the rim's displacement scaled by
/// `1 + x * dispersion * 0.35`. Where red and blue land less than a quarter
/// pixel apart there is one sample, as without dispersion; elsewhere three
/// samples give red, green, and blue their own wavelength, or six wavelengths
/// are blended with weights that sum to 1 per channel. Every sample keeps the
/// valid-rectangle clamp.
static float3 gw_lens_glass(
    float2 pixel, float2 q, float2 rimNormal, float rimDisplacement,
    constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    const GWShapeSample shape = gw_shape_rounded_rect(q, uniforms);
    GWLensField field = gw_lens_host(shape, uniforms);
    gw_lens_add_inlays(q, uniforms, field);
    const float2 rim = uniforms.lensProfile == GWLensProfileRim ? -rimNormal * rimDisplacement : float2(0.0);
    const float ior = uniforms.lensIOR;
    const float2 center = rim + gw_lens_offset(field, ior, uniforms);
    if (uniforms.lensTapCount == 0u || uniforms.lensDispersion <= 0.0) {
        return gw_glass_sample(pixel + center, uniforms, source);
    }
    const float spread = uniforms.lensDispersion * gw_lens_ior_spread;
    const float rimSpread = uniforms.lensDispersion * gw_lens_rim_spread;
    const float2 red = rim * (1.0 - rimSpread) + gw_lens_offset(field, max(ior - spread, 1.0), uniforms);
    const float2 blue = rim * (1.0 + rimSpread) + gw_lens_offset(field, ior + spread, uniforms);
    const float2 separation = blue - red;
    if (dot(separation, separation) < gw_lens_min_separation * gw_lens_min_separation) {
        return gw_glass_sample(pixel + center, uniforms, source);
    }
    if (uniforms.lensTapCount == 3u) {
        return float3(gw_glass_sample(pixel + red, uniforms, source).r,
                      gw_glass_sample(pixel + center, uniforms, source).g,
                      gw_glass_sample(pixel + blue, uniforms, source).b);
    }
    float3 color = float3(0.0);
    for (uint tap = 0u; tap < 6u; ++tap) {
        const float x = gw_lens_tap_x[tap];
        const float2 offset = rim * (1.0 + x * rimSpread) + gw_lens_offset(field, max(ior + x * spread, 1.0), uniforms);
        color += gw_lens_tap_weight[tap] * gw_glass_sample(pixel + offset, uniforms, source);
    }
    return color;
}

// MARK: Light model (GW-23)
//
// One movable light (docs/glass-optics.md): a Fresnel outline, a specular
// streak, an analytic studio reflected on the rim, chrome and prismatic
// finishes, a soft knee, and a bloom. The code exists only in the `lighting`
// pipeline variant: the host builds this function with `gw_lighting_constant`
// true for a panel whose `GlassLighting` is not `.legacy`, and with it unset
// otherwise, in which case everything below is compiled out and the shader is
// the one of GW-22, byte for byte (a frozen copy in the tests proves it). The
// shader is the reference of the model; there is no CPU mirror.

constant bool gw_lighting_constant [[function_constant(1)]];
constant bool gw_lighting = is_function_constant_defined(gw_lighting_constant) ? gw_lighting_constant : false;

/// The surface normal of the panel at `q`, from the slope of its height
/// field: the lens's (host profile and inlays) or, without a lens profile, a
/// quarter-round edge `lighting.bevel` wide. `outward` receives the outline's
/// unit normal at `q`.
static float3 gw_light_normal(float2 q, constant GWGlassUniforms &uniforms, thread float2 &outward) {
    constant GWLightingUniforms &lighting = uniforms.lighting;
    GWLensField field;
    field.height = 0.0;
    field.gradient = float2(0.0);
    if (uniforms.lensProfile != GWLensProfileRim) {
        const GWShapeSample shape = gw_shape_rounded_rect(q, uniforms);
        field = gw_lens_host(shape, uniforms);
        outward = shape.normal;
    } else {
        outward = gw_rounded_rect_normal(q, uniforms.panelHalfSize, lighting.fieldRadius);
        const float depth = max(-gw_rounded_rect_distance(q, uniforms.panelHalfSize, lighting.fieldRadius), 0.0);
        const float t = lighting.bevel > 0.0 ? saturate(depth / lighting.bevel) : 1.0;
        if (t < 1.0) {
            const float2 profile = gw_lens_profile(GWLensProfileCircular, t, 0.0, 0.0);
            // Thickness equals the bevel, so the slope is the profile's.
            field.gradient = -outward * clamp(profile.y, -gw_lens_max_slope, gw_lens_max_slope);
        }
    }
    if (uniforms.lensInlayCount > 0u) {
        gw_lens_add_inlays(q, uniforms, field);
    }
    return normalize(float3(-field.gradient, 1.0));
}

/// The soft knee: identity up to 0.8, then a shoulder that is C1 there
/// (slope 1) and rises monotonically toward 1 without reaching it.
static float3 gw_light_knee(float3 x) {
    const float3 shoulder = 0.8 + 0.2 * (1.0 - exp(-(x - 0.8) * 5.0));
    return select(shoulder, x, x <= 0.8);
}

/// A soft rectangle in the studio's (azimuth, elevation) space, 1 inside and
/// 0 outside, with edges `soft` radians wide. `center` is (azimuth,
/// elevation) and `extent` the half width and half height, in radians.
static float gw_studio_box(float2 azel, float2 center, float2 extent, float soft) {
    const float2 d = abs(azel - center);
    const float2 inside = 1.0 - smoothstep(extent - soft, extent + soft, d);
    return inside.x * inside.y;
}

/// The studio seen along the unit direction `R` (x right, y down, z toward the
/// viewer), turned by `azimuth` radians with the key light: the sky, the
/// horizon line, and the floor in `base`, and the key softbox (`x`) and the two
/// tall strips at either side (`y`) in `boxes`, each at its brightness. Light
/// studio: a pale sky, a dark floor, white boxes. Dark studio: a near-black
/// room with gray boxes.
static void gw_studio(float3 R, float azimuth, uint environment, thread float3 &base, thread float2 &boxes) {
    const float elevation = asin(clamp(R.z, -1.0, 1.0));
    float az = precise::atan2(R.x, -R.y) - azimuth;
    az = az - 2.0 * M_PI_F * round(az / (2.0 * M_PI_F));
    const bool dark = environment == GWLightingEnvironmentStudioDark;
    const float up = saturate(R.z);
    const float3 sky = dark ? mix(float3(0.020, 0.022, 0.030), float3(0.040, 0.044, 0.056), up)
                            : mix(float3(0.50, 0.51, 0.55), float3(0.30, 0.31, 0.35), up);
    const float3 floorColor = dark ? float3(0.006, 0.006, 0.008) : float3(0.20, 0.20, 0.23);
    const float3 horizonColor = dark ? float3(0.12, 0.125, 0.14) : float3(0.95, 0.95, 0.97);
    const float horizon = exp(-pow(elevation / 0.09, 2.0));
    base = mix(floorColor, sky, smoothstep(-0.06, 0.06, elevation)) + horizonColor * horizon;
    const float keyBox = gw_studio_box(float2(az, elevation), float2(0.0, 0.66), float2(0.70, 0.26), 0.10);
    const float stripLeft = gw_studio_box(float2(az, elevation), float2(-1.68, 0.45), float2(0.22, 0.55), 0.08);
    const float stripRight = gw_studio_box(float2(az, elevation), float2(1.68, 0.45), float2(0.22, 0.55), 0.08);
    boxes = float2(keyBox * (dark ? 1.5 : 2.0), max(stripLeft, stripRight) * (dark ? 1.3 : 3.2));
}

/// A thin-film palette at `h` turns, as a color that multiplies a reflection:
/// white at `saturation` 0, the full rainbow at 1.
static float3 gw_light_film(float h, float saturation) {
    const float3 rainbow = 0.5 + 0.5 * cos(2.0 * M_PI_F * (h + float3(0.0, 1.0 / 3.0, 2.0 / 3.0)));
    return mix(float3(1.0), rainbow, saturation);
}

/// A Blinn-Phong lobe of one light, with its exponent limited by the pixel
/// footprint so it is never narrower than a pixel's change of normal, and its
/// peak lowered to match (the lobe's energy stays the same).
static float3 gw_light_lobe(float3 N, float4 direction, float4 color, float footprint) {
    if (direction.w <= 0.0) {
        return float3(0.0);
    }
    const float3 H = normalize(direction.xyz + float3(0.0, 0.0, 1.0));
    const float p = max(color.w, 1.0);
    const float effective = 1.0 / (1.0 / p + footprint * footprint);
    return color.xyz * direction.w * ((effective + 2.0) / (p + 2.0)) * pow(saturate(dot(N, H)), effective);
}

/// The bright lines of the light model at a point inside the band, in linear
/// light before the knee: the Fresnel outline and the specular streaks of the
/// key and rim lights. `depth` pixels inside the outline, `N` the surface
/// normal there.
static float3 gw_light_lines(float3 N, float depth, constant GWGlassUniforms &uniforms) {
    constant GWLightingUniforms &lighting = uniforms.lighting;
    const float band = lighting.bandWidth;
    if (band <= 0.0 || depth >= band) {
        return float3(0.0);
    }
    const float mask = 1.0 - smoothstep(0.75 * band, band, depth);
    const float edge = 1.0 - N.z;
    const float edge2 = edge * edge;
    const float outline = edge2 * edge2 * edge;
    const float2 direction = N.xy / max(length(N.xy), 1e-4);
    const float facing = 0.65 + 0.35 * (0.5 + 0.5 * dot(direction, lighting.edgeDirection));
    const float3 outlineColor = mix(float3(1.0), lighting.keyColor.xyz, 0.6);
    float3 energy = outlineColor * (lighting.fresnel * outline * facing * (lighting.contrast > 0.0 ? 0.0 : 1.0));
    const float3 lobes = gw_light_lobe(N, lighting.key, lighting.keyColor, lighting.footprint)
                       + gw_light_lobe(N, lighting.rim, lighting.rimColor, lighting.footprint);
    energy += lobes * lighting.specular;
    return energy * mask;
}

/// The glass with the light model composited: reflections of the studio on
/// the rim (glass mixed with the Fresnel reflection, or chrome or the
/// prismatic finish replacing it), then the bright lines and their bloom added
/// through the soft knee, `G + (1 - G) K(E)`, which never darkens a channel
/// and never exceeds 1. Returns the changed color and, in `touched`, whether
/// this pixel is changed at all (then it is dithered like the glow).
static float3 gw_light_model(
    float3 glass, float2 q, float depth, constant GWGlassUniforms &uniforms, thread float &touched)
{
    constant GWLightingUniforms &lighting = uniforms.lighting;
    const float band = lighting.bandWidth;
    const float reach = band + (lighting.bloom > 0.0 ? lighting.bloomWidth : 0.0);
    touched = 0.0;
    if (reach <= 0.0 || depth >= reach) {
        return glass;
    }
    float2 outward;
    const float3 N = gw_light_normal(q, uniforms, outward);
    const float bandMask = band > 0.0 ? 1.0 - smoothstep(0.75 * band, band, depth) : 0.0;

    // Reflections.
    if (lighting.reflection > 0.0 && bandMask > 0.0) {
        const float3 R = float3(2.0 * N.z * N.xy, 2.0 * N.z * N.z - 1.0);
        float3 base;
        float2 boxes;
        gw_studio(R, lighting.azimuth, lighting.environment, base, boxes);
        const float F = lighting.f0 + (1.0 - lighting.f0) * pow(1.0 - N.z, 5.0);
        if (lighting.finish == GWLightingFinishDielectric) {
            // The part of the reflectance that grows toward the outline is
            // boosted up to five times at `reflection` 1, so a studio shows on
            // glass as it does in a photograph of it; at N.z = 1 it is F0.
            const float reflectance = saturate(lighting.f0 + (F - lighting.f0) * (1.0 + 4.0 * lighting.reflection));
            const float alpha = reflectance * lighting.reflection * bandMask;
            glass = glass * (1.0 - alpha) + gw_light_knee(base + boxes.x + boxes.y) * alpha;
            touched = max(touched, alpha);
        } else {
            float3 environment = (base + boxes.x + boxes.y) * lighting.tint.xyz;
            if (lighting.finish == GWLightingFinishPrismatic) {
                const float turn = precise::atan2(N.x, -N.y) * (0.5 / M_PI_F) - lighting.azimuth * (0.5 / M_PI_F);
                const float hue = lighting.prism.z + lighting.prism.x * (turn - floor(turn)) + 0.5 * (1.0 - N.z);
                const float3 film = gw_light_film(hue, lighting.prism.y);
                const float3 mild = gw_light_film(hue, 0.25 * lighting.prism.y);
                environment = (base * mild + boxes.x * mix(float3(1.0), film, 0.5) + boxes.y * film) * lighting.tint.xyz;
            }
            const float metal = 0.85 + 0.15 * F;
            const float alpha = lighting.reflection * smoothstep(0.005, 0.08, 1.0 - N.z) * bandMask;
            glass = mix(glass, gw_light_knee(environment * metal), alpha);
            touched = max(touched, alpha);
        }
    }

    // The contrasting hairline (accessibility): the outline mixes toward light
    // on dark glass and toward dark on light glass.
    if (lighting.contrast > 0.0 && band > 0.0) {
        const float edge = 1.0 - N.z;
        const float edge2 = edge * edge;
        const float hairline = saturate(1.5 * lighting.fresnel * edge2 * edge2 * edge) * bandMask;
        const float luminance = dot(glass, float3(0.2126, 0.7152, 0.0722));
        const float3 target = luminance > 0.5 ? float3(0.10, 0.10, 0.12) : float3(0.96, 0.96, 0.98);
        glass = mix(glass, target, hairline);
        touched = max(touched, hairline);
    }

    // The bright lines, and the bloom spread along the surface from them.
    float3 energy = gw_light_lines(N, depth, uniforms);
    if (lighting.bloom > 0.0 && lighting.bloomWidth > 0.0) {
        float3 spill = float3(0.0);
        for (uint i = 1u; i <= 3u; ++i) {
            const float weight = (1.0 - float(i) * 0.25) * (1.0 - float(i) * 0.25);
            const float k = lighting.bloomWidth * float(i) * 0.25;
            for (uint side = 0u; side < 2u; ++side) {
                const float2 tap = q + outward * (side == 0u ? k : -k);
                const float tapDistance = gw_rounded_rect_distance(tap, uniforms.panelHalfSize, uniforms.cornerRadius);
                if (tapDistance > 0.0) {
                    continue;
                }
                float2 ignored;
                spill += weight * gw_light_lines(gw_light_normal(tap, uniforms, ignored), -tapDistance, uniforms);
            }
        }
        energy += spill * (0.6 * lighting.bloom);
    }
    if (energy.x > 0.0 || energy.y > 0.0 || energy.z > 0.0) {
        glass = glass + (1.0 - glass) * gw_light_knee(energy);
        touched = 1.0;
    }
    return glass;
}

// MARK: Grounding (GW-25)
//
// Depth cues for panels on light pages (docs/glass-optics.md): a drop shadow,
// a contact shadow, an inner shadow, and a colored caustic, all analytic from
// the panel's rounded-rectangle field and all driven by one direction, away
// from the key light (`grounding.shadowDirection`). The code exists only in
// the `grounded` pipeline variant, built with function constant 2
// (`gw_grounding_constant`); without it everything here is compiled out and
// the shader is the one of GW-23, byte for byte (a frozen copy in the tests
// proves it).
//
// Two passes make a grounded panel. Before any panel body, a pre-pass draws
// one quad per grounded panel, blended onto the background that is already in
// the target: the drop and contact shadows by *multiplying* the encoded value
// (`gw_grounding_shadow_fragment`), then the caustic by *adding* to it
// (`gw_grounding_caustic_fragment`). Both blend in the encoded `bgra8Unorm`
// target, so they are encoded-space operations; a multiply there approximates
// a multiply in linear light. The body (below) leaves every pixel outside its
// outline to the pre-pass, so a neighbour's shadow is never erased, and
// composites its antialiased ring over whatever the target holds.

constant bool gw_grounding_constant [[function_constant(2)]];
constant bool gw_grounding = is_function_constant_defined(gw_grounding_constant) ? gw_grounding_constant : false;

/// A Gaussian-blurred half-plane's coverage at signed distance `d` from its
/// edge (positive outside): 0.5 at the edge, 1 deep inside, 0 far outside,
/// `0.5 erfc(d / (sigma sqrt 2))`. Abramowitz and Stegun 7.1.26 for `erf`.
static float gw_blur_edge(float d, float sigma) {
    const float x = d / (max(sigma, 0.25) * 1.41421356);
    const float t = 1.0 / (1.0 + 0.3275911 * abs(x));
    const float poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
    const float tail = 0.5 * poly * exp(-x * x);
    return x >= 0.0 ? tail : 1.0 - tail;
}

/// What the drop and contact shadows multiply the encoded background by at a
/// pixel, per channel: 1 for no shadow, below 1 where shadowed. Never above 1.
static float3 gw_grounding_multiplier(float2 pixel, constant GWGlassUniforms &uniforms) {
    constant GWGroundingUniforms &g = uniforms.grounding;
    const float2 q = pixel - uniforms.panelCenter;
    float3 multiplier = float3(1.0);
    if (g.dropColor.w > 0.0) {
        // The outline moved away from the light, grown by the spread, with a
        // Gaussian edge: the blurred shadow of a rounded rectangle.
        const float d = gw_rounded_rect_distance(q - g.shadowDirection * g.dropOffset, uniforms.panelHalfSize, uniforms.cornerRadius) - g.dropSpread;
        const float s = g.dropColor.w * gw_blur_edge(d, g.dropSigma);
        multiplier *= 1.0 - s * (1.0 - g.dropColor.xyz);
    }
    if (g.contactColor.w > 0.0 && g.contactWidth > 0.0) {
        // A tight, dark line where the glass meets the page: full at the
        // outline, falling quadratically over `contactWidth` pixels.
        const float d = gw_rounded_rect_distance(q - g.shadowDirection * g.contactOffset, uniforms.panelHalfSize, uniforms.cornerRadius);
        const float c = saturate(1.0 - d / g.contactWidth);
        multiplier *= 1.0 - g.contactColor.w * c * c * (1.0 - g.contactColor.xyz);
    }
    return multiplier;
}

/// The caustic's light at a pixel, encoded, to add: a band of focused light
/// along the outline moved away from the light by `causticOffset`, strongest
/// where the outline faces away from the light, its red, green and blue parts
/// pulled apart by `causticDispersion` and its hue turning around the band by
/// `causticSpectrum`. Exactly zero three widths (and the dispersion) from the
/// band, and never negative.
static float3 gw_grounding_caustic(float2 pixel, constant GWGlassUniforms &uniforms) {
    constant GWGroundingUniforms &g = uniforms.grounding;
    if (g.causticColor.w <= 0.0 || g.causticWidth <= 0.0) { return float3(0.0); }
    const float2 q = pixel - uniforms.panelCenter - g.shadowDirection * g.causticOffset;
    const float d = gw_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float reach = g.causticWidth * (3.0 + 1.2 * g.causticDispersion);
    if (abs(d) > reach) { return float3(0.0); }
    const float2 n = gw_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float facing = saturate(dot(n, g.shadowDirection));
    if (facing <= 0.0) { return float3(0.0); }
    // The three wavelengths' bands sit at slightly different distances.
    const float3 x = (d + float3(-1.0, 0.0, 1.0) * g.causticDispersion * g.causticWidth * 0.55) / g.causticWidth;
    const float3 band = exp(-x * x);
    const float2 across = float2(-g.shadowDirection.y, g.shadowDirection.x);
    const float angle = atan2(dot(n, across), dot(n, g.shadowDirection));
    const float hue = 0.5 + 0.55 * angle / 6.2831853;
    const float3 rainbow = saturate(0.5 + 0.5 * cos(6.2831853 * (hue + float3(0.0, 1.0 / 3.0, 2.0 / 3.0))) * 1.15);
    const float3 color = g.causticColor.xyz * mix(float3(1.0), rainbow, g.causticSpectrum);
    return color * band * (g.causticColor.w * facing * facing);
}

static float3 gw_glass_decode_srgb(float3 encoded) {
    const float3 c = saturate(encoded);
    const float3 low = c / 12.92;
    const float3 high = pow((c + 0.055) / 1.055, float3(2.4));
    return select(high, low, c <= 0.04045);
}

/// The grounding's quad: the panel rectangle grown by `grounding.reach`.
vertex GWGlassVertexOut gw_grounding_vertex(
    uint vertexID [[vertex_id]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + uniforms.grounding.reach);
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWGlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// The shadows' pre-pass fragment: the multiplier, blended as
/// `destination * source` (source factor zero, destination factor source
/// color).
fragment float4 gw_grounding_shadow_fragment(
    GWGlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    return float4(gw_grounding_multiplier(in.position.xy, uniforms), 1.0);
}

/// The caustic's pre-pass fragment: the light, blended by addition.
fragment float4 gw_grounding_caustic_fragment(
    GWGlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    return float4(gw_grounding_caustic(in.position.xy, uniforms), 0.0);
}

/// One rounded glass panel over the background.
///
/// Inside the rim (`bezelWidth` pixels inward from the outline) the sample
/// moves toward the panel interior, like a convex rim: by
/// `maxDisplacement * (1 - depth / bezelWidth)^2` pixels at `depth` pixels
/// inside the outline. The mapping from depth to sampled depth never folds
/// over for refraction in [0, 1]. Beyond the rim the panel is flat and
/// samples in place.
///
/// The tint mixes in linear light, then edge illumination moves the rim at
/// most `edgeHighlight` of the way to white, strongest at the outline and on
/// the side facing the light. With a glow (GW-17, `glowStopCount` > 0), the
/// glow layer is composited over that glass in linear light as a
/// premultiplied layer `(color * alpha, alpha)`. The outline is antialiased
/// over one pixel by mixing with the undisplaced background in linear light,
/// so the edge has no dark or bright fringe. Where the glow draws, a 4 x 4
/// ordered dither of at most 0.47 of an 8-bit step breaks up bands; where it
/// does not (and always without a glow) the output is exactly the glow-free
/// result. Every pixel is written opaque.
///
/// With a halo (GW-18, `glowHaloRadius` > 0), the part of each pixel
/// outside the outline is the background with the halo's light added: the
/// premultiplied light `L = color * haloAlpha` is screened over the
/// background in linear light, `background + L * (1 - background)` per
/// channel, with `haloAlpha = glowHaloIntensity * (1 - s / glowHaloRadius)^2
/// * light` at distance `s` outside the outline (zero from the radius on).
/// A halo therefore never darkens any channel of the background and never
/// exceeds 1; over black it is exactly `L`. The antialiased outline mixes
/// that with the glass, so rim and halo meet without a gap. The halo is
/// exactly zero from its radius on: such pixels skip it and write the
/// background sample, like the one-pixel ring around a panel without a
/// halo. Nothing is discarded, so the GPU's hidden-surface removal still
/// skips the background fragments the panel's opaque quad covers. Halo
/// pixels are dithered like the glow.
///
/// The glow's color and light (an angle by `precise::atan2`) are evaluated
/// only where the glow layer can be non-zero: inside the outline, within
/// the rim's and inner glow's reach or wherever a center fill is set;
/// outside it, within the halo radius. Elsewhere the layer is exactly
/// transparent, so skipping it changes no byte.
///
/// With an interior (GW-19, `interiorEffect` above 0), the interior's value
/// `e` (0...1) gives its light `L = ramp(e) * e * interiorIntensity * fade`,
/// with `fade = 1 - interiorCenterFade * smoothstep(0.3, 0.85, w)` for the
/// depth fraction `w` (depth over half the shorter side). `L` is screened
/// over the glowing glass in linear light, `G + L * (1 - G)`, before the
/// outline's antialiasing. Embers' sparks above the panel's center line and
/// within the halo radius outside the outline are screened over the haloed
/// background with `(1 - s / glowHaloRadius)^2` in place of the fade. The
/// pattern is evaluated only where `fade` is above 0. Pixels the interior
/// lights are dithered like the glow; elsewhere the bytes are those without
/// an interior.
///
/// With inner light (GW-21, `lightEmitterCount` above 0), each emitter's
/// light is composited over the glass and the interior, in order: its body
/// `intensity * profile * fade`, with the same `fade` as the interior's, and
/// its piping `lightPiping * intensity * pipe * (1 - depth / lightPipingWidth)^2`
/// in the rim band, combine as `a = 1 - (1 - body) * (1 - piping)`. `.light`
/// screens it, `G + color * a * (1 - G)`, which never darkens a channel;
/// `.paint` mixes toward the color by `min(a, 0.85)`. Pixels it lights are
/// dithered like the glow; elsewhere the bytes are those without light.
///
/// With the light model (GW-23, the `lighting` pipeline variant and
/// `lighting.finish` above 0), the panel's edge highlight and the inlays' rim
/// light follow the key light, and the model is composited last, over the glow,
/// the interior, and the inner light, inside the band `lighting.bandWidth`
/// deep (see "Light model" above). Pixels it changes are dithered like the
/// glow; elsewhere the bytes are those without it.
///
/// With grounding (GW-25, the `grounded` pipeline variant and
/// `grounding.flags` active), the body is composited over the target by
/// premultiplied alpha, `(encoded * coverage, coverage)`, so a pixel outside
/// the outline keeps what the pre-pass drew there (every panel's shadows and
/// caustics, a neighbour's included) and the antialiased ring mixes with it.
/// The inner shadow multiplies the glass (linear light) before the highlight,
/// the glow, the interior and the lights; the caustic is added, encoded, over
/// everything, so it continues the pre-pass's across the outline. Only where a
/// halo draws is a pixel written opaque, over the body's own shadowed
/// background: the halo replaces other panels' shadows under it.
fragment float4 gw_glass_fragment(
    GWGlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]],
    texture2d<float, access::sample> source [[texture(GWGlassBindingIndexSourceTexture)]])
{
    const float2 pixel = in.position.xy;
    const float2 q = pixel - uniforms.panelCenter;
    const float distance = gw_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float coverage = saturate(0.5 - distance);
    float3 background = gw_glass_sample(pixel, uniforms, source);
    const bool grounded = gw_grounding && (uniforms.grounding.flags & GWGroundingFlagActive) != 0u;
    if (grounded && uniforms.glowHaloRadius > 0.0 && coverage < 1.0 && distance < uniforms.glowHaloRadius) {
        // The halo replaces the pre-pass's pixels, so it is drawn over this
        // panel's own shadow and caustic.
        const float3 shadowed = gw_glass_encode_srgb(background) * gw_grounding_multiplier(pixel, uniforms) + gw_grounding_caustic(pixel, uniforms);
        background = gw_glass_decode_srgb(shadowed);
    }

    // The halo, for the part of the pixel outside the outline.
    float haloAlpha = 0.0;
    float3 outside = background;
    if (uniforms.glowHaloRadius > 0.0 && coverage < 1.0 && distance < uniforms.glowHaloRadius) {
        const float4 shade = gw_glow_shade(q, uniforms);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        haloAlpha = uniforms.glowHaloIntensity * (1.0 - t) * (1.0 - t) * shade.w;
        outside = background + shade.xyz * haloAlpha * (1.0 - background);
    }
    // Embers' sparks that rise past the top half of the outline, within the
    // halo, are light over the haloed background (GW-19).
    float sparkAlpha = 0.0;
    if (uniforms.interiorEffect == GWInteriorEffectEmbers && uniforms.glowHaloRadius > 0.0
        && coverage < 1.0 && q.y < 0.0 && distance < uniforms.glowHaloRadius) {
        const float e = gw_interior_sparks(q / uniforms.interiorPixelsPerPoint, uniforms);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        sparkAlpha = e * uniforms.interiorIntensity * (1.0 - t) * (1.0 - t);
        if (sparkAlpha > 0.0) {
            outside = outside + gw_interior_ramp(e, uniforms) * sparkAlpha * (1.0 - outside);
        }
    }
    if (coverage <= 0.0) {
        if (haloAlpha <= 0.0 && sparkAlpha <= 0.0) {
            // Grounded: leave the pre-pass's pixel alone.
            if (grounded) { return float4(0.0); }
            return float4(gw_glass_encode_srgb(background), 1.0);
        }
        const uint2 cell = uint2(pixel) & 3u;
        const float3 encoded = saturate(gw_glass_encode_srgb(outside) + ((gw_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
        return float4(encoded, 1.0);
    }

    const float depth = max(-distance, 0.0);
    const float rim = uniforms.bezelWidth > 0.0 ? saturate(1.0 - depth / uniforms.bezelWidth) : 0.0;
    const float2 normal = gw_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.normalRadius);
    const float displacement = uniforms.maxDisplacement * rim * rim;
    float3 glass;
    if (gw_optics && gw_lens_active(uniforms)) {
        // The thick lens (GW-22) replaces the rim refraction.
        glass = gw_lens_glass(pixel, q, normal, displacement, uniforms, source);
    } else {
        glass = gw_glass_sample(pixel - normal * displacement, uniforms, source);
    }

    glass = mix(glass, uniforms.tint.xyz, uniforms.tint.w);
    if (grounded && (uniforms.grounding.flags & GWGroundingFlagInner) != 0u) {
        // The inner shadow: the rim nearest the light shades the glass just
        // inside it, as an inset shadow moved away from the light.
        constant GWGroundingUniforms &g = uniforms.grounding;
        const float d = gw_rounded_rect_distance(q - g.shadowDirection * g.innerOffset, uniforms.panelHalfSize, uniforms.cornerRadius);
        const float s = g.innerColor.w * gw_blur_edge(d, g.innerSigma);
        glass = glass * (1.0 - s * (1.0 - g.innerColor.xyz));
    }
    // The edge light: the upper left, or the key light with the light model.
    const float2 edgeLight = (gw_lighting && uniforms.lighting.finish != GWLightingFinishNone)
        ? uniforms.lighting.edgeDirection : gw_light_direction;
    const float facing = saturate(dot(normal, edgeLight));
    const float highlight = uniforms.edgeHighlight * rim * rim * rim * (0.4 + 0.6 * facing);
    glass = glass + (1.0 - glass) * highlight;
    if (gw_optics && uniforms.lensInlayCount > 0u) {
        glass = glass + (1.0 - glass) * gw_lens_inlay_highlight(q, edgeLight, uniforms);
    }

    float glowAlpha = 0.0;
    // Beyond the rim band and the inner glow's radius, with no center fill,
    // the glow layer's opacity is exactly zero. The 0.01 px margin keeps
    // pixels where approximate division might leave a residue in the
    // computed path, so the result is the same as always evaluating it.
    const float rimReach = uniforms.glowRimIntensity > 0.0 ? uniforms.glowRimWidth + uniforms.glowRimFeather : 0.0;
    const float glowReach = max(rimReach, uniforms.glowInnerRadius) + 0.01;
    if (uniforms.glowStopCount > 0u && (uniforms.glowCenterOpacity > 0.0 || depth < glowReach)) {
        const float4 glow = gw_glow(q, depth, uniforms);
        glowAlpha = glow.w;
        glass = mix(glass, glow.xyz, glowAlpha);
    }

    // The interior, light screened over the glowing glass (GW-19).
    float interiorAlpha = 0.0;
    if (uniforms.interiorEffect != GWInteriorEffectNone) {
        const float w = saturate(depth / min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y));
        const float fade = 1.0 - uniforms.interiorCenterFade * smoothstep(0.3, 0.85, w);
        if (fade > 0.0) {
            const float e = gw_interior_value(q, w, uniforms);
            interiorAlpha = e * uniforms.interiorIntensity * fade;
            if (interiorAlpha > 0.0) {
                glass = glass + gw_interior_ramp(e, uniforms) * interiorAlpha * (1.0 - glass);
            }
        }
    }

    // Inner light, over the glass, the glow, and the interior (GW-21).
    float lightAlpha = 0.0;
    if (uniforms.lightEmitterCount > 0u) {
        const float minHalf = max(min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y), 1e-3);
        const float w = saturate(depth / minHalf);
        const float fade = (1.0 - uniforms.lightCenterFade * smoothstep(0.3, 0.85, w)) * uniforms.lightBodyScale;
        const float pipeBand = uniforms.lightPipingWidth > 0.0 ? gw_light_falloff(depth / uniforms.lightPipingWidth) : 0.0;
        const float pipeScale = pipeBand * uniforms.lightPiping;
        if (fade > 0.0 || pipeScale > 0.0) {
            for (uint i = 0u; i < min(uniforms.lightEmitterCount, 4u); ++i) {
                constant GWLightEmitter &emitter = uniforms.lightEmitters[i];
                float pipe = 0.0;
                const float4 emitted = gw_light_emitter(q, depth, w, emitter, uniforms, pipe);
                const float body = emitted.w * emitter.intensity * fade;
                const float piping = pipe * pipeScale * emitter.intensity;
                const float alpha = 1.0 - (1.0 - body) * (1.0 - piping);
                if (alpha > 0.0) {
                    if (uniforms.lightComposite == GWLightCompositePaint) {
                        glass = mix(glass, emitted.xyz, min(alpha, gw_light_paint_cap));
                    } else {
                        glass = glass + emitted.xyz * alpha * (1.0 - glass);
                    }
                    lightAlpha = max(lightAlpha, alpha);
                }
            }
        }
    }

    // The light model (GW-23), over everything below, inside its band.
    float lightingAlpha = 0.0;
    if (gw_lighting && uniforms.lighting.finish != GWLightingFinishNone) {
        glass = gw_light_model(glass, q, depth, uniforms, lightingAlpha);
    }

    if (grounded && haloAlpha <= 0.0 && sparkAlpha <= 0.0) {
        // Composited over the target by premultiplied alpha (see above).
        float3 encodedGlass = gw_glass_encode_srgb(glass);
        const float3 caustic = (uniforms.grounding.flags & GWGroundingFlagCaustic) != 0u ? gw_grounding_caustic(pixel, uniforms) : float3(0.0);
        if (glowAlpha > 0.0 || interiorAlpha > 0.0 || lightAlpha > 0.0 || lightingAlpha > 0.0 || any(caustic > 0.0)) {
            const uint2 cell = uint2(pixel) & 3u;
            encodedGlass += ((gw_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0;
        }
        encodedGlass = saturate(encodedGlass + caustic);
        return float4(encodedGlass * coverage, coverage);
    }
    float3 encoded = gw_glass_encode_srgb(mix(outside, glass, coverage));
    if (glowAlpha > 0.0 || haloAlpha > 0.0 || interiorAlpha > 0.0 || sparkAlpha > 0.0 || lightAlpha > 0.0 || lightingAlpha > 0.0) {
        const uint2 cell = uint2(pixel) & 3u;
        encoded = saturate(encoded + ((gw_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
    }
    return float4(encoded, 1.0);
}
