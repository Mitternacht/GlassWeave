#include <metal_stdlib>
#include "../../GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"
#include "GlassFrost.h"

using namespace metal;

// The shader's view of the shared records must match the host layout
// asserted in GlassWeaveFrostTypes.c.
static_assert(sizeof(GWFrostPyramidLayout) == 24, "GWFrostPyramidLayout size");
static_assert(sizeof(GWFrostBuildUniforms) == 80, "GWFrostBuildUniforms size");
static_assert(sizeof(GWFrostProfileUniforms) == 72, "GWFrostProfileUniforms size");
static_assert(sizeof(GWFrostProbePoint) == 16, "GWFrostProbePoint size");
static_assert(sizeof(GWFrostProbeUniforms) == 32, "GWFrostProbeUniforms size");
static_assert(sizeof(GWFrostAtlasUniforms) == 96, "GWFrostAtlasUniforms size");

/// The 13-tap downsample (a, b, c / j, k / d, e, f / l, m / g, h, i of the
/// well-known 13-tap scheme): x and y offsets in input texels, and the tap's
/// weight. The weights sum to one.
constant float3 gw_frost_taps[13] = {
    float3(0.0, 0.0, 0.125),
    float3(-1.0, 1.0, 0.125), float3(1.0, 1.0, 0.125), float3(-1.0, -1.0, 0.125), float3(1.0, -1.0, 0.125),
    float3(-2.0, 2.0, 0.03125), float3(0.0, 2.0, 0.0625), float3(2.0, 2.0, 0.03125),
    float3(-2.0, 0.0, 0.0625), float3(2.0, 0.0, 0.0625),
    float3(-2.0, -2.0, 0.03125), float3(0.0, -2.0, 0.0625), float3(2.0, -2.0, 0.03125),
};

/// Level 0: half resolution in destination space, read from the source frame
/// through the background pass's mapping. A tap position in destination
/// pixels goes to destination UV, then to texture UV, and is clamped half a
/// texel inside the valid rectangle, so no tap reads outside it.
kernel void gw_frost_downsample_source(
    constant GWFrostBuildUniforms &u [[buffer(GWFrostBindingIndexUniforms)]],
    texture2d<float, access::sample> source [[texture(GWFrostBindingIndexInput)]],
    texture2d<float, access::write> output [[texture(GWFrostBindingIndexOutput)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outputSize.x || gid.y >= u.outputSize.y) { return; }
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    // The texel covers outputSpacing destination pixels; taps are one half of
    // that apart (the size of the input texel the scheme assumes).
    const float2 center = u.regionOrigin + (float2(gid) + 0.5) * u.outputSpacing;
    const float step = u.outputSpacing * 0.5;
    float3 sum = float3(0.0);
    for (int tap = 0; tap < 13; ++tap) {
        const float2 position = center + gw_frost_taps[tap].xy * step;
        const float2 destinationUV = position / u.targetSize;
        float2 uv = u.uvFromDestinationX * destinationUV.x
                  + u.uvFromDestinationY * destinationUV.y
                  + u.uvOrigin;
        uv = clamp(uv, u.sampleClampMin, u.sampleClampMax);
        sum += gw_frost_taps[tap].z * source.sample(linearClamp, uv).rgb;
    }
    output.write(float4(sum, 1.0), gid);
}

/// Levels 1 and up: the 13-tap downsample of the level before, which covers
/// the same rectangle with twice the texel size.
kernel void gw_frost_downsample_level(
    constant GWFrostBuildUniforms &u [[buffer(GWFrostBindingIndexUniforms)]],
    texture2d<float, access::sample> input [[texture(GWFrostBindingIndexInput)]],
    texture2d<float, access::write> output [[texture(GWFrostBindingIndexOutput)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= u.outputSize.x || gid.y >= u.outputSize.y) { return; }
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    const float2 uv = (float2(gid) + 0.5) / float2(u.outputSize);
    float3 sum = float3(0.0);
    for (int tap = 0; tap < 13; ++tap) {
        sum += gw_frost_taps[tap].z * input.sample(linearClamp, uv + gw_frost_taps[tap].xy * u.inputTexelSize).rgb;
    }
    output.write(float4(sum, 1.0), gid);
}

/// Reads the pyramid at points and levels of detail, for tests and tools.
kernel void gw_frost_probe(
    constant GWFrostProbeUniforms &u [[buffer(GWFrostBindingIndexUniforms)]],
    constant GWFrostProbePoint *points [[buffer(GWFrostBindingIndexPoints)]],
    device float4 *results [[buffer(GWFrostBindingIndexResults)]],
    texture2d<float, access::sample> pyramid [[texture(GWFrostBindingIndexInput)]],
    uint index [[thread_position_in_grid]])
{
    if (index >= u.pointCount) { return; }
    results[index] = float4(gw_frost_sample(pyramid, u.layout, points[index].position, points[index].lod), 1.0);
}

static inline float3 gw_frost_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// The laboratory's view of the pyramid: one tile per level (the whole
/// pyramid rectangle at that level, magnified with the cubic B-spline), then
/// one tile per frost profile showing its blur radius over a capsule (bright
/// is more blur). Writes encoded sRGB into a `bgra8Unorm` texture.
kernel void gw_frost_atlas(
    constant GWFrostAtlasUniforms &u [[buffer(GWFrostBindingIndexUniforms)]],
    texture2d<float, access::sample> pyramid [[texture(GWFrostBindingIndexInput)]],
    texture2d<float, access::write> output [[texture(GWFrostBindingIndexOutput)]],
    uint2 gid [[thread_position_in_grid]])
{
    const uint tiles = u.levelTiles + u.profileTiles;
    const uint rows = (tiles + u.columns - 1) / u.columns;
    if (gid.x >= u.tileSize.x * u.columns || gid.y >= u.tileSize.y * rows) { return; }
    const uint tile = (gid.y / u.tileSize.y) * u.columns + gid.x / u.tileSize.x;
    if (tile >= tiles) {
        output.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }
    const float2 local = (float2(gid.x % u.tileSize.x, gid.y % u.tileSize.y) + 0.5) / float2(u.tileSize);
    float3 color;
    if (tile < u.levelTiles) {
        const float2 position = u.profile.layout.regionOrigin + local * u.profile.layout.coverSize;
        color = gw_frost_sample(pyramid, u.profile.layout, position, float(tile));
    } else {
        GWFrostProfileUniforms frost = u.profile;
        frost.profile = tile - u.levelTiles;
        const float2 pixel = local * float2(u.tileSize);
        const float depth = gw_frost_depth(pixel - frost.panelCenter, frost.panelHalfSize, frost.cornerRadius);
        const float coverage = saturate(depth + 0.5);
        const float blur = saturate(gw_frost_sigma(frost, pixel) / max(frost.sigma, 1.0e-4));
        color = mix(float3(0.02), float3(blur), coverage);
        // Linear light: lift the map so mid values read as mid grays.
        color = pow(color, float3(2.2));
    }
    output.write(float4(gw_frost_encode_srgb(color), 1.0), gid);
}
