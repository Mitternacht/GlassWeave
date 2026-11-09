#include <metal_stdlib>

using namespace metal;

// The laboratory's moving background. Every pixel is a pure function of the
// parameters below, so frame n of the deterministic clock always looks the
// same. The output target is `bgra8Unorm`; the shader writes sRGB-encoded
// values, which the frame hands to GlassWeave through a `bgra8Unorm_srgb`
// view of the same texture.
//
// Parameters (`constant float *`, one float each):
//   0  content time in seconds (from the deterministic clock)
//   1  pixels per point (display scale)
//   2  frame ID (exact up to 2^24)
//   3  1 to draw the frame-ID strip, 0 to omit it
//   4  frame-ID strip center, in pixels from the top
constant uint kLabTime = 0;
constant uint kLabScale = 1;
constant uint kLabFrameID = 2;
constant uint kLabShowsFrameID = 3;
constant uint kLabStripCenterY = 4;

struct LabBackgroundVertexOut {
    float4 position [[position]];
};

vertex LabBackgroundVertexOut lab_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    LabBackgroundVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment float4 lab_background_fragment(
    LabBackgroundVertexOut in [[stage_in]],
    constant float *parameters [[buffer(0)]])
{
    const float time = parameters[kLabTime];
    const float scale = parameters[kLabScale];
    // Work in points so the pattern looks the same at every display scale.
    const float2 p = in.position.xy / scale;

    // Diagonal stripes sliding left at 40 points per second, with thin dark
    // separators that make refraction at the panel rim easy to see.
    const float stripe = (p.x + p.y * 0.6 + time * 40.0) / 36.0;
    const float3 palette[3] = {
        float3(0.19, 0.69, 0.78),   // teal
        float3(0.36, 0.35, 0.84),   // indigo
        float3(1.00, 0.58, 0.00),   // orange
    };
    const int index = int(fmod(floor(stripe), 3.0) + 3.0) % 3;
    float3 color = palette[index];
    if (fract(stripe) < 0.07) {
        color = float3(0.12, 0.12, 0.16);
    }

    // A soft light disc on a slow Lissajous path.
    const float2 center = float2(180.0 + 120.0 * sin(time * 0.7), 260.0 + 140.0 * sin(time * 0.43 + 1.0));
    const float glow = 1.0 - smoothstep(40.0, 90.0, distance(p, center));
    color = mix(color, float3(1.0, 0.97, 0.88), glow * 0.75);

    // Frame-ID strip: 12-point cells; cell i shows bit (i mod 16) of the
    // frame ID, white for 1 and near-black for 0, with a one-point border.
    if (parameters[kLabShowsFrameID] > 0.5) {
        const float stripY = parameters[kLabStripCenterY] / scale;
        if (abs(p.y - stripY) <= 7.0) {
            const float cellX = p.x / 12.0;
            const uint bit = uint(floor(cellX)) % 16u;
            const uint frameID = uint(parameters[kLabFrameID]);
            const bool set = ((frameID >> bit) & 1u) != 0u;
            const bool border = fract(cellX) * 12.0 < 1.0 || abs(p.y - stripY) > 6.0;
            color = border ? float3(0.5) : (set ? float3(1.0) : float3(0.06));
        }
    }
    return float4(color, 1.0);
}
