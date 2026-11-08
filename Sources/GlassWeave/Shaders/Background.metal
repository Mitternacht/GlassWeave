#include <metal_stdlib>
#include "../../GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"

using namespace metal;

// The shader's view of the shared record must match the host layout asserted
// in GlassWeaveShaderTypes.c.
static_assert(sizeof(GWBackgroundUniforms) == 40, "GWBackgroundUniforms size");
static_assert(alignof(GWBackgroundUniforms) == 8, "GWBackgroundUniforms alignment");

struct GWBackgroundVertexOut {
    float4 position [[position]];
    /// Destination UV: origin top-left of the render target, y downward.
    float2 destinationUV;
};

/// One triangle that covers the whole render target. Clip space has y up;
/// destination UV has y down, so the top edge of the target is UV y = 0.
vertex GWBackgroundVertexOut gw_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    const float2 position = positions[vertexID];
    GWBackgroundVertexOut out;
    out.position = float4(position, 0.0, 1.0);
    out.destinationUV = float2(position.x * 0.5 + 0.5, 0.5 - position.y * 0.5);
    return out;
}

/// sRGB transfer function, linear light to encoded. The output target is a
/// non-sRGB `bgra8Unorm` texture (the Simulator cannot write sRGB textures),
/// so the shader encodes explicitly and stores the encoded value.
static float3 gw_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// Samples the source in linear light. The source texture is
/// `bgra8Unorm_srgb`, so the hardware decodes sRGB on read. The v0.1 source
/// convention is opaque: the source alpha channel is ignored.
fragment float4 gw_background_fragment(
    GWBackgroundVertexOut in [[stage_in]],
    constant GWBackgroundUniforms &uniforms [[buffer(GWBackgroundBindingIndexUniforms)]],
    texture2d<float, access::sample> source [[texture(GWBackgroundBindingIndexSourceTexture)]])
{
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    float2 uv = uniforms.uvFromDestinationX * in.destinationUV.x
              + uniforms.uvFromDestinationY * in.destinationUV.y
              + uniforms.uvOrigin;
    uv = clamp(uv, uniforms.sampleClampMin, uniforms.sampleClampMax);
    const float3 linearColor = source.sample(linearClamp, uv).rgb;
    return float4(gw_encode_srgb(linearColor), 1.0);
}
