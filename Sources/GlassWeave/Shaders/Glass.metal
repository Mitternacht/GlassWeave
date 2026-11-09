#include <metal_stdlib>
#include "../../GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"

using namespace metal;

// The shader's view of the shared record must match the host layout asserted
// in GlassWeaveShaderTypes.c.
static_assert(sizeof(GWGlassUniforms) == 336, "GWGlassUniforms size");
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
// times in 64 s, and through sparks that rise a whole number of times in 64 s.

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

/// The value at a 2D lattice point, periodic per axis, in [0, 1).
static float gw_lattice2(int2 cell, int2 period, uint seed) {
    const uint x = uint(gw_wrap(cell.x, period.x));
    const uint y = uint(gw_wrap(cell.y, period.y));
    return gw_unit(gw_hash(x * 0x8da6b343u + y * 0xd8163841u + seed));
}

/// The value at a 3D lattice point, periodic per axis, in [0, 1).
static float gw_lattice3(int3 cell, int3 period, uint seed) {
    const uint x = uint(gw_wrap(cell.x, period.x));
    const uint y = uint(gw_wrap(cell.y, period.y));
    const uint z = uint(gw_wrap(cell.z, period.z));
    return gw_unit(gw_hash(x * 0x8da6b343u + y * 0xd8163841u + z * 0xcb1ab31fu + seed));
}

/// 2D value noise with smoothstep interpolation, periodic with `period`
/// cells per axis, in [0, 1).
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

/// 3D value noise with smoothstep interpolation, periodic with `period`
/// cells per axis, in [0, 1).
static float gw_noise3(float3 p, int3 period, uint seed) {
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
static float gw_fbm3(float3 p, int3 period, uint seed) {
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

/// A smooth wave in [-1, 1] with period 1, without trigonometry.
static float gw_wave(float x) {
    const float t = abs(2.0 * (x - floor(x)) - 1.0);
    return 2.0 * t * t * (3.0 - 2.0 * t) - 1.0;
}

/// The length the energy and rays patterns scale with: half the panel's
/// shorter side, but at least 12 points, so a small or thin panel never gets
/// filaments or bands finer than the pixels that show them.
static float gw_interior_size(float2 halfSize) {
    return max(min(halfSize.x, halfSize.y), 12.0);
}

/// Energy: filaments where domain-warped noise crosses one half, with a
/// faint haze around them, turning once per 64 s around the center (twisted
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
    const int3 period = int3(4096, 4096, 32);
    const float wx = gw_fbm3(float3(p, z), period, seed);
    const float wy = gw_fbm3(float3(p.x + 19.0, p.y + 7.0, z), period, seed + 0x51ed270bu);
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
    const float twinkle = gw_noise2(float2(float(cell), z), int2(count, 32), seed + 0x3c6ef372u);
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
    const float flow = gw_noise2(float2(turn * 7.0, r / size * 2.5 - phase * 0.75), int2(7, 48), seed + 0xb5297a4du);
    const float resolved = smoothstep(1.5, 4.5, r * (2.0 * M_PI_F / 29.0));
    return saturate((0.55 * beams + rays) * (0.4 + 0.6 * flow)) * resolved;
}

/// Embers: flame tongues rising from the bottom edge, as heat 0...1: rising
/// turbulence (tall cells, 0.75 cells a second upward) shapes the top of a
/// flame whose height varies along the bottom edge; heat is highest at the
/// base and falls to 0 at a tongue's ragged top. `halfSize` in points.
static float gw_interior_flames(float2 u, float2 halfSize, float phase, uint seed) {
    const float above = halfSize.y - u.y;
    const float y = above / (1.3 * halfSize.y);
    const float n = gw_fbm3(float3(u.x / 9.0, above / 22.0 - phase * 0.75, phase * 0.5), int3(4096, 48, 32), seed);
    const float tongues = gw_noise2(float2(u.x / 16.0, phase * 0.25), int2(4096, 16), seed + 0x2545f491u);
    const float v = (1.0 - y / (0.45 + 0.9 * tongues)) + (n - 0.5) * 0.8;
    return smoothstep(0.0, 1.25, v);
}

/// Embers: twelve sparks rising from near the bottom edge to `exitHeight`
/// points above the top edge (each a whole number of times per 64 s),
/// swaying, each a bright core with a faint glow three times its radius,
/// fading out over the last 30 % of the rise; the brightest spark at a
/// point, 0...1.
static float gw_interior_sparks(float2 u, float2 halfSize, float exitHeight, float phase, uint seed) {
    const float start = 0.16 * halfSize.y;
    const float travel = 2.0 * halfSize.y + exitHeight - start;
    float spark = 0.0;
    for (uint i = 0u; i < 12u; ++i) {
        const uint h = gw_hash(seed + 0x9e3779b9u * (i + 1u));
        const float r0 = gw_unit(gw_hash(h + 1u));
        const float r1 = gw_unit(gw_hash(h + 2u));
        const float r2 = gw_unit(gw_hash(h + 3u));
        const float r3 = gw_unit(gw_hash(h + 4u));
        float life = r1 + phase * float(12u + h % 21u) / 64.0;
        life = life - floor(life);
        const float above = start + life * travel;
        const float sway = (2.0 + 4.0 * r2) * gw_wave(above / (16.0 + 14.0 * r2) + r3);
        const float2 center = float2((r0 * 2.0 - 1.0) * max(halfSize.x - 3.0, 0.0) + sway, halfSize.y - above);
        const float radius = 1.6 + 1.2 * r3;
        const float2 d = u - center;
        const float dd = dot(d, d) / (radius * radius);
        if (dd < 9.0) {
            const float core = dd < 1.0 ? (1.0 - dd) * (1.0 - dd) : 0.0;
            const float glow = (1.0 - dd / 9.0) * (1.0 - dd / 9.0);
            const float fade = smoothstep(0.0, 0.05, life) * (1.0 - smoothstep(0.7, 1.0, life));
            spark = max(spark, max(core, 0.45 * glow) * fade);
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
        return max(gw_interior_flames(u, halfSize, phase, seed),
                   gw_interior_sparks(u, halfSize, uniforms.glowHaloRadius / scale, phase, seed));
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
fragment float4 gw_glass_fragment(
    GWGlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]],
    texture2d<float, access::sample> source [[texture(GWGlassBindingIndexSourceTexture)]])
{
    const float2 pixel = in.position.xy;
    const float2 q = pixel - uniforms.panelCenter;
    const float distance = gw_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float coverage = saturate(0.5 - distance);
    const float3 background = gw_glass_sample(pixel, uniforms, source);

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
        const float scale = uniforms.interiorPixelsPerPoint;
        const float e = gw_interior_sparks(q / scale, uniforms.panelHalfSize / scale,
                                           uniforms.glowHaloRadius / scale, uniforms.interiorPhase, uniforms.interiorSeed);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        sparkAlpha = e * uniforms.interiorIntensity * (1.0 - t) * (1.0 - t);
        if (sparkAlpha > 0.0) {
            outside = outside + gw_interior_ramp(e, uniforms) * sparkAlpha * (1.0 - outside);
        }
    }
    if (coverage <= 0.0) {
        if (haloAlpha <= 0.0 && sparkAlpha <= 0.0) {
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
    float3 glass = gw_glass_sample(pixel - normal * displacement, uniforms, source);

    glass = mix(glass, uniforms.tint.xyz, uniforms.tint.w);
    const float facing = saturate(dot(normal, gw_light_direction));
    const float highlight = uniforms.edgeHighlight * rim * rim * rim * (0.4 + 0.6 * facing);
    glass = glass + (1.0 - glass) * highlight;

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

    float3 encoded = gw_glass_encode_srgb(mix(outside, glass, coverage));
    if (glowAlpha > 0.0 || haloAlpha > 0.0 || interiorAlpha > 0.0 || sparkAlpha > 0.0) {
        const uint2 cell = uint2(pixel) & 3u;
        encoded = saturate(encoded + ((gw_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
    }
    return float4(encoded, 1.0);
}
