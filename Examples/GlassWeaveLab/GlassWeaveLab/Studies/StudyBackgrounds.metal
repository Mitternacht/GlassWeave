#include <metal_stdlib>

using namespace metal;

// The four material studies' backgrounds (GW-29): pearl, pill, shelf and vessel.
//
// Every picture is a pure function of the position on the screen in points
// and of the parameters below, written by us; no picture is traced from or
// copied out of anything. The output target is `bgra8Unorm`; the shader writes
// sRGB-encoded values (the glass surface samples a `bgra8Unorm_srgb` view of
// the same texture) with a small ordered dither, so the soft gradients of the
// light page do not band.
//
// Parameters (`constant float4 *`), lengths in points, origin top-left:
//   0  unused, unused, pixels per point, appearance (0 light ... 1 dark)
//   1  screen width, screen height, script time in seconds, progress 0...1
//   2...7  up to six rectangles as x, y, width, height (what each study
//      draws into them is documented at its fragment function)
struct StudyVertexOut {
    float4 position [[position]];
};

vertex StudyVertexOut study_vertex(uint vertexID [[vertex_id]]) {
    const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
    StudyVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    return out;
}

// MARK: Helpers

static float studyHash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static float studyNoise(float2 p) {
    const float2 i = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    const float a = studyHash(i);
    const float b = studyHash(i + float2(1.0, 0.0));
    const float c = studyHash(i + float2(0.0, 1.0));
    const float d = studyHash(i + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float studyFBM(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int i = 0; i < 4; ++i) {
        sum += amplitude * studyNoise(p);
        p = p * 2.03 + float2(17.1, 9.7);
        amplitude *= 0.5;
    }
    return sum;
}

/// A rounded rectangle's signed distance: negative inside.
static float studyRoundRect(float2 p, float4 rect, float radius) {
    const float2 half2 = rect.zw * 0.5;
    const float r = min(radius, min(half2.x, half2.y));
    const float2 q = abs(p - (rect.xy + half2)) - half2 + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float2 studyRoundRectGradient(float2 p, float4 rect, float radius) {
    const float e = 0.75;
    return normalize(float2(
        studyRoundRect(p + float2(e, 0.0), rect, radius) - studyRoundRect(p - float2(e, 0.0), rect, radius),
        studyRoundRect(p + float2(0.0, e), rect, radius) - studyRoundRect(p - float2(0.0, e), rect, radius)
    ) + 1e-5);
}

/// A rainbow as thin-film interference: red, green and blue at their own
/// phases of one cosine, so the hues run through the spectrum smoothly.
static float3 studyFilm(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + float3(0.0, 0.33, 0.67)));
}

static float3 studyFinish(float3 color, float2 pixel) {
    // Triangular-ish ordered dither, one 8-bit step.
    const float n = studyHash(pixel) + studyHash(pixel + 17.0) - 1.0;
    return saturate(color + n / 255.0);
}

/// The studies' one light: the upper left, pointing from the surface to the
/// light, in screen directions (x right, y down).
constant float2 studyLight = float2(-0.6, -0.8);

// MARK: Pearl (light page, embossed plate and well)

// Rectangles: 0 the plate (a rounded rectangle, radius 40), 1 the well (the
// bounding square of a disc, which the round button sits in).
fragment float4 study_pearl_fragment(
    StudyVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float scale = max(parameters[0].z, 1.0);
    const float2 size = max(parameters[1].xy, float2(1.0));
    const float2 p = in.position.xy / scale;
    const float2 uv = p / size;
    const float4 plate = parameters[2];
    const float4 well = parameters[3];

    // The page: a warm paper white that is a touch brighter at the top left.
    float3 color = float3(0.918, 0.920, 0.930);
    color *= 1.0 + 0.030 * (1.0 - uv.y) - 0.040 * dot(uv - float2(0.35, 0.3), uv - float2(0.35, 0.3));
    color += (studyFBM(p * 0.012) - 0.5) * 0.012;

    // The plate stands a little above the page: a long soft shadow away from
    // the light, a tight contact line, then the plate's top face.
    const float plateRadius = 40.0;
    const float2 away = -studyLight;
    const float dPlate = studyRoundRect(p, plate, plateRadius);
    const float drop = smoothstep(34.0, -6.0, studyRoundRect(p - away * 16.0, plate, plateRadius));
    const float contact = smoothstep(5.0, -1.0, studyRoundRect(p - away * 2.5, plate, plateRadius));
    const float3 shade = float3(0.30, 0.31, 0.40);
    color = mix(color, color * 0.72 + shade * 0.1, drop * 0.27);
    color = mix(color, color * 0.80, contact * 0.30);

    if (dPlate < 0.5) {
        const float face = smoothstep(0.5, -0.5, dPlate);
        // The top face: brighter toward the light.
        float3 top = float3(0.962, 0.963, 0.970);
        top *= 1.0 + 0.026 * (0.5 - uv.y) * 2.0;
        // A bevel as wide as the plate's lip: a bright line toward the light,
        // a faint dark one away from it.
        const float2 normal = studyRoundRectGradient(p, plate, plateRadius);
        const float facing = dot(normal, studyLight);
        const float lip = smoothstep(-3.2, -0.2, dPlate);
        top = mix(top, float3(1.0), lip * saturate(facing) * 0.95);
        top = mix(top, top * 0.90, lip * saturate(-facing) * 0.55);
        color = mix(color, top, face);
    }

    // The well: a round dish pressed into the plate. Its far wall (toward the
    // light) lies in shadow; the near wall catches the light. A thin lip rings
    // the opening.
    const float2 wellCenter = well.xy + well.zw * 0.5;
    const float wellRadius = min(well.z, well.w) * 0.5;
    const float2 fromCenter = p - wellCenter;
    const float dWell = length(fromCenter) - wellRadius;
    const float2 outward = fromCenter / max(length(fromCenter), 0.001);
    const float wall = dot(outward, studyLight);    // 1: the wall nearest the light
    if (dWell < 1.0) {
        const float inside = smoothstep(0.5, -0.5, dWell);
        float3 dish = float3(0.925, 0.927, 0.937);
        dish *= 1.0 - 0.022 * (0.5 - uv.y) * 2.0;
        // The inner wall: a soft gradient, dark where it faces away from the
        // light, clean where it faces the light.
        const float depth = smoothstep(-15.0, 0.0, dWell);
        dish *= 1.0 - depth * (0.095 * saturate(wall) + 0.020);
        dish = mix(dish, dish * 1.05 + 0.012, depth * saturate(-wall) * 0.9);
        color = mix(color, dish, inside);
    }
    // The lip around the opening.
    const float lipBand = smoothstep(1.6, 0.0, abs(dWell - 0.4));
    color = mix(color, float3(1.0), lipBand * saturate(-wall) * 0.85);
    color = mix(color, color * 0.86, lipBand * saturate(wall) * 0.5);
    // A little light spilling just outside the opening, on the lit side.
    const float spill = smoothstep(8.0, 0.0, dWell) * step(0.0, dWell);
    color = mix(color, color * 0.95, spill * saturate(wall) * 0.18);

    return float4(studyFinish(color, in.position.xy), 1.0);
}

// MARK: Pill (a field of large fuzzy spheres)

// Spheres of sage, slate, periwinkle, lavender and one dusty coral, drawn
// back to front: each has Lambert shading from the upper left, a darkened
// limb where it turns away, and a felted, fuzzy surface and edge.
struct StudySphere {
    float2 center;      // in screen widths and heights
    float radius;       // in screen widths
    float3 color;
};

fragment float4 study_pill_fragment(
    StudyVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float scale = max(parameters[0].z, 1.0);
    const float2 size = max(parameters[1].xy, float2(1.0));
    const float2 p = in.position.xy / scale;
    const float2 uv = p / size;
    const float fine = studyNoise(p * 1.4) * 0.5 + studyNoise(p * 3.7) * 0.5;
    const float coarse = studyFBM(p * 0.05);

    // The wall behind them.
    float3 color = mix(float3(0.34, 0.50, 0.64), float3(0.20, 0.30, 0.46), smoothstep(0.0, 1.0, uv.y));

    const StudySphere spheres[9] = {
        { float2(0.10, 0.10), 0.56, float3(0.30, 0.46, 0.72) },    // slate blue
        { float2(0.98, 0.12), 0.50, float3(0.34, 0.58, 0.56) },    // sage
        { float2(-0.06, 0.46), 0.52, float3(0.40, 0.48, 0.78) },   // periwinkle
        { float2(1.05, 0.46), 0.48, float3(0.28, 0.44, 0.70) },    // slate blue
        { float2(0.60, 0.16), 0.47, float3(0.78, 0.48, 0.56) },    // dusty coral
        { float2(0.44, 0.71), 0.62, float3(0.46, 0.44, 0.80) },    // lavender
        { float2(0.02, 0.90), 0.54, float3(0.30, 0.54, 0.56) },    // sage teal
        { float2(1.00, 0.88), 0.54, float3(0.30, 0.44, 0.74) },    // slate blue
        { float2(0.60, 1.06), 0.54, float3(0.62, 0.40, 0.56) }     // rose
    };
    for (int i = 0; i < 9; ++i) {
        const StudySphere sphere = spheres[i];
        const float2 center = sphere.center * size;
        const float radius = sphere.radius * size.x;
        const float2 d2 = (p - center) / radius;
        const float d = length(d2);
        const float edge = smoothstep(1.0, 0.978, d + (fine - 0.5) * 0.028);
        if (edge <= 0.0) { continue; }
        const float z = sqrt(max(1.0 - d * d, 0.0));
        const float3 normal = normalize(float3(d2, z + 0.0001));
        const float3 lightDirection = normalize(float3(studyLight, 0.9));
        const float lambert = saturate(dot(normal, lightDirection));
        float3 surface = sphere.color * (0.50 + 0.62 * lambert);
        // Felt: fine noise lightens and darkens the colour a few percent.
        surface *= 0.93 + 0.14 * fine;
        surface *= 0.96 + 0.08 * coarse;
        // The limb darkens where the sphere turns away, which also reads as
        // contact where one sphere sits in front of another.
        surface *= 1.0 - 0.34 * smoothstep(0.72, 1.0, d);
        // A soft sheen at the top left.
        surface += float3(0.9, 0.95, 1.0) * 0.05 * pow(lambert, 3.0);
        color = mix(color, surface, edge);
    }
    // The sphere field is soft: the whole picture settles toward its own
    // mean a little, so the glass's bevel is what carries the contrast.
    color = mix(color, float3(0.42, 0.52, 0.72), 0.06);
    color *= 1.0 - 0.10 * smoothstep(0.55, 1.15, uv.y);
    return float4(studyFinish(color, in.position.xy), 1.0);
}

// MARK: Shelf (a blue sky, a rainbow arc and iridescent pebbles)

// Parameters: 1.z is the script time in seconds; the pebbles drift slowly
// with it (a few points around their rest positions, closing a loop every
// 48 seconds).
struct StudyPebble {
    float2 center;      // in screen widths and heights
    float2 radii;       // in points
    float angle;        // radians
    float phase;        // drift phase, in turns
    float3 pastel;
};

fragment float4 study_shelf_fragment(
    StudyVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float scale = max(parameters[0].z, 1.0);
    const float2 size = max(parameters[1].xy, float2(1.0));
    const float time = parameters[1].z;
    const float2 p = in.position.xy / scale;
    const float2 uv = p / size;

    // The sky: a bright azure that settles toward periwinkle at the bottom,
    // with a pale bloom up and to the left.
    float3 color = mix(float3(0.14, 0.48, 0.90), float3(0.22, 0.32, 0.74), smoothstep(0.05, 1.0, uv.y));
    color += float3(0.07, 0.09, 0.08) * exp(-3.2 * dot(uv - float2(0.12, 0.10), uv - float2(0.12, 0.10)));

    // The rainbow arc: a band centred far below the screen, so it crosses the
    // upper half as a wide arc. Red lies outside, violet inside, as in sunlight;
    // it is soft and it fades toward both ends.
    const float2 arcCenter = float2(0.50 * size.x, 0.95 * size.y);
    const float arcRadius = 0.54 * size.y;
    const float arcWidth = 0.19 * size.x;
    const float ring = (length(p - arcCenter) - arcRadius) / arcWidth + 0.5;     // 0 inner ... 1 outer
    const float arcFade = smoothstep(0.0, 0.25, 1.0 - abs(uv.x - 0.5) * 1.25);
    const float band = smoothstep(0.0, 0.22, ring) * smoothstep(1.0, 0.78, ring);
    const float3 spectrum = studyFilm(0.70 - ring * 0.62);
    color = mix(color, color * 0.35 + spectrum * 0.90, band * arcFade * 0.50);
    // A wide halo around the arc.
    const float halo = exp(-pow((ring - 0.5) * 1.5, 2.0));
    color += float3(0.18, 0.15, 0.20) * halo * arcFade * 0.18;

    // The pebbles: smooth iridescent stones, each lit from the upper left,
    // with a thin-film colour that turns around its rim.
    const StudyPebble pebbles[7] = {
        { float2(0.30, 0.392), float2(70.0, 56.0), 0.35, 0.00, float3(1.00, 0.78, 0.86) },
        { float2(0.80, 0.385), float2(80.0, 60.0), -0.30, 0.20, float3(0.80, 0.86, 1.00) },
        { float2(0.52, 0.610), float2(74.0, 60.0), 0.20, 0.45, float3(1.00, 0.88, 0.76) },
        { float2(0.08, 0.580), float2(58.0, 48.0), -0.50, 0.85, float3(0.90, 0.80, 1.00) },
        { float2(0.94, 0.585), float2(64.0, 52.0), 0.60, 0.70, float3(0.86, 1.00, 0.92) },
        { float2(0.66, 0.760), float2(72.0, 58.0), 0.10, 0.35, float3(0.78, 0.94, 1.00) },
        { float2(0.20, 0.215), float2(46.0, 40.0), -0.20, 0.55, float3(0.92, 0.86, 1.00) }
    };
    for (int i = 0; i < 7; ++i) {
        const StudyPebble pebble = pebbles[i];
        const float turns = time / 48.0 + pebble.phase;
        const float2 drift = 7.0 * float2(sin(6.28318 * turns), cos(6.28318 * (turns + 0.25) * 2.0) * 0.6);
        const float2 center = pebble.center * size + drift;
        const float c = cos(pebble.angle), s = sin(pebble.angle);
        const float2 q = p - center;
        const float2 local = float2(c * q.x + s * q.y, -s * q.x + c * q.y) / pebble.radii;
        // A superellipse of exponent 2.6: a stone, not an ellipse.
        const float r = pow(pow(abs(local.x), 2.6) + pow(abs(local.y), 2.6), 1.0 / 2.6);
        const float pixelsPerUnit = min(pebble.radii.x, pebble.radii.y);
        const float edge = smoothstep(1.0, 1.0 - 1.4 / pixelsPerUnit, r);
        if (edge <= 0.0) { continue; }
        const float z = sqrt(max(1.0 - r * r, 0.0));
        const float2 n2 = normalize(local + 1e-4);
        const float3 normal = normalize(float3(n2 * (1.0 - z), z + 0.15));
        // The same upper-left light, in the stone's frame.
        const float3 lightDirection = normalize(float3(studyLight, 0.85));
        const float facing = saturate(dot(normal, lightDirection));
        // A pale, pearly stone: a pastel body, lit from one side. The thin
        // film shows only toward the rim, where the stone turns away, and its
        // hue follows the direction of the slope (a continuous function, so
        // it has no seam).
        const float rim = smoothstep(0.50, 1.0, r);
        const float film = 0.10 + 0.55 * r + 0.30 * dot(n2, float2(0.7, 0.4)) + pebble.phase;
        float3 stone = mix(pebble.pastel, float3(1.0), 0.18) * (0.84 + 0.24 * facing);
        stone = mix(stone, studyFilm(film) * 0.85 + 0.15, rim * 0.42);
        // A soft sheen high on the stone, toward the light.
        stone += 0.07 * pow(facing, 5.0);
        // Where it meets the sky its edge turns toward the sky's colour, so it
        // sits in the picture and does not look cut out; the body is a little
        // translucent.
        stone = mix(stone, color * 1.10, 0.30 * smoothstep(0.80, 1.0, r));
        const float opacity = 0.72 + 0.20 * z;
        color = mix(color, stone, edge * opacity);
    }
    return float4(studyFinish(color, in.position.xy), 1.0);
}

// MARK: Vessel (a dark stage under warm glass)

// Rectangles: 0 the large vessel, 1 the small one (their frames, in points).
// 1.w is the small vessel's liquid level, 0...1: a fuller vessel lights the
// table beneath it a little more.
//
// The picture is quiet on purpose, so the liquid is the only bright thing: a
// near-black wall that warms toward the table, one far soft box at the upper
// left (the studies' one light, so the glass has an edge to bend and a lit
// side to catch it), and the warm light each vessel throws on the table below
// it, a wide Gaussian that peaks just under the vessel.
fragment float4 study_vessel_fragment(
    StudyVertexOut in [[stage_in]],
    constant float4 *parameters [[buffer(0)]])
{
    const float scale = max(parameters[0].z, 1.0);
    const float2 size = max(parameters[1].xy, float2(1.0));
    const float level = saturate(parameters[1].w);
    const float2 p = in.position.xy / scale;
    const float2 uv = p / size;

    float3 color = mix(float3(0.011, 0.012, 0.017), float3(0.030, 0.026, 0.025), smoothstep(0.15, 1.0, uv.y));

    // The far soft box: a tall rounded strip, faint, with a wide falloff.
    const float2 q = (uv - float2(0.08, 0.36)) / float2(0.16, 0.34);
    const float strip = 1.0 - smoothstep(0.0, 1.0, length(q));
    color += float3(0.50, 0.55, 0.66) * 0.045 * strip;

    // The light of the liquids on the table.
    for (int i = 0; i < 2; ++i) {
        const float4 rect = parameters[2 + i];
        if (rect.z <= 0.0) { continue; }
        const float2 center = float2(rect.x + 0.5 * rect.z, rect.y + 0.97 * rect.w);
        const float2 d = (p - center) / float2(0.78 * rect.z, 0.30 * rect.w);
        const float pool = exp(-1.7 * dot(d, d));
        const float strength = i == 0 ? 0.17 : 0.05 + 0.10 * level;
        color += float3(1.0, 0.40, 0.09) * strength * pool;
    }

    // A soft vignette, so the edges of the screen fall away.
    const float2 v = (uv - 0.5) * float2(1.0, 0.8);
    color *= 1.0 - 0.45 * smoothstep(0.30, 0.80, length(v));
    return float4(studyFinish(color, in.position.xy), 1.0);
}
