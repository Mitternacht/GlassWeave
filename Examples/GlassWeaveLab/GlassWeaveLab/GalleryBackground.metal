#include <metal_stdlib>

using namespace metal;

// The glow gallery's calm background (GW-20). Every pixel is a pure function
// of the parameters below, which the gallery derives from its layout, its
// theme, and its selection, so the background changes only when they do.
// The output target is `bgra8Unorm`; the shader writes sRGB-encoded values,
// which the frame hands to GlassWeave through a `bgra8Unorm_srgb` view of the
// same texture.
//
// Parameters (`constant float4 *`), lengths in points, origin top-left:
//   0  pixels per point, theme (0 light ... 1 dark), width, height
//   1  theme toggle track rectangle (x, y, width, height)
//   2  elements stage rectangle
//   3  orb bar rectangle
//   4  capsule count (0...3), reflections on (1) or off (0), unused, unused
//   5...7   capsule rectangles
//   8...10  capsule edge colors (sRGB, 0...1) and reflection strength (0...1)
constant uint kGalleryGeneral = 0;
constant uint kGalleryTrack = 1;
constant uint kGalleryStage = 2;
constant uint kGalleryBar = 3;
constant uint kGalleryCounts = 4;
constant uint kGalleryCapsules = 5;
constant uint kGalleryCapsuleColors = 8;

struct GalleryVertexOut {
    float4 position [[position]];
};

vertex GalleryVertexOut gallery_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    GalleryVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

/// Signed distance to a rounded rectangle given as (x, y, width, height):
/// negative inside.
static float gallery_rounded_rect(float2 p, float4 rect, float radius) {
    const float2 halfSize = rect.zw * 0.5;
    const float2 center = rect.xy + halfSize;
    const float r = min(radius, min(halfSize.x, halfSize.y));
    const float2 d = abs(p - center) - (halfSize - r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

/// Coverage of a shape at signed distance `d`, antialiased over one pixel.
static float gallery_fill(float d, float pixel) {
    return saturate(0.5 - d / pixel);
}

/// A cheap hash for star positions.
static float gallery_hash(float2 cell) {
    return fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
}

fragment float4 gallery_background_fragment(
    GalleryVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float4 general = parameters[kGalleryGeneral];
    const float scale = general.x;
    const float theme = saturate(general.y);
    const float2 size = general.zw;
    const float2 p = in.position.xy / scale;
    const float pixel = 1.0 / scale;

    // Page: a soft vertical gradient with three wide, blurred color fields.
    const float v = saturate(p.y / max(size.y, 1.0));
    const float3 lightPage = mix(float3(0.975, 0.955, 0.925), float3(0.915, 0.930, 0.975), v);
    const float3 darkPage = mix(float3(0.060, 0.068, 0.135), float3(0.018, 0.020, 0.050), v);
    float3 color = mix(lightPage, darkPage, theme);
    const float2 fields[3] = { float2(0.10, 0.10), float2(0.98, 0.46), float2(0.22, 0.92) };
    const float3 lightFields[3] = { float3(1.00, 0.82, 0.66), float3(0.80, 0.84, 1.00), float3(0.97, 0.84, 0.95) };
    const float3 darkFields[3] = { float3(0.22, 0.14, 0.42), float3(0.04, 0.24, 0.34), float3(0.26, 0.07, 0.26) };
    for (uint i = 0; i < 3; ++i) {
        const float2 center = fields[i] * size;
        const float radius = 0.62 * max(size.x, 360.0);
        const float t = saturate(1.0 - distance(p, center) / radius);
        color = mix(color, mix(lightFields[i], darkFields[i], theme), 0.55 * t * t);
    }

    // Theme toggle track: a recessed capsule with a day or night sky.
    const float4 track = parameters[kGalleryTrack];
    if (track.z > 0.0) {
        const float d = gallery_rounded_rect(p, track, track.w * 0.5);
        const float coverage = gallery_fill(d, pixel);
        if (coverage > 0.0) {
            const float u = saturate((p.x - track.x) / track.z);
            const float w = saturate((p.y - track.y) / track.w);
            const float3 day = mix(float3(0.50, 0.76, 0.98), float3(0.99, 0.84, 0.60), u * 0.8 + w * 0.2);
            float3 night = mix(float3(0.10, 0.12, 0.32), float3(0.03, 0.04, 0.12), u * 0.6 + w * 0.4);
            // Stars on a 7-point lattice, a few of them lit.
            const float2 starCell = floor((p - track.xy) / 7.0);
            const float2 starLocal = fract((p - track.xy) / 7.0) * 7.0 - 3.5;
            const float lit = step(0.78, gallery_hash(starCell));
            night += lit * gallery_fill(length(starLocal) - 0.7, pixel) * float3(0.75, 0.78, 0.9);
            float3 sky = mix(day, night, theme);
            // Inset: darker under the top edge, a fine light line at the bottom.
            sky = mix(sky, sky * float3(0.88, 0.90, 0.95), saturate(1.0 - (-d) / 5.0) * saturate(1.0 - w * 1.6));
            sky = mix(sky, float3(1.0), 0.35 * saturate(1.0 - abs(d + 0.75) / 0.75) * step(0.5, w));
            color = mix(color, sky, coverage);
        }
    }

    // Elements stage: a dark display case, the same in both themes but
    // a little lifted in the dark theme so it reads against the page.
    const float4 stage = parameters[kGalleryStage];
    if (stage.z > 0.0) {
        const float d = gallery_rounded_rect(p, stage, 30.0);
        const float coverage = gallery_fill(d, pixel);
        if (coverage > 0.0) {
            const float w = saturate((p.y - stage.y) / stage.w);
            float3 plate = mix(float3(0.055, 0.062, 0.105), float3(0.030, 0.032, 0.060), w);
            plate = mix(plate, plate + float3(0.035, 0.038, 0.06), theme);
            // A soft light behind the capsules and a faint dot grid, so the
            // see-through middles and the refraction at their rims show.
            const float2 spot = (p - float2(stage.x + stage.z * 0.5, stage.y + stage.w * 0.42)) / float2(stage.z * 0.55, stage.w * 0.5);
            plate += float3(0.05, 0.06, 0.11) * saturate(1.0 - dot(spot, spot));
            const float2 plateLocal = (fract((p - stage.xy) / 14.0) - 0.5) * 14.0;
            plate += float3(0.07, 0.075, 0.10) * gallery_fill(length(plateLocal) - 0.9, pixel);
            // A hairline border.
            plate = mix(plate, float3(0.35, 0.38, 0.5), 0.45 * saturate(1.0 - abs(d + 0.6) / 0.6));
            color = mix(color, plate, coverage);
        }
    }

    // Floor reflections under the capsules: the bottom of each outline,
    // mirrored, in its edge color, fading over 34 points, screened as light.
    const float4 counts = parameters[kGalleryCounts];
    if (counts.y > 0.5) {
        const uint capsuleCount = min(uint(counts.x), 3u);
        for (uint i = 0; i < capsuleCount; ++i) {
            const float4 rect = parameters[kGalleryCapsules + i];
            const float4 tint = parameters[kGalleryCapsuleColors + i];
            const float below = p.y - (rect.y + rect.w);
            if (below <= 0.0 || below >= 34.0 || abs(p.x - (rect.x + rect.z * 0.5)) > rect.z * 0.5 + 6.0) {
                continue;
            }
            const float2 mirrored = float2(p.x, rect.y + rect.w - below - 2.0);
            const float d = gallery_rounded_rect(mirrored, rect, rect.z * 0.5);
            const float line = exp(-abs(d) / 1.6);
            const float body = d < 0.0 ? 0.22 : 0.0;
            const float fade = (1.0 - below / 34.0) * (1.0 - below / 34.0);
            // A soft contact glow right under the capsule.
            const float contact = exp(-below / 3.0) * saturate(1.0 - abs(p.x - (rect.x + rect.z * 0.5)) / (rect.z * 0.5));
            const float a = saturate(tint.w * ((line * 0.75 + body) * fade + contact * 0.35));
            color = color + tint.rgb * a * (1.0 - color);
        }
    }

    // Orb bar: a dark rounded bar with a faint top highlight.
    const float4 bar = parameters[kGalleryBar];
    if (bar.z > 0.0) {
        const float d = gallery_rounded_rect(p, bar, 28.0);
        const float coverage = gallery_fill(d, pixel);
        if (coverage > 0.0) {
            const float w = saturate((p.y - bar.y) / bar.w);
            float3 fill = mix(float3(0.070, 0.066, 0.120), float3(0.025, 0.024, 0.050), w);
            fill = mix(fill, fill + float3(0.03, 0.03, 0.05), theme);
            fill = mix(fill, float3(0.42, 0.44, 0.58), 0.4 * saturate(1.0 - abs(d + 0.6) / 0.6) * step(w, 0.5));
            color = mix(color, fill, coverage);
        }
    }

    // A 4 x 4 ordered dither of under half a step, so the soft gradients
    // show no bands.
    const float bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    const uint2 c = uint2(in.position.xy) & 3u;
    color = saturate(color + ((bayer[c.x + 4u * c.y] + 0.5) / 16.0 - 0.5) / 255.0);
    return float4(color, 1.0);
}
