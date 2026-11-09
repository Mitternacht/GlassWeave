#include <metal_stdlib>
#include "../../../Sources/GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"

using namespace metal;

/// Writes the shader's view of a GWBackgroundUniforms record, field by field,
/// plus the shader's size, alignment, and field offsets. The host compares
/// these with what it uploaded and with its own layout.
kernel void gw_test_background_uniforms_probe(
    constant GWBackgroundUniforms &record [[buffer(0)]],
    device float *values [[buffer(1)]],
    device uint *layout [[buffer(2)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid != 0) { return; }
    values[0] = record.uvFromDestinationX.x;
    values[1] = record.uvFromDestinationX.y;
    values[2] = record.uvFromDestinationY.x;
    values[3] = record.uvFromDestinationY.y;
    values[4] = record.uvOrigin.x;
    values[5] = record.uvOrigin.y;
    values[6] = record.sampleClampMin.x;
    values[7] = record.sampleClampMin.y;
    values[8] = record.sampleClampMax.x;
    values[9] = record.sampleClampMax.y;

    layout[0] = sizeof(GWBackgroundUniforms);
    layout[1] = alignof(GWBackgroundUniforms);
    layout[2] = __builtin_offsetof(GWBackgroundUniforms, uvFromDestinationX);
    layout[3] = __builtin_offsetof(GWBackgroundUniforms, uvFromDestinationY);
    layout[4] = __builtin_offsetof(GWBackgroundUniforms, uvOrigin);
    layout[5] = __builtin_offsetof(GWBackgroundUniforms, sampleClampMin);
    layout[6] = __builtin_offsetof(GWBackgroundUniforms, sampleClampMax);
}

/// Writes the shader's view of a GWGlassUniforms record, field by field
/// (including the nested background record, the glow, and the halo), plus its size,
/// alignment, and field offsets.
kernel void gw_test_glass_uniforms_probe(
    constant GWGlassUniforms &record [[buffer(0)]],
    device float *values [[buffer(1)]],
    device uint *layout [[buffer(2)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid != 0) { return; }
    values[0] = record.background.uvFromDestinationX.x;
    values[1] = record.background.uvFromDestinationX.y;
    values[2] = record.background.uvFromDestinationY.x;
    values[3] = record.background.uvFromDestinationY.y;
    values[4] = record.background.uvOrigin.x;
    values[5] = record.background.uvOrigin.y;
    values[6] = record.background.sampleClampMin.x;
    values[7] = record.background.sampleClampMin.y;
    values[8] = record.background.sampleClampMax.x;
    values[9] = record.background.sampleClampMax.y;
    values[10] = record.targetSize.x;
    values[11] = record.targetSize.y;
    values[12] = record.panelCenter.x;
    values[13] = record.panelCenter.y;
    values[14] = record.panelHalfSize.x;
    values[15] = record.panelHalfSize.y;
    values[16] = record.cornerRadius;
    values[17] = record.bezelWidth;
    values[18] = record.normalRadius;
    values[19] = record.maxDisplacement;
    values[20] = record.edgeHighlight;
    values[21] = record.tint.x;
    values[22] = record.tint.y;
    values[23] = record.tint.z;
    values[24] = record.tint.w;
    const float4 glowColors[4] = {record.glowColor0, record.glowColor1, record.glowColor2, record.glowColor3};
    for (uint i = 0; i < 4; ++i) {
        values[25 + 4 * i] = glowColors[i].x;
        values[26 + 4 * i] = glowColors[i].y;
        values[27 + 4 * i] = glowColors[i].z;
        values[28 + 4 * i] = glowColors[i].w;
    }
    values[41] = record.glowStopTurns.x;
    values[42] = record.glowStopTurns.y;
    values[43] = record.glowStopTurns.z;
    values[44] = record.glowStopTurns.w;
    values[45] = record.glowLightDirection.x;
    values[46] = record.glowLightDirection.y;
    values[47] = float(record.glowStopCount);
    values[48] = record.glowRimWidth;
    values[49] = record.glowRimFeather;
    values[50] = record.glowRimIntensity;
    values[51] = record.glowInnerRadius;
    values[52] = record.glowInnerIntensity;
    values[53] = record.glowCenterOpacity;
    values[54] = record.glowDirectionality;
    values[55] = record.glowNormalRadius;
    values[56] = record.glowHaloRadius;
    values[57] = record.glowHaloIntensity;

    layout[0] = sizeof(GWGlassUniforms);
    layout[1] = alignof(GWGlassUniforms);
    layout[2] = __builtin_offsetof(GWGlassUniforms, background);
    layout[3] = __builtin_offsetof(GWGlassUniforms, targetSize);
    layout[4] = __builtin_offsetof(GWGlassUniforms, panelCenter);
    layout[5] = __builtin_offsetof(GWGlassUniforms, panelHalfSize);
    layout[6] = __builtin_offsetof(GWGlassUniforms, cornerRadius);
    layout[7] = __builtin_offsetof(GWGlassUniforms, bezelWidth);
    layout[8] = __builtin_offsetof(GWGlassUniforms, normalRadius);
    layout[9] = __builtin_offsetof(GWGlassUniforms, maxDisplacement);
    layout[10] = __builtin_offsetof(GWGlassUniforms, edgeHighlight);
    layout[11] = __builtin_offsetof(GWGlassUniforms, tint);
    layout[12] = __builtin_offsetof(GWGlassUniforms, glowColor0);
    layout[13] = __builtin_offsetof(GWGlassUniforms, glowColor1);
    layout[14] = __builtin_offsetof(GWGlassUniforms, glowColor2);
    layout[15] = __builtin_offsetof(GWGlassUniforms, glowColor3);
    layout[16] = __builtin_offsetof(GWGlassUniforms, glowStopTurns);
    layout[17] = __builtin_offsetof(GWGlassUniforms, glowLightDirection);
    layout[18] = __builtin_offsetof(GWGlassUniforms, glowStopCount);
    layout[19] = __builtin_offsetof(GWGlassUniforms, glowRimWidth);
    layout[20] = __builtin_offsetof(GWGlassUniforms, glowRimFeather);
    layout[21] = __builtin_offsetof(GWGlassUniforms, glowRimIntensity);
    layout[22] = __builtin_offsetof(GWGlassUniforms, glowInnerRadius);
    layout[23] = __builtin_offsetof(GWGlassUniforms, glowInnerIntensity);
    layout[24] = __builtin_offsetof(GWGlassUniforms, glowCenterOpacity);
    layout[25] = __builtin_offsetof(GWGlassUniforms, glowDirectionality);
    layout[26] = __builtin_offsetof(GWGlassUniforms, glowNormalRadius);
    layout[27] = __builtin_offsetof(GWGlassUniforms, glowHaloRadius);
    layout[28] = __builtin_offsetof(GWGlassUniforms, glowHaloIntensity);
}
