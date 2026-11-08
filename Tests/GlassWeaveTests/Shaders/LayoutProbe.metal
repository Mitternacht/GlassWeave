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
