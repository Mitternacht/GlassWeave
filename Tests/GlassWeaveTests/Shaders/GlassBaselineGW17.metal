// FROZEN COPY of the GW-17 glass panel shader (Sources/GlassWeave/Shaders/
// Glass.metal at the commit before the halo and pulse were added), kept so
// tests can show that a glow without a halo renders byte-identical output to
// the GW-17 shader. Do not edit it to follow later shader changes: its
// purpose is to stay the old reference. Only the names are changed (gw_gw17_
// prefix) and the record types are defined here, frozen, with the GW-17
// layout, so a change to the shared header cannot silently change this
// reference.

#include <metal_stdlib>

using namespace metal;

/// GWBackgroundUniforms as of GW-17: 40 bytes, alignment 8.
struct GWBaselineGW17BackgroundUniforms {
    float2 uvFromDestinationX;
    float2 uvFromDestinationY;
    float2 uvOrigin;
    float2 sampleClampMin;
    float2 sampleClampMax;
};

/// GWBaselineGW17GlassUniforms as of GW-17: 240 bytes, alignment 16. The current record
/// must keep this layout as its prefix.
struct GWBaselineGW17GlassUniforms {
    GWBaselineGW17BackgroundUniforms background;
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
};

static_assert(sizeof(GWBaselineGW17GlassUniforms) == 240, "GW-17 GWGlassUniforms size");
static_assert(alignof(GWBaselineGW17GlassUniforms) == 16, "GW-17 GWGlassUniforms alignment");

// The optical model below is mirrored on the CPU by `GlassPanelGeometry`
// (GlassPanelGeometry.swift); tests compare the two pixel by pixel. Change
// both together.

/// Light direction for edge illumination, in target pixels (y down): light
/// arrives from the upper left.
constant float2 gw_gw17_light_direction = float2(-0.70710678, -0.70710678);

struct GWBaselineGW17GlassVertexOut {
    float4 position [[position]];
};

/// A quad covering the panel rectangle grown by one pixel on every side, so
/// the antialiased outline (half a pixel either side of the edge) is inside
/// it. Pixels outside the quad keep the background pass's output.
vertex GWBaselineGW17GlassVertexOut gw_gw17_glass_vertex(
    uint vertexID [[vertex_id]],
    constant GWBaselineGW17GlassUniforms &uniforms [[buffer(0)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + 1.0);
    // Target pixels (y down) to clip space (y up).
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWBaselineGW17GlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// sRGB transfer function, linear light to encoded. Same as the background
/// pass: the output target is non-sRGB `bgra8Unorm` holding encoded values.
static float3 gw_gw17_glass_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// Samples the source, in linear light, at a position in target pixels.
/// Uses the background pass's mapping and clamps half a texel inside the
/// valid rectangle, so a displaced sample never reads outside it.
static float3 gw_gw17_glass_sample(
    float2 pixel, constant GWBaselineGW17GlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    const float2 destinationUV = pixel / uniforms.targetSize;
    float2 uv = uniforms.background.uvFromDestinationX * destinationUV.x
              + uniforms.background.uvFromDestinationY * destinationUV.y
              + uniforms.background.uvOrigin;
    uv = clamp(uv, uniforms.background.sampleClampMin, uniforms.background.sampleClampMax);
    return source.sample(linearClamp, uv).rgb;
}

static float gw_gw17_sign(float x) {
    return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
}

/// Signed distance in pixels to a rounded rectangle centered at the origin:
/// negative inside, zero on the outline, positive outside.
static float gw_gw17_rounded_rect_distance(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

/// Outward unit normal of a rounded rectangle with corner radius `radius`:
/// radial in the corner regions, axis-aligned along the straight edges.
static float2 gw_gw17_rounded_rect_normal(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    if (d.x > 0.0 && d.y > 0.0) {
        return normalize(d) * float2(gw_gw17_sign(q.x), gw_gw17_sign(q.y));
    }
    if (d.x > d.y) {
        return float2(gw_gw17_sign(q.x), 0.0);
    }
    return float2(0.0, gw_gw17_sign(q.y));
}

/// The 4 x 4 ordered-dither (Bayer) matrix, row by row.
constant float gw_gw17_bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

/// The glow color at an angle in turns (0 at the top, clockwise), in linear
/// light: linear interpolation between the neighbouring stops around the
/// circle, which wraps from the last stop back to the first. Stops are
/// ordered by angle; one stop is a solid color.
static float3 gw_gw17_glow_color(float turn, constant GWBaselineGW17GlassUniforms &uniforms) {
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

/// The glow layer's opacity and color at a pixel inside the panel
/// (docs/glow.md): a rim band, an inner glow falling off as (1 - t)^2, and
/// a center fill, all in one color, with the rim and inner glow lit from
/// one side. Returns the opacity in `w`.
static float4 gw_gw17_glow(float2 q, float depth, constant GWBaselineGW17GlassUniforms &uniforms) {
    // The angle around the center with the panel scaled to a square. The
    // precise atan2: on the axis through the center `-p.y` is a signed
    // zero, which the fast-math atan2 puts in the wrong half-plane.
    const float2 p = q / uniforms.panelHalfSize;
    float turn = 0.0;
    if (p.x != 0.0 || p.y != 0.0) {
        turn = precise::atan2(p.x, -p.y) * (0.5 / M_PI_F);
        turn = turn - floor(turn);
    }
    const float3 color = gw_gw17_glow_color(turn, uniforms);

    const float2 normal = gw_gw17_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.glowNormalRadius);
    const float facing = (1.0 + dot(normal, uniforms.glowLightDirection)) * 0.5;
    const float light = (1.0 - uniforms.glowDirectionality) + uniforms.glowDirectionality * facing * facing;

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
fragment float4 gw_gw17_glass_fragment(
    GWBaselineGW17GlassVertexOut in [[stage_in]],
    constant GWBaselineGW17GlassUniforms &uniforms [[buffer(0)]],
    texture2d<float, access::sample> source [[texture(0)]])
{
    const float2 pixel = in.position.xy;
    const float2 q = pixel - uniforms.panelCenter;
    const float distance = gw_gw17_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float coverage = saturate(0.5 - distance);
    const float3 background = gw_gw17_glass_sample(pixel, uniforms, source);
    if (coverage <= 0.0) {
        return float4(gw_gw17_glass_encode_srgb(background), 1.0);
    }

    const float depth = max(-distance, 0.0);
    const float rim = uniforms.bezelWidth > 0.0 ? saturate(1.0 - depth / uniforms.bezelWidth) : 0.0;
    const float2 normal = gw_gw17_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.normalRadius);
    const float displacement = uniforms.maxDisplacement * rim * rim;
    float3 glass = gw_gw17_glass_sample(pixel - normal * displacement, uniforms, source);

    glass = mix(glass, uniforms.tint.xyz, uniforms.tint.w);
    const float facing = saturate(dot(normal, gw_gw17_light_direction));
    const float highlight = uniforms.edgeHighlight * rim * rim * rim * (0.4 + 0.6 * facing);
    glass = glass + (1.0 - glass) * highlight;

    float glowAlpha = 0.0;
    if (uniforms.glowStopCount > 0u) {
        const float4 glow = gw_gw17_glow(q, depth, uniforms);
        glowAlpha = glow.w;
        glass = mix(glass, glow.xyz, glowAlpha);
    }

    float3 encoded = gw_gw17_glass_encode_srgb(mix(background, glass, coverage));
    if (glowAlpha > 0.0) {
        const uint2 cell = uint2(pixel) & 3u;
        encoded = saturate(encoded + ((gw_gw17_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
    }
    return float4(encoded, 1.0);
}
