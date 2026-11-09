#include <metal_stdlib>

using namespace metal;

// The material bench's backgrounds (GW-21): five procedural 8-bit sRGB pages
// that every glass look can be shown over, so a look is judged against a
// known backdrop. Every pixel is a pure function of the parameters below, so
// the pages are reproducible. The output target is `bgra8Unorm`; the shader
// writes sRGB-encoded values, which GlassWeave samples through a
// `bgra8Unorm_srgb` view of the same texture.
//
// Parameters (`constant float4 *`, one block):
//   x pixels per point, y page (0...5), z width in points, w height in points
//
// Pages: 0 dot grid, 1 checkerboard, 2 color ribbons, 3 charcoal stage,
// 4 light paper, 5 orbs (GW-22: soft shaded spheres on a dusk gradient, an
// original backdrop with strong colored edges and fine structure, to show a
// lens's magnification and dispersion).

struct BenchVertexOut {
    float4 position [[position]];
};

vertex BenchVertexOut bench_background_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    BenchVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

/// Coverage of a shape at signed distance `d` (points), antialiased over one
/// pixel (`pixel` points).
static float bench_fill(float d, float pixel) {
    return saturate(0.5 - d / pixel);
}

static float bench_hash(float2 cell) {
    return fract(sin(dot(cell, float2(127.1, 311.7))) * 43758.5453);
}

/// A saturated palette, 0...1 around the hue circle, in sRGB-encoded values.
static float3 bench_hue(float t) {
    const float3 phase = float3(0.0, 0.33, 0.67);
    return saturate(0.5 + 0.5 * cos(6.2831853 * (t + phase)) * 1.1 - 0.05);
}

/// One orb of page 5: `x`, `y` the center and `z` the radius, in units of the
/// page width, and `w` the hue position on the palette below.
constant float4 bench_orbs[18] = {
    float4(0.10, 0.20, 0.26, 1.0), float4(0.52, 0.12, 0.22, 5.0), float4(0.92, 0.25, 0.28, 2.0),
    float4(0.30, 0.45, 0.20, 0.0), float4(0.70, 0.52, 0.24, 4.0), float4(0.05, 0.75, 0.22, 3.0),
    float4(0.45, 0.80, 0.28, 1.0), float4(0.88, 0.82, 0.20, 0.0), float4(0.22, 1.10, 0.25, 4.0),
    float4(0.62, 1.12, 0.22, 2.0), float4(0.98, 1.15, 0.26, 5.0), float4(0.08, 1.45, 0.27, 0.0),
    float4(0.48, 1.42, 0.24, 3.0), float4(0.85, 1.50, 0.28, 1.0), float4(0.30, 1.80, 0.30, 2.0),
    float4(0.75, 1.85, 0.30, 4.0), float4(0.50, 2.10, 0.30, 0.0), float4(0.05, 2.05, 0.26, 5.0),
};

/// The orbs' base colors, in sRGB-encoded values: mauve pink, steel blue,
/// periwinkle, violet, orange-magenta, and cyan.
constant float3 bench_orb_colors[6] = {
    float3(0.80, 0.50, 0.70),
    float3(0.40, 0.55, 0.86),
    float3(0.55, 0.52, 0.92),
    float3(0.62, 0.34, 0.80),
    float3(0.95, 0.40, 0.45),
    float3(0.30, 0.78, 0.92),
};

fragment float4 bench_background_fragment(
    BenchVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float4 general = parameters[0];
    const float scale = general.x;
    const uint page = uint(general.y + 0.5);
    const float2 size = general.zw;
    const float2 p = in.position.xy / scale;
    const float pixel = 1.0 / scale;
    float3 color = float3(0.0);

    switch (page) {
    case 0: {
        // Dot grid: bright dots of radius 2.5 points on a 16-point lattice
        // over near-black, for measuring displacement by their centroids.
        const float2 local = (fract(p / 16.0) - 0.5) * 16.0;
        color = float3(0.06) + float3(0.88) * bench_fill(length(local) - 2.5, pixel);
        break;
    }
    case 1: {
        // Checkerboard: 16-point cells, dark and light gray.
        const float2 cell = floor(p / 16.0);
        color = mix(float3(0.14), float3(0.86), fmod(cell.x + cell.y, 2.0));
        break;
    }
    case 2: {
        // Color ribbons: bands of saturated hue running diagonally, bent by
        // two slow waves, with a dark seam between neighbours.
        const float2 q = p / max(size.x, 320.0);
        const float bend = 0.22 * sin(q.y * 9.0 + 0.6) + 0.10 * sin(q.y * 21.0 + q.x * 3.0);
        const float t = (q.x + 0.42 * q.y + bend) * 3.2;
        const float band = fract(t);
        const float3 hue = bench_hue(floor(t) * 0.173 + 0.05);
        const float lit = 0.34 + 0.40 * smoothstep(0.0, 0.5, band) * (1.0 - smoothstep(0.5, 1.0, band) * 0.35);
        color = hue * lit;
        const float seam = smoothstep(0.0, 0.035, band) * smoothstep(0.0, 0.035, 1.0 - band);
        color *= 0.25 + 0.75 * seam;
        break;
    }
    case 3: {
        // Charcoal stage: a dark graphite wall with a soft spot from above,
        // and a slightly lighter floor with a faint reflection line.
        const float horizon = size.y * 0.90;
        const float2 spot = (p - float2(size.x * 0.5, size.y * 0.30)) / float2(size.x * 0.75, size.y * 0.45);
        const float wall = 0.075 + 0.055 * saturate(1.0 - dot(spot, spot));
        const float floorShade = 0.045 + 0.035 * saturate((p.y - horizon) / max(size.y - horizon, 1.0));
        const float onFloor = smoothstep(horizon - 0.5, horizon + 0.5, p.y);
        color = float3(mix(wall, floorShade, onFloor)) * float3(1.0, 1.02, 1.08);
        color += float3(0.10, 0.105, 0.12) * exp(-abs(p.y - horizon) / 1.1);
        break;
    }
    case 5: {
        // Orbs: a dusk gradient from steel blue to deep violet with soft
        // spheres lit from the upper left, each with a fine grain like felt,
        // painted back to front with antialiased edges.
        const float unit = max(size.x, 320.0);
        const float2 u = p / unit;
        color = mix(float3(0.36, 0.52, 0.70), float3(0.20, 0.09, 0.30), saturate(p.y / max(size.y, 1.0)));
        const float grain = bench_hash(floor(p * 0.75)) - 0.5;
        for (uint i = 0; i < 18; ++i) {
            const float4 orb = bench_orbs[i];
            const float2 offset = (u - orb.xy) / orb.z;
            const float r = length(offset);
            const float edge = bench_fill((r - 1.0) * orb.z * unit, pixel);
            if (edge > 0.0) {
                const float3 normal = float3(offset, sqrt(max(1.0 - r * r, 0.0)));
                const float light = saturate(dot(normal, normalize(float3(-0.5, -0.65, 0.6))));
                const float limb = 0.55 + 0.45 * pow(saturate(normal.z), 0.6);
                float3 base = bench_orb_colors[uint(orb.w + 0.5)];
                float3 shaded = base * (0.30 + 0.85 * light) * limb + float3(0.05) * pow(light, 6.0);
                shaded *= 1.0 + 0.22 * grain;
                color = mix(color, shaded, edge);
            }
        }
        break;
    }
    default: {
        // Light paper: warm white with a faint vertical shade and fine grain.
        const float v = saturate(p.y / max(size.y, 1.0));
        color = mix(float3(0.975, 0.965, 0.945), float3(0.930, 0.925, 0.915), v);
        color += (bench_hash(floor(p * scale * 0.5)) - 0.5) * 0.018;
        break;
    }
    }

    // A 4 x 4 ordered dither of under half a step, so the soft gradients
    // show no bands; the dots, checkerboard, and ribbons are exact enough.
    const float bayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };
    const uint2 c = uint2(in.position.xy) & 3u;
    color = saturate(color + ((bayer[c.x + 4u * c.y] + 0.5) / 16.0 - 0.5) / 255.0);
    return float4(color, 1.0);
}
