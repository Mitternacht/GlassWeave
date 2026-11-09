// FROZEN COPY of the GW-05 glass panel shader (Sources/GlassWeave/Shaders/
// Glass.metal at the commit before glow was added), kept so tests can show
// that a panel without glow renders byte-identical output to the pre-glow
// shader. Do not edit it to follow later shader changes: its purpose is to
// stay the old reference. Only the names are changed (gw_baseline_ prefix)
// and the record types are defined here, frozen, with the GW-05 layout, so a
// change to the shared header cannot silently change this reference.

#include <metal_stdlib>

using namespace metal;

/// GWBackgroundUniforms as of GW-05: 40 bytes, alignment 8.
struct GWBaselineBackgroundUniforms {
    float2 uvFromDestinationX;
    float2 uvFromDestinationY;
    float2 uvOrigin;
    float2 sampleClampMin;
    float2 sampleClampMax;
};

/// GWGlassUniforms as of GW-05: 112 bytes, alignment 16. The current record
/// must keep this layout as its prefix.
struct GWBaselineGlassUniforms {
    GWBaselineBackgroundUniforms background;
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
};

static_assert(sizeof(GWBaselineGlassUniforms) == 112, "GW-05 GWGlassUniforms size");
static_assert(alignof(GWBaselineGlassUniforms) == 16, "GW-05 GWGlassUniforms alignment");

// The optical model below is mirrored on the CPU by `GlassPanelGeometry`
// (GlassPanelGeometry.swift); tests compare the two pixel by pixel. Change
// both together.

/// Light direction for edge illumination, in target pixels (y down): light
/// arrives from the upper left.
constant float2 gw_baseline_light_direction = float2(-0.70710678, -0.70710678);

struct GWBaselineGlassVertexOut {
    float4 position [[position]];
};

/// A quad covering the panel rectangle grown by one pixel on every side, so
/// the antialiased outline (half a pixel either side of the edge) is inside
/// it. Pixels outside the quad keep the background pass's output.
vertex GWBaselineGlassVertexOut gw_baseline_glass_vertex(
    uint vertexID [[vertex_id]],
    constant GWBaselineGlassUniforms &uniforms [[buffer(0)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + 1.0);
    // Target pixels (y down) to clip space (y up).
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWBaselineGlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// sRGB transfer function, linear light to encoded. Same as the background
/// pass: the output target is non-sRGB `bgra8Unorm` holding encoded values.
static float3 gw_baseline_glass_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// Samples the source, in linear light, at a position in target pixels.
/// Uses the background pass's mapping and clamps half a texel inside the
/// valid rectangle, so a displaced sample never reads outside it.
static float3 gw_baseline_glass_sample(
    float2 pixel, constant GWBaselineGlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    const float2 destinationUV = pixel / uniforms.targetSize;
    float2 uv = uniforms.background.uvFromDestinationX * destinationUV.x
              + uniforms.background.uvFromDestinationY * destinationUV.y
              + uniforms.background.uvOrigin;
    uv = clamp(uv, uniforms.background.sampleClampMin, uniforms.background.sampleClampMax);
    return source.sample(linearClamp, uv).rgb;
}

static float gw_baseline_sign(float x) {
    return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
}

/// Signed distance in pixels to a rounded rectangle centered at the origin:
/// negative inside, zero on the outline, positive outside.
static float gw_baseline_rounded_rect_distance(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

/// Outward unit normal of a rounded rectangle with corner radius `radius`:
/// radial in the corner regions, axis-aligned along the straight edges.
static float2 gw_baseline_rounded_rect_normal(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    if (d.x > 0.0 && d.y > 0.0) {
        return normalize(d) * float2(gw_baseline_sign(q.x), gw_baseline_sign(q.y));
    }
    if (d.x > d.y) {
        return float2(gw_baseline_sign(q.x), 0.0);
    }
    return float2(0.0, gw_baseline_sign(q.y));
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
/// the side facing the light. The outline is antialiased over one pixel by
/// mixing with the undisplaced background in linear light, so the edge has
/// no dark or bright fringe. Every pixel is written opaque.
fragment float4 gw_baseline_glass_fragment(
    GWBaselineGlassVertexOut in [[stage_in]],
    constant GWBaselineGlassUniforms &uniforms [[buffer(0)]],
    texture2d<float, access::sample> source [[texture(0)]])
{
    const float2 pixel = in.position.xy;
    const float2 q = pixel - uniforms.panelCenter;
    const float distance = gw_baseline_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    const float coverage = saturate(0.5 - distance);
    const float3 background = gw_baseline_glass_sample(pixel, uniforms, source);
    if (coverage <= 0.0) {
        return float4(gw_baseline_glass_encode_srgb(background), 1.0);
    }

    const float depth = max(-distance, 0.0);
    const float rim = uniforms.bezelWidth > 0.0 ? saturate(1.0 - depth / uniforms.bezelWidth) : 0.0;
    const float2 normal = gw_baseline_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.normalRadius);
    const float displacement = uniforms.maxDisplacement * rim * rim;
    float3 glass = gw_baseline_glass_sample(pixel - normal * displacement, uniforms, source);

    glass = mix(glass, uniforms.tint.xyz, uniforms.tint.w);
    const float facing = saturate(dot(normal, gw_baseline_light_direction));
    const float highlight = uniforms.edgeHighlight * rim * rim * rim * (0.4 + 0.6 * facing);
    glass = glass + (1.0 - glass) * highlight;

    return float4(gw_baseline_glass_encode_srgb(mix(background, glass, coverage)), 1.0);
}
