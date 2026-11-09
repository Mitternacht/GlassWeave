#include <metal_stdlib>

using namespace metal;

// The Apple vs GlassWeave screen's backdrop (GW-29a). One procedural picture,
// a pure function of the position on the screen in points, so the two halves
// of the screen show the same pixels where they meet: the native half draws
// it into a plain Metal layer, the GlassWeave half into the frame the glass
// surface samples. The output target is `bgra8Unorm`; the shader writes
// sRGB-encoded values (the GlassWeave half hands them over through a
// `bgra8Unorm_srgb` view of the same texture).
//
// Parameters (`constant float4 *`), lengths in points, origin top-left:
//   0  x and y of this target's top-left corner on the screen, pixels per
//      point, appearance (0 light ... 1 dark)
//   1  screen width, screen height, unused, unused
struct VersusVertexOut {
    float4 position [[position]];
};

vertex VersusVertexOut versus_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    VersusVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

fragment float4 versus_background_fragment(
    VersusVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float4 general = parameters[0];
    const float scale = max(general.z, 1.0);
    const float dark = saturate(general.w);
    const float2 size = max(parameters[1].xy, float2(1.0));
    // Screen position in points.
    const float2 p = in.position.xy / scale + general.xy;
    const float aspect = size.x / size.y;
    const float2 uv = float2(p.x / size.x * aspect, p.y / size.y);

    // Five wide color fields over a calm base: warm at the top, cool at the
    // bottom, so tint, fill, rim and halo each have a hue to differ from.
    const float2 centers[5] = {
        float2(0.10 * aspect, 0.16), float2(0.92 * aspect, 0.10), float2(0.12 * aspect, 0.62),
        float2(0.95 * aspect, 0.55), float2(0.50 * aspect, 0.98)
    };
    const float3 colors[5] = {
        float3(1.00, 0.20, 0.52),   // magenta
        float3(1.00, 0.64, 0.06),   // amber
        float3(0.04, 0.78, 0.84),   // teal
        float3(0.45, 0.28, 0.96),   // violet
        float3(0.56, 0.92, 0.26)    // lime
    };
    const float radii[5] = { 0.62, 0.55, 0.60, 0.58, 0.45 };
    float3 accum = float3(0.0);
    float weight = 0.0;
    for (uint i = 0; i < 5; ++i) {
        const float d = distance(uv, centers[i]) / radii[i];
        const float w = exp(-3.2 * d * d);
        accum += colors[i] * w;
        weight += w;
    }
    const float3 field = accum / max(weight, 0.0001);
    const float strength = 1.0 - exp(-1.9 * weight);
    const float3 lightBase = float3(0.95, 0.95, 0.985);
    const float3 darkBase = float3(0.055, 0.060, 0.105);
    const float3 base = mix(lightBase, darkBase, dark);
    const float3 fieldAdjusted = mix(field, field * 0.74, dark);
    float3 color = mix(base, fieldAdjusted, strength * mix(0.80, 0.92, dark));

    // Two sets of fine detail that make bending and fills easy to see: a
    // dot lattice, and thin diagonal lines every 120 points.
    const float pitch = 14.0;
    const float2 cell = (fract(p / pitch) - 0.5) * pitch;
    const float dot = 1.0 - smoothstep(0.9, 1.7, length(cell));
    const float3 ink = mix(float3(0.10, 0.10, 0.30), float3(1.0), dark);
    color = mix(color, ink, dot * mix(0.28, 0.34, dark));

    const float s = (p.x + 0.55 * p.y) / 120.0;
    const float line = 1.0 - smoothstep(0.010, 0.018, 0.5 - abs(fract(s) - 0.5));
    color = mix(color, ink, line * 0.34);

    return float4(saturate(color), 1.0);
}
