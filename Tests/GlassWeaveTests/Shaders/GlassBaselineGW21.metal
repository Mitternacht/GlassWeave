// FROZEN COPY of the GW-21 glass panel shader (Sources/GlassWeave/Shaders/
// Glass.metal at the commit that added the inner light fields, GW-21), kept
// so tests can show that a panel without the thick-lens optics (GW-22)
// renders byte-identical output to the GW-21 shader, with or without light.
// Do not edit it to follow later shader changes: its purpose is to stay the
// old reference. Only the names are changed (gw_gw21_ prefix) and the record
// types are defined here, frozen, with the GW-21 layout, so a change to the
// shared header cannot silently change this reference.

#include <metal_stdlib>

using namespace metal;

/// GWBackgroundUniforms as of GW-21: 40 bytes, alignment 8.
struct GWBaselineGW21BackgroundUniforms {
    float2 uvFromDestinationX;
    float2 uvFromDestinationY;
    float2 uvOrigin;
    float2 sampleClampMin;
    float2 sampleClampMax;
};

/// One inner light emitter as of GW-21: 112 bytes, alignment 16.
struct GWBaselineGW21LightEmitter {
    float4 color0;
    float4 color1;
    float4 color2;
    float4 color3;
    float4 shape;
    float4 motion;
    uint kind;
    uint colorCount;
    float intensity;
    uint seed;
};

/// GWGlassUniforms as of GW-21: 1008 bytes, alignment 16. The current record
/// must keep this layout as its prefix.
struct GWBaselineGW21GlassUniforms {
    GWBaselineGW21BackgroundUniforms background;
    float2 targetSize;
    float2 panelCenter;
    float2 panelHalfSize;
    float cornerRadius;
    float bezelWidth;
    float normalRadius;
    float maxDisplacement;
    float edgeHighlight;
    float padding0;
    float padding1;
    float padding2;
    float4 tint;
    float4 glowColor0;
    float4 glowColor1;
    float4 glowColor2;
    float4 glowColor3;
    float4 glowStopTurns;
    float2 glowLightDirection;
    uint glowStopCount;
    float glowRimWidth;
    float glowRimFeather;
    float glowRimIntensity;
    float glowInnerRadius;
    float glowInnerIntensity;
    float glowCenterOpacity;
    float glowDirectionality;
    float glowNormalRadius;
    float padding3;
    float glowHaloRadius;
    float glowHaloIntensity;
    float padding4;
    float padding5;
    float4 interiorColor0;
    float4 interiorColor1;
    float4 interiorColor2;
    uint interiorEffect;
    uint interiorColorCount;
    uint interiorSeed;
    float interiorIntensity;
    float interiorPhase;
    float interiorCenterFade;
    float interiorPixelsPerPoint;
    float padding6;
    float4 interiorSparks[12];
    uint lightEmitterCount;
    uint lightComposite;
    float lightCenterFade;
    float lightPiping;
    float lightPipingWidth;
    float lightBodyScale;
    float padding7;
    float padding8;
    GWBaselineGW21LightEmitter lightEmitters[4];
};

/// The interior effect codes of GW-21.
enum GWBaselineGW21InteriorEffect : uint {
    kGW21InteriorEffectNone = 0,
    kGW21InteriorEffectEnergy = 1,
    kGW21InteriorEffectRays = 2,
    kGW21InteriorEffectEmbers = 3,
};

/// The light placements of GW-21.
enum GWBaselineGW21LightKind : uint {
    kGW21LightKindNone = 0,
    kGW21LightKindBand = 1,
    kGW21LightKindArc = 2,
    kGW21LightKindPoint = 3,
    kGW21LightKindField = 4,
};

/// The light composites of GW-21.
enum GWBaselineGW21LightComposite : uint {
    kGW21LightCompositeLight = 0,
    kGW21LightCompositePaint = 1,
};

static_assert(sizeof(GWBaselineGW21GlassUniforms) == 1008, "GW-21 GWGlassUniforms size");
static_assert(alignof(GWBaselineGW21GlassUniforms) == 16, "GW-21 GWGlassUniforms alignment");
static_assert(sizeof(GWBaselineGW21LightEmitter) == 112, "GW-21 GWLightEmitter size");
static_assert(alignof(GWBaselineGW21LightEmitter) == 16, "GW-21 GWLightEmitter alignment");

// The optical model below is mirrored on the CPU by `GlassPanelGeometry`
// (GlassPanelGeometry.swift); tests compare the two pixel by pixel. Change
// both together.

/// Light direction for edge illumination, in target pixels (y down): light
/// arrives from the upper left.
constant float2 gw_gw21_light_direction = float2(-0.70710678, -0.70710678);

struct GWBaselineGW21GlassVertexOut {
    float4 position [[position]];
};

/// A quad covering the panel rectangle grown by one pixel on every side, so
/// the antialiased outline (half a pixel either side of the edge) is inside
/// it, and by the halo radius when there is a halo (GW-18; zero otherwise,
/// which leaves the quad exactly as before). The rasterizer clips it to the
/// target, so a halo never reaches past the surface. Pixels outside the quad
/// keep the background pass's output.
vertex GWBaselineGW21GlassVertexOut gw_gw21_glass_vertex(
    uint vertexID [[vertex_id]],
    constant GWBaselineGW21GlassUniforms &uniforms [[buffer(0)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + 1.0 + uniforms.glowHaloRadius);
    // Target pixels (y down) to clip space (y up).
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWBaselineGW21GlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// sRGB transfer function, linear light to encoded. Same as the background
/// pass: the output target is non-sRGB `bgra8Unorm` holding encoded values.
static float3 gw_gw21_glass_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// Samples the source, in linear light, at a position in target pixels.
/// Uses the background pass's mapping and clamps half a texel inside the
/// valid rectangle, so a displaced sample never reads outside it.
static float3 gw_gw21_glass_sample(
    float2 pixel, constant GWBaselineGW21GlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    const float2 destinationUV = pixel / uniforms.targetSize;
    float2 uv = uniforms.background.uvFromDestinationX * destinationUV.x
              + uniforms.background.uvFromDestinationY * destinationUV.y
              + uniforms.background.uvOrigin;
    uv = clamp(uv, uniforms.background.sampleClampMin, uniforms.background.sampleClampMax);
    return source.sample(linearClamp, uv).rgb;
}

static float gw_gw21_sign(float x) {
    return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
}

/// Signed distance in pixels to a rounded rectangle centered at the origin:
/// negative inside, zero on the outline, positive outside.
static float gw_gw21_rounded_rect_distance(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

/// Outward unit normal of a rounded rectangle with corner radius `radius`:
/// radial in the corner regions, axis-aligned along the straight edges.
static float2 gw_gw21_rounded_rect_normal(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    if (d.x > 0.0 && d.y > 0.0) {
        return normalize(d) * float2(gw_gw21_sign(q.x), gw_gw21_sign(q.y));
    }
    if (d.x > d.y) {
        return float2(gw_gw21_sign(q.x), 0.0);
    }
    return float2(0.0, gw_gw21_sign(q.y));
}

/// The 4 x 4 ordered-dither (Bayer) matrix, row by row.
constant float gw_gw21_bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

/// The glow color at an angle in turns (0 at the top, clockwise), in linear
/// light: linear interpolation between the neighbouring stops around the
/// circle, which wraps from the last stop back to the first. Stops are
/// ordered by angle; one stop is a solid color.
static float3 gw_gw21_glow_color(float turn, constant GWBaselineGW21GlassUniforms &uniforms) {
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
static float4 gw_gw21_glow_shade(float2 q, constant GWBaselineGW21GlassUniforms &uniforms) {
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
    const float3 color = gw_gw21_glow_color(turn, uniforms);

    // The same normal field inside and outside the outline, so the light is
    // continuous across it.
    const float2 normal = gw_gw21_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.glowNormalRadius);
    const float facing = (1.0 + dot(normal, uniforms.glowLightDirection)) * 0.5;
    const float light = (1.0 - uniforms.glowDirectionality) + uniforms.glowDirectionality * facing * facing;
    return float4(color, light);
}

/// The glow layer's opacity and color at a pixel inside the panel
/// (docs/glow.md): a rim band, an inner glow falling off as (1 - t)^2, and
/// a center fill, all in one color, with the rim and inner glow lit from
/// one side. Returns the opacity in `w`.
static float4 gw_gw21_glow(float2 q, float depth, constant GWBaselineGW21GlassUniforms &uniforms) {
    const float4 shade = gw_gw21_glow_shade(q, uniforms);
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
static uint gw_gw21_hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

/// The top 24 bits of a hash as a float in [0, 1), exact in float.
static float gw_gw21_unit(uint h) {
    return float(h >> 8u) * (1.0 / 16777216.0);
}

/// A lattice coordinate wrapped into [0, period).
static int gw_gw21_wrap(int i, int period) {
    const int r = i % period;
    return r < 0 ? r + period : r;
}

/// A lattice coordinate wrapped into [0, period) for a power-of-two
/// period, by a mask (no integer division), or unchanged for period 0.
static int gw_gw21_wrap_pow2(int i, int period) {
    return period == 0 ? i : (i & (period - 1));
}

/// The value at a 3D lattice point, in [0, 1). The x axis does not wrap;
/// y and z wrap with the power-of-two periods in `period` (0 for none).
static float gw_gw21_lattice3(int3 cell, int2 period, uint seed) {
    const uint x = uint(cell.x);
    const uint y = uint(gw_gw21_wrap_pow2(cell.y, period.x));
    const uint z = uint(gw_gw21_wrap_pow2(cell.z, period.y));
    return gw_gw21_unit(gw_gw21_hash(x * 0x8da6b343u + y * 0xd8163841u + z * 0xcb1ab31fu + seed));
}

/// The value at a 2D lattice point, in [0, 1), periodic per axis with the
/// power-of-two periods in `period` (0 for none).
static float gw_gw21_lattice2(int2 cell, int2 period, uint seed) {
    const uint x = uint(gw_gw21_wrap_pow2(cell.x, period.x));
    const uint y = uint(gw_gw21_wrap_pow2(cell.y, period.y));
    return gw_gw21_unit(gw_gw21_hash(x * 0x8da6b343u + y * 0xd8163841u + seed));
}

/// 2D value noise with smoothstep interpolation, in [0, 1), periodic per
/// axis with the power-of-two periods in `period` (0 for none).
static float gw_gw21_noise2(float2 p, int2 period, uint seed) {
    const float2 base = floor(p);
    const int2 c = int2(base);
    const float2 f = p - base;
    const float2 s = f * f * (3.0 - 2.0 * f);
    const float v00 = gw_gw21_lattice2(c, period, seed);
    const float v10 = gw_gw21_lattice2(c + int2(1, 0), period, seed);
    const float v01 = gw_gw21_lattice2(c + int2(0, 1), period, seed);
    const float v11 = gw_gw21_lattice2(c + int2(1, 1), period, seed);
    const float x0 = v00 + (v10 - v00) * s.x;
    const float x1 = v01 + (v11 - v01) * s.x;
    return x0 + (x1 - x0) * s.y;
}

/// 3D value noise with smoothstep interpolation, in [0, 1), periodic in y
/// and z with the power-of-two periods in `period` (0 for none).
static float gw_gw21_noise3(float3 p, int2 period, uint seed) {
    const float3 base = floor(p);
    const int3 c = int3(base);
    const float3 f = p - base;
    const float3 s = f * f * (3.0 - 2.0 * f);
    const float v000 = gw_gw21_lattice3(c, period, seed);
    const float v100 = gw_gw21_lattice3(c + int3(1, 0, 0), period, seed);
    const float v010 = gw_gw21_lattice3(c + int3(0, 1, 0), period, seed);
    const float v110 = gw_gw21_lattice3(c + int3(1, 1, 0), period, seed);
    const float v001 = gw_gw21_lattice3(c + int3(0, 0, 1), period, seed);
    const float v101 = gw_gw21_lattice3(c + int3(1, 0, 1), period, seed);
    const float v011 = gw_gw21_lattice3(c + int3(0, 1, 1), period, seed);
    const float v111 = gw_gw21_lattice3(c + int3(1, 1, 1), period, seed);
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
static float gw_gw21_fbm3(float3 p, int2 period, uint seed) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (uint octave = 0u; octave < 3u; ++octave) {
        sum += amplitude * gw_gw21_noise3(p, period, seed + octave * 0x9e3779b9u);
        p *= 2.0;
        period *= 2;
        amplitude *= 0.5;
    }
    return sum / 0.875;
}

/// The length the energy and rays patterns scale with: half the panel's
/// shorter side, but at least 12 points, so a small or thin panel never gets
/// filaments or bands finer than the pixels that show them.
static float gw_gw21_interior_size(float2 halfSize) {
    return max(min(halfSize.x, halfSize.y), 12.0);
}

/// Energy: filaments where noise, warped by two more noise fields, crosses
/// one half, with a faint haze around them, turning once per 64 s around the center (twisted
/// by up to 0.9 rad out to `size` from it) and evolving with time, brighter
/// toward the rim. `u` in points from the center (y down), `size` from
/// `gw_gw21_interior_size`, `w` the depth fraction (0 at the outline).
static float gw_gw21_interior_energy(float2 u, float size, float w, float phase, uint seed) {
    const float2 p0 = u / size;
    const float angle = (2.0 * M_PI_F) * (phase / 64.0) + 0.9 * min(length(p0), 1.0);
    const float c = precise::cos(angle);
    const float s = precise::sin(angle);
    const float2 p = float2(c * p0.x - s * p0.y, s * p0.x + c * p0.y) * 2.2;
    const float z = phase * 0.5;
    const int2 period = int2(0, 32);
    const float wx = gw_gw21_noise3(float3(p, z), period, seed);
    const float wy = gw_gw21_noise3(float3(p.x + 19.0, p.y + 7.0, z), period, seed + 0x51ed270bu);
    const float2 warped = p + 1.4 * (float2(wx, wy) - 0.5);
    const float n = gw_gw21_fbm3(float3(warped, z + 11.0), period, seed + 0xa3c59ac3u);
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
static float gw_gw21_ray_layer(float turn, float r, int count, float minWidth, float maxWidth, float z, uint seed) {
    const float x = turn * float(count);
    const float base = floor(x);
    const int cell = gw_gw21_wrap(int(base), count);
    const float f = x - base;
    const uint h = gw_gw21_hash(uint(cell) * 0x8da6b343u + seed);
    const float center = 0.3 + 0.4 * gw_gw21_unit(gw_gw21_hash(h + 1u));
    const float width = minWidth + (maxWidth - minWidth) * gw_gw21_unit(gw_gw21_hash(h + 2u));
    const float cellPoints = max(r * (2.0 * M_PI_F) / float(count), 0.001);
    const float drawn = min(max(width, 0.75 / cellPoints), 0.28);
    const float profile = 1.0 - smoothstep(0.0, drawn, abs(f - center));
    // The ray's own brightness over time: 1D value noise in z, period 32.
    const float zBase = floor(z);
    const int zCell = int(zBase);
    const float zf = z - zBase;
    const uint key = uint(cell) * 0x8da6b343u + seed + 0x3c6ef372u;
    const float t0 = gw_gw21_unit(gw_gw21_hash(key + uint(zCell & 31) * 0xd8163841u));
    const float t1 = gw_gw21_unit(gw_gw21_hash(key + uint((zCell + 1) & 31) * 0xd8163841u));
    const float twinkle = t0 + (t1 - t0) * (zf * zf * (3.0 - 2.0 * zf));
    return profile * profile * (width / drawn) * (0.35 + 0.65 * twinkle);
}

/// Rays: 13 soft beams and 29 thin rays per turn from the center, turning
/// in opposite directions (two turns and one turn per 64 s), twinkling, with
/// brightness flowing outward; they fade in from the center where the thin
/// rays' spacing reaches 1.5 points.
static float gw_gw21_interior_rays(float2 u, float size, float phase, uint seed) {
    const float r = length(u);
    if (r <= 0.0) {
        return 0.0;
    }
    float turn = precise::atan2(u.x, -u.y) * (0.5 / M_PI_F);
    turn = turn - floor(turn);
    const float z = phase * 0.5;
    const float beams = gw_gw21_ray_layer(turn + 2.0 * phase / 64.0, r, 13, 0.1, 0.28, z, seed);
    const float rays = gw_gw21_ray_layer(turn - phase / 64.0, r, 29, 0.03, 0.09, z + 7.0, seed + 0x68e31da4u);
    const float flow = gw_gw21_noise2(float2(turn * 8.0, r / size * 2.5 - phase * 0.5), int2(8, 32), seed + 0xb5297a4du);
    const float resolved = smoothstep(1.5, 4.5, r * (2.0 * M_PI_F / 29.0));
    return saturate((0.55 * beams + rays) * (0.4 + 0.6 * flow)) * resolved;
}

/// Embers: flame tongues rising from the bottom edge, as heat 0...1: rising
/// turbulence (tall cells, 0.5 cells a second upward) shapes the top of a
/// flame whose height varies along the bottom edge; heat is highest at the
/// base and falls to 0 at a tongue's ragged top. Above 1.4 times a tongue's
/// height the turbulence cannot lift the flame, so it is not evaluated
/// there (the heat is exactly 0 either way). `halfSize` in points.
static float gw_gw21_interior_flames(float2 u, float2 halfSize, float phase, uint seed) {
    const float above = halfSize.y - u.y;
    const float y = above / (1.3 * halfSize.y);
    const float top = 0.45 + 0.9 * gw_gw21_noise2(float2(u.x / 16.0, phase * 0.25), int2(0, 16), seed + 0x2545f491u);
    if (y >= 1.4 * top) {
        return 0.0;
    }
    const float n = gw_gw21_fbm3(float3(u.x / 9.0, above / 30.0 - phase * 0.5, phase * 0.5), int2(32, 32), seed);
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
static float gw_gw21_interior_sparks(float2 u, constant GWBaselineGW21GlassUniforms &uniforms) {
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
static float gw_gw21_interior_value(float2 q, float w, constant GWBaselineGW21GlassUniforms &uniforms) {
    const float scale = uniforms.interiorPixelsPerPoint;
    const float2 u = q / scale;
    const float2 halfSize = uniforms.panelHalfSize / scale;
    const float phase = uniforms.interiorPhase;
    const uint seed = uniforms.interiorSeed;
    switch (uniforms.interiorEffect) {
    case kGW21InteriorEffectEnergy:
        return gw_gw21_interior_energy(u, gw_gw21_interior_size(halfSize), w, phase, seed);
    case kGW21InteriorEffectRays:
        return gw_gw21_interior_rays(u, gw_gw21_interior_size(halfSize), phase, seed);
    case kGW21InteriorEffectEmbers:
        return max(gw_gw21_interior_flames(u, halfSize, phase, seed), gw_gw21_interior_sparks(u, uniforms));
    default:
        return 0.0;
    }
}

/// The interior's ramp color at value `e`, in linear light: one color, or
/// two or three spread evenly from 0 to 1.
static float3 gw_gw21_interior_ramp(float e, constant GWBaselineGW21GlassUniforms &uniforms) {
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
constant float gw_gw21_light_paint_cap = 0.85;

/// The emitter's palette at position `x`, in linear light. The palette
/// folds back and forth (period 2: stop 0 to the last stop and back), so
/// shifting `x` by 2 is the identity and a flowing palette never jumps. Stops
/// are spread evenly over 0 to 1 and interpolate linearly.
static float3 gw_gw21_light_palette(float x, constant GWBaselineGW21LightEmitter &emitter) {
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
static float gw_gw21_light_falloff(float x) {
    const float t = 1.0 - saturate(x);
    return t * t;
}

/// A pooled profile, 1 at `x` 0 and exactly 0 from `x` 1 on, falling slowly
/// near 0 and near 1: 1 - smoothstep(0, 1, x). Never rises with `x`. The
/// bands, arcs, and fields use it for their body light.
static float gw_gw21_light_pool(float x) {
    return 1.0 - smoothstep(0.0, 1.0, x);
}

/// One emitter's color (`xyz`) and body light (`w`, before intensity and
/// center fade) at pixel offset `q` from the panel's center, `depth` pixels
/// inside the outline and `w` of the way to the deepest point. `pipe`
/// receives the weight of its piping, 0...1: the falloff with the Euclidean
/// distance, in pixels, from the emitter's source.
static float4 gw_gw21_light_emitter(
    float2 q, float depth, float w, constant GWBaselineGW21LightEmitter &emitter,
    constant GWBaselineGW21GlassUniforms &uniforms, thread float &pipe)
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
    case kGW21LightKindBand: {
        // The half-plane toward the lit edge: `edge` is the unit-space
        // distance from it, never negative (the corners of a rectangle lie
        // past it and get the full light).
        const float2 direction = shape.xy;
        const float edge = max(1.0 - dot(u, direction), 0.0);
        const float reach = max(shape.z * (1.0 + 0.3 * motion.z), 1e-4);
        body = gw_gw21_light_pool(edge / reach);
        const float tau = saturate(0.5 + 0.5 * dot(u, float2(direction.y, -direction.x)));
        color = gw_gw21_light_palette(tau + motion.x, emitter);
        if (pipeReach > 0.0) {
            pipe = gw_gw21_light_falloff(edge * shape.w / pipeReach);
        }
        break;
    }
    case kGW21LightKindArc: {
        float turn = 0.0;
        if (u.x != 0.0 || u.y != 0.0) {
            turn = precise::atan2(u.x, -u.y) * (0.5 / M_PI_F);
            turn = turn - floor(turn);
        }
        float delta = turn - (shape.x + 0.12 * motion.y);
        delta = delta - round(delta);
        const float halfSpan = max(shape.y, 1e-4);
        const float along = 1.0 - smoothstep(0.4 * halfSpan, halfSpan, abs(delta));
        body = along * gw_gw21_light_pool(depth / max(shape.z, 1e-4));
        color = gw_gw21_light_palette(saturate(0.5 + delta / (2.0 * halfSpan)) + motion.x, emitter);
        if (pipeReach > 0.0) {
            // Euclidean distance to the arc: the depth, and the way along
            // the outline past the arc's end.
            const float beyond = max(abs(delta) - halfSpan, 0.0) * (2.0 * M_PI_F) * length(q);
            pipe = gw_gw21_light_falloff(length(float2(depth, beyond)) / pipeReach);
        }
        break;
    }
    case kGW21LightKindPoint: {
        const float2 center = (shape.xy + motion.yz * 0.25) * halfSize;
        const float2 offset = q - center;
        const float2 radii = float2(shape.w, 1.0) * max(shape.z, 1e-3);
        const float2 scaled = offset / radii;
        const float d2 = dot(scaled, scaled);
        const float t = 1.0 - saturate(d2);
        body = t * t;
        color = gw_gw21_light_palette(sqrt(min(d2, 1.0)) + motion.x, emitter);
        if (pipeReach > 0.0) {
            pipe = gw_gw21_light_falloff(length(offset) / pipeReach);
        }
        break;
    }
    case kGW21LightKindField: {
        // Four corner colors, bilinear, warped by one octave of noise that
        // moves around a loop (`shape.yz`) and wanders with the drift.
        const float2 uv = saturate(u * 0.5 + 0.5);
        const float2 noiseAt = uv * 2.5 + shape.yz + motion.yz * 3.0;
        const float2 noise = float2(
            gw_gw21_noise2(noiseAt, int2(0), emitter.seed),
            gw_gw21_noise2(noiseAt + float2(17.3, 5.1), int2(0), emitter.seed + 0x51ed270bu));
        const float2 warped = saturate(uv + shape.x * 0.9 * (noise - 0.5));
        const float3 top = mix(emitter.color0.xyz, emitter.color1.xyz, warped.x);
        const float3 bottom = mix(emitter.color2.xyz, emitter.color3.xyz, warped.x);
        color = mix(top, bottom, warped.y);
        body = gw_gw21_light_pool(w);
        pipe = 1.0;
        break;
    }
    default:
        break;
    }
    return float4(color, body);
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
fragment float4 gw_gw21_glass_fragment(
    GWBaselineGW21GlassVertexOut in [[stage_in]],
    constant GWBaselineGW21GlassUniforms &uniforms [[buffer(0)]],
    texture2d<float, access::sample> source [[texture(0)]])
{
    const float2 pixel = in.position.xy;
    const float2 q = pixel - uniforms.panelCenter;
    const float distance = gw_gw21_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float coverage = saturate(0.5 - distance);
    const float3 background = gw_gw21_glass_sample(pixel, uniforms, source);

    // The halo, for the part of the pixel outside the outline.
    float haloAlpha = 0.0;
    float3 outside = background;
    if (uniforms.glowHaloRadius > 0.0 && coverage < 1.0 && distance < uniforms.glowHaloRadius) {
        const float4 shade = gw_gw21_glow_shade(q, uniforms);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        haloAlpha = uniforms.glowHaloIntensity * (1.0 - t) * (1.0 - t) * shade.w;
        outside = background + shade.xyz * haloAlpha * (1.0 - background);
    }
    // Embers' sparks that rise past the top half of the outline, within the
    // halo, are light over the haloed background (GW-19).
    float sparkAlpha = 0.0;
    if (uniforms.interiorEffect == kGW21InteriorEffectEmbers && uniforms.glowHaloRadius > 0.0
        && coverage < 1.0 && q.y < 0.0 && distance < uniforms.glowHaloRadius) {
        const float e = gw_gw21_interior_sparks(q / uniforms.interiorPixelsPerPoint, uniforms);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        sparkAlpha = e * uniforms.interiorIntensity * (1.0 - t) * (1.0 - t);
        if (sparkAlpha > 0.0) {
            outside = outside + gw_gw21_interior_ramp(e, uniforms) * sparkAlpha * (1.0 - outside);
        }
    }
    if (coverage <= 0.0) {
        if (haloAlpha <= 0.0 && sparkAlpha <= 0.0) {
            return float4(gw_gw21_glass_encode_srgb(background), 1.0);
        }
        const uint2 cell = uint2(pixel) & 3u;
        const float3 encoded = saturate(gw_gw21_glass_encode_srgb(outside) + ((gw_gw21_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
        return float4(encoded, 1.0);
    }

    const float depth = max(-distance, 0.0);
    const float rim = uniforms.bezelWidth > 0.0 ? saturate(1.0 - depth / uniforms.bezelWidth) : 0.0;
    const float2 normal = gw_gw21_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.normalRadius);
    const float displacement = uniforms.maxDisplacement * rim * rim;
    float3 glass = gw_gw21_glass_sample(pixel - normal * displacement, uniforms, source);

    glass = mix(glass, uniforms.tint.xyz, uniforms.tint.w);
    const float facing = saturate(dot(normal, gw_gw21_light_direction));
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
        const float4 glow = gw_gw21_glow(q, depth, uniforms);
        glowAlpha = glow.w;
        glass = mix(glass, glow.xyz, glowAlpha);
    }

    // The interior, light screened over the glowing glass (GW-19).
    float interiorAlpha = 0.0;
    if (uniforms.interiorEffect != kGW21InteriorEffectNone) {
        const float w = saturate(depth / min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y));
        const float fade = 1.0 - uniforms.interiorCenterFade * smoothstep(0.3, 0.85, w);
        if (fade > 0.0) {
            const float e = gw_gw21_interior_value(q, w, uniforms);
            interiorAlpha = e * uniforms.interiorIntensity * fade;
            if (interiorAlpha > 0.0) {
                glass = glass + gw_gw21_interior_ramp(e, uniforms) * interiorAlpha * (1.0 - glass);
            }
        }
    }

    // Inner light, over the glass, the glow, and the interior (GW-21).
    float lightAlpha = 0.0;
    if (uniforms.lightEmitterCount > 0u) {
        const float minHalf = max(min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y), 1e-3);
        const float w = saturate(depth / minHalf);
        const float fade = (1.0 - uniforms.lightCenterFade * smoothstep(0.3, 0.85, w)) * uniforms.lightBodyScale;
        const float pipeBand = uniforms.lightPipingWidth > 0.0 ? gw_gw21_light_falloff(depth / uniforms.lightPipingWidth) : 0.0;
        const float pipeScale = pipeBand * uniforms.lightPiping;
        if (fade > 0.0 || pipeScale > 0.0) {
            for (uint i = 0u; i < min(uniforms.lightEmitterCount, 4u); ++i) {
                constant GWBaselineGW21LightEmitter &emitter = uniforms.lightEmitters[i];
                float pipe = 0.0;
                const float4 emitted = gw_gw21_light_emitter(q, depth, w, emitter, uniforms, pipe);
                const float body = emitted.w * emitter.intensity * fade;
                const float piping = pipe * pipeScale * emitter.intensity;
                const float alpha = 1.0 - (1.0 - body) * (1.0 - piping);
                if (alpha > 0.0) {
                    if (uniforms.lightComposite == kGW21LightCompositePaint) {
                        glass = mix(glass, emitted.xyz, min(alpha, gw_gw21_light_paint_cap));
                    } else {
                        glass = glass + emitted.xyz * alpha * (1.0 - glass);
                    }
                    lightAlpha = max(lightAlpha, alpha);
                }
            }
        }
    }

    float3 encoded = gw_gw21_glass_encode_srgb(mix(outside, glass, coverage));
    if (glowAlpha > 0.0 || haloAlpha > 0.0 || interiorAlpha > 0.0 || sparkAlpha > 0.0 || lightAlpha > 0.0) {
        const uint2 cell = uint2(pixel) & 3u;
        encoded = saturate(encoded + ((gw_gw21_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
    }
    return float4(encoded, 1.0);
}
