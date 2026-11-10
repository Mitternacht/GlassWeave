// FROZEN COPY of the glass panel shader as it stood before the overlay mode
// (Sources/GlassWeave/Shaders/Glass.metal at the commit before GW-30: GW-21 to
// GW-29 and the touch response and the clean passes), kept so a test can show
// that the opaque surface renders byte-identical output to it, in every pipeline
// variant. Do not edit it to follow later shader changes: its purpose is to stay
// the old reference. Only the names are changed (gw_gw30_ prefix for the
// shader's own functions and constants; the frost pyramid readers of
// GlassFrost.h keep their names because that header is included as is; the
// shared record types come from the shared header, whose sizes the static_asserts
// below pin, so a layout change fails to compile here instead of silently
// changing the reference).

#include <metal_stdlib>
#include "../../../Sources/GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"
#include "../../../Sources/GlassWeave/Shaders/GlassFrost.h"

using namespace metal;

// The shader's view of the shared record must match the host layout asserted
// in GlassWeaveShaderTypes.c.
static_assert(sizeof(GWGlassUniforms) == 1776, "GWGlassUniforms size");
static_assert(sizeof(GWShapeUniforms) == 336, "GWShapeUniforms size");
static_assert(alignof(GWShapeUniforms) == 16, "GWShapeUniforms alignment");
static_assert(sizeof(GWShapePrimitive) == 48, "GWShapePrimitive size");
static_assert(sizeof(GWGroundingUniforms) == 128, "GWGroundingUniforms size");
static_assert(alignof(GWGroundingUniforms) == 16, "GWGroundingUniforms alignment");
static_assert(sizeof(GWLightingUniforms) == 160, "GWLightingUniforms size");
static_assert(alignof(GWLightingUniforms) == 16, "GWLightingUniforms alignment");
static_assert(sizeof(GWLensInlay) == 48, "GWLensInlay size");
static_assert(alignof(GWLensInlay) == 16, "GWLensInlay alignment");
static_assert(sizeof(GWLightEmitter) == 112, "GWLightEmitter size");
static_assert(alignof(GWLightEmitter) == 16, "GWLightEmitter alignment");
static_assert(alignof(GWGlassUniforms) == 16, "GWGlassUniforms alignment");
static_assert(sizeof(GWFrostPanelUniforms) == 128, "GWFrostPanelUniforms size");
static_assert(alignof(GWFrostPanelUniforms) == 8, "GWFrostPanelUniforms alignment");
static_assert(sizeof(GWFillUniforms) == 784, "GWFillUniforms size");
static_assert(alignof(GWFillUniforms) == 16, "GWFillUniforms alignment");
static_assert(sizeof(GWTouchPoint) == 48, "GWTouchPoint size");
static_assert(sizeof(GWTouchUniforms) == 128, "GWTouchUniforms size");
static_assert(alignof(GWTouchUniforms) == 8, "GWTouchUniforms alignment");

// The optical model below is mirrored on the CPU by `GlassPanelGeometry`
// (GlassPanelGeometry.swift); tests compare the two pixel by pixel. Change
// both together.

/// Light direction for edge illumination, in target pixels (y down): light
/// arrives from the upper left.
constant float2 gw_gw30_light_direction = float2(-0.70710678, -0.70710678);

struct GWBaselineGW30GlassVertexOut {
    float4 position [[position]];
};

/// A quad covering the panel rectangle grown by one pixel on every side, so
/// the antialiased outline (half a pixel either side of the edge) is inside
/// it, and by the halo radius when there is a halo (GW-18; zero otherwise,
/// which leaves the quad exactly as before). The rasterizer clips it to the
/// target, so a halo never reaches past the surface. Pixels outside the quad
/// keep the background pass's output.
vertex GWBaselineGW30GlassVertexOut gw_gw30_glass_vertex(
    uint vertexID [[vertex_id]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + 1.0 + uniforms.glowHaloRadius);
    // Target pixels (y down) to clip space (y up).
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWBaselineGW30GlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// sRGB transfer function, linear light to encoded. Same as the background
/// pass: the output target is non-sRGB `bgra8Unorm` holding encoded values.
static float3 gw_gw30_glass_encode_srgb(float3 linear) {
    const float3 c = saturate(linear);
    const float3 low = c * 12.92;
    const float3 high = 1.055 * pow(c, float3(1.0 / 2.4)) - 0.055;
    return select(high, low, c <= 0.0031308);
}

/// Samples the source, in linear light, at a position in target pixels.
/// Uses the background pass's mapping and clamps half a texel inside the
/// valid rectangle, so a displaced sample never reads outside it.
static float3 gw_gw30_glass_sample(
    float2 pixel, constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    constexpr sampler linearClamp(filter::linear, address::clamp_to_edge);
    const float2 destinationUV = pixel / uniforms.targetSize;
    float2 uv = uniforms.background.uvFromDestinationX * destinationUV.x
              + uniforms.background.uvFromDestinationY * destinationUV.y
              + uniforms.background.uvOrigin;
    uv = clamp(uv, uniforms.background.sampleClampMin, uniforms.background.sampleClampMax);
    return source.sample(linearClamp, uv).rgb;
}

static float gw_gw30_sign(float x) {
    return x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
}

/// Signed distance in pixels to a rounded rectangle centered at the origin:
/// negative inside, zero on the outline, positive outside.
static float gw_gw30_rounded_rect_distance(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
}

/// Outward unit normal of a rounded rectangle with corner radius `radius`:
/// radial in the corner regions, axis-aligned along the straight edges.
static float2 gw_gw30_rounded_rect_normal(float2 q, float2 halfSize, float radius) {
    const float2 d = abs(q) - (halfSize - radius);
    if (d.x > 0.0 && d.y > 0.0) {
        return normalize(d) * float2(gw_gw30_sign(q.x), gw_gw30_sign(q.y));
    }
    if (d.x > d.y) {
        return float2(gw_gw30_sign(q.x), 0.0);
    }
    return float2(0.0, gw_gw30_sign(q.y));
}

// MARK: Freeform shapes (GW-26)
//
// An ellipse, a superellipse, or a smooth blob replaces the rounded rectangle
// everywhere the panel's outline matters: the antialiased edge, the rim
// refraction and the lens, the glow, the halo, the interior and light, the
// light model, and the grounding. The code exists only in the `shaped`
// pipeline variant, built with function constant 3 (`gw_gw30_shape_constant`) set;
// without it everything here is compiled out and the shader is the one of
// GW-25, byte for byte (a frozen copy in the tests proves it). The CPU mirror
// is `GlassShapeField` (GlassShape.swift).
//
// Every shape answers with the same four things (`GWBaselineGW30ShapeSample`): a signed
// distance renormalized by the gradient length so the antialiased edge is one
// pixel wide, the outward normal, the lens depth, and the inscribed radius.
// The distance to a blob is the polynomial smooth minimum of its primitives'
// distances, whose gradient is the blended gradient of the primitives: C1, so
// the normal turns smoothly through a neck.

constant bool gw_gw30_shape_constant [[function_constant(3)]];
constant bool gw_gw30_shaped = is_function_constant_defined(gw_gw30_shape_constant) ? gw_gw30_shape_constant : false;

/// What the optics ask of a panel's shape (GlassShapeField.swift documents
/// the interface; every shape kind returns the same four things).
struct GWBaselineGW30ShapeSample {
    /// Signed distance to the outline in pixels: negative inside.
    float distance;
    /// The unit direction in which `lensDepth` falls (outward).
    float2 normal;
    /// Pixels inside the shape, 0 at and outside the outline. C1: the inward
    /// distance of the rounded rectangle of `lensFieldRadius`, whose
    /// iso-contours keep a corner radius of at least the bevel width; for a
    /// freeform shape the inward distance, whose iso-contours keep a radius
    /// of curvature of at least the bevel width where the bevel is narrower
    /// than the outline's smallest radius of curvature.
    float lensDepth;
    /// Radius of the largest circle inside the shape, in pixels.
    float inscribedRadius;
};

/// A distance and its gradient (not unit length where fields blend).
struct GWBaselineGW30ShapeRaw {
    float distance;
    float2 gradient;
};

/// The ellipse of half sizes `radii`: the first-order distance
/// `k0 (k0 - 1) / k1` with `k0 = |q / r|` and `k1 = |q / r^2|`, exact on the
/// outline and on the axes' ends, whose gradient has unit length.
static GWBaselineGW30ShapeRaw gw_gw30_shape_ellipse(float2 q, float2 radii) {
    const float2 n = q / (radii * radii);
    const float k1 = length(n);
    const float k0 = length(q / radii);
    GWBaselineGW30ShapeRaw raw;
    raw.distance = k1 > 1e-6 ? k0 * (k0 - 1.0) / k1 : -min(radii.x, radii.y);
    raw.gradient = k1 > 1e-6 ? n / k1 : float2(0.0, -1.0);
    return raw;
}

/// The superellipse `|x/a|^n + |y/b|^n = 1`: the first-order distance
/// `(k0 - 1) / |grad k0|` of the homogeneous function
/// `k0 = (|x/a|^n + |y/b|^n)^(1/n)`; exact on the axes. `n = 2` is the ellipse.
static GWBaselineGW30ShapeRaw gw_gw30_shape_superellipse(float2 q, float2 radii, float n) {
    const float2 a = max(abs(q) / radii, 1e-6);
    const float k0 = pow(pow(a.x, n) + pow(a.y, n), 1.0 / n);
    const float2 slope = pow(a, float2(n - 1.0)) / radii / pow(max(k0, 1e-6), n - 1.0);
    const float length2 = length(slope);
    GWBaselineGW30ShapeRaw raw;
    if (abs(q.x) + abs(q.y) < 1e-4 || length2 < 1e-6) {
        raw.distance = -min(radii.x, radii.y);
        raw.gradient = float2(0.0, -1.0);
        return raw;
    }
    raw.distance = (k0 - 1.0) / length2;
    raw.gradient = float2(q.x >= 0.0 ? 1.0 : -1.0, q.y >= 0.0 ? 1.0 : -1.0) * slope / length2;
    return raw;
}

/// One blob primitive's distance and gradient at `q`.
static GWBaselineGW30ShapeRaw gw_gw30_shape_primitive(float2 q, constant GWShapePrimitive &primitive) {
    GWBaselineGW30ShapeRaw raw;
    if (primitive.kind == GWShapePrimitiveCircle) {
        const float2 offset = q - primitive.geometry.xy;
        const float length2 = length(offset);
        raw.distance = length2 - primitive.geometry.z;
        raw.gradient = length2 > 1e-4 ? offset / length2 : float2(0.0, -1.0);
    } else if (primitive.kind == GWShapePrimitiveCapsule) {
        const float2 a = primitive.geometry.xy;
        const float2 axis = primitive.geometry.zw - a;
        const float2 offset = q - a;
        const float h = saturate(dot(offset, axis) / max(dot(axis, axis), 1e-6));
        const float2 away = offset - axis * h;
        const float length2 = length(away);
        raw.distance = length2 - primitive.shape.x;
        const float2 across = normalize(float2(axis.y, -axis.x) + float2(1e-6, 0.0));
        raw.gradient = length2 > 1e-4 ? away / length2 : across;
    } else {
        // A rounded box turned by the angle whose cosine and sine are in
        // `shape.yz`: evaluated in its own frame, the gradient turned back.
        const float2 offset = q - primitive.geometry.xy;
        const float c = primitive.shape.y;
        const float s = primitive.shape.z;
        const float2 local = float2(c * offset.x + s * offset.y, -s * offset.x + c * offset.y);
        const float2 halfSize = primitive.geometry.zw;
        const float radius = primitive.shape.x;
        const float2 d = abs(local) - (halfSize - radius);
        raw.distance = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - radius;
        float2 normal;
        if (d.x > 0.0 && d.y > 0.0) {
            normal = normalize(d) * float2(local.x >= 0.0 ? 1.0 : -1.0, local.y >= 0.0 ? 1.0 : -1.0);
        } else if (d.x > d.y) {
            normal = float2(local.x >= 0.0 ? 1.0 : -1.0, 0.0);
        } else {
            normal = float2(0.0, local.y >= 0.0 ? 1.0 : -1.0);
        }
        raw.gradient = float2(c * normal.x - s * normal.y, s * normal.x + c * normal.y);
    }
    return raw;
}

/// The polynomial smooth minimum of two fields, with the blended gradient:
/// `min - k h^2 / 4` for `h = max(k - |a - b|, 0) / k`, whose gradient is
/// `(1 - h/2) grad(min) + (h/2) grad(other)`. C1 across the blend.
static void gw_gw30_shape_union(thread GWBaselineGW30ShapeRaw &a, GWBaselineGW30ShapeRaw b, float k) {
    const float h = max(k - abs(a.distance - b.distance), 0.0) / max(k, 1e-4);
    const bool first = a.distance < b.distance;
    const float lower = first ? a.distance : b.distance;
    const float2 near = first ? a.gradient : b.gradient;
    const float2 far = first ? b.gradient : a.gradient;
    a.distance = lower - h * h * k * 0.25;
    a.gradient = near * (1.0 - 0.5 * h) + far * (0.5 * h);
}

/// The blob: the smooth union of its primitives, plus the wobble, three plane
/// waves of amplitude `wobbleAmplitude / 3` each whose phases the CPU resolves
/// from the effect time (they loop exactly).
static GWBaselineGW30ShapeRaw gw_gw30_shape_blob(float2 q, constant GWShapeUniforms &shape) {
    GWBaselineGW30ShapeRaw raw = gw_gw30_shape_primitive(q, shape.primitives[0]);
    for (uint i = 1u; i < min(shape.primitiveCount, 6u); ++i) {
        gw_gw30_shape_union(raw, gw_gw30_shape_primitive(q, shape.primitives[i]), shape.smoothness);
    }
    if (shape.wobbleAmplitude > 0.0) {
        const float2 directions[3] = {float2(0.96, 0.28), float2(-0.5, 0.866025), float2(-0.6, -0.8)};
        const float k = 6.2831853 / max(shape.wobbleWavelength, 1.0);
        for (uint i = 0u; i < 3u; ++i) {
            const float phase = dot(directions[i], q) * k + shape.wobblePhases[i];
            raw.distance += shape.wobbleAmplitude * (1.0 / 3.0) * sin(phase);
            raw.gradient += directions[i] * (shape.wobbleAmplitude * (1.0 / 3.0) * k * cos(phase));
        }
    }
    return raw;
}

/// A blob with a softer interior (GW-13): the outline is `gw_gw30_shape_blob`'s
/// (the blend distance `smoothness`, wobble included), and the inside blends
/// the same primitives with the wider `depthSmoothness`, fading in from 0 at
/// the outline to full a few pixels deeper. Where two parts overlap, the depth
/// the lens reads is the larger of two cones and has a V-shaped valley along
/// their bisector (the medial seam); the wider blend rounds that valley over
/// a distance of about `depthSmoothness` while the outline (and a pill that
/// the parts end as) stays exact. Only a blob with a `depthSmoothness` above 0
/// takes this path; every other blob is `gw_gw30_shape_blob`, unchanged.
static GWBaselineGW30ShapeRaw gw_gw30_shape_blob_soft_interior(float2 q, constant GWShapeUniforms &shape) {
    GWBaselineGW30ShapeRaw raw = gw_gw30_shape_blob(q, shape);
    GWBaselineGW30ShapeRaw soft = gw_gw30_shape_primitive(q, shape.primitives[0]);
    for (uint i = 1u; i < min(shape.primitiveCount, 6u); ++i) {
        gw_gw30_shape_union(soft, gw_gw30_shape_primitive(q, shape.primitives[i]), shape.depthSmoothness);
    }
    const float inside = saturate(-raw.distance / max(0.3 * shape.depthSmoothness, 1.0));
    const float weight = inside * inside * (3.0 - 2.0 * inside);
    raw.distance = mix(raw.distance, soft.distance, weight);
    raw.gradient = mix(raw.gradient, soft.gradient, weight);
    return raw;
}

/// The shape field at `q`: the raw distance renormalized by the gradient
/// length (at least 0.3, so a flat saddle never inflates it past the
/// inscribed radius; fading out deep inside), the unit outward normal, and the
/// lens depth.
static GWBaselineGW30ShapeSample gw_gw30_shape_field(float2 q, constant GWGlassUniforms &uniforms) {
    constant GWShapeUniforms &shape = uniforms.shape;
    GWBaselineGW30ShapeRaw raw;
    switch (shape.kind) {
    case GWShapeKindEllipse:
        raw = gw_gw30_shape_ellipse(q, uniforms.panelHalfSize);
        break;
    case GWShapeKindSuperellipse:
        raw = gw_gw30_shape_superellipse(q, uniforms.panelHalfSize, shape.exponent);
        break;
    default:
        raw = shape.depthSmoothness > 0.0 ? gw_gw30_shape_blob_soft_interior(q, shape) : gw_gw30_shape_blob(q, shape);
        break;
    }
    const float length2 = length(raw.gradient);
    // The renormalization only matters near the outline, where it keeps the
    // antialiased edge one pixel wide. Deeper than 35 % of the inscribed
    // radius it fades out: a primitive's own medial lines, where its gradient
    // jumps, would otherwise jump the depth.
    const float deep = saturate(-raw.distance / max(0.35 * shape.inscribedRadius, 1.0));
    GWBaselineGW30ShapeSample sample;
    sample.distance = max(raw.distance / mix(max(length2, 0.3), 1.0, deep), -shape.inscribedRadius);
    sample.normal = raw.gradient / max(length2, 1e-4);
    sample.lensDepth = max(-sample.distance, 0.0);
    sample.inscribedRadius = shape.inscribedRadius;
    return sample;
}

/// The panel's signed distance to its outline in pixels: the shape's, or the
/// rounded rectangle's.
static float gw_gw30_panel_distance(float2 q, constant GWGlassUniforms &uniforms) {
    if (gw_gw30_shaped) {
        return gw_gw30_shape_field(q, uniforms).distance;
    }
    return gw_gw30_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
}

/// The panel's outward unit normal that orients the rim and the light: the
/// shape's, or the rounded rectangle's with the corner radius `radius`.
static float2 gw_gw30_panel_normal(float2 q, float radius, constant GWGlassUniforms &uniforms) {
    if (gw_gw30_shaped) {
        return gw_gw30_shape_field(q, uniforms).normal;
    }
    return gw_gw30_rounded_rect_normal(q, uniforms.panelHalfSize, radius);
}

/// The radius of the largest circle inside the panel, in pixels: the depth
/// fractions of the interior and the light divide by it.
static float gw_gw30_panel_inscribed(constant GWGlassUniforms &uniforms) {
    if (gw_gw30_shaped) {
        return uniforms.shape.inscribedRadius;
    }
    return min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y);
}

/// CLEAN: the clean level of the refined look, 0...1, packed above the presence
/// in `lighting.tint.w` (`1 + presence + 256 * clean`; see the C header). 0 for
/// the classic look and for a refined panel without it, so every path that
/// reads it is the shader before CLEAN, byte for byte.
static float gw_gw30_clean_level(constant GWLightingUniforms &lighting) {
    const uint packed = uint(max(lighting.tint.w - 1.0, 0.0) + 0.5);
    return float((packed >> 8u) & 255u) * (1.0 / 255.0);
}

/// CLEAN-2: how much of the wide, soft rim the clean look keeps, 0...1, packed
/// above the clean level (`+ 65536 * softRim`; zero unless the clean level is
/// above 0). 0 is the thin crisp hairline, 1 the first clean pass's soft
/// gradient, byte for byte.
static float gw_gw30_soft_rim_level(constant GWLightingUniforms &lighting) {
    const uint packed = uint(max(lighting.tint.w - 1.0, 0.0) + 0.5);
    return float((packed >> 16u) & 255u) * (1.0 / 255.0);
}

/// CLEAN-2: the share of the thin rim in the clean look: 0 for the classic
/// look, a refined panel without the clean look and the soft rim at 1 (all of
/// them draw as before), up to 1 for the thin crisp hairline.
static float gw_gw30_thin_rim(constant GWLightingUniforms &lighting) {
    return gw_gw30_clean_level(lighting) > 0.0 ? 1.0 - gw_gw30_soft_rim_level(lighting) : 0.0;
}

/// CLEAN-2: the profile of the thin rim at `depth` pixels inside the outline:
/// 1 at the outline and a Gaussian falloff with the scale `reach` (a full width
/// at half maximum of about 1.6 reach measured from the outline), a smooth
/// function of the exact distance, so it is antialiased without any threshold.
static float gw_gw30_thin_profile(float depth, float reach) {
    const float x = depth / reach;
    return exp(-x * x);
}

/// CLEAN-2: how far inside the nearest lens inlay's outline a pixel is, in
/// pixels (a large number outside every inlay). The thin rim's profiles run
/// from the panel's outline and, with an inlay (a dome button), from its
/// outline too, so the dome keeps its rim line (the soft rim's tilt window
/// found it by itself).
static float gw_gw30_inlay_edge_depth(float2 q, constant GWGlassUniforms &uniforms) {
    float d = 1e4;
    for (uint i = 0u; i < min(uniforms.lensInlayCount, 2u); ++i) {
        constant GWLensInlay &inlay = uniforms.lensInlays[i];
        if (inlay.shape.x <= 0.0) {
            continue;
        }
        const float r = length(q - inlay.geometry.xy);
        if (r < inlay.geometry.z) {
            d = min(d, inlay.geometry.z - r);
        }
    }
    return d;
}

/// CLEAN: whether the panel is dithered with the triangular dither and its
/// glow and light palettes interpolate with a smooth step (`padding0` is the
/// dither mode, or the refined look's clean level is above 0).
static bool gw_gw30_triangular(constant GWGlassUniforms &uniforms) {
    return uniforms.padding0 > 0.5 || gw_gw30_clean_level(uniforms.lighting) > 0.0;
}

/// The 4 x 4 ordered-dither (Bayer) matrix, row by row.
constant float gw_gw30_bayer[16] = {0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5};

/// The glow color at an angle in turns (0 at the top, clockwise), in linear
/// light: linear interpolation between the neighbouring stops around the
/// circle, which wraps from the last stop back to the first. Stops are
/// ordered by angle; one stop is a solid color.
static float3 gw_gw30_glow_color(float turn, constant GWGlassUniforms &uniforms) {
    const float3 colors[4] = {
        uniforms.glowColor0.xyz, uniforms.glowColor1.xyz,
        uniforms.glowColor2.xyz, uniforms.glowColor3.xyz,
    };
    const uint count = min(uniforms.glowStopCount, 4u);
    if (count <= 1u) {
        return colors[0];
    }
    // `following` stops lie at or before `turn`.
    uint following = 0u;
    for (uint i = 0u; i < count; ++i) {
        if (uniforms.glowStopTurns[i] <= turn) {
            following = i + 1u;
        }
    }
    const uint previous = (following + count - 1u) % count;
    const uint next = following % count;
    const float start = following == 0u ? uniforms.glowStopTurns[previous] - 1.0 : uniforms.glowStopTurns[previous];
    const float end = following == count ? uniforms.glowStopTurns[next] + 1.0 : uniforms.glowStopTurns[next];
    float fraction = saturate((turn - start) / max(end - start, 1e-6));
    if (gw_gw30_triangular(uniforms)) {
        // CLEAN: a smooth step between the stops, so the hue has no kink (no
        // visible line) where one stop hands over to the next.
        fraction = fraction * fraction * (3.0 - 2.0 * fraction);
    }
    return mix(colors[previous], colors[next], fraction);
}

/// The glow color and light factor at a pixel, inside or outside the
/// panel: the color at the pixel's angle around the center, in `xyz`, and
/// the light factor, in `w`.
static float4 gw_gw30_glow_shade(float2 q, constant GWGlassUniforms &uniforms) {
    // The angle around the center with the panel scaled to a square. The
    // precise atan2: on the axis through the center `-p.y` is a signed
    // zero, which the fast-math atan2 puts in the wrong half-plane. One
    // color needs no angle.
    const float2 p = q / uniforms.panelHalfSize;
    float turn = 0.0;
    if (uniforms.glowStopCount > 1u && (p.x != 0.0 || p.y != 0.0)) {
        turn = precise::atan2(p.x, -p.y) * (0.5 / M_PI_F);
        turn = turn - floor(turn);
    }
    const float3 color = gw_gw30_glow_color(turn, uniforms);

    // The same normal field inside and outside the outline, so the light is
    // continuous across it.
    const float2 normal = gw_gw30_panel_normal(q, uniforms.glowNormalRadius, uniforms);
    const float facing = (1.0 + dot(normal, uniforms.glowLightDirection)) * 0.5;
    const float light = (1.0 - uniforms.glowDirectionality) + uniforms.glowDirectionality * facing * facing;
    return float4(color, light);
}

/// The glow layer's opacity and color at a pixel inside the panel
/// (docs/glow.md): a rim band, an inner glow falling off as (1 - t)^2, and
/// a center fill, all in one color, with the rim and inner glow lit from
/// one side. Returns the opacity in `w`.
static float4 gw_gw30_glow(float2 q, float depth, constant GWGlassUniforms &uniforms) {
    const float4 shade = gw_gw30_glow_shade(q, uniforms);
    const float3 color = shade.xyz;
    const float light = shade.w;

    float rim = 0.0;
    if (uniforms.glowRimIntensity > 0.0) {
        rim = uniforms.glowRimIntensity * light
            * (1.0 - smoothstep(uniforms.glowRimWidth, uniforms.glowRimWidth + uniforms.glowRimFeather, depth));
    }
    float inner = 0.0;
    if (uniforms.glowInnerRadius > 0.0) {
        const float t = saturate(depth / uniforms.glowInnerRadius);
        inner = uniforms.glowInnerIntensity * (1.0 - t) * (1.0 - t) * light;
    }
    const float alpha = 1.0 - (1.0 - uniforms.glowCenterOpacity) * (1.0 - inner) * (1.0 - rim);
    return float4(color, alpha);
}


// MARK: Interiors (GW-19)
//
// Mirrored on the CPU by `GlassPanelGeometry`'s interior model
// (GlassInteriorModel.swift), which tests compare with this shader. The
// hashes are integer arithmetic, exact on both sides; everything else is the
// same arithmetic in float here and double there. Every pattern repeats after
// 64 s of interior time (`interiorPhase` is reduced into [0, 64) on the CPU):
// time enters only through lattice axes whose period is the number of cells
// the pattern moves in 64 s, through turns that complete a whole number of
// times in 64 s, and through sparks that rise a whole number of times in 64 s
// (their positions are computed on the CPU and uploaded).

/// The lowbias32 integer hash (C. Wellons): a well-mixed 32-bit value.
static uint gw_gw30_hash(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

/// The top 24 bits of a hash as a float in [0, 1), exact in float.
static float gw_gw30_unit(uint h) {
    return float(h >> 8u) * (1.0 / 16777216.0);
}

/// CLEAN: a static, isotropic triangular-PDF dither of one 8-bit step, per
/// channel, in encoded units: the sum of two independent uniform values in
/// (-0.5, 0.5) of one step each, from an integer hash of the pixel. The
/// triangular density makes the quantization error independent of the signal (no
/// banding, no pattern), the hash has no direction (it cannot read as a streak)
/// and nothing in it moves (it does not shimmer).
static float3 gw_gw30_dither_triangular(uint2 cell) {
    const uint seed = cell.x * 0x8da6b343u + cell.y * 0xd8163841u + 0x1b873593u;
    const uint h0 = gw_gw30_hash(seed);
    const uint h1 = gw_gw30_hash(h0 + 0x9e3779b9u);
    const uint h2 = gw_gw30_hash(h1 + 0x9e3779b9u);
    const float3 a = float3(float(h0 & 0xFFFFu), float(h1 & 0xFFFFu), float(h2 & 0xFFFFu));
    const float3 b = float3(float(h0 >> 16u), float(h1 >> 16u), float(h2 >> 16u));
    return ((a + b) * (1.0 / 65536.0) - 1.0) * (1.0 / 255.0);
}

/// A lattice coordinate wrapped into [0, period).
static int gw_gw30_wrap(int i, int period) {
    const int r = i % period;
    return r < 0 ? r + period : r;
}

/// A lattice coordinate wrapped into [0, period) for a power-of-two
/// period, by a mask (no integer division), or unchanged for period 0.
static int gw_gw30_wrap_pow2(int i, int period) {
    return period == 0 ? i : (i & (period - 1));
}

/// The value at a 3D lattice point, in [0, 1). The x axis does not wrap;
/// y and z wrap with the power-of-two periods in `period` (0 for none).
static float gw_gw30_lattice3(int3 cell, int2 period, uint seed) {
    const uint x = uint(cell.x);
    const uint y = uint(gw_gw30_wrap_pow2(cell.y, period.x));
    const uint z = uint(gw_gw30_wrap_pow2(cell.z, period.y));
    return gw_gw30_unit(gw_gw30_hash(x * 0x8da6b343u + y * 0xd8163841u + z * 0xcb1ab31fu + seed));
}

/// The value at a 2D lattice point, in [0, 1), periodic per axis with the
/// power-of-two periods in `period` (0 for none).
static float gw_gw30_lattice2(int2 cell, int2 period, uint seed) {
    const uint x = uint(gw_gw30_wrap_pow2(cell.x, period.x));
    const uint y = uint(gw_gw30_wrap_pow2(cell.y, period.y));
    return gw_gw30_unit(gw_gw30_hash(x * 0x8da6b343u + y * 0xd8163841u + seed));
}

/// 2D value noise with smoothstep interpolation, in [0, 1), periodic per
/// axis with the power-of-two periods in `period` (0 for none).
static float gw_gw30_noise2(float2 p, int2 period, uint seed) {
    const float2 base = floor(p);
    const int2 c = int2(base);
    const float2 f = p - base;
    const float2 s = f * f * (3.0 - 2.0 * f);
    const float v00 = gw_gw30_lattice2(c, period, seed);
    const float v10 = gw_gw30_lattice2(c + int2(1, 0), period, seed);
    const float v01 = gw_gw30_lattice2(c + int2(0, 1), period, seed);
    const float v11 = gw_gw30_lattice2(c + int2(1, 1), period, seed);
    const float x0 = v00 + (v10 - v00) * s.x;
    const float x1 = v01 + (v11 - v01) * s.x;
    return x0 + (x1 - x0) * s.y;
}

/// 3D value noise with smoothstep interpolation, in [0, 1), periodic in y
/// and z with the power-of-two periods in `period` (0 for none).
static float gw_gw30_noise3(float3 p, int2 period, uint seed) {
    const float3 base = floor(p);
    const int3 c = int3(base);
    const float3 f = p - base;
    const float3 s = f * f * (3.0 - 2.0 * f);
    const float v000 = gw_gw30_lattice3(c, period, seed);
    const float v100 = gw_gw30_lattice3(c + int3(1, 0, 0), period, seed);
    const float v010 = gw_gw30_lattice3(c + int3(0, 1, 0), period, seed);
    const float v110 = gw_gw30_lattice3(c + int3(1, 1, 0), period, seed);
    const float v001 = gw_gw30_lattice3(c + int3(0, 0, 1), period, seed);
    const float v101 = gw_gw30_lattice3(c + int3(1, 0, 1), period, seed);
    const float v011 = gw_gw30_lattice3(c + int3(0, 1, 1), period, seed);
    const float v111 = gw_gw30_lattice3(c + int3(1, 1, 1), period, seed);
    const float x00 = v000 + (v100 - v000) * s.x;
    const float x10 = v010 + (v110 - v010) * s.x;
    const float x01 = v001 + (v101 - v001) * s.x;
    const float x11 = v011 + (v111 - v011) * s.x;
    const float y0 = x00 + (x10 - x00) * s.y;
    const float y1 = x01 + (x11 - x01) * s.y;
    return y0 + (y1 - y0) * s.z;
}

/// Three octaves of 3D value noise (amplitudes 1/2, 1/4, 1/8, normalized),
/// each at twice the frequency and twice the period of the one before, so
/// the sum keeps the first octave's period. In [0, 1).
static float gw_gw30_fbm3(float3 p, int2 period, uint seed) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (uint octave = 0u; octave < 3u; ++octave) {
        sum += amplitude * gw_gw30_noise3(p, period, seed + octave * 0x9e3779b9u);
        p *= 2.0;
        period *= 2;
        amplitude *= 0.5;
    }
    return sum / 0.875;
}

/// The length the energy and rays patterns scale with: half the panel's
/// shorter side, but at least 12 points, so a small or thin panel never gets
/// filaments or bands finer than the pixels that show them.
static float gw_gw30_interior_size(float2 halfSize) {
    return max(min(halfSize.x, halfSize.y), 12.0);
}

/// Energy: filaments where noise, warped by two more noise fields, crosses
/// one half, with a faint haze around them, turning once per 64 s around the center (twisted
/// by up to 0.9 rad out to `size` from it) and evolving with time, brighter
/// toward the rim. `u` in points from the center (y down), `size` from
/// `gw_gw30_interior_size`, `w` the depth fraction (0 at the outline).
static float gw_gw30_interior_energy(float2 u, float size, float w, float phase, uint seed) {
    const float2 p0 = u / size;
    const float angle = (2.0 * M_PI_F) * (phase / 64.0) + 0.9 * min(length(p0), 1.0);
    const float c = precise::cos(angle);
    const float s = precise::sin(angle);
    const float2 p = float2(c * p0.x - s * p0.y, s * p0.x + c * p0.y) * 2.2;
    const float z = phase * 0.5;
    const int2 period = int2(0, 32);
    const float wx = gw_gw30_noise3(float3(p, z), period, seed);
    const float wy = gw_gw30_noise3(float3(p.x + 19.0, p.y + 7.0, z), period, seed + 0x51ed270bu);
    const float2 warped = p + 1.4 * (float2(wx, wy) - 0.5);
    const float n = gw_gw30_fbm3(float3(warped, z + 11.0), period, seed + 0xa3c59ac3u);
    const float offset = abs(n - 0.5);
    const float core = 1.0 - smoothstep(0.0, 0.045, offset);
    const float haze = 1.0 - smoothstep(0.0, 0.16, offset);
    return saturate(0.85 * core * core + 0.3 * haze * haze) * (0.45 + 0.55 * (1.0 - w));
}

/// One layer of rays: `count` rays per turn, one per angular cell at a
/// random offset, with a random half-width between `minWidth` and
/// `maxWidth` of its cell (at most 0.28, so a ray never crosses its cell)
/// and a brightness that twinkles over time. A ray is drawn at least 0.75
/// points wide and dimmed by the same factor, so thin rays near the center
/// fade instead of aliasing. `r` is the distance from the center in points.
static float gw_gw30_ray_layer(float turn, float r, int count, float minWidth, float maxWidth, float z, uint seed) {
    const float x = turn * float(count);
    const float base = floor(x);
    const int cell = gw_gw30_wrap(int(base), count);
    const float f = x - base;
    const uint h = gw_gw30_hash(uint(cell) * 0x8da6b343u + seed);
    const float center = 0.3 + 0.4 * gw_gw30_unit(gw_gw30_hash(h + 1u));
    const float width = minWidth + (maxWidth - minWidth) * gw_gw30_unit(gw_gw30_hash(h + 2u));
    const float cellPoints = max(r * (2.0 * M_PI_F) / float(count), 0.001);
    const float drawn = min(max(width, 0.75 / cellPoints), 0.28);
    const float profile = 1.0 - smoothstep(0.0, drawn, abs(f - center));
    // The ray's own brightness over time: 1D value noise in z, period 32.
    const float zBase = floor(z);
    const int zCell = int(zBase);
    const float zf = z - zBase;
    const uint key = uint(cell) * 0x8da6b343u + seed + 0x3c6ef372u;
    const float t0 = gw_gw30_unit(gw_gw30_hash(key + uint(zCell & 31) * 0xd8163841u));
    const float t1 = gw_gw30_unit(gw_gw30_hash(key + uint((zCell + 1) & 31) * 0xd8163841u));
    const float twinkle = t0 + (t1 - t0) * (zf * zf * (3.0 - 2.0 * zf));
    return profile * profile * (width / drawn) * (0.35 + 0.65 * twinkle);
}

/// Rays: 13 soft beams and 29 thin rays per turn from the center, turning
/// in opposite directions (two turns and one turn per 64 s), twinkling, with
/// brightness flowing outward; they fade in from the center where the thin
/// rays' spacing reaches 1.5 points.
static float gw_gw30_interior_rays(float2 u, float size, float phase, uint seed) {
    const float r = length(u);
    if (r <= 0.0) {
        return 0.0;
    }
    float turn = precise::atan2(u.x, -u.y) * (0.5 / M_PI_F);
    turn = turn - floor(turn);
    const float z = phase * 0.5;
    const float beams = gw_gw30_ray_layer(turn + 2.0 * phase / 64.0, r, 13, 0.1, 0.28, z, seed);
    const float rays = gw_gw30_ray_layer(turn - phase / 64.0, r, 29, 0.03, 0.09, z + 7.0, seed + 0x68e31da4u);
    const float flow = gw_gw30_noise2(float2(turn * 8.0, r / size * 2.5 - phase * 0.5), int2(8, 32), seed + 0xb5297a4du);
    const float resolved = smoothstep(1.5, 4.5, r * (2.0 * M_PI_F / 29.0));
    return saturate((0.55 * beams + rays) * (0.4 + 0.6 * flow)) * resolved;
}

/// Embers: flame tongues rising from the bottom edge, as heat 0...1: rising
/// turbulence (tall cells, 0.5 cells a second upward) shapes the top of a
/// flame whose height varies along the bottom edge; heat is highest at the
/// base and falls to 0 at a tongue's ragged top. Above 1.4 times a tongue's
/// height the turbulence cannot lift the flame, so it is not evaluated
/// there (the heat is exactly 0 either way). `halfSize` in points.
static float gw_gw30_interior_flames(float2 u, float2 halfSize, float phase, uint seed) {
    const float above = halfSize.y - u.y;
    const float y = above / (1.3 * halfSize.y);
    const float top = 0.45 + 0.9 * gw_gw30_noise2(float2(u.x / 16.0, phase * 0.25), int2(0, 16), seed + 0x2545f491u);
    if (y >= 1.4 * top) {
        return 0.0;
    }
    const float n = gw_gw30_fbm3(float3(u.x / 9.0, above / 30.0 - phase * 0.5, phase * 0.5), int2(32, 32), seed);
    const float v = (1.0 - y / top) + (n - 0.5) * 0.8;
    return smoothstep(0.0, 1.25, v);
}

/// Embers: the brightest of the twelve uploaded sparks at a point `u` in
/// points from the panel's center, 0...1. Each is a bright core
/// `(1 - d^2 / r^2)^2` with a faint glow three times its radius,
/// `0.45 (1 - d^2 / 9 r^2)^2`, times its brightness. The sparks' paths (they
/// rise from near the bottom edge to the halo's radius above the top edge, a
/// whole number of times per 64 s, swaying, and fade over the last 30 % of
/// their rise) are computed on the CPU, once per draw.
static float gw_gw30_interior_sparks(float2 u, constant GWGlassUniforms &uniforms) {
    float spark = 0.0;
    for (uint i = 0u; i < 12u; ++i) {
        const float4 s = uniforms.interiorSparks[i];
        if (s.w <= 0.0) {
            continue;
        }
        const float2 d = u - s.xy;
        const float dd = dot(d, d) / (s.z * s.z);
        if (dd < 9.0) {
            const float core = dd < 1.0 ? (1.0 - dd) * (1.0 - dd) : 0.0;
            const float glow = (1.0 - dd / 9.0) * (1.0 - dd / 9.0);
            spark = max(spark, max(core, 0.45 * glow) * s.w);
        }
    }
    return spark;
}

/// The interior's value (0...1) at a pixel inside the panel.
static float gw_gw30_interior_value(float2 q, float w, constant GWGlassUniforms &uniforms) {
    const float scale = uniforms.interiorPixelsPerPoint;
    const float2 u = q / scale;
    const float2 halfSize = uniforms.panelHalfSize / scale;
    const float phase = uniforms.interiorPhase;
    const uint seed = uniforms.interiorSeed;
    switch (uniforms.interiorEffect) {
    case GWInteriorEffectEnergy:
        return gw_gw30_interior_energy(u, gw_gw30_interior_size(halfSize), w, phase, seed);
    case GWInteriorEffectRays:
        return gw_gw30_interior_rays(u, gw_gw30_interior_size(halfSize), phase, seed);
    case GWInteriorEffectEmbers:
        return max(gw_gw30_interior_flames(u, halfSize, phase, seed), gw_gw30_interior_sparks(u, uniforms));
    default:
        return 0.0;
    }
}

/// The interior's ramp color at value `e`, in linear light: one color, or
/// two or three spread evenly from 0 to 1.
static float3 gw_gw30_interior_ramp(float e, constant GWGlassUniforms &uniforms) {
    const float3 c0 = uniforms.interiorColor0.xyz;
    const float3 c1 = uniforms.interiorColor1.xyz;
    const float3 c2 = uniforms.interiorColor2.xyz;
    if (uniforms.interiorColorCount <= 1u) {
        return c0;
    }
    if (uniforms.interiorColorCount == 2u) {
        return c0 + (c1 - c0) * e;
    }
    return e < 0.5 ? c0 + (c1 - c0) * (e * 2.0) : c1 + (c2 - c1) * (e * 2.0 - 1.0);
}

// MARK: Inner light (GW-21)
//
// Colored light inside the glass (docs/glass-optics.md). The CPU resolves
// every emitter for the draw (`GlassPanelGeometry.Light`): directions,
// pixel lengths, the palette's flow and hue drift, and the drift offset, all
// at the draw's effect time, so the shader sees no time. Every emitter is
// evaluated in panel unit space, `u = q / panelHalfSize` (the panel scaled
// to a square), so a band or an arc means the same for any panel shape. With
// no emitters (`lightEmitterCount` 0) none of this runs and the output is
// the output without light.

/// The most opacity `.paint` light gives one emitter.
constant float gw_gw30_light_paint_cap = 0.85;

/// The emitter's palette at position `x`, in linear light. The palette
/// folds back and forth (period 2: stop 0 to the last stop and back), so
/// shifting `x` by 2 is the identity and a flowing palette never jumps. Stops
/// are spread evenly over 0 to 1 and interpolate linearly.
static float3 gw_gw30_light_palette(float x, constant GWLightEmitter &emitter, bool smooth) {
    const uint count = emitter.colorCount;
    if (count <= 1u) {
        return emitter.color0.xyz;
    }
    const float folded = x - 2.0 * floor(x * 0.5);
    const float m = folded <= 1.0 ? folded : 2.0 - folded;
    const float position = m * float(count - 1u);
    const uint index = min(uint(position), count - 2u);
    const float3 colors[4] = {emitter.color0.xyz, emitter.color1.xyz, emitter.color2.xyz, emitter.color3.xyz};
    float fraction = position - float(index);
    if (smooth) {
        // CLEAN: a smooth step between the stops (no kink where they meet).
        fraction = fraction * fraction * (3.0 - 2.0 * fraction);
    }
    return mix(colors[index], colors[index + 1u], fraction);
}

/// A quick profile, 1 at `x` 0 and exactly 0 from `x` 1 on: (1 - x)^2. The
/// piping uses it.
static float gw_gw30_light_falloff(float x) {
    const float t = 1.0 - saturate(x);
    return t * t;
}

/// A pooled profile, 1 at `x` 0 and exactly 0 from `x` 1 on, falling slowly
/// near 0 and near 1: 1 - smoothstep(0, 1, x). Never rises with `x`. The
/// bands, arcs, and fields use it for their body light.
static float gw_gw30_light_pool(float x) {
    return 1.0 - smoothstep(0.0, 1.0, x);
}

/// One emitter's color (`xyz`) and body light (`w`, before intensity and
/// center fade) at pixel offset `q` from the panel's center, `depth` pixels
/// inside the outline and `w` of the way to the deepest point. `pipe`
/// receives the weight of its piping, 0...1: the falloff with the Euclidean
/// distance, in pixels, from the emitter's source.
static float4 gw_gw30_light_emitter(
    float2 q, float depth, float w, constant GWLightEmitter &emitter,
    constant GWGlassUniforms &uniforms, thread float &pipe)
{
    const float2 halfSize = uniforms.panelHalfSize;
    const float2 u = q / halfSize;
    const float4 shape = emitter.shape;
    const float4 motion = emitter.motion;
    const float pipeReach = motion.w;
    const bool smoothStops = gw_gw30_triangular(uniforms);
    float3 color = emitter.color0.xyz;
    float body = 0.0;
    pipe = 0.0;
    switch (emitter.kind) {
    case GWLightKindBand: {
        // The half-plane toward the lit edge: `edge` is the unit-space
        // distance from it, never negative (the corners of a rectangle lie
        // past it and get the full light).
        const float2 direction = shape.xy;
        const float edge = max(1.0 - dot(u, direction), 0.0);
        const float reach = max(shape.z * (1.0 + 0.3 * motion.z), 1e-4);
        body = gw_gw30_light_pool(edge / reach);
        const float tau = saturate(0.5 + 0.5 * dot(u, float2(direction.y, -direction.x)));
        color = gw_gw30_light_palette(tau + motion.x, emitter, smoothStops);
        if (pipeReach > 0.0) {
            pipe = gw_gw30_light_falloff(edge * shape.w / pipeReach);
        }
        break;
    }
    case GWLightKindArc: {
        float turn = 0.0;
        if (u.x != 0.0 || u.y != 0.0) {
            turn = precise::atan2(u.x, -u.y) * (0.5 / M_PI_F);
            turn = turn - floor(turn);
        }
        float delta = turn - (shape.x + 0.12 * motion.y);
        delta = delta - round(delta);
        const float halfSpan = max(shape.y, 1e-4);
        const float along = 1.0 - smoothstep(0.4 * halfSpan, halfSpan, abs(delta));
        body = along * gw_gw30_light_pool(depth / max(shape.z, 1e-4));
        color = gw_gw30_light_palette(saturate(0.5 + delta / (2.0 * halfSpan)) + motion.x, emitter, smoothStops);
        if (pipeReach > 0.0) {
            // Euclidean distance to the arc: the depth, and the way along
            // the outline past the arc's end.
            const float beyond = max(abs(delta) - halfSpan, 0.0) * (2.0 * M_PI_F) * length(q);
            pipe = gw_gw30_light_falloff(length(float2(depth, beyond)) / pipeReach);
        }
        break;
    }
    case GWLightKindPoint: {
        const float2 center = (shape.xy + motion.yz * 0.25) * halfSize;
        const float2 offset = q - center;
        const float2 radii = float2(shape.w, 1.0) * max(shape.z, 1e-3);
        const float2 scaled = offset / radii;
        const float d2 = dot(scaled, scaled);
        const float t = 1.0 - saturate(d2);
        body = t * t;
        color = gw_gw30_light_palette(sqrt(min(d2, 1.0)) + motion.x, emitter, smoothStops);
        if (pipeReach > 0.0) {
            pipe = gw_gw30_light_falloff(length(offset) / pipeReach);
        }
        break;
    }
    case GWLightKindField: {
        // Four corner colors, bilinear, warped by one octave of noise that
        // moves around a loop (`shape.yz`) and wanders with the drift.
        const float2 uv = saturate(u * 0.5 + 0.5);
        const float2 noiseAt = uv * 2.5 + shape.yz + motion.yz * 3.0;
        const float2 noise = float2(
            gw_gw30_noise2(noiseAt, int2(0), emitter.seed),
            gw_gw30_noise2(noiseAt + float2(17.3, 5.1), int2(0), emitter.seed + 0x51ed270bu));
        const float2 warped = saturate(uv + shape.x * 0.9 * (noise - 0.5));
        const float3 top = mix(emitter.color0.xyz, emitter.color1.xyz, warped.x);
        const float3 bottom = mix(emitter.color2.xyz, emitter.color3.xyz, warped.x);
        color = mix(top, bottom, warped.y);
        body = gw_gw30_light_pool(w);
        pipe = 1.0;
        break;
    }
    default:
        break;
    }
    return float4(color, body);
}

// MARK: Shape field and thick lens (GW-22)
//
// The thick-lens code exists only in the `optics` pipeline variant: the host
// builds this function with `gw_gw30_optics_constant` true for a panel whose
// `GlassLens` draws something, and with it unset otherwise, in which case
// everything below is compiled out and the shader is the one of GW-21, byte
// for byte (a frozen copy in the tests proves it). The model is mirrored on
// the CPU by `GlassLensModel` (GlassLensModel.swift).

constant bool gw_gw30_optics_constant [[function_constant(0)]];
constant bool gw_gw30_optics = is_function_constant_defined(gw_gw30_optics_constant) ? gw_gw30_optics_constant : false;

/// The rounded-rectangle shape field.
static GWBaselineGW30ShapeSample gw_gw30_shape_rounded_rect(float2 q, constant GWGlassUniforms &uniforms) {
    GWBaselineGW30ShapeSample shape;
    shape.distance = gw_gw30_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.cornerRadius);
    shape.normal = gw_gw30_rounded_rect_normal(q, uniforms.panelHalfSize, uniforms.lensFieldRadius);
    shape.lensDepth = max(-gw_gw30_rounded_rect_distance(q, uniforms.panelHalfSize, uniforms.lensFieldRadius), 0.0);
    shape.inscribedRadius = min(uniforms.panelHalfSize.x, uniforms.panelHalfSize.y);
    return shape;
}

/// The panel's shape field: the freeform shape's, or the rounded rectangle's.
static GWBaselineGW30ShapeSample gw_gw30_shape_sample(float2 q, constant GWGlassUniforms &uniforms) {
    if (gw_gw30_shaped) {
        return gw_gw30_shape_field(q, uniforms);
    }
    return gw_gw30_shape_rounded_rect(q, uniforms);
}

/// The steepest surface slope the optics use (rise over run).
constant float gw_gw30_lens_max_slope = 12.0;

/// A height profile `s(t)` (x) and its slope `s'(t)` (y), `t` in 0...1 the
/// depth into the bevel over the bevel width: 0 at the outline. `a` and `b`
/// are the profile's parameters (`GWLensProfile`).
static float2 gw_gw30_lens_profile(uint profile, float t, float a, float b) {
    t = saturate(t);
    switch (profile) {
    case GWLensProfileCircular:
    case GWLensProfileDome: {
        const float s = sqrt(max(t * (2.0 - t), 0.0));
        return float2(s, s > 1e-6 ? (1.0 - t) / s : gw_gw30_lens_max_slope * 100.0);
    }
    case GWLensProfileSquircle: {
        const float n = max(a, 1.0);
        const float u = 1.0 - t;
        const float inner = max(1.0 - pow(u, n), 0.0);
        const float s = pow(inner, 1.0 / n);
        return float2(s, inner > 1e-9 ? pow(u, n - 1.0) * pow(inner, 1.0 / n - 1.0) : gw_gw30_lens_max_slope * 100.0);
    }
    case GWLensProfileChamfer: {
        const float knee = 0.7;
        const float norm = (1.0 + knee) * 0.5;
        if (t < knee) {
            return float2(t / norm, 1.0 / norm);
        }
        const float u = t - knee;
        return float2((knee + u - u * u / (2.0 * (1.0 - knee))) / norm, (1.0 - u / (1.0 - knee)) / norm);
    }
    case GWLensProfileRing: {
        const float x = (t - a) / max(b, 1e-6);
        if (abs(x) >= 1.0) {
            return float2(0.0);
        }
        const float s = sqrt(1.0 - x * x);
        return float2(s, s > 1e-6 ? -x / (b * s) : (x < 0.0 ? 1.0 : -1.0) * gw_gw30_lens_max_slope * 100.0);
    }
    default:
        return float2(0.0);
    }
}

/// The glass surface at a pixel: its height in pixels and the gradient of
/// the height (pixels per pixel, pointing toward the interior).
struct GWBaselineGW30LensField {
    float height;
    float2 gradient;
    /// A factor 0...1 on the offset (`GlassLens.softness`): 1 where the lens
    /// is not softened, and a smooth window over the bevel where it is. It
    /// starts at 1 on every field that is built without a lens.
    float window = 1.0;
};

/// The lens's softness 0...1 (`GlassLens.softness`), carried in the integer
/// part of `lensOffsetScale` as `2 * round(softness * 255)` (the scale itself,
/// 0...1, is the fraction), so the uniform record keeps its layout. Exactly 0
/// for every lens that does not ask for it.
static float gw_gw30_lens_softness(constant GWGlassUniforms &uniforms) {
    return floor(uniforms.lensOffsetScale * 0.5) * (1.0 / 255.0);
}

/// The offset scale, 0...1, with the softness removed.
static float gw_gw30_lens_offset_scale(constant GWGlassUniforms &uniforms) {
    return uniforms.lensOffsetScale - 2.0 * floor(uniforms.lensOffsetScale * 0.5);
}

/// The quintic smoothstep, C2 at both ends.
static float gw_gw30_lens_smoother(float edge0, float edge1, float x) {
    const float t = saturate((x - edge0) / max(edge1 - edge0, 1e-6));
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// The host panel's height field: `h = H * s(lensDepth / bevel)`.
static GWBaselineGW30LensField gw_gw30_lens_host(GWBaselineGW30ShapeSample shape, constant GWGlassUniforms &uniforms) {
    GWBaselineGW30LensField field;
    field.height = 0.0;
    field.gradient = float2(0.0);
    if (uniforms.lensProfile == GWLensProfileRim) {
        return field;
    }
    const float t = uniforms.lensBevel > 0.0 ? saturate(shape.lensDepth / uniforms.lensBevel) : 1.0;
    const float2 profile = gw_gw30_lens_profile(uniforms.lensProfile, t, uniforms.lensProfileA, uniforms.lensProfileB);
    field.height = uniforms.lensThickness * profile.x;
    if (t < 1.0) {
        // The depth falls toward the outline, so the height rises along the
        // inward direction: against the outward normal.
        const float rise = clamp(uniforms.lensThickness * profile.y / uniforms.lensBevel, -gw_gw30_lens_max_slope, gw_gw30_lens_max_slope);
        field.gradient = -shape.normal * rise;
        if (uniforms.lensProfile == GWLensProfileRing && gw_gw30_clean_level(uniforms.lighting) > 0.0) {
            // CLEAN-2: the ring's profile is a half circle, whose slope is
            // infinite where the ring starts and where it ends (clamped, so it
            // jumped from flat to nearly upright within a pixel). The light's
            // normal swung with it and the dark band began in a hard step of
            // about 70 levels, a staircase with no antialiasing at 8x to 16x,
            // and the refraction's chromatic fringe began in a one-pixel
            // colored line. The gradient now turns up over the first four
            // pixels of either end (a smooth, antialiased onset); the ring keeps
            // its slope everywhere else, so no bend is raised, only the first
            // pixels of each end are gentler.
            const float toEnd = min(t - (uniforms.lensProfileA - uniforms.lensProfileB),
                                    (uniforms.lensProfileA + uniforms.lensProfileB) - t) * uniforms.lensBevel;
            field.gradient *= gw_gw30_lens_smoother(0.0, 4.0, toEnd);
        }
    }
    const float softness = gw_gw30_lens_softness(uniforms);
    if (softness > 0.0 && uniforms.lensProfile != GWLensProfileRing) {
        // A softened lens: the bend rises from nothing at the outline over the
        // first quarter of the bevel and fades out toward the flat top from
        // under a fifth of the way in, both with zero slope and curvature at
        // the ends, so the bend has no visible start line and no kink where the
        // bevel ends, and the first pixels at the outline do not smear (the
        // raw offset climbs to its peak within a pixel or two of the outline,
        // which would stretch the content there many times over).
        const float window = gw_gw30_lens_smoother(0.0, 0.26, t) * (1.0 - gw_gw30_lens_smoother(0.18, 1.0, t));
        field.window = mix(1.0, window, softness);
    }
    return field;
}

/// Where the glass sends the sample for a pixel, as an offset in pixels
/// (toward the interior for a convex edge): the surface normal
/// `N = normalize(-gradient, 1)` bends the downward ray with Snell's law,
/// `T = refract(-z, N, 1 / ior)`, and the ray travels the glass height to the
/// background: `T.xy / (-T.z) * h`, scaled by `lensOffsetScale` and at most
/// `lensMaximumOffset` long.
static float2 gw_gw30_lens_offset(GWBaselineGW30LensField field, float ior, constant GWGlassUniforms &uniforms) {
    if (field.height <= 0.0 || all(field.gradient == float2(0.0))) {
        return float2(0.0);
    }
    const float3 normal = normalize(float3(-field.gradient, 1.0));
    const float3 ray = refract(float3(0.0, 0.0, -1.0), normal, 1.0 / ior);
    float2 offset = ray.xy / max(-ray.z, 1e-3) * (field.height * gw_gw30_lens_offset_scale(uniforms));
    const float softness = gw_gw30_lens_softness(uniforms);
    if (softness > 0.0) {
        // A softened lens: the window above, and a smooth ceiling (a fourth
        // power knee, C-infinity) in place of the hard clamp, which would
        // show as a kink where the offset reaches the maximum.
        offset *= field.window;
        const float knee = dot(offset, offset) / max(uniforms.lensMaximumOffset * uniforms.lensMaximumOffset, 1e-6);
        return offset * rsqrt(sqrt(1.0 + knee * knee));
    }
    const float length2 = dot(offset, offset);
    if (length2 > uniforms.lensMaximumOffset * uniforms.lensMaximumOffset) {
        offset *= uniforms.lensMaximumOffset * rsqrt(length2);
    }
    return offset;
}

/// Adds the inlays' bumps to the height field: each is a profile over the
/// depth into the inlay from its base, `t = (radius - r) / bevel`, so the
/// height is 0 on the base (C0 with the panel) and nothing is added beyond
/// it. The gradient points toward the inlay's center.
static void gw_gw30_lens_add_inlays(float2 q, constant GWGlassUniforms &uniforms, thread GWBaselineGW30LensField &field) {
    for (uint i = 0u; i < min(uniforms.lensInlayCount, 2u); ++i) {
        constant GWLensInlay &inlay = uniforms.lensInlays[i];
        const float2 offset = q - inlay.geometry.xy;
        const float radius = inlay.geometry.z;
        const float r = length(offset);
        if (r >= radius || inlay.shape.x <= 0.0) {
            continue;
        }
        const float t = saturate((radius - r) / inlay.shape.x);
        const float2 profile = gw_gw30_lens_profile(inlay.profile, t, inlay.shape.y, inlay.shape.z);
        field.height += inlay.geometry.w * profile.x;
        const float softness = gw_gw30_lens_softness(uniforms);
        if (softness > 0.0) {
            // The host's window falls to 0 over the flat top, where the inlay
            // stands: the inlay brings its own, which only rises from its base.
            field.window = max(field.window, mix(1.0, gw_gw30_lens_smoother(0.0, 0.26, t), softness));
        }
        if (t < 1.0 && r > 1e-4) {
            const float rise = clamp(inlay.geometry.w * profile.y / inlay.shape.x, -gw_gw30_lens_max_slope, gw_gw30_lens_max_slope);
            field.gradient -= offset / r * rise;
        }
    }
}

/// The inlays' rim light, as a fraction of the way to white: a thin line at
/// the base and a brighter bevel inside it, both lit from the direction of the
/// panel's edge light (`lightDirection`, the upper left, or the key light's
/// azimuth with the light model). Exactly 0 beyond half a pixel outside every
/// base.
static float gw_gw30_lens_inlay_highlight(float2 q, float2 lightDirection, constant GWGlassUniforms &uniforms) {
    float light = 0.0;
    for (uint i = 0u; i < min(uniforms.lensInlayCount, 2u); ++i) {
        constant GWLensInlay &inlay = uniforms.lensInlays[i];
        const float2 offset = q - inlay.geometry.xy;
        const float radius = inlay.geometry.z;
        const float r = length(offset);
        if (r >= radius + 0.5 || inlay.shape.w <= 0.0 || inlay.shape.x <= 0.0) {
            continue;
        }
        const float facing = r > 1e-4 ? saturate(dot(offset / r, lightDirection)) : 0.0;
        const float lit = 0.35 + 0.65 * facing;
        // A line about 1.5 pixels wide at the base, antialiased on both sides.
        const float line = saturate(1.0 - abs(r - (radius - 0.75)) / 1.25);
        const float bevel = saturate((radius - r) / inlay.shape.x);
        const float rim = (1.0 - bevel) * (1.0 - bevel) * (1.0 - bevel);
        light = max(light, inlay.shape.w * (0.85 * line * lit + 0.35 * rim * lit));
    }
    return saturate(light);
}

/// How far the index of refraction of red and blue light differs from the
/// base index at dispersion 1.
constant float gw_gw30_lens_ior_spread = 0.12;
/// How far the original rim's displacement differs between red and blue
/// light at dispersion 1, as a fraction of it.
constant float gw_gw30_lens_rim_spread = 0.35;
/// The smallest red-to-blue separation, in pixels, that is worth separate
/// samples; below it the colors are not split.
constant float gw_gw30_lens_min_separation = 0.25;
/// The six wavelengths of the six-tap spectrum, -1 (red) to 1 (blue).
constant float gw_gw30_lens_tap_x[6] = {-1.0, -0.6, -0.2, 0.2, 0.6, 1.0};
/// Each tap's weights in red, green, and blue: triangles centered on
/// -1, 0, and 1, normalized so every channel's weights sum to 1 (a white
/// source stays white).
constant float3 gw_gw30_lens_tap_weight[6] = {
    float3(11.0 / 21.0, 0.0, 0.0),
    float3(7.0 / 21.0, 0.15, 0.0),
    float3(3.0 / 21.0, 0.35, 0.0),
    float3(0.0, 0.35, 3.0 / 21.0),
    float3(0.0, 0.15, 7.0 / 21.0),
    float3(0.0, 0.0, 11.0 / 21.0),
};

/// Whether the thick-lens path draws the panel: a lens profile, dispersion
/// on the original rim, or an inlay.
static bool gw_gw30_lens_active(constant GWGlassUniforms &uniforms) {
    return uniforms.lensProfile != GWLensProfileRim || uniforms.lensTapCount > 0u || uniforms.lensInlayCount > 0u;
}

/// The glass color at a pixel under a lens, in linear light. `rimNormal` and
/// `rimDisplacement` are the original rim's, used when the host profile is
/// the rim (with dispersion).
///
/// Dispersion: a wavelength `x` (-1 red, 0 green, 1 blue) sees the index
/// `ior + x * dispersion * 0.12`, and the rim's displacement scaled by
/// `1 + x * dispersion * 0.35`. Where red and blue land less than a quarter
/// pixel apart there is one sample, as without dispersion; elsewhere three
/// samples give red, green, and blue their own wavelength, or six wavelengths
/// are blended with weights that sum to 1 per channel. Every sample keeps the
/// valid-rectangle clamp.
static float3 gw_gw30_lens_glass(
    float2 pixel, float2 q, float2 rimNormal, float rimDisplacement,
    constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    const GWBaselineGW30ShapeSample shape = gw_gw30_shape_sample(q, uniforms);
    GWBaselineGW30LensField field = gw_gw30_lens_host(shape, uniforms);
    gw_gw30_lens_add_inlays(q, uniforms, field);
    const float2 rim = uniforms.lensProfile == GWLensProfileRim ? -rimNormal * rimDisplacement : float2(0.0);
    const float ior = uniforms.lensIOR;
    const float2 center = rim + gw_gw30_lens_offset(field, ior, uniforms);
    if (uniforms.lensTapCount == 0u || uniforms.lensDispersion <= 0.0) {
        return gw_gw30_glass_sample(pixel + center, uniforms, source);
    }
    const float spread = uniforms.lensDispersion * gw_gw30_lens_ior_spread;
    const float rimSpread = uniforms.lensDispersion * gw_gw30_lens_rim_spread;
    const float2 red = rim * (1.0 - rimSpread) + gw_gw30_lens_offset(field, max(ior - spread, 1.0), uniforms);
    const float2 blue = rim * (1.0 + rimSpread) + gw_gw30_lens_offset(field, ior + spread, uniforms);
    const float2 separation = blue - red;
    if (dot(separation, separation) < gw_gw30_lens_min_separation * gw_gw30_lens_min_separation) {
        return gw_gw30_glass_sample(pixel + center, uniforms, source);
    }
    if (uniforms.lensTapCount == 3u) {
        return float3(gw_gw30_glass_sample(pixel + red, uniforms, source).r,
                      gw_gw30_glass_sample(pixel + center, uniforms, source).g,
                      gw_gw30_glass_sample(pixel + blue, uniforms, source).b);
    }
    float3 color = float3(0.0);
    for (uint tap = 0u; tap < 6u; ++tap) {
        const float x = gw_gw30_lens_tap_x[tap];
        const float2 offset = rim * (1.0 + x * rimSpread) + gw_gw30_lens_offset(field, max(ior + x * spread, 1.0), uniforms);
        color += gw_gw30_lens_tap_weight[tap] * gw_gw30_glass_sample(pixel + offset, uniforms, source);
    }
    return color;
}

// MARK: Frost (GW-24b)
//
// A blur that varies over the glass, read from the pyramid of filtered
// backgrounds that GW-24a builds (Frost.metal; GlassFrost.h reads it). The code
// exists only in the frost pipeline variants: the host builds this function
// with `gw_gw30_frost_constant` (function constant 4) true for a panel whose
// `GlassFrost` is active, and with it unset otherwise, in which case
// everything below is compiled out and the shader is the one before GW-24b,
// byte for byte (a frozen copy in the tests proves it). The pyramid and a
// `GWFrostPanelUniforms` record are bound only for those variants.
//
// The blur radius sigma (destination pixels) comes from the profile at the
// pixel (and optionally the lens thickness there), and sets a level of
// detail, LOD = log2(sigma / sigma0) between the pyramid's levels
// (`gw_frost_lod`). One position is read by two levels of the pyramid, each
// reconstructed with a four-fetch cubic B-spline, at the lens-refracted
// position; with dispersion, each wavelength is one trilinear tap at the
// shared LOD. Below sigma0 (the finest level's own blur, 1.32 px) the weight
// ramps from the single-sample path to the pyramid, so a clear region is the
// unfrosted shader's exact sample and there is no seam.

constant bool gw_gw30_frost_constant [[function_constant(4)]];
constant bool gw_gw30_frosted = is_function_constant_defined(gw_gw30_frost_constant) ? gw_gw30_frost_constant : false;

/// How much of the pyramid a pixel shows: its blur radius, the level of
/// detail, and the weight (0...1) of the pyramid against the unfrosted sample.
struct GWBaselineGW30FrostPixel {
    float sigma;
    float lod;
    float weight;
};

/// The frost at a pixel `depth` inside the outline and `relativeY` below the
/// shape's center; `heightFraction` is the glass height over the thickest
/// height (1 without a lens), for the thickness term.
static GWBaselineGW30FrostPixel gw_gw30_frost_pixel(float depth, float relativeY, float heightFraction, constant GWFrostPanelUniforms &frost) {
    GWBaselineGW30FrostPixel pixel;
    pixel.sigma = 0.0;
    pixel.lod = 0.0;
    pixel.weight = 0.0;
    if ((frost.flags & GWFrostFlagSampling) == 0u) {
        return pixel;
    }
    float sigma = gw_frost_sigma_at(frost.profile, depth, relativeY);
    sigma *= (1.0 - frost.thickness) + frost.thickness * heightFraction;
    pixel.sigma = sigma;
    pixel.weight = saturate(sigma / gw_frost_level_sigma(0u));
    pixel.lod = gw_frost_lod(sigma, frost.profile.layout.levelCount);
    return pixel;
}

/// The glass color at `position` (target pixels), in linear light: the
/// source's single sample, or the pyramid's two levels blended by the cubic
/// B-spline, or a mix of the two while the blur is below sigma0.
static float3 gw_gw30_frost_color(
    float2 position, GWBaselineGW30FrostPixel frostPixel, constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source,
    constant GWFrostPanelUniforms &frost, texture2d<float, access::sample> pyramid)
{
    if (frostPixel.weight <= 0.0) {
        return gw_gw30_glass_sample(position, uniforms, source);
    }
    const float3 blurred = gw_frost_sample(pyramid, frost.profile.layout, position, frostPixel.lod);
    if (frostPixel.weight >= 1.0) {
        return blurred;
    }
    return mix(gw_gw30_glass_sample(position, uniforms, source), blurred, frostPixel.weight);
}

/// One dispersion tap: a single trilinear fetch at the shared level of detail.
static float3 gw_gw30_frost_color_tap(
    float2 position, GWBaselineGW30FrostPixel frostPixel, constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source,
    constant GWFrostPanelUniforms &frost, texture2d<float, access::sample> pyramid)
{
    if (frostPixel.weight <= 0.0) {
        return gw_gw30_glass_sample(position, uniforms, source);
    }
    const float3 blurred = gw_frost_tap(pyramid, frost.profile.layout, position, frostPixel.lod);
    if (frostPixel.weight >= 1.0) {
        return blurred;
    }
    return mix(gw_gw30_glass_sample(position, uniforms, source), blurred, frostPixel.weight);
}

/// `gw_gw30_lens_glass` with the pyramid in place of the single sample: the same
/// rays and wavelengths, the same fallbacks, a frosted color for each. Without
/// dispersion the one position reads the B-spline; with it, every wavelength
/// is one tap at the shared level of detail (three taps, or six blended).
static float3 gw_gw30_lens_glass_frosted(
    float2 pixel, float2 q, float2 rimNormal, float rimDisplacement, GWBaselineGW30FrostPixel frostPixel,
    constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source,
    constant GWFrostPanelUniforms &frost, texture2d<float, access::sample> pyramid)
{
    const GWBaselineGW30ShapeSample shape = gw_gw30_shape_sample(q, uniforms);
    GWBaselineGW30LensField field = gw_gw30_lens_host(shape, uniforms);
    gw_gw30_lens_add_inlays(q, uniforms, field);
    const float2 rim = uniforms.lensProfile == GWLensProfileRim ? -rimNormal * rimDisplacement : float2(0.0);
    const float ior = uniforms.lensIOR;
    const float2 center = rim + gw_gw30_lens_offset(field, ior, uniforms);
    if (uniforms.lensTapCount == 0u || uniforms.lensDispersion <= 0.0) {
        return gw_gw30_frost_color(pixel + center, frostPixel, uniforms, source, frost, pyramid);
    }
    const float spread = uniforms.lensDispersion * gw_gw30_lens_ior_spread;
    const float rimSpread = uniforms.lensDispersion * gw_gw30_lens_rim_spread;
    const float2 red = rim * (1.0 - rimSpread) + gw_gw30_lens_offset(field, max(ior - spread, 1.0), uniforms);
    const float2 blue = rim * (1.0 + rimSpread) + gw_gw30_lens_offset(field, ior + spread, uniforms);
    const float2 separation = blue - red;
    if (dot(separation, separation) < gw_gw30_lens_min_separation * gw_gw30_lens_min_separation) {
        return gw_gw30_frost_color(pixel + center, frostPixel, uniforms, source, frost, pyramid);
    }
    if (uniforms.lensTapCount == 3u) {
        return float3(gw_gw30_frost_color_tap(pixel + red, frostPixel, uniforms, source, frost, pyramid).r,
                      gw_gw30_frost_color_tap(pixel + center, frostPixel, uniforms, source, frost, pyramid).g,
                      gw_gw30_frost_color_tap(pixel + blue, frostPixel, uniforms, source, frost, pyramid).b);
    }
    float3 color = float3(0.0);
    for (uint tap = 0u; tap < 6u; ++tap) {
        const float x = gw_gw30_lens_tap_x[tap];
        const float2 offset = rim * (1.0 + x * rimSpread) + gw_gw30_lens_offset(field, max(ior + x * spread, 1.0), uniforms);
        color += gw_gw30_lens_tap_weight[tap] * gw_gw30_frost_color_tap(pixel + offset, frostPixel, uniforms, source, frost, pyramid);
    }
    return color;
}

/// The relative luminance weights of linear sRGB (WCAG 2).
constant float3 gw_gw30_frost_luma = float3(0.2126, 0.7152, 0.0722);

/// The frosted color's grade and grain, weighted by how much of the pyramid
/// the pixel shows: saturation and brightness in linear light (saturation
/// about the pixel's own luminance), and a static, multiplicative grain
/// (about +-4 % of the color at full strength, one pixel in size).
static float3 gw_gw30_frost_grade(float3 color, float2 pixel, GWBaselineGW30FrostPixel frostPixel, constant GWFrostPanelUniforms &frost, float clean) {
    const float luminance = dot(color, gw_gw30_frost_luma);
    const float3 graded = mix(float3(luminance), color, frost.saturation) * frost.brightness;
    color = mix(color, graded, frostPixel.weight);
    if (frost.profile.grain > 0.0) {
        uint2 cell = uint2(pixel);
        uint h = cell.x * 1664525u + cell.y * 1013904223u + 374761393u;
        h ^= h >> 15; h *= 2246822519u; h ^= h >> 13; h *= 3266489917u; h ^= h >> 16;
        const float noise = float(h & 0xFFFFu) * (1.0 / 65535.0) - 0.5;
        if (clean > 0.0) {
            // CLEAN: the white grain gives way to the triangular dither: a calm,
            // even frost with no speckle.
            color *= 1.0 + noise * 0.08 * frost.profile.grain * frostPixel.weight * (1.0 - clean);
        } else {
            color *= 1.0 + noise * 0.08 * frost.profile.grain * frostPixel.weight;
        }
    }
    return max(color, 0.0);
}

/// A luminance `x` limited to `limit` without a corner: unchanged up to 60 %
/// of the limit, then an exponential approach that stays below it. Never above
/// `limit`, so the contrast it guarantees is met with room to spare.
static float gw_gw30_frost_soft_limit(float x, float limit) {
    const float knee = 0.6 * limit;
    if (x <= knee) { return x; }
    const float headroom = max(limit - knee, 1e-4);
    return knee + headroom * (1.0 - exp(-(x - knee) / headroom));
}

/// The legibility scrim (GW-24b): inside the text rectangle (and fading out
/// over `scrimFeather` pixels beyond it) the glass is darkened, for light
/// text, or lightened, for dark text, by the least that gives the text
/// `scrimRatio` (WCAG 2 contrast) against it. A pixel that already has the
/// ratio is untouched; the others are scaled in luminance (darkening scales
/// the color, lightening mixes toward white), so hue is kept. It runs on the
/// final linear color, after every light term. `touched` is set where the color
/// changed.
static float3 gw_gw30_frost_scrim(float3 color, float2 pixel, constant GWFrostPanelUniforms &frost, thread bool &touched) {
    const float2 d = abs(pixel - frost.scrimCenter) - frost.scrimHalfSize;
    const float outside = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    const float weight = 1.0 - smoothstep(0.0, max(frost.scrimFeather, 1e-3), outside);
    if (weight <= 0.0) { return color; }
    const float luminance = dot(color, gw_gw30_frost_luma);
    const float text = frost.scrimTextLuminance;
    float3 result = color;
    // Text lighter than the midpoint of the contrast scale gets a darker
    // glass; darker text, a lighter one.
    if (text > 0.179) {
        const float limit = max((text + 0.05) / frost.scrimRatio - 0.05, 0.0);
        const float limited = gw_gw30_frost_soft_limit(luminance, limit);
        if (limited < luminance) {
            const float gain = limited / max(luminance, 1e-6);
            result = color * gain;
            // A darkened color keeps its richness: the chroma about the
            // (unchanged) luminance grows with the dimming, as far as no channel
            // goes below zero, so a bright cyan becomes a deep blue-teal and
            // not a gray-teal. The luminance, and so the contrast, is exactly
            // what the plain scaling gave.
            const float cmin = min(result.x, min(result.y, result.z));
            const float room = limited > cmin + 1e-6 ? limited / (limited - cmin) : 1.0;
            const float lift = min(1.0 + 0.6 * (1.0 - gain), room);
            result = float3(limited) + (result - float3(limited)) * lift;
        }
    } else {
        const float floorLuminance = min(frost.scrimRatio * (text + 0.05) - 0.05, 1.0);
        const float limited = 1.0 - gw_gw30_frost_soft_limit(1.0 - luminance, max(1.0 - floorLuminance, 0.0));
        if (limited > luminance) {
            result = color + (1.0 - color) * ((limited - luminance) / max(1.0 - luminance, 1e-6));
        }
    }
    result = mix(color, result, weight);
    touched = any(result != color);
    return result;
}

// MARK: Light model (GW-23)
//
// One movable light (docs/glass-optics.md): a Fresnel outline, a specular
// streak, an analytic studio reflected on the rim, chrome and prismatic
// finishes, a soft knee, and a bloom. The code exists only in the `lighting`
// pipeline variant: the host builds this function with `gw_gw30_lighting_constant`
// true for a panel whose `GlassLighting` is not `.legacy`, and with it unset
// otherwise, in which case everything below is compiled out and the shader is
// the one of GW-22, byte for byte (a frozen copy in the tests proves it). The
// shader is the reference of the model; there is no CPU mirror.

constant bool gw_gw30_lighting_constant [[function_constant(1)]];
constant bool gw_gw30_lighting = is_function_constant_defined(gw_gw30_lighting_constant) ? gw_gw30_lighting_constant : false;

/// The surface normal of the panel at `q`, from the slope of its height
/// field: the lens's (host profile and inlays) or, without a lens profile, a
/// quarter-round edge `lighting.bevel` wide. `outward` receives the outline's
/// unit normal at `q`.
static float3 gw_gw30_light_normal(float2 q, constant GWGlassUniforms &uniforms, thread float2 &outward) {
    constant GWLightingUniforms &lighting = uniforms.lighting;
    GWBaselineGW30LensField field;
    field.height = 0.0;
    field.gradient = float2(0.0);
    if (uniforms.lensProfile != GWLensProfileRim) {
        const GWBaselineGW30ShapeSample shape = gw_gw30_shape_sample(q, uniforms);
        field = gw_gw30_lens_host(shape, uniforms);
        outward = shape.normal;
    } else {
        float depth;
        if (gw_gw30_shaped) {
            const GWBaselineGW30ShapeSample shape = gw_gw30_shape_field(q, uniforms);
            outward = shape.normal;
            depth = shape.lensDepth;
        } else {
            outward = gw_gw30_rounded_rect_normal(q, uniforms.panelHalfSize, lighting.fieldRadius);
            depth = max(-gw_gw30_rounded_rect_distance(q, uniforms.panelHalfSize, lighting.fieldRadius), 0.0);
        }
        const float t = lighting.bevel > 0.0 ? saturate(depth / lighting.bevel) : 1.0;
        if (t < 1.0) {
            const float2 profile = gw_gw30_lens_profile(GWLensProfileCircular, t, 0.0, 0.0);
            // Thickness equals the bevel, so the slope is the profile's.
            field.gradient = -outward * clamp(profile.y, -gw_gw30_lens_max_slope, gw_gw30_lens_max_slope);
        }
    }
    if (uniforms.lensInlayCount > 0u) {
        gw_gw30_lens_add_inlays(q, uniforms, field);
    }
    return normalize(float3(-field.gradient, 1.0));
}

/// The soft knee: identity up to 0.8, then a shoulder that is C1 there
/// (slope 1) and rises monotonically toward 1 without reaching it.
static float3 gw_gw30_light_knee(float3 x) {
    const float3 shoulder = 0.8 + 0.2 * (1.0 - exp(-(x - 0.8) * 5.0));
    return select(shoulder, x, x <= 0.8);
}

/// A soft rectangle in the studio's (azimuth, elevation) space, 1 inside and
/// 0 outside, with edges `soft` radians wide. `center` is (azimuth,
/// elevation) and `extent` the half width and half height, in radians.
static float gw_gw30_studio_box(float2 azel, float2 center, float2 extent, float soft) {
    const float2 d = abs(azel - center);
    const float2 inside = 1.0 - smoothstep(extent - soft, extent + soft, d);
    return inside.x * inside.y;
}

/// The studio seen along the unit direction `R` (x right, y down, z toward the
/// viewer), turned by `azimuth` radians with the key light: the sky, the
/// horizon line, and the floor in `base`, and the key softbox (`x`) and the two
/// tall strips at either side (`y`) in `boxes`, each at its brightness. Light
/// studio: a pale sky, a dark floor, white boxes. Dark studio: a near-black
/// room with gray boxes.
static void gw_gw30_studio(float3 R, float azimuth, uint environment, thread float3 &base, thread float2 &boxes) {
    const float elevation = asin(clamp(R.z, -1.0, 1.0));
    float az = precise::atan2(R.x, -R.y) - azimuth;
    az = az - 2.0 * M_PI_F * round(az / (2.0 * M_PI_F));
    const bool dark = environment == GWLightingEnvironmentStudioDark;
    const float up = saturate(R.z);
    const float3 sky = dark ? mix(float3(0.020, 0.022, 0.030), float3(0.040, 0.044, 0.056), up)
                            : mix(float3(0.50, 0.51, 0.55), float3(0.30, 0.31, 0.35), up);
    const float3 floorColor = dark ? float3(0.006, 0.006, 0.008) : float3(0.20, 0.20, 0.23);
    const float3 horizonColor = dark ? float3(0.12, 0.125, 0.14) : float3(0.95, 0.95, 0.97);
    const float horizon = exp(-pow(elevation / 0.09, 2.0));
    base = mix(floorColor, sky, smoothstep(-0.06, 0.06, elevation)) + horizonColor * horizon;
    const float keyBox = gw_gw30_studio_box(float2(az, elevation), float2(0.0, 0.66), float2(0.70, 0.26), 0.10);
    const float stripLeft = gw_gw30_studio_box(float2(az, elevation), float2(-1.68, 0.45), float2(0.22, 0.55), 0.08);
    const float stripRight = gw_gw30_studio_box(float2(az, elevation), float2(1.68, 0.45), float2(0.22, 0.55), 0.08);
    boxes = float2(keyBox * (dark ? 1.5 : 2.0), max(stripLeft, stripRight) * (dark ? 1.3 : 3.2));
}

/// A thin-film palette at `h` turns, as a color that multiplies a reflection:
/// white at `saturation` 0, the full rainbow at 1.
static float3 gw_gw30_light_film(float h, float saturation) {
    const float3 rainbow = 0.5 + 0.5 * cos(2.0 * M_PI_F * (h + float3(0.0, 1.0 / 3.0, 2.0 / 3.0)));
    return mix(float3(1.0), rainbow, saturation);
}

/// A Blinn-Phong lobe of one light, with its exponent limited by the pixel
/// footprint so it is never narrower than a pixel's change of normal, and its
/// peak lowered to match (the lobe's energy stays the same).
static float3 gw_gw30_light_lobe(float3 N, float4 direction, float4 color, float footprint) {
    if (direction.w <= 0.0) {
        return float3(0.0);
    }
    const float3 H = normalize(direction.xyz + float3(0.0, 0.0, 1.0));
    const float p = max(color.w, 1.0);
    const float effective = 1.0 / (1.0 / p + footprint * footprint);
    return color.xyz * direction.w * ((effective + 2.0) / (p + 2.0)) * pow(saturate(dot(N, H)), effective);
}

/// The bright lines of the light model at a point inside the band, in linear
/// light before the knee: the Fresnel outline and the specular streaks of the
/// key and rim lights. `depth` pixels inside the outline, `N` the surface
/// normal there.
static float3 gw_gw30_light_lines(float3 N, float depth, constant GWGlassUniforms &uniforms) {
    constant GWLightingUniforms &lighting = uniforms.lighting;
    const float band = lighting.bandWidth;
    if (band <= 0.0 || depth >= band) {
        return float3(0.0);
    }
    const float mask = 1.0 - smoothstep(0.75 * band, band, depth);
    const float edge = 1.0 - N.z;
    const float edge2 = edge * edge;
    const float outline = edge2 * edge2 * edge;
    const float2 direction = N.xy / max(length(N.xy), 1e-4);
    const float facing = 0.65 + 0.35 * (0.5 + 0.5 * dot(direction, lighting.edgeDirection));
    const float3 outlineColor = mix(float3(1.0), lighting.keyColor.xyz, 0.6);
    float3 energy = outlineColor * (lighting.fresnel * outline * facing * (lighting.contrast > 0.0 ? 0.0 : 1.0));
    const float3 lobes = gw_gw30_light_lobe(N, lighting.key, lighting.keyColor, lighting.footprint)
                       + gw_gw30_light_lobe(N, lighting.rim, lighting.rimColor, lighting.footprint);
    energy += lobes * lighting.specular;
    return energy * mask;
}

// MARK: Refined look (Apple-grade defaults)
//
// `GlassLighting.Look.refined` (`lighting.tint.w` is 1): one light direction, a
// thin crisp rim line, one soft long highlight, a calm edge reflection, and a
// polished band for the chrome finishes. No softboxes, no horizon ring, no
// round glare spot. The classic model above and below does not change; this
// code runs only for a panel that asks for it (docs/glass-optics.md, "Apple-grade
// defaults").

/// 1 at `center`, falling smoothly to 0 `width` away from it.
static float gw_gw30_refined_bump(float x, float center, float width) {
    const float t = saturate(abs(x - center) / max(width, 1e-4));
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

/// How the surface at `N` faces a light whose direction in the panel plane is
/// `toward`: `lit` is 1 on the side toward the light, a quarter at right
/// angles, 0 on the far side; `back` is 1 on the far side and falls fast, the
/// faint echo of the light inside the glass.
static void gw_gw30_refined_facing(float3 N, float2 toward, thread float &lit, thread float &back) {
    const float len = length(N.xy);
    const float side = len > 1e-4 ? dot(N.xy / len, toward) : 0.0;
    const float a = saturate(0.5 + 0.5 * side);
    const float b = saturate(0.5 - 0.5 * side);
    lit = a * a;
    back = b * b * b * b;
}

/// One light's soft, long highlight: a narrow window of the surface tilt,
/// placed by the light's elevation (a low light lands near the wall, a high
/// one deeper) and never narrower than about a pixel and a half, that runs
/// along the rim and fades over the quarter turn to either side of the light.
static float3 gw_gw30_refined_highlight(
    float3 N, float4 direction, float4 color, float footprint, float clean, float depth, float thin)
{
    if (direction.w <= 0.0) {
        return float3(0.0);
    }
    const float planar = length(direction.xy);
    const float2 toward = planar > 1e-4 ? direction.xy / planar : float2(0.0, -1.0);
    float lit, back;
    gw_gw30_refined_facing(N, toward, lit, back);
    const float tilt = 1.0 - N.z;
    const float center = mix(0.55, 0.20, saturate(direction.z));
    const float width = max(clamp(1.6 * rsqrt(max(color.w, 1.0)), 0.14, 0.45), 1.5 * footprint);
    if (clean > 0.0) {
        // CLEAN: the window is one-sided. It rises smoothly with the surface
        // tilt (no start line) and stays up to the outline, so the highlight is
        // one gradient that falls off from the rim inward and not a ring that
        // sits a few pixels inside the hairline (a doubled line).
        const float rising = smoothstep(center - 1.6 * width, center + 1.2 * width, tilt);
        float window = mix(gw_gw30_refined_bump(tilt, center, width), 0.36 * rising, clean);
        if (thin > 0.0) {
            // CLEAN-2: the default rim is a hairline: the window is a function
            // of the exact depth, about 0.5 point wide at the outline, instead
            // of the tilt window that spreads over the bevel (the soft rim).
            window = mix(window, 0.36 * gw_gw30_thin_profile(depth, 1.9), thin);
        }
        return color.xyz * (direction.w * window * (lit * lit * lit + 0.1 * back));
    }
    return color.xyz * (direction.w * gw_gw30_refined_bump(tilt, center, width) * (lit * lit * lit + 0.1 * back));
}

/// The refined model's bright lines at a point inside the band, in linear
/// light before the knee: the rim line and the highlights of the key and rim
/// lights.
static float3 gw_gw30_refined_lines(float3 N, float depth, float thinDepth, constant GWGlassUniforms &uniforms) {
    constant GWLightingUniforms &lighting = uniforms.lighting;
    const float band = lighting.bandWidth;
    if (band <= 0.0 || depth >= band) {
        return float3(0.0);
    }
    const float mask = 1.0 - smoothstep(0.75 * band, band, depth);
    float lit, back;
    gw_gw30_refined_facing(N, lighting.edgeDirection, lit, back);
    const float tilt = 1.0 - N.z;
    const float t3 = tilt * tilt * tilt;
    const float3 tint = mix(float3(1.0), lighting.keyColor.xyz, 0.35);
    // A hairline: the surface at the outline is nearly upright. Lit side
    // bright, the sides faint, the far side a weak echo.
    const float clean = gw_gw30_clean_level(lighting);
    const float thin = gw_gw30_thin_rim(lighting);
    // CLEAN-2: the hairline's falloff is a function of the exact depth, a
    // Gaussian about 0.5 point wide, where the tilt's sixth power (the soft
    // rim) trails off over the whole bevel.
    float3 energy;
    if (thin > 0.0) {
        const float hairlineShape = mix(t3 * t3, 0.4 * gw_gw30_thin_profile(thinDepth, 1.6), thin);
        energy = tint * (lighting.fresnel * 0.25 * hairlineShape * (0.35 + 0.65 * lit) * (lighting.contrast > 0.0 ? 0.0 : 1.0));
    } else {
        energy = tint * (lighting.fresnel * 0.25 * t3 * t3 * lit * (lighting.contrast > 0.0 ? 0.0 : 1.0));
    }
    energy += (gw_gw30_refined_highlight(N, lighting.key, lighting.keyColor, lighting.footprint, clean, thinDepth, thin)
               + 0.6 * gw_gw30_refined_highlight(N, lighting.rim, lighting.rimColor, lighting.footprint, clean, thinDepth, thin))
              * (0.16 * lighting.specular);
    return energy * mask;
}

/// The refined look's optional enhancements (`GlassLighting.edgeDepth`,
/// `.banding`, `.glints`). The host packs them as three 8-bit fields in
/// `lighting.prism.w`, which was zero padding that nothing read (the record's
/// layout is unchanged), and zero when none is on, so a panel without them
/// takes none of the paths below and is drawn as before.
struct GWBaselineGW30Enhance {
    float depth;
    float banding;
    float glints;
};

static GWBaselineGW30Enhance gw_gw30_enhance(constant GWLightingUniforms &lighting) {
    GWBaselineGW30Enhance e;
    const uint packed = uint(max(lighting.prism.w, 0.0) + 0.5);
    e.depth = float(packed & 255u) * (1.0 / 255.0);
    e.banding = float((packed >> 8) & 255u) * (1.0 / 255.0);
    e.glints = float((packed >> 16) & 255u) * (1.0 / 255.0);
    return e;
}

/// The thick slab (`edgeDepth`): across the bevel the glass is deeper, a
/// darker body, toward the side away from the light, and carries a faint inner
/// light on the lit side, both in the tilt window between the flat top and the
/// outline hairline. Inside the light model's band only.
static float3 gw_gw30_enhance_slab(
    float3 glass, float3 N, float depth, float pixelDepth, float bandMask, constant GWLightingUniforms &lighting,
    thread float &touched)
{
    float lit, back;
    gw_gw30_refined_facing(N, lighting.edgeDirection, lit, back);
    const float tilt = 1.0 - N.z;
    float wall = smoothstep(0.02, 0.32, tilt) * (1.0 - 0.45 * smoothstep(0.7, 0.95, tilt));
    const float clean = gw_gw30_clean_level(lighting);
    if (clean > 0.0) {
        // CLEAN: the shade is monotone in the tilt (no lighter notch just inside
        // the hairline, which read as a second line).
        wall = mix(wall, smoothstep(0.02, 0.5, tilt), clean);
    }
    const float thin = gw_gw30_thin_rim(lighting);
    if (thin > 0.0) {
        // CLEAN-2: the shade lives within a few pixels of the outline (the soft
        // rim keeps the shade across the bevel).
        wall = mix(wall, gw_gw30_thin_profile(pixelDepth, 2.6), thin);
    }
    const float away = 1.0 - lit;
    const float darkening = depth * 0.52 * wall * (0.16 + 0.84 * away) * bandMask;
    glass *= 1.0 - darkening;
    const bool dark = lighting.environment == GWLightingEnvironmentStudioDark;
    const float3 sky = dark ? float3(0.52, 0.55, 0.64) : float3(0.97, 0.975, 1.0);
    float inner = gw_gw30_refined_bump(tilt, 0.15, 0.15);
    if (clean > 0.0) {
        // CLEAN: the faint inner light rises toward the rim like the rest of it.
        inner = mix(inner, 0.7 * smoothstep(0.0, 0.5, tilt), clean);
    }
    if (thin > 0.0) {
        inner = mix(inner, 0.7 * gw_gw30_thin_profile(pixelDepth, 2.0), thin);
    }
    const float light = depth * (dark ? 0.20 : 0.13) * inner * lit * bandMask;
    glass += (1.0 - glass) * sky * light;
    touched = max(touched, max(darkening, light));
    return glass;
}

/// Reflection bands of a polished rim (`banding`): the metal is multiplied by
/// stripes that are even in the surface angle, as a ring that reflects a studio
/// of alternating light and dark panels, a little brighter toward the light.
static float3 gw_gw30_enhance_bands(float3 metal, float3 N, float banding, float lit, float clean) {
    const float theta = acos(clamp(N.z, 0.0, 1.0));
    if (clean > 0.0) {
        // CLEAN: a few wide, soft-edged bands (about one and a quarter periods
        // across the bevel, no thin dark stripe), a little brighter toward the
        // light: a polished ring, not a set of lines.
        const float soft = 0.5 + 0.5 * cos(theta * 5.2 - 0.9);
        const float legacy = 0.16 + 1.8 * smoothstep(0.2, 0.8, 0.5 + 0.5 * cos(theta * 10.0 - 1.4));
        const float shapedSoft = 0.52 + 0.78 * (soft * soft * (3.0 - 2.0 * soft));
        return metal * mix(1.0, mix(legacy, shapedSoft, clean) * (0.8 + 0.5 * lit), banding);
    }
    const float stripe = 0.5 + 0.5 * cos(theta * 10.0 - 1.4);
    // Polished bands: a deep dark stripe between bright ones, with crisp
    // transitions (a wider gap between the dark and the bright level).
    const float shaped = 0.16 + 1.8 * smoothstep(0.2, 0.8, stripe);
    return metal * mix(1.0, shaped * (0.8 + 0.5 * lit), banding);
}

/// Small glints of a polished rim (`glints`): narrow lobes around the rim at
/// fixed angles from the key light (one facing it, a weaker opposite, two faint
/// at the sides) in a narrow window of the surface tilt, in linear light
/// before the knee. White for chrome; the thin-film hue turns across each glint
/// under the prismatic finish.
static float3 gw_gw30_enhance_glints(float3 N, float glints, constant GWLightingUniforms &lighting) {
    const float clean = gw_gw30_clean_level(lighting);
    if (clean > 0.0) {
        // CLEAN: the same glints, broader (about twice the width) and calmer
        // (about 40 percent less peak), over a wider window of the tilt, so
        // they read as soft catches of light on a polished ring and not as
        // sparks. Opt-in finish only (glints are off by default).
        const float tiltC = 1.0 - N.z;
        float u = precise::atan2(N.x, -N.y) * (0.5 / M_PI_F) - lighting.azimuth * (0.5 / M_PI_F);
        u -= round(u);
        const float wide = 1.0 + clean;
        const float c0 = exp(-pow(u / (0.04 * wide), 2.0));
        const float c1 = 0.6 * exp(-pow((abs(u) - 0.5) / (0.06 * wide), 2.0));
        const float c2 = 0.35 * (exp(-pow((u - 0.26) / (0.04 * wide), 2.0)) + exp(-pow((u + 0.26) / (0.04 * wide), 2.0)));
        const float c3 = 0.42 * (exp(-pow((u - 0.13) / (0.022 * wide), 2.0)) + exp(-pow((u + 0.14) / (0.022 * wide), 2.0)));
        const float c4 = 0.32 * (exp(-pow((abs(u) - 0.38) / (0.024 * wide), 2.0)));
        const float softWindow = gw_gw30_refined_bump(tiltC, 0.3, 0.32);
        float3 tone = float3(1.0);
        if (lighting.finish == GWLightingFinishPrismatic) {
            // The hue turns with a periodic function of the angle (a plain
            // multiple of it jumps where the angle wraps, which showed as a
            // notch at the glint opposite the light).
            // The hue also turns slowly across the bevel (0.9 turns, where the
            // plain glint turned 3.4: that sweep compressed to a thin rainbow
            // stripe across the steep wall), at a calmer saturation.
            tone = gw_gw30_light_film(lighting.prism.z + 0.9 * tiltC + 0.28 * sin(2.0 * M_PI_F * u), 0.7 * max(lighting.prism.y, 0.95));
        } else {
            tone = mix(float3(1.0), lighting.tint.xyz, 0.5);
        }
        return tone * (glints * 2.0 * (c0 + c1 + c2 + c3 + c4) * softWindow);
    }
    const float tilt = 1.0 - N.z;
    float t = precise::atan2(N.x, -N.y) * (0.5 / M_PI_F) - lighting.azimuth * (0.5 / M_PI_F);
    t -= round(t);
    const float g0 = exp(-pow(t / 0.04, 2.0));
    const float g1 = 0.6 * exp(-pow((abs(t) - 0.5) / 0.06, 2.0));
    const float g2 = 0.35 * (exp(-pow((t - 0.26) / 0.04, 2.0)) + exp(-pow((t + 0.26) / 0.04, 2.0)));
    // Four more small glints (two near the key light, two near the far side),
    // narrower and fainter: a polished ring catches a few small sparks, not one.
    const float g3 = 0.42 * (exp(-pow((t - 0.13) / 0.022, 2.0)) + exp(-pow((t + 0.14) / 0.022, 2.0)));
    const float g4 = 0.32 * (exp(-pow((abs(t) - 0.38) / 0.024, 2.0)));
    const float window = gw_gw30_refined_bump(tilt, 0.3, 0.25);
    float3 color = float3(1.0);
    if (lighting.finish == GWLightingFinishPrismatic) {
        const float hue = lighting.prism.z + 3.4 * tilt + 1.6 * t;
        color = gw_gw30_light_film(hue, max(lighting.prism.y, 0.95));
    } else {
        color = mix(float3(1.0), lighting.tint.xyz, 0.5);
    }
    return color * (glints * 3.4 * (g0 + g1 + g2 + g3 + g4) * window);
}

/// The refined edge reflection: a smooth gradient, sky toward the light and
/// floor away from it, mixed in by a soft Fresnel term, so the rim reads as
/// the edge of a thick clear body. The chrome finishes add one soft reflective
/// band across the bevel (the polished edge), partly clear, with the thin-film
/// hue on the band and the rim line only. `touched` receives the mix.
static float3 gw_gw30_refined_edge(
    float3 glass, float3 N, float depth, float thinDepth, float bandMask, constant GWGlassUniforms &uniforms,
    thread float &touched)
{
    constant GWLightingUniforms &lighting = uniforms.lighting;
    if (lighting.reflection <= 0.0 || bandMask <= 0.0) {
        return glass;
    }
    float lit, back;
    gw_gw30_refined_facing(N, lighting.edgeDirection, lit, back);
    const float tilt = 1.0 - N.z;
    const bool dark = lighting.environment == GWLightingEnvironmentStudioDark;
    const float3 sky = dark ? float3(0.30, 0.31, 0.35) : float3(0.97, 0.975, 1.0);
    const float3 floorColor = dark ? float3(0.07, 0.07, 0.08) : float3(0.40, 0.41, 0.46);
    const float toward = saturate(0.12 + 0.88 * lit + 0.25 * back);
    const float3 reflected = mix(floorColor, sky, toward);
    // A soft Fresnel body near the wall and a crisp hairline at the outline: the
    // hairline is the sky on the lit side and the floor on the far side, so it
    // shows on light pages (a thin gray line) as well as on dark ones.
    const float t2 = tilt * tilt;
    const float soft = lighting.f0 + (1.0 - lighting.f0) * t2 * tilt * sqrt(tilt);
    // The hairline is a fixed one to two pixels at the outline, whatever the
    // profile, a little stronger on the lit side and on its echo opposite.
    const float hair = 1.0 - smoothstep(0.4, 1.8, depth);
    const float weight = 0.55 + 0.30 * lit + 0.45 * back;
    if (lighting.finish == GWLightingFinishDielectric) {
        const float thin = gw_gw30_thin_rim(lighting);
        if (thin <= 0.0) {
            const float body = saturate(soft * lighting.reflection * 0.5);
            const float line = saturate(hair * lighting.fresnel * 1.15 * weight);
            const float alpha = (1.0 - (1.0 - body) * (1.0 - line)) * bandMask;
            glass = mix(glass, reflected, alpha);
            touched = max(touched, alpha);
            return glass;
        }
        {
            // CLEAN-2: the default clean rim is a thin crisp hairline. There is
            // no Fresnel body (it mixed a sky or floor tint into the whole
            // bevel, a ten-point gradient) and the line is a Gaussian of the
            // exact depth about 0.7 point wide at half maximum, a little less
            // bright (the system glass's line is calm).
            const float softTerm = mix(soft, (1.0 - lighting.f0) * t2 * t2 * tilt, thin);
            const float hairTerm = mix(hair, gw_gw30_thin_profile(thinDepth, 2.0), thin);
            const float lineGain = mix(1.0, 0.42, thin);
            const float body = saturate(softTerm * lighting.reflection * 0.5);
            const float line = saturate(hairTerm * lighting.fresnel * 1.15 * weight * lineGain);
            const float alpha = (1.0 - (1.0 - body) * (1.0 - line)) * bandMask;
            glass = mix(glass, reflected, alpha);
            touched = max(touched, alpha);
            // The shade half of the system glass's line: a thin darker edge, a
            // little stronger on the side away from the light, so the outline
            // reads on a light page too (one light, one shade, one line).
            const float shade = thin * (dark ? 0.20 : 0.40) * gw_gw30_thin_profile(thinDepth, 1.3) * (0.85 + 0.15 * (1.0 - lit)) * bandMask;
            glass *= 1.0 - shade;
            touched = max(touched, shade);
            return glass;
        }
    }
    // The polished edge: across the bevel the reflected gradient runs from a
    // darker wall at the outline, through one soft bright band, to the clear
    // face. The wall is what makes the edge crisp on a light page.
    const float cleanEdge = gw_gw30_clean_level(lighting);
    const float band = cleanEdge > 0.0 ? mix(gw_gw30_refined_bump(tilt, 0.26, 0.20), gw_gw30_refined_bump(tilt, 0.30, 0.34), cleanEdge)
                                       : gw_gw30_refined_bump(tilt, 0.26, 0.20);
    const float wall = smoothstep(0.45, 0.85, tilt);
    const float3 wallColor = floorColor * (dark ? 1.0 : 0.78) * (0.7 + 0.6 * lit);
    float3 metal = mix(reflected * (0.75 + 0.25 * band), wallColor, wall) * lighting.tint.xyz;
    const GWBaselineGW30Enhance enhance = gw_gw30_enhance(lighting);
    if (enhance.banding > 0.0) {
        metal = gw_gw30_enhance_bands(metal, N, enhance.banding, lit, cleanEdge);
    }
    if (lighting.finish == GWLightingFinishPrismatic) {
        const float turn = precise::atan2(N.x, -N.y) * (0.5 / M_PI_F) - lighting.azimuth * (0.5 / M_PI_F);
        if (cleanEdge > 0.0) {
            // CLEAN: the hue is periodic around the ring (a multiple of the
            // wrapped angle jumped by a fraction of a turn at the seam, a visible
            // notch), turns slowly across the bevel, and the thin film lives in
            // the wide soft band, not on the steep wall, where it compressed to a
            // thin rainbow line.
            const float periodic = 0.5 - 0.5 * cos(2.0 * M_PI_F * turn);
            const float hueClean = lighting.prism.z + lighting.prism.x * periodic + 0.35 * (1.0 - N.z);
            const float filmWeight = mix(saturate(band + 0.5 * wall), saturate(band * (1.0 - 0.8 * wall) + 0.12 * wall), cleanEdge);
            metal *= mix(float3(1.0), gw_gw30_light_film(hueClean, lighting.prism.y), filmWeight);
        } else {
            const float hue = lighting.prism.z + lighting.prism.x * (turn - floor(turn)) + 0.5 * (1.0 - N.z);
            metal *= mix(float3(1.0), gw_gw30_light_film(hue, lighting.prism.y), saturate(band + 0.5 * wall));
        }
    }
    float alpha = lighting.reflection * smoothstep(0.01, 0.10, tilt) * (0.30 + 0.42 * band + 0.38 * wall) * bandMask;
    if (enhance.banding > 0.0) {
        // Stripes need a more opaque band to read; the glass still shows through.
        alpha = min(alpha * (1.0 + 0.55 * enhance.banding), 0.9 * bandMask);
    }
    glass = mix(glass, metal, alpha);
    touched = max(touched, alpha);
    return glass;
}

/// The glass with the light model composited: reflections of the studio on
/// the rim (glass mixed with the Fresnel reflection, or chrome or the
/// prismatic finish replacing it), then the bright lines and their bloom added
/// through the soft knee, `G + (1 - G) K(E)`, which never darkens a channel
/// and never exceeds 1. Returns the changed color and, in `touched`, whether
/// this pixel is changed at all (then it is dithered like the glow).
static float3 gw_gw30_light_model(
    float3 glass, float2 q, float depth, constant GWGlassUniforms &uniforms, float localLuma, thread float &touched)
{
    constant GWLightingUniforms &lighting = uniforms.lighting;
    const float band = lighting.bandWidth;
    const float reach = band + (lighting.bloom > 0.0 ? lighting.bloomWidth : 0.0);
    touched = 0.0;
    if (reach <= 0.0 || depth >= reach) {
        return glass;
    }
    float2 outward;
    const float3 N = gw_gw30_light_normal(q, uniforms, outward);
    float thinDepth = depth;
    if (uniforms.lensInlayCount > 0u && gw_gw30_thin_rim(lighting) > 0.0) {
        thinDepth = min(depth, gw_gw30_inlay_edge_depth(q, uniforms));
    }
    float bandMask = band > 0.0 ? 1.0 - smoothstep(0.75 * band, band, depth) : 0.0;
    if (uniforms.lensProfile == GWLensProfileRing && uniforms.lensBevel > 0.0 && gw_gw30_clean_level(lighting) > 0.0) {
        // CLEAN-2: the polished band of a ring enters over the first four and a
        // half pixels of either end of the ring (a quintic ramp of the exact
        // distance to the end, so the transition is smooth and antialiased):
        // with the normal alone, the reflection's opacity and the thin film's
        // hue rose from nothing to most of their value within a pixel, a hard
        // step of about 70 levels with a one-pixel colored line at it.
        const GWBaselineGW30ShapeSample ringShape = gw_gw30_shape_sample(q, uniforms);
        const float ringT = saturate(ringShape.lensDepth / uniforms.lensBevel);
        const float toEnd = min(ringT - (uniforms.lensProfileA - uniforms.lensProfileB),
                                (uniforms.lensProfileA + uniforms.lensProfileB) - ringT) * uniforms.lensBevel;
        bandMask *= gw_gw30_lens_smoother(0.0, 4.5, toEnd);
    }

    // The refined look (lighting.tint.w) has its own edge reflection and lines.
    const bool refined = lighting.tint.w > 0.5;

    // Reflections.
    if (refined) {
        const GWBaselineGW30Enhance enhance = gw_gw30_enhance(lighting);
        if (enhance.depth > 0.0 && bandMask > 0.0) {
            glass = gw_gw30_enhance_slab(glass, N, enhance.depth, thinDepth, bandMask, lighting, touched);
        }
        glass = gw_gw30_refined_edge(glass, N, depth, thinDepth, bandMask, uniforms, touched);
    } else if (lighting.reflection > 0.0 && bandMask > 0.0) {
        const float3 R = float3(2.0 * N.z * N.xy, 2.0 * N.z * N.z - 1.0);
        float3 base;
        float2 boxes;
        gw_gw30_studio(R, lighting.azimuth, lighting.environment, base, boxes);
        const float F = lighting.f0 + (1.0 - lighting.f0) * pow(1.0 - N.z, 5.0);
        if (lighting.finish == GWLightingFinishDielectric) {
            // The part of the reflectance that grows toward the outline is
            // boosted up to five times at `reflection` 1, so a studio shows on
            // glass as it does in a photograph of it; at N.z = 1 it is F0.
            const float reflectance = saturate(lighting.f0 + (F - lighting.f0) * (1.0 + 4.0 * lighting.reflection));
            const float alpha = reflectance * lighting.reflection * bandMask;
            glass = glass * (1.0 - alpha) + gw_gw30_light_knee(base + boxes.x + boxes.y) * alpha;
            touched = max(touched, alpha);
        } else {
            float3 environment = (base + boxes.x + boxes.y) * lighting.tint.xyz;
            if (lighting.finish == GWLightingFinishPrismatic) {
                const float turn = precise::atan2(N.x, -N.y) * (0.5 / M_PI_F) - lighting.azimuth * (0.5 / M_PI_F);
                const float hue = lighting.prism.z + lighting.prism.x * (turn - floor(turn)) + 0.5 * (1.0 - N.z);
                const float3 film = gw_gw30_light_film(hue, lighting.prism.y);
                const float3 mild = gw_gw30_light_film(hue, 0.25 * lighting.prism.y);
                environment = (base * mild + boxes.x * mix(float3(1.0), film, 0.5) + boxes.y * film) * lighting.tint.xyz;
            }
            const float metal = 0.85 + 0.15 * F;
            const float alpha = lighting.reflection * smoothstep(0.005, 0.08, 1.0 - N.z) * bandMask;
            glass = mix(glass, gw_gw30_light_knee(environment * metal), alpha);
            touched = max(touched, alpha);
        }
    }

    // The contrasting hairline (accessibility): the outline mixes toward light
    // on dark glass and toward dark on light glass.
    if (lighting.contrast > 0.0 && band > 0.0) {
        const float edge = 1.0 - N.z;
        const float edge2 = edge * edge;
        const float hairline = saturate(1.5 * lighting.fresnel * edge2 * edge2 * edge) * bandMask;
        const float luminance = dot(glass, float3(0.2126, 0.7152, 0.0722));
        if (localLuma >= 0.0) {
            // CLEAN: the polarity follows the luminance of the glass around the
            // pixel (a wide soft average, `localLuma`) through a smooth step, so
            // the line changes from light to dark gradually, over a stretch of
            // the outline, where a backdrop edge or grain crosses mid gray; with
            // a hard test at the pixel it broke into dashes. A floor on the
            // strength keeps it visible where the two polarities meet.
            const float blended = mix(luminance, localLuma, 0.75);
            const float polarity = smoothstep(0.36, 0.64, blended);
            const float3 target = mix(float3(0.96, 0.96, 0.98), float3(0.10, 0.10, 0.12), polarity);
            const float floorStrength = 1.0 - 0.25 * (1.0 - abs(2.0 * polarity - 1.0));
            const float strength = hairline * floorStrength;
            glass = mix(glass, target, strength);
            touched = max(touched, strength);
        } else {
            const float3 target = luminance > 0.5 ? float3(0.10, 0.10, 0.12) : float3(0.96, 0.96, 0.98);
            glass = mix(glass, target, hairline);
            touched = max(touched, hairline);
        }
    }

    // The bright lines, and the bloom spread along the surface from them.
    float3 energy = float3(0.0);
    if (refined) {
        energy = gw_gw30_refined_lines(N, depth, thinDepth, uniforms);
        const GWBaselineGW30Enhance enhance = gw_gw30_enhance(lighting);
        if (enhance.glints > 0.0 && bandMask > 0.0 && (lighting.finish == GWLightingFinishChrome || lighting.finish == GWLightingFinishPrismatic)) {
            energy += gw_gw30_enhance_glints(N, enhance.glints, lighting) * bandMask;
        }
    } else {
        energy = gw_gw30_light_lines(N, depth, uniforms);
    }
    if (lighting.bloom > 0.0 && lighting.bloomWidth > 0.0) {
        float3 spill = float3(0.0);
        for (uint i = 1u; i <= 3u; ++i) {
            const float weight = (1.0 - float(i) * 0.25) * (1.0 - float(i) * 0.25);
            const float k = lighting.bloomWidth * float(i) * 0.25;
            for (uint side = 0u; side < 2u; ++side) {
                const float2 tap = q + outward * (side == 0u ? k : -k);
                const float tapDistance = gw_gw30_panel_distance(tap, uniforms);
                if (tapDistance > 0.0) {
                    continue;
                }
                float2 ignored;
                if (refined) {
                    spill += weight * gw_gw30_refined_lines(gw_gw30_light_normal(tap, uniforms, ignored), -tapDistance, -tapDistance, uniforms);
                } else {
                    spill += weight * gw_gw30_light_lines(gw_gw30_light_normal(tap, uniforms, ignored), -tapDistance, uniforms);
                }
            }
        }
        // The refined bloom is shorter in reach and strength: neutral, not neon.
        energy += spill * ((refined ? 0.4 : 0.6) * lighting.bloom);
    }
    if (energy.x > 0.0 || energy.y > 0.0 || energy.z > 0.0) {
        glass = glass + (1.0 - glass) * gw_gw30_light_knee(energy);
        touched = 1.0;
    }
    return glass;
}

// MARK: Presence (refined look)
//
// `GlassLighting.presence` (the level rides in `lighting.tint.w` as 1 + level,
// level 0...255): a livelier body and edge that add no bend. Everything here
// runs only for a refined panel whose level is above zero, so a panel without
// it is the shader above, byte for byte (the baseline tests prove it). Nothing
// moves a sample: the body is colored by a soft average of the backdrop around
// the pixel, never by an offset, and only where that backdrop is flat (a few
// taps of an edge, a dot or a character would show as ghost copies: the
// flatness gate, VERIFY-ROUND4). The one change to the picture's geometry is
// the opposite of a bend: a plain rim refraction is feathered to nothing at the
// outline, so the backdrop joins the glass without a step (docs/glass-optics.md,
// "Presence").

constant float3 gw_gw30_presence_luma = float3(0.2126, 0.7152, 0.0722);
/// The inner ring of the soft average: six points at unit distance.
constant float2 gw_gw30_presence_inner[6] = {
    float2(1.0, 0.0), float2(0.5, 0.8660254), float2(-0.5, 0.8660254),
    float2(-1.0, 0.0), float2(-0.5, -0.8660254), float2(0.5, -0.8660254),
};
/// The outer ring, turned by a twelfth of a turn so the rings interleave.
constant float2 gw_gw30_presence_outer[6] = {
    float2(0.8660254, 0.5), float2(0.0, 1.0), float2(-0.8660254, 0.5),
    float2(-0.8660254, -0.5), float2(0.0, -1.0), float2(0.8660254, -0.5),
};

/// The presence level, 0...1.
static float gw_gw30_presence_level(constant GWLightingUniforms &lighting) {
    // The presence is the low byte; CLEAN's level rides above it.
    const uint packed = uint(max(lighting.tint.w - 1.0, 0.0) + 0.5);
    return float(packed & 255u) * (1.0 / 255.0);
}

/// A soft average of the backdrop around `pixel`, in linear light (`xyz`), and
/// how flat the backdrop is around it (`w`, 1 flat, 0 an edge, a dot or a
/// character): thirteen bilinear samples (the center, six on a ring at half the
/// radius, six on a ring at the radius). Thirteen taps are a faithful average
/// only where the backdrop is smooth; across a hard edge or a small colored
/// feature they would show as faint ghost copies and as a halo that washes the
/// feature out, so the caller scales the pickup by `w`. The measure is the
/// largest distance of any one sample, and of the backdrop the glass shows
/// (`seen`, which a lens may have taken from somewhere else), from the average,
/// relative to the local light level: grain and slow shading stay below it, a single
/// sample that hits an edge or a dot, or a bent view that no longer matches the
/// undisturbed surroundings, is far above it.
static float4 gw_gw30_presence_ambient(
    float2 pixel, float radius, float3 seen, constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source,
    thread float &ratio)
{
    const float3 center = gw_gw30_glass_sample(pixel, uniforms, source);
    float3 taps[12];
    float3 sum = 2.0 * center;
    for (uint i = 0u; i < 6u; ++i) {
        taps[i] = gw_gw30_glass_sample(pixel + (0.5 * radius) * gw_gw30_presence_inner[i], uniforms, source);
        taps[6u + i] = gw_gw30_glass_sample(pixel + radius * gw_gw30_presence_outer[i], uniforms, source);
        sum += taps[i] + 0.7 * taps[6u + i];
    }
    const float3 average = sum * (1.0 / 12.2);
    float spread = max(length(center - average), length(seen - average));
    for (uint i = 0u; i < 12u; ++i) {
        spread = max(spread, length(taps[i] - average));
    }
    const float scale = 0.06 + dot(average, gw_gw30_presence_luma);
    ratio = spread / scale;
    return float4(average, 1.0 - smoothstep(0.10, 0.32, ratio));
}

/// A lens inlay's shade: the dome's side away from the light darkens a little
/// toward its base, its lit side lifts, and a faint contact shade falls on the
/// glass beside it, away from the light. The inlay's own rim light
/// (`rimLine`) is added later with the other edge lights.
static float3 gw_gw30_presence_inlays(float3 glass, float2 q, float level, float3 sky, constant GWGlassUniforms &uniforms) {
    constant GWLightingUniforms &lighting = uniforms.lighting;
    for (uint i = 0u; i < min(uniforms.lensInlayCount, 2u); ++i) {
        constant GWLensInlay &inlay = uniforms.lensInlays[i];
        const float bevel = inlay.shape.x;
        const float2 offset = q - inlay.geometry.xy;
        const float radius = inlay.geometry.z;
        const float r = length(offset);
        if (bevel <= 0.0 || r >= radius + 0.5 * bevel + 2.0) {
            continue;
        }
        const float2 toward = r > 1e-4 ? offset / r : float2(0.0);
        const float facing = dot(toward, lighting.edgeDirection);
        const float far = saturate(0.5 - 0.5 * facing);
        const float near = saturate(0.5 + 0.5 * facing);
        if (r < radius) {
            const float t = saturate((radius - r) / bevel);
            const float tilt = smoothstep(0.0, 0.7, 1.0 - t);
            glass *= 1.0 - level * 0.32 * tilt * far * far;
            glass += (1.0 - glass) * sky * (level * 0.22 * tilt * near * near);
        } else {
            const float s = exp(-(r - radius) / (0.18 * bevel + 1.0));
            glass *= 1.0 - level * 0.22 * s * far * far;
        }
    }
    return glass;
}

/// The presence of a panel at one pixel: the body, the inner edge, the inlays.
///
/// Body: a gentle pickup of the backdrop's own color (14 percent in the middle,
/// 28 percent at the rim, of a slightly more vivid soft average of the backdrop,
/// times the flatness of the backdrop around the pixel, so it vanishes at an
/// edge or a dot), a small saturation lift (14 percent), and a luminance gain
/// that keeps the hue (12 percent on dark pages), a little more toward the
/// light. `shown` is what the glass shows of the backdrop before the tint and
/// the fill. Inner edge: a thin glow that falls
/// off within an eighth of the bevel, in the backdrop's hue brightened (a dark
/// backdrop has no hue to pick up, so it is the sky's), brighter on the side
/// toward the light, and a deeper far side: a soft shade just inside the
/// hairline. All proportional to `level`.
static float3 gw_gw30_presence_apply(
    float3 glass, float3 shown, float2 pixel, float2 q, float depth, float2 normal, float level,
    bool frosted, constant GWGlassUniforms &uniforms, texture2d<float, access::sample> source)
{
    constant GWLightingUniforms &lighting = uniforms.lighting;
    const bool dark = lighting.environment == GWLightingEnvironmentStudioDark;
    const float bevel = max(lighting.bevel, 1.0);
    const float inscribed = max(gw_gw30_panel_inscribed(uniforms), 1.0);
    const float radius = clamp(0.7 * bevel, 8.0, max(0.5 * inscribed, 8.0));
    float ratio;
    const float4 soft = gw_gw30_presence_ambient(pixel, radius, shown, uniforms, source, ratio);
    // Where the backdrop is flat the soft average; where it is not, what the
    // glass shows itself, so the glow's color and strength never follow the
    // taps' ghost pattern.
    const float3 ambient = mix(shown, soft.xyz, soft.w);
    const float ambientLuma = dot(ambient, gw_gw30_presence_luma);
    const float3 vivid = max(mix(float3(ambientLuma), ambient, 1.3), 0.0);
    const float3 sky = dark ? float3(0.62, 0.66, 0.78) : float3(0.97, 0.975, 1.0);

    // Body.
    const float cleanBody = gw_gw30_clean_level(lighting);
    if (cleanBody > 0.0 && !frosted) {
        // CLEAN-2: where the backdrop under the glass is only noise (a patch as
        // flat as the dither or grain of its source: the largest distance of any
        // tap from the average is a few percent of the light level), the body
        // shows the average of the taps in place of the one sample, so a clear
        // body is as smooth as the system glass's (the system glass blurs a
        // little; this smooths nothing that has any structure, because the gate
        // closes at 0.2 of the light level, where an edge, a dot or a character
        // starts). The tint's share of the glass is not the backdrop's.
        const float flatNoise = 1.0 - smoothstep(0.06, 0.20, ratio);
        glass += (soft.xyz - shown) * ((1.0 - uniforms.tint.w) * flatNoise * cleanBody);
    }
    const float rimness = 1.0 - smoothstep(0.0, 1.6 * bevel, depth);
    glass = mix(glass, vivid, level * mix(0.14, 0.28, rimness) * soft.w);
    const float luma = dot(glass, gw_gw30_presence_luma);
    glass = max(mix(float3(luma), glass, 1.0 + 0.14 * level), 0.0);
    const float across = clamp(dot(q, lighting.edgeDirection) / max(length(uniforms.panelHalfSize), 1.0), -1.0, 1.0);
    // The lift is mostly a gain (it keeps the hue; an added gray would
    // desaturate a dark color), with a trace of the sky's light.
    const float gain = level * (dark ? 0.12 : 0.04) * (1.0 + 0.5 * across);
    glass = min(glass * (1.0 + gain), 1.0);
    glass += (1.0 - glass) * sky * (level * 0.012);

    // Inner edge.
    const float side = dot(normal, lighting.edgeDirection);
    const float a = saturate(0.5 + 0.5 * side);
    const float b = saturate(0.5 - 0.5 * side);
    const float lit = a * a;
    const float back = b * b;
    const float peak = max(max(vivid.x, vivid.y), vivid.z);
    const float3 hue = vivid / max(peak, 1e-3);
    const float chroma = saturate(peak * 6.0);
    const float3 glowColor = mix(sky, mix(sky, hue, 0.6), chroma);
    // Thin (a tenth of the bevel and a pixel and a half); half as strong on a
    // light page, where a white glow would read as milk, and weaker over a
    // backdrop that is nearly black, where there is no color to pick up.
    const float thin = gw_gw30_thin_rim(lighting);
    const float backdropLight = mix(0.5, 1.0, saturate(ambientLuma * 6.0));
    if (thin > 0.0) {
        // CLEAN-2: the thin rim narrows the glow to a hairline's reach and calms
        // it (the lit side's glow and the line of the light model add up).
        const float edgeThin = exp(-depth / mix(0.12 * bevel + 1.5, 1.2, thin));
        glass += (1.0 - glass) * glowColor * (level * edgeThin * (dark ? 1.0 : 0.55) * backdropLight * mix(0.06 + 0.38 * lit, 0.14 + 0.30 * lit, thin) * mix(1.0, 0.18, thin));
    } else {
        const float edge = exp(-depth / (0.12 * bevel + 1.5));
        glass += (1.0 - glass) * glowColor * (level * edge * (dark ? 1.0 : 0.55) * backdropLight * (0.06 + 0.38 * lit));
    }
    float inner = smoothstep(0.4, 2.5, depth) * exp(-depth / (0.3 * bevel + 2.0));
    const float clean = gw_gw30_clean_level(lighting);
    if (clean > 0.0) {
        // CLEAN: the far side's deeper shade starts at the outline and falls off
        // from there, in one smooth gradient with the glow: no dark crease a few
        // pixels inside the hairline. CLEAN-2: with the thin rim the fall-off is
        // a hairline's too.
        inner = mix(inner, 0.9 * exp(-depth / (thin > 0.0 ? mix(0.34 * bevel + 2.0, 1.6, thin) : 0.34 * bevel + 2.0)), clean);
    }
    glass *= 1.0 - level * 0.30 * back * inner;

    if (gw_gw30_optics && uniforms.lensInlayCount > 0u) {
        glass = gw_gw30_presence_inlays(glass, q, level, sky, uniforms);
    }
    return glass;
}

/// CLEAN-2: the depth fraction `w` (0 at the outline, 1 at the deepest point)
/// of a pixel with the crease of the distance field removed. The distance to a
/// rectangle's or a capsule's outline has a medial axis, a ridge where the
/// nearest edge changes, and the pooled light of a light field (and its center
/// fade), a function of `w`, showed it as a thin diagonal crease at the inner
/// corners. The signed distance is averaged over thirteen points of a disk of
/// a third of the inscribed radius (exact where the distance is linear, so the
/// light near the outline does not move), which turns the ridge into a smooth
/// crest. Only the clean look and the triangular dither use it.
static float gw_gw30_light_smooth_w(float2 q, float minHalf, constant GWGlassUniforms &uniforms) {
    const float radius = clamp(0.32 * minHalf, 3.0, 60.0);
    float sum = -2.0 * gw_gw30_panel_distance(q, uniforms);
    for (uint i = 0u; i < 6u; ++i) {
        sum -= gw_gw30_panel_distance(q + (0.5 * radius) * gw_gw30_presence_inner[i], uniforms);
        sum -= 0.7 * gw_gw30_panel_distance(q + radius * gw_gw30_presence_outer[i], uniforms);
    }
    return saturate(sum * (1.0 / 12.2) / minHalf);
}

// MARK: Grounding (GW-25)
//
// Depth cues for panels on light pages (docs/glass-optics.md): a drop shadow,
// a contact shadow, an inner shadow, and a colored caustic, all analytic from
// the panel's rounded-rectangle field and all driven by one direction, away
// from the key light (`grounding.shadowDirection`). The code exists only in
// the `grounded` pipeline variant, built with function constant 2
// (`gw_gw30_grounding_constant`); without it everything here is compiled out and
// the shader is the one of GW-23, byte for byte (a frozen copy in the tests
// proves it).
//
// Two passes make a grounded panel. Before any panel body, a pre-pass draws
// one quad per grounded panel, blended onto the background that is already in
// the target: the drop and contact shadows by *multiplying* the encoded value
// (`gw_gw30_grounding_shadow_fragment`), then the caustic by *adding* to it
// (`gw_gw30_grounding_caustic_fragment`). Both blend in the encoded `bgra8Unorm`
// target, so they are encoded-space operations; a multiply there approximates
// a multiply in linear light. The body (below) leaves every pixel outside its
// outline to the pre-pass, so a neighbour's shadow is never erased, and
// composites its antialiased ring over whatever the target holds.

constant bool gw_gw30_grounding_constant [[function_constant(2)]];
constant bool gw_gw30_grounding = is_function_constant_defined(gw_gw30_grounding_constant) ? gw_gw30_grounding_constant : false;

/// A Gaussian-blurred half-plane's coverage at signed distance `d` from its
/// edge (positive outside): 0.5 at the edge, 1 deep inside, 0 far outside,
/// `0.5 erfc(d / (sigma sqrt 2))`. Abramowitz and Stegun 7.1.26 for `erf`.
static float gw_gw30_blur_edge(float d, float sigma) {
    const float x = d / (max(sigma, 0.25) * 1.41421356);
    const float t = 1.0 / (1.0 + 0.3275911 * abs(x));
    const float poly = ((((1.061405429 * t - 1.453152027) * t + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t;
    const float tail = 0.5 * poly * exp(-x * x);
    return x >= 0.0 ? tail : 1.0 - tail;
}

/// What the drop and contact shadows multiply the encoded background by at a
/// pixel, per channel: 1 for no shadow, below 1 where shadowed. Never above 1.
static float3 gw_gw30_grounding_multiplier(float2 pixel, constant GWGlassUniforms &uniforms) {
    constant GWGroundingUniforms &g = uniforms.grounding;
    const float2 q = pixel - uniforms.panelCenter;
    float3 multiplier = float3(1.0);
    if (g.dropColor.w > 0.0) {
        // The outline moved away from the light, grown by the spread, with a
        // Gaussian edge: the blurred shadow of a rounded rectangle.
        const float d = gw_gw30_panel_distance(q - g.shadowDirection * g.dropOffset, uniforms) - g.dropSpread;
        const float s = g.dropColor.w * gw_gw30_blur_edge(d, g.dropSigma);
        multiplier *= 1.0 - s * (1.0 - g.dropColor.xyz);
    }
    if (g.contactColor.w > 0.0 && g.contactWidth > 0.0) {
        // A tight, dark line where the glass meets the page: full at the
        // outline, falling quadratically over `contactWidth` pixels.
        const float d = gw_gw30_panel_distance(q - g.shadowDirection * g.contactOffset, uniforms);
        const float c = saturate(1.0 - d / g.contactWidth);
        multiplier *= 1.0 - g.contactColor.w * c * c * (1.0 - g.contactColor.xyz);
    }
    return multiplier;
}

/// The caustic's light at a pixel, encoded, to add: a band of focused light
/// along the outline moved away from the light by `causticOffset`, strongest
/// where the outline faces away from the light, its red, green and blue parts
/// pulled apart by `causticDispersion` and its hue turning around the band by
/// `causticSpectrum`. Exactly zero three widths (and the dispersion) from the
/// band, and never negative.
static float3 gw_gw30_grounding_caustic(float2 pixel, constant GWGlassUniforms &uniforms) {
    constant GWGroundingUniforms &g = uniforms.grounding;
    if (g.causticColor.w <= 0.0 || g.causticWidth <= 0.0) { return float3(0.0); }
    const float2 q = pixel - uniforms.panelCenter - g.shadowDirection * g.causticOffset;
    const float d = gw_gw30_panel_distance(q, uniforms);
    const float reach = g.causticWidth * (3.0 + 1.2 * g.causticDispersion);
    if (abs(d) > reach) { return float3(0.0); }
    const float2 n = gw_gw30_panel_normal(q, uniforms.cornerRadius, uniforms);
    const float facing = saturate(dot(n, g.shadowDirection));
    if (facing <= 0.0) { return float3(0.0); }
    // The three wavelengths' bands sit at slightly different distances.
    const float3 x = (d + float3(-1.0, 0.0, 1.0) * g.causticDispersion * g.causticWidth * 0.55) / g.causticWidth;
    const float3 band = exp(-x * x);
    const float2 across = float2(-g.shadowDirection.y, g.shadowDirection.x);
    const float angle = atan2(dot(n, across), dot(n, g.shadowDirection));
    const float hue = 0.5 + 0.55 * angle / 6.2831853;
    const float3 rainbow = saturate(0.5 + 0.5 * cos(6.2831853 * (hue + float3(0.0, 1.0 / 3.0, 2.0 / 3.0))) * 1.15);
    const float3 color = g.causticColor.xyz * mix(float3(1.0), rainbow, g.causticSpectrum);
    return color * band * (g.causticColor.w * facing * facing);
}

static float3 gw_gw30_glass_decode_srgb(float3 encoded) {
    const float3 c = saturate(encoded);
    const float3 low = c / 12.92;
    const float3 high = pow((c + 0.055) / 1.055, float3(2.4));
    return select(high, low, c <= 0.04045);
}

/// The grounding's quad: the panel rectangle grown by `grounding.reach`.
vertex GWBaselineGW30GlassVertexOut gw_gw30_grounding_vertex(
    uint vertexID [[vertex_id]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    const float2 corner = float2(float(vertexID & 1u), float(vertexID >> 1u)) * 2.0 - 1.0;
    const float2 pixel = uniforms.panelCenter + corner * (uniforms.panelHalfSize + uniforms.grounding.reach);
    const float2 clip = float2(pixel.x / uniforms.targetSize.x * 2.0 - 1.0,
                               1.0 - pixel.y / uniforms.targetSize.y * 2.0);
    GWBaselineGW30GlassVertexOut out;
    out.position = float4(clip, 0.0, 1.0);
    return out;
}

/// The shadows' pre-pass fragment: the multiplier, blended as
/// `destination * source` (source factor zero, destination factor source
/// color).
fragment float4 gw_gw30_grounding_shadow_fragment(
    GWBaselineGW30GlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    float3 multiplier = gw_gw30_grounding_multiplier(in.position.xy, uniforms);
    if (gw_gw30_triangular(uniforms)) {
        // CLEAN: the product with the target is rounded to 8 bits by the blend,
        // so a soft shadow would step; the multiplier carries the triangular
        // dither (a step of the target is at most one, and less on a dark page,
        // where the shadow is faint anyway). The unshadowed 1 stays 1.
        // The noise fades in over the first three steps of shadow, so the
        // faint far tail (and the quad's edge) stays exactly 1.
        const float3 amount = smoothstep(float3(0.0), float3(3.0 / 255.0), 1.0 - multiplier);
        multiplier = min(multiplier + gw_gw30_dither_triangular(uint2(in.position.xy)) * amount, 1.0);
    }
    return float4(multiplier, 1.0);
}

/// The caustic's pre-pass fragment: the light, blended by addition.
fragment float4 gw_gw30_grounding_caustic_fragment(
    GWBaselineGW30GlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]])
{
    float3 light = gw_gw30_grounding_caustic(in.position.xy, uniforms);
    if (gw_gw30_triangular(uniforms)) {
        // CLEAN: the caustic's soft falloff is added to the 8-bit target, so it
        // carries the triangular dither too, faded in over its first three steps.
        const float3 amount = smoothstep(float3(0.0), float3(3.0 / 255.0), light);
        light = max(light + gw_gw30_dither_triangular(uint2(in.position.xy)) * amount, 0.0);
    }
    return float4(light, 0.0);
}

// MARK: Liquid and gel fill (GW-28)
//
// A luminous liquid or gel inside the glass vessel (docs/glass-optics.md). The
// code exists only in the `filled` pipeline variants, built with function
// constant 5 (`gw_gw30_fill_constant`) set; without it everything here is compiled
// out and the shader is the one before GW-28, byte for byte (a frozen copy in
// the tests proves it). The record is its own buffer (`GWFillUniforms`, bound at
// `GWGlassBindingIndexFill`), so `GWGlassUniforms` is unchanged. The CPU
// mirror of the region and the bubbles is `GlassFillModel`.
//
// The liquid is seen THROUGH the shell: its field is evaluated at the position
// the shell sends the pixel to (`q' = q + offset`, the thick lens's or the rim's
// refraction), so the wall magnifies and bends it. Coverage is cut in pixel
// space by the inset shell (the glass between the outline and the liquid), so
// no liquid is shallower than the wall.
//
// Body: the liquid's thickness is a parabolic dome `h = 1 - (1 - s)^2` over the
// depth `s` (the depth into the region over the dome radius), plus a slow field
// of luminous masses that drifts on small loops. The gradient of that height is
// a surface normal; one key light shades it (lit side brighter and yellower, far
// side a deeper amber) and a soft specular streak follows the lit wall. The
// surface also bends what is inside the liquid, so the edges magnify it. The
// background seen through the liquid is absorbed, `T = exp(-sigma * h * R)`
// (Beer-Lambert), and the liquid's own light follows the thickness along a
// three-stop ramp, screened over what is left. Contour sheets are iso-offsets
// of the depth, bent by noise, each with a thin bright caustic edge on the side
// that faces the light, a dark gap outside it and a lifted inside; edges, the
// streak and the bubbles' highlights are added through the light model's soft
// knee with an analytic bloom. A thin line in the wall at the inset boundary, a
// soft glow, a long reflection on the lit wall and a faint secondary rim on the
// far wall are the glass's part.

constant bool gw_gw30_fill_constant [[function_constant(5)]];
constant bool gw_gw30_filled = is_function_constant_defined(gw_gw30_fill_constant) ? gw_gw30_fill_constant : false;

/// The shell's refraction of a pixel as an offset in pixels: the thick lens's
/// (host profile, inlays) or the original rim's displacement.
static float2 gw_gw30_fill_shell_offset(
    float2 q, float2 rimNormal, float rimDisplacement, constant GWGlassUniforms &uniforms)
{
    if (gw_gw30_optics && gw_gw30_lens_active(uniforms)) {
        const GWBaselineGW30ShapeSample shape = gw_gw30_shape_sample(q, uniforms);
        GWBaselineGW30LensField field = gw_gw30_lens_host(shape, uniforms);
        gw_gw30_lens_add_inlays(q, uniforms, field);
        const float2 rim = uniforms.lensProfile == GWLensProfileRim ? -rimNormal * rimDisplacement : float2(0.0);
        return rim + gw_gw30_lens_offset(field, uniforms.lensIOR, uniforms);
    }
    return -rimNormal * rimDisplacement;
}

/// The gel's own shape: the signed distance (renormalized like the panel's,
/// negative inside) and the outward normal at `q`, relative to the gel's box.
static float3 gw_gw30_fill_gel(float2 q, constant GWShapeUniforms &shape, float2 halfSize) {
    GWBaselineGW30ShapeRaw raw;
    switch (shape.kind) {
    case GWShapeKindEllipse:
        raw = gw_gw30_shape_ellipse(q, halfSize);
        break;
    case GWShapeKindSuperellipse:
        raw = gw_gw30_shape_superellipse(q, halfSize, shape.exponent);
        break;
    default:
        raw = gw_gw30_shape_blob(q, shape);
        break;
    }
    const float length2 = length(raw.gradient);
    const float deep = saturate(-raw.distance / max(0.35 * shape.inscribedRadius, 1.0));
    const float distance = max(raw.distance / mix(max(length2, 0.3), 1.0, deep), -shape.inscribedRadius);
    return float3(distance, raw.gradient / max(length2, 1e-4));
}

/// The emissive ramp at a thickness 0...1: stops at 0, 1/2 and 1.
static float3 gw_gw30_fill_ramp(float t, constant GWFillUniforms &fill) {
    const uint count = uint(fill.detail.w + 0.5);
    if (count <= 1u) {
        return fill.ramp0.xyz;
    }
    if (count == 2u) {
        return mix(fill.ramp0.xyz, fill.ramp1.xyz, t);
    }
    return t < 0.5 ? mix(fill.ramp0.xyz, fill.ramp1.xyz, t * 2.0) : mix(fill.ramp1.xyz, fill.ramp2.xyz, (t - 0.5) * 2.0);
}

/// `v` as a unit vector; a (near) zero vector, as a panel's normal on its center
/// line, stays zero instead of turning into NaN.
static float2 gw_gw30_fill_unit(float2 v) {
    return v / max(length(v), 1e-4);
}

/// The smaller of two depths, blended smoothly over `k` pixels where they are
/// nearly equal (a polynomial smooth minimum), and never below 0.
static float gw_gw30_fill_smooth_depth(float a, float b, float k) {
    const float h = max(k - abs(a - b), 0.0) / k;
    return max(min(a, b) - h * h * k * 0.25, 0.0);
}

/// A slow, smooth field in 0...1 whose crests are the liquid's luminous masses.
/// `cell` is 1 over the size of the biggest mass in pixels; the two drifts (in
/// lattice units) move the two octaves on small loops, so the body flows.
static float gw_gw30_fill_lobes(float2 p, float cell, float2 driftA, float2 driftB, uint seed) {
    return 0.82 * gw_gw30_noise2(p * cell + driftA, int2(0), seed + 11u)
        + 0.18 * gw_gw30_noise2(p * cell * 2.3 + driftB + 9.3, int2(0), seed + 0x51ed270bu);
}

/// Composites the fill over `glass` (linear light) at `pixel`. `q` is the
/// pixel relative to the panel's center, `rimNormal` and `rimDisplacement` the
/// original rim's refraction, `depth` the pixel's depth inside the outline.
/// `touched` receives 1 where the fill changes the pixel (it is dithered like
/// the glow) and 0 elsewhere.
///
/// The liquid is a curved body: its height is the dome plus a slow field of
/// luminous masses, the gradient of that height is a surface normal, and one key
/// light shades it (a lit side that is brighter and yellower, a far side that is a
/// deeper amber, a soft specular streak a fixed depth inside the lit wall). The
/// surface bends what is inside the liquid (the sheets, the bubbles) like a
/// lens, so the edges magnify it.
static float3 gw_gw30_fill_apply(
    float3 glass, float2 pixel, float2 q, float2 rimNormal, float rimDisplacement, float depth,
    constant GWGlassUniforms &uniforms, constant GWFillUniforms &fill, thread float &touched)
{
    touched = 0.0;
    const bool gel = uint(fill.region.x + 0.5) == GWFillModeGel;
    const bool opaque = (fill.flags & GWFillFlagOpaque) != 0u;
    const float wall = fill.region.y;
    const float domeRadius = max(fill.region.z, 1.0);
    const float flow = fill.region.w;
    const float gloss = saturate(fill.padding0);
    const float2 lightDirection = (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone)
        ? uniforms.lighting.edgeDirection : gw_gw30_light_direction;
    const uint seed = uint(fill.detail.y);
    // The opt-in finish (`GlassFill.richness`): bits 8...15 of the flags. Zero
    // takes none of the terms below, and the fill is drawn as it was without it.
    const float richness = float((fill.flags >> 8u) & 255u) * (1.0 / 255.0);
    // CLEAN: the panel's refined look's clean level calms the fine structure
    // (the grain, the veins and the sheet edges become softer and fainter).
    const float cleanFill = (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone) ? gw_gw30_clean_level(uniforms.lighting) : 0.0;

    // Through the shell: the field is read where the shell sends this pixel.
    const float2 qf = q + gw_gw30_fill_shell_offset(q, rimNormal, rimDisplacement, uniforms);
    const float shellD = gw_gw30_panel_distance(qf, uniforms);
    const float insetD = shellD + wall;
    // The width of the smooth blends where two boundaries meet.
    const float blend = 0.22 * domeRadius + 2.0;

    // The region: its signed distance (negative inside), outward normal, and
    // how deep the liquid is there (the thickness's depth).
    float outsideD;
    float2 regionNormal;
    float boundaryD;
    float bodyDepth;
    float surfaceFade = 1.0;
    if (gel) {
        const float3 g = gw_gw30_fill_gel(qf - fill.gelBounds.xy, fill.gel, fill.gelBounds.zw);
        boundaryD = g.x;
        outsideD = g.x;
        // Where the gel meets the inset wall the depth and the normal blend
        // smoothly (a smooth minimum), so no crease or seam shows.
        bodyDepth = gw_gw30_fill_smooth_depth(-g.x, -insetD, blend);
        regionNormal = gw_gw30_fill_unit(mix(gw_gw30_panel_normal(qf, uniforms.normalRadius, uniforms), g.yz, smoothstep(-blend, blend, g.x - insetD)));
    } else {
        float levelD = -1.0e4;
        if ((fill.flags & GWFillFlagFull) == 0u) {
            const float k = 6.2831853 / max(fill.waves.y, 1.0);
            const float wave = fill.waves.x * (0.6 * sin(k * qf.x + fill.waves.z) + 0.4 * sin(k / 0.62 * qf.x + fill.waves.w));
            const float climb = fill.surface.z * exp(-max(-insetD, 0.0) / max(fill.surface.w, 1.0));
            const float surfaceY = fill.surface.x + fill.surface.y * qf.x + wave - climb;
            levelD = (surfaceY - qf.y) * rsqrt(1.0 + fill.surface.y * fill.surface.y);
        }
        boundaryD = levelD;
        outsideD = levelD;
        // The liquid is as deep as the vessel is, a little thinner right under
        // the surface (smoothly, as the gel's).
        bodyDepth = gw_gw30_fill_smooth_depth(-insetD, -levelD * 4.0, blend);
        surfaceFade = 0.80 + 0.20 * smoothstep(0.0, 0.3 * domeRadius, -levelD);
        regionNormal = gw_gw30_fill_unit(mix(
            gw_gw30_panel_normal(qf, uniforms.normalRadius, uniforms), normalize(float2(fill.surface.y, -1.0)),
            smoothstep(-blend, blend, -insetD + levelD * 4.0)));
    }

    // Where the liquid is, in pixel space: inside the inset shell and inside
    // the region (its own edge antialiased at the refracted position).
    const float insetPixel = gw_gw30_panel_distance(q, uniforms) + wall;
    const float shellCover = saturate(0.5 - insetPixel);
    const float cover = shellCover * saturate(0.5 - boundaryD);

    const float3 edgeColor = fill.ramp0.xyz;
    const float lineWidth = max(fill.sheets.z, 0.5);
    float3 energy = float3(0.0);
    float3 result = glass;

    if (cover > 0.0) {
        const float s = saturate(bodyDepth / domeRadius);
        const float h = 1.0 - (1.0 - s) * (1.0 - s);
        float3 liquid;
        if (opaque) {
            // One flat, opaque color (Reduce Transparency).
            liquid = fill.ramp1.xyz * (0.55 + 0.45 * fill.absorption.w);
        } else {
            // The luminous masses: a smooth field that drifts on small loops, so
            // the body is never one flat color and flows slowly. Its gradient
            // tilts the surface; none of it near the boundary, where the dome
            // alone shapes the edge.
            const float cell = 1.0 / max(1.25 * domeRadius, 8.0);
            const float2 driftA = 0.6 * float2(sin(flow), cos(flow));
            const float2 driftB = 0.6 * float2(cos(flow * 2.0 + 0.7), sin(flow * 2.0));
            // The masses are seen through the dome too: near the edge they are
            // read from deeper in, so they stretch and bend with the wall.
            const float slopeScale = 0.55;
            const float bendPixels = domeRadius * 0.42 * (fill.ior - 1.0);
            const float2 domeTilt = slopeScale * regionNormal * (2.0 * (1.0 - s));
            const float2 qm = qf - domeTilt * bendPixels;
            const float lobe = gw_gw30_fill_lobes(qm, cell, driftA, driftB, seed);
            const float eps = max(0.1 / cell, 2.0);
            const float lobeX = gw_gw30_fill_lobes(qm + float2(eps, 0.0), cell, driftA, driftB, seed);
            const float lobeY = gw_gw30_fill_lobes(qm + float2(0.0, eps), cell, driftA, driftB, seed);
            const float2 lobeGradient = float2(lobeX - lobe, lobeY - lobe) / eps;
            const float lobeWeight = smoothstep(0.0, 0.55, s);
            const float lobeAmplitude = 0.55;
            const float hEff = max(h + lobeAmplitude * lobeWeight * (lobe - 0.5), 0.0);

            // Fine internal structure (richness): a calm two-octave grain that
            // drifts slowly, and a few faint veins where a slower field crosses
            // its middle, both read through the dome like the masses.
            float grain = 0.0;
            float veins = 0.0;
            if (richness > 0.0) {
                // The grain runs along the contour: noise on a frame turned
                // with the region's boundary (stretched along it, finer across
                // it), so the body reads as flowing layers and not as clouds.
                // It fades toward the middle, where the frame has no direction.
                const float2 tangent = float2(-regionNormal.y, regionNormal.x);
                const float2 fineDrift = 0.9 * float2(cos(flow + 1.3), sin(flow + 0.4));
                const float2 frame = float2(dot(qm, tangent) * 0.34, dot(qm, regionNormal) * 1.5) * (cell * 3.0);
                const float n1 = gw_gw30_noise2(frame + fineDrift, int2(0), seed + 71u);
                const float n2 = gw_gw30_noise2(frame * float2(1.8, 2.2) + 7.7 - fineDrift, int2(0), seed + 97u);
                const float layered = smoothstep(0.03, 0.22, s) * (1.0 - smoothstep(0.5, 0.85, s));
                grain = ((n1 - 0.5) * 0.7 + (n2 - 0.5) * 0.3) * layered;
                const float v = gw_gw30_noise2(frame * 0.8 + driftB, int2(0), seed + 131u);
                const float ridge = saturate(1.0 - abs(2.0 * v - 1.0) * 5.0);
                veins = ridge * ridge * layered;
                if (cleanFill > 0.0) {
                    grain *= 1.0 - 0.7 * cleanFill;
                    veins *= 1.0 - 0.7 * cleanFill;
                }
            }

            // The surface normal: the dome's slope (steep at the boundary, flat
            // in the middle) and the masses' slope. `slopeScale` is how tall
            // the dome is against its radius.
            const float2 tilt = slopeScale * (regionNormal * (2.0 * (1.0 - s)) - domeRadius * lobeAmplitude * lobeWeight * lobeGradient);
            const float3 normal3 = normalize(float3(tilt, 1.0));

            // One key light, low over the screen: its half vector with the
            // viewer tilts 33 degrees toward the light, so the specular streak
            // follows the lit wall.
            const float3 toLight = normalize(float3(lightDirection * 0.914, 0.407));
            const float3 halfVector = normalize(toLight + float3(0.0, 0.0, 1.0));
            const float facingLight = dot(normal3, toLight) - 0.407;
            const float shade = clamp(1.0 + 0.55 * facingLight, 0.45, 1.35);

            // What lies inside the liquid is seen through its curved surface:
            // near the edge it is magnified, the sheets crowd toward the wall
            // and the bubbles are pushed outward.
            const float2 bendOffset = normal3.xy * bendPixels;
            const float depthBent = bodyDepth + max(dot(normal3.xy, regionNormal), 0.0) * bendPixels;
            const float2 qb = qf - bendOffset;

            const float3 transmittance = exp(-fill.absorption.xyz * (hEff * domeRadius));
            // The deepest part of a thick body glows hotter: a luminous core.
            // It saturates at the dome radius, where the body is flat, so the distance
            // field's ridges (the medial axis) never show as a crease.
            const float core = smoothstep(0.6 * domeRadius, 1.0 * domeRadius, bodyDepth);
            // Dark amber toward the walls, a calm glow in the thick middle.
            const float lum = (0.08 + 0.92 * pow(1.0 - exp(-2.4 * hEff), 1.3)) * (0.97 + 0.06 * lobe) * surfaceFade * shade * (1.0 + 0.14 * core)
                * (1.0 + richness * 0.48 * grain);
            const float t = saturate(hEff * hEff * (0.52 + 0.14 * lobe) + 0.18 * core + 0.30 * facingLight + richness * 0.12 * grain);
            liquid = glass * transmittance;
            const float3 emitted = gw_gw30_fill_ramp(t, fill) * (lum * fill.absorption.w);
            liquid = liquid + (1.0 - liquid) * saturate(emitted);

            // Contour sheets: nested membranes, iso-offsets of the depth seen
            // through the surface, bent by noise. Each has a thin, sharp
            // caustic edge on the lit side (the light falls off slowly inside
            // the sheet and quickly outside it), a soft dark gap just outside,
            // and a slightly brighter inside.
            const float edgeBrightness = fill.line.w;
            const float3 lineColor = fill.line.xyz;
            // The broad highlights are a saturated gold, not the pale of the
            // thin lines (which would wash the amber out to beige).
            const float3 goldColor = mix(fill.ramp1.xyz, fill.ramp2.xyz, 0.55);
            // Brighter edges stay warm (richness): a thin sheet edge that is
            // bright without being white-hot.
            const float3 edgeTint = mix(lineColor, goldColor, 0.40 * richness);
            const float edgeGain = 0.62 + 0.36 * richness;
            const float facing = dot(regionNormal, lightDirection);
            const float lit = 0.10 + 0.90 * pow(saturate(0.5 + 0.5 * facing), 1.6);
            float plate = 0.0;
            float gap = 0.0;
            for (uint i = 0u; i < min(uint(fill.sheets.x + 0.5), 4u); ++i) {
                const float bend = (gw_gw30_noise2(qf * fill.detail.x * 1.1, int2(0), seed + 31u * (i + 1u)) - 0.5) * 2.0 * fill.sheets.w;
                // The sheets crowd toward the lit wall and spread on the far one.
                const float spacing = fill.sheets.y * float(i + 1u) * (1.0 - 0.22 * facing);
                const float u = depthBent - spacing - bend;
                // Sheets near the middle (the distance field's ridge) fade out, so no
                // crease shows.
                const float ridge = 1.0 - smoothstep(0.55, 0.95, spacing / domeRadius);
                // Richness softens the sheets (PRESENCE): the thin edge widens
                // and loses some of its brightness, and the soft glow behind it
                // widens, so a sheet reads as a fold in one gel and not as a
                // contour line.
                float soften = 1.0 + 0.9 * richness;
                float sheetGain = 1.0;
                if (cleanFill > 0.0) {
                    // CLEAN: a wider, fainter edge, so a sheet reads as a fold
                    // in one gel and not as a contour line.
                    soften += 0.9 * cleanFill;
                    sheetGain = 1.0 - 0.5 * cleanFill;
                }
                const float width = (u < 0.0 ? lineWidth : 2.4 * lineWidth) * soften;
                const float edge = exp(-(u * u) / (width * width));
                const float bloom = exp(-(u * u) / (34.0 * soften * lineWidth * lineWidth * soften));
                if (cleanFill > 0.0) {
                    energy += (edgeTint * (edgeBrightness * lit * ridge * edgeGain * edge * (1.0 - 0.28 * richness)) + goldColor * (edgeBrightness * lit * ridge * (0.20 + 0.06 * richness) * bloom)) * sheetGain;
                } else {
                    energy += edgeTint * (edgeBrightness * lit * ridge * edgeGain * edge * (1.0 - 0.28 * richness)) + goldColor * (edgeBrightness * lit * ridge * (0.20 + 0.06 * richness) * bloom);
                }
                plate += ridge * 0.6 * smoothstep(-lineWidth, 5.0 * lineWidth, u);
                const float gapU = (u + 3.0 * lineWidth) / (2.6 * lineWidth);
                gap += ridge * (0.25 + 0.75 * lit) * exp(-gapU * gapU);
            }
            liquid = liquid * (1.0 - min(gap, 1.0) * 0.16);
            liquid = liquid + (1.0 - liquid) * (gw_gw30_fill_ramp(1.0, fill) * (0.07 * plate * fill.absorption.w));

            // Gloss: a soft specular streak (and a wider, weaker sheen) where
            // the surface faces the half vector, so the lit wall carries a long
            // smooth reflection that follows the liquid's edge.
            const float aligned = saturate(dot(normal3, halfVector));
            const float sheen = 0.85 * pow(aligned, 30.0) + 0.07 * pow(aligned, 6.0);
            energy += mix(goldColor, lineColor, 0.4) * (0.80 * gloss * sheen * surfaceFade);
            if (richness > 0.0) {
                // The key light on the liquid's own curved surface: one soft,
                // elongated window a fixed depth inside the lit boundary,
                // fading out along it over the quarter turn to either side, so
                // it reads as a reflection on a curved skin and never as a spot.
                const float litSide = pow(saturate(0.5 + 0.5 * facing), 3.2);
                const float windowU = (depthBent - 0.20 * domeRadius) / (0.13 * domeRadius + 2.0);
                const float window = exp(-windowU * windowU) * litSide * smoothstep(0.04, 0.30, s) * (0.7 + 0.3 * lobe);
                energy += mix(goldColor, float3(1.0, 0.96, 0.88), 0.72) * (1.7 * richness * gloss * window * surfaceFade);
                // Faint veins of light inside the body.
                energy += mix(goldColor, lineColor, 0.3) * (0.07 * richness * veins * (0.45 + 0.55 * lit) * surfaceFade);
            }
            // Light passing through the thin liquid at the far edge: a narrow
            // hot golden line a little inside the boundary, away from the light.
            const float farSide = pow(saturate(0.5 - 0.5 * facing), 2.0);
            const float transmitU = (bodyDepth - (0.07 * domeRadius + 2.0 * lineWidth)) / (0.045 * domeRadius + 2.0 * lineWidth);
            energy += goldColor * (0.30 * gloss * farSide * exp(-transmitU * transmitU) * surfaceFade);

            // The liquid's own edge: the surface line of a level (a glossy
            // meniscus, with a brighter band just under it) or the gel's
            // outline. Bright where it catches the light, faint on the far
            // side, where light passes through the thin liquid.
            const float rim = 0.16 + 0.84 * lit * lit;
            const float edgeLine = exp(-(boundaryD * boundaryD) / (lineWidth * lineWidth));
            const float edgeSoft = exp(-(boundaryD * boundaryD) / (16.0 * lineWidth * lineWidth));
            energy += edgeTint * (edgeBrightness * (0.55 + 0.24 * richness) * rim * edgeLine) + goldColor * (edgeBrightness * 0.08 * rim * edgeSoft);
            if (!gel) {
                const float below = (-boundaryD - 3.2 * lineWidth) / (2.6 * lineWidth);
                energy += lineColor * (gloss * 0.20 * (0.4 + 0.6 * lit) * exp(-below * below));
                energy += lineColor * (gloss * 0.30 * (0.4 + 0.6 * lit) * edgeLine);
            }

            // Bubbles: tiny, sparse, each a small darker disc of air with a
            // micro highlight toward the light and a fainter one opposite it.
            // No rings, no crescents.
            for (uint i = 0u; i < min(fill.bubbleCount, 16u); ++i) {
                const float4 bubble = fill.bubbles[i];
                const float2 offset = qb - bubble.xy;
                const float r = length(offset);
                if (r < bubble.z * 2.0) {
                    const float body = 1.0 - smoothstep(bubble.z * 0.82, bubble.z, r);
                    liquid = mix(liquid, liquid * 0.78 + lineColor * 0.035, body * 0.6 * bubble.w);
                    const float2 spot = offset - lightDirection * (bubble.z * 0.42);
                    const float spotR = length(spot) / max(bubble.z * 0.24, 0.6);
                    const float2 echo = offset + lightDirection * (bubble.z * 0.52);
                    const float echoR = length(echo) / max(bubble.z * 0.18, 0.5);
                    energy += lineColor * (bubble.w * (0.95 * exp(-spotR * spotR) + 0.22 * exp(-echoR * echoR)));
                }
            }
        }
        if (energy.x > 0.0 || energy.y > 0.0 || energy.z > 0.0) {
            liquid = liquid + (1.0 - liquid) * gw_gw30_light_knee(energy);
        }
        result = mix(glass, liquid, cover);
        touched = 1.0;
        energy = float3(0.0);
    }

    if (!opaque) {
        // The liquid lights the glass around it: a tight glow that continues
        // the liquid's own edge light outward, a wide, faint one that warms the
        // dark wall, and a thin line in the wall at the inset boundary, brighter
        // where the liquid is near and where the wall is steep. Outside the
        // liquid only. On top of that, two reflections along the glass: a soft,
        // long gradient on the lit wall, and a faint secondary rim on the far
        // one (the wall's inner face).
        const float outside = 1.0 - cover;
        const float reach = wall * 1.5 + 8.0;
        const float near = max(outsideD, 0.0);
        const float glow = 0.10 * exp(-near / (0.04 * domeRadius + 2.0)) + 0.04 * exp(-near / (0.25 * domeRadius + 6.0));
        const float presence = exp(-near / reach);
        float wallLine = exp(-((insetPixel - 0.6) * (insetPixel - 0.6)) / (1.8 * lineWidth * lineWidth));
        const float bezel = max(uniforms.bezelWidth, 1.0);
        const float steep = 0.45 + 0.55 * pow(1.0 - saturate(depth / bezel), 1.5);
        const float2 shellNormal = gw_gw30_panel_normal(q, uniforms.normalRadius, uniforms);
        const float shellFacing = dot(shellNormal, lightDirection);
        const float lit = 0.35 + 0.65 * pow(saturate(0.5 + 0.5 * shellFacing), 1.5);
        const float3 coolGray = float3(0.62, 0.66, 0.74);
        const float3 warmGray = mix(coolGray, fill.line.xyz, 0.35);
        const float litWall = pow(saturate(0.5 + 0.5 * shellFacing), 3.0);
        const float farWall = pow(saturate(0.5 - 0.5 * shellFacing), 3.0);
        const float longReflection = exp(-pow((depth - 0.42 * bezel) / (0.30 * bezel), 2.0));
        float farRim = exp(-pow((depth - 0.16 * bezel) / (0.06 * bezel + 1.0), 2.0));
        if (cleanFill > 0.0) {
            // CLEAN: the thin line at the inset boundary and the faint secondary
            // rim become wide, faint gradients (about two and a half times the
            // width, a little over half the strength), so the shell shows no
            // hairline across it.
            const float widen = 1.0 + 1.5 * cleanFill;
            wallLine = mix(wallLine, 0.6 * exp(-((insetPixel - 0.6) * (insetPixel - 0.6)) / (1.8 * lineWidth * lineWidth * widen * widen)), cleanFill);
            farRim = mix(farRim, 0.6 * exp(-pow((depth - 0.16 * bezel) / ((0.06 * bezel + 1.0) * widen), 2.0)), cleanFill);
        }
        // The finish's long reflection: a wide, smooth gradient of studio sky
        // along the lit outer wall, a little farther in than the line above.
        const float wideReflection = exp(-pow((depth - 0.50 * bezel) / (0.40 * bezel), 2.0));
        const float3 spillEnergy = edgeColor * (fill.absorption.w * glow * outside)
            + fill.line.xyz * (fill.detail.z * presence * wallLine * steep * lit * 0.55)
            + warmGray * (outside * (0.12 * litWall * longReflection + 0.05 * farWall * farRim) * (0.35 + 0.65 * gloss))
            + float3(0.74, 0.78, 0.88) * (outside * richness * 0.20 * litWall * wideReflection * (0.4 + 0.6 * gloss));
        if (spillEnergy.x > 0.0 || spillEnergy.y > 0.0 || spillEnergy.z > 0.0) {
            result = result + (1.0 - result) * gw_gw30_light_knee(spillEnergy);
            touched = 1.0;
        }
    }
    return result;
}

// MARK: Touch response (GW-12)
//
// A soft finger light that follows the touch, one ring that travels out from
// where the touch began and bends the backdrop a little, and a gleam on the
// outline nearest the finger. The code exists only in the touch pipeline
// variants: the host builds this function with `gw_gw30_touch_constant` (function
// constant 6) true for a panel with something to show for a touch that began
// inside it, and with it unset otherwise, in which case everything below is
// compiled out and the shader is the one before GW-12, byte for byte (a frozen
// copy in the tests proves it). A `GWTouchUniforms` record is bound only for
// those variants. The time is resolved on the CPU (`GlassTouch.state`): the
// record holds positions, radii and levels.
constant bool gw_gw30_touch_constant [[function_constant(6)]];
constant bool gw_gw30_touched = is_function_constant_defined(gw_gw30_touch_constant) ? gw_gw30_touch_constant : false;

/// How the rings move the background sample at `pixel`: a bump travelling
/// outward is a thin lens, so the sample moves along the ring's slope,
/// `-dir * amplitude * g(x)` with `g(x) = x exp(1/2 - x^2/2)` (peak 1 at
/// |x| = 1, so the shift never exceeds `ringAmplitude`) and `x` the distance
/// from the ring's crest in ring widths. The crest magnifies. Near the outline
/// the ring is softer, where the rim's own refraction already works.
static float2 gw_gw30_touch_offset(float2 pixel, float depth, constant GWGlassUniforms &uniforms, constant GWTouchUniforms &touch) {
    float2 offset = float2(0.0);
    const float edge = mix(0.35, 1.0, smoothstep(0.0, max(uniforms.bezelWidth, 1.0), depth));
    for (uint i = 0u; i < min(touch.count, 2u); ++i) {
        constant GWTouchPoint &point = touch.points[i];
        if (point.ringAmplitude > 0.0) {
            const float2 d = pixel - point.origin;
            const float r = length(d);
            const float x = (r - point.ringRadius) / point.ringWidth;
            if (abs(x) < 4.0) {
                const float g = x * exp(0.5 - 0.5 * x * x);
                offset -= (d / max(r, 1e-3)) * (point.ringAmplitude * g * edge);
            }
        }
    }
    return offset;
}

/// The finger light at `pixel`: a soft pool (one Gaussian) around each
/// finger, combined like light, scaled by the style's strength.
static float gw_gw30_touch_light(float2 pixel, constant GWTouchUniforms &touch) {
    float level = 0.0;
    for (uint i = 0u; i < min(touch.count, 2u); ++i) {
        constant GWTouchPoint &point = touch.points[i];
        const float x = length(pixel - point.position) / max(point.lightRadius, 1.0);
        if (point.light > 0.0 && x < 2.5) {
            const float profile = exp(-2.0 * x * x);
            level = 1.0 - (1.0 - level) * (1.0 - point.light * profile);
        }
    }
    return level * touch.fingerLight;
}

/// The ring's catch light: the ring's slope tilts the surface (`g(x)` along
/// the radial direction), and the side that faces the one light is brighter.
static float gw_gw30_touch_ring_light(float2 pixel, float2 lightDirection, constant GWTouchUniforms &touch) {
    float shine = 0.0;
    for (uint i = 0u; i < min(touch.count, 2u); ++i) {
        constant GWTouchPoint &point = touch.points[i];
        if (point.ringStrength > 0.0) {
            const float2 d = pixel - point.origin;
            const float r = length(d);
            const float x = (r - point.ringRadius) / point.ringWidth;
            if (abs(x) < 4.0) {
                const float g = x * exp(0.5 - 0.5 * x * x);
                shine += saturate(dot(g * d / max(r, 1e-3), lightDirection)) * point.ringStrength;
            }
        }
    }
    return min(shine, 1.0) * touch.ringShine;
}

/// The rim gleam at `pixel`, `depth` pixels inside the outline: a thin line on
/// the outline that is brightest at the point nearest the finger and fades along
/// the rim (`s - rimDistance` is how much farther than the nearest rim point
/// the pixel is from the finger), stronger the closer the finger is to the rim,
/// and brighter on the side that faces the light (`facing`).
static float gw_gw30_touch_gleam(float2 pixel, float depth, float facing, constant GWTouchUniforms &touch) {
    float level = 0.0;
    for (uint i = 0u; i < min(touch.count, 2u); ++i) {
        constant GWTouchPoint &point = touch.points[i];
        if (point.gleam > 0.0) {
            const float along = max(length(pixel - point.position) - point.rimDistance, 0.0) / max(touch.gleamWidth, 1.0);
            const float near = 1.0 - smoothstep(0.0, max(touch.gleamReach, 1.0), point.rimDistance);
            level = max(level, point.gleam * near * exp(-along * along));
        }
    }
    const float band = 1.0 - smoothstep(0.0, max(touch.gleamBand, 1.0), depth);
    return level * band * (0.35 + 0.65 * facing) * touch.gleamIntensity;
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
/// the side facing the light. With a glow (GW-17, `glowStopCount` > 0), the
/// glow layer is composited over that glass in linear light as a
/// premultiplied layer `(color * alpha, alpha)`. The outline is antialiased
/// over one pixel by mixing with the undisplaced background in linear light,
/// so the edge has no dark or bright fringe. Where the glow draws, a 4 x 4
/// ordered dither of at most 0.47 of an 8-bit step breaks up bands; where it
/// does not (and always without a glow) the output is exactly the glow-free
/// result. Every pixel is written opaque.
///
/// With a halo (GW-18, `glowHaloRadius` > 0), the part of each pixel
/// outside the outline is the background with the halo's light added: the
/// premultiplied light `L = color * haloAlpha` is screened over the
/// background in linear light, `background + L * (1 - background)` per
/// channel, with `haloAlpha = glowHaloIntensity * (1 - s / glowHaloRadius)^2
/// * light` at distance `s` outside the outline (zero from the radius on).
/// A halo therefore never darkens any channel of the background and never
/// exceeds 1; over black it is exactly `L`. The antialiased outline mixes
/// that with the glass, so rim and halo meet without a gap. The halo is
/// exactly zero from its radius on: such pixels skip it and write the
/// background sample, like the one-pixel ring around a panel without a
/// halo. Nothing is discarded, so the GPU's hidden-surface removal still
/// skips the background fragments the panel's opaque quad covers. Halo
/// pixels are dithered like the glow.
///
/// The glow's color and light (an angle by `precise::atan2`) are evaluated
/// only where the glow layer can be non-zero: inside the outline, within
/// the rim's and inner glow's reach or wherever a center fill is set;
/// outside it, within the halo radius. Elsewhere the layer is exactly
/// transparent, so skipping it changes no byte.
///
/// With an interior (GW-19, `interiorEffect` above 0), the interior's value
/// `e` (0...1) gives its light `L = ramp(e) * e * interiorIntensity * fade`,
/// with `fade = 1 - interiorCenterFade * smoothstep(0.3, 0.85, w)` for the
/// depth fraction `w` (depth over half the shorter side). `L` is screened
/// over the glowing glass in linear light, `G + L * (1 - G)`, before the
/// outline's antialiasing. Embers' sparks above the panel's center line and
/// within the halo radius outside the outline are screened over the haloed
/// background with `(1 - s / glowHaloRadius)^2` in place of the fade. The
/// pattern is evaluated only where `fade` is above 0. Pixels the interior
/// lights are dithered like the glow; elsewhere the bytes are those without
/// an interior.
///
/// With inner light (GW-21, `lightEmitterCount` above 0), each emitter's
/// light is composited over the glass and the interior, in order: its body
/// `intensity * profile * fade`, with the same `fade` as the interior's, and
/// its piping `lightPiping * intensity * pipe * (1 - depth / lightPipingWidth)^2`
/// in the rim band, combine as `a = 1 - (1 - body) * (1 - piping)`. `.light`
/// screens it, `G + color * a * (1 - G)`, which never darkens a channel;
/// `.paint` mixes toward the color by `min(a, 0.85)`. Pixels it lights are
/// dithered like the glow; elsewhere the bytes are those without light.
///
/// With the light model (GW-23, the `lighting` pipeline variant and
/// `lighting.finish` above 0), the panel's edge highlight and the inlays' rim
/// light follow the key light, and the model is composited last, over the glow,
/// the interior, and the inner light, inside the band `lighting.bandWidth`
/// deep (see "Light model" above). Pixels it changes are dithered like the
/// glow; elsewhere the bytes are those without it.
///
/// With grounding (GW-25, the `grounded` pipeline variant and
/// `grounding.flags` active), the body is composited over the target by
/// premultiplied alpha, `(encoded * coverage, coverage)`, so a pixel outside
/// the outline keeps what the pre-pass drew there (every panel's shadows and
/// caustics, a neighbour's included) and the antialiased ring mixes with it.
/// The inner shadow multiplies the glass (linear light) before the highlight,
/// the glow, the interior and the lights; the caustic is added, encoded, over
/// everything, so it continues the pre-pass's across the outline. Only where a
/// halo draws is a pixel written opaque, over the body's own shadowed
/// background: the halo replaces other panels' shadows under it.
fragment float4 gw_gw30_glass_fragment(
    GWBaselineGW30GlassVertexOut in [[stage_in]],
    constant GWGlassUniforms &uniforms [[buffer(GWGlassBindingIndexUniforms)]],
    texture2d<float, access::sample> source [[texture(GWGlassBindingIndexSourceTexture)]],
    constant GWFrostPanelUniforms &frost [[buffer(GWGlassBindingIndexFrost), function_constant(gw_gw30_frosted)]],
    texture2d<float, access::sample> pyramid [[texture(GWGlassBindingIndexFrostPyramid), function_constant(gw_gw30_frosted)]],
    constant GWFillUniforms &fill [[buffer(GWGlassBindingIndexFill), function_constant(gw_gw30_filled)]],
    constant GWTouchUniforms &touch [[buffer(GWGlassBindingIndexTouch), function_constant(gw_gw30_touched)]])
{
    const float2 pixel = in.position.xy;
    const float2 q = pixel - uniforms.panelCenter;
    const float distance = gw_gw30_panel_distance(q, uniforms);
    const float coverage = saturate(0.5 - distance);
    // CLEAN: the refined look's clean level, and whether this panel is dithered
    // with the triangular dither (every pixel) and not the ordered one.
    const float cleanLevel = (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone) ? gw_gw30_clean_level(uniforms.lighting) : 0.0;
    const bool triangular = uniforms.padding0 > 0.5 || cleanLevel > 0.0;
    float3 background = gw_gw30_glass_sample(pixel, uniforms, source);
    const bool grounded = gw_gw30_grounding && (uniforms.grounding.flags & GWGroundingFlagActive) != 0u;
    if (grounded && uniforms.glowHaloRadius > 0.0 && coverage < 1.0 && distance < uniforms.glowHaloRadius) {
        // The halo replaces the pre-pass's pixels, so it is drawn over this
        // panel's own shadow and caustic.
        const float3 shadowed = gw_gw30_glass_encode_srgb(background) * gw_gw30_grounding_multiplier(pixel, uniforms) + gw_gw30_grounding_caustic(pixel, uniforms);
        background = gw_gw30_glass_decode_srgb(shadowed);
    }

    // The halo, for the part of the pixel outside the outline.
    float haloAlpha = 0.0;
    float3 outside = background;
    if (uniforms.glowHaloRadius > 0.0 && coverage < 1.0 && distance < uniforms.glowHaloRadius) {
        const float4 shade = gw_gw30_glow_shade(q, uniforms);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        haloAlpha = uniforms.glowHaloIntensity * (1.0 - t) * (1.0 - t) * shade.w;
        outside = background + shade.xyz * haloAlpha * (1.0 - background);
    }
    // Embers' sparks that rise past the top half of the outline, within the
    // halo, are light over the haloed background (GW-19).
    float sparkAlpha = 0.0;
    if (uniforms.interiorEffect == GWInteriorEffectEmbers && uniforms.glowHaloRadius > 0.0
        && coverage < 1.0 && q.y < 0.0 && distance < uniforms.glowHaloRadius) {
        const float e = gw_gw30_interior_sparks(q / uniforms.interiorPixelsPerPoint, uniforms);
        const float t = saturate(max(distance, 0.0) / uniforms.glowHaloRadius);
        sparkAlpha = e * uniforms.interiorIntensity * (1.0 - t) * (1.0 - t);
        if (sparkAlpha > 0.0) {
            outside = outside + gw_gw30_interior_ramp(e, uniforms) * sparkAlpha * (1.0 - outside);
        }
    }
    if (coverage <= 0.0) {
        if (haloAlpha <= 0.0 && sparkAlpha <= 0.0) {
            // Grounded: leave the pre-pass's pixel alone.
            if (grounded) { return float4(0.0); }
            return float4(gw_gw30_glass_encode_srgb(background), 1.0);
        }
        if (triangular) {
            // CLEAN-2: a halo or a spark is a glow, a gradient that needs it.
            const float need = smoothstep(0.0, 0.03, max(haloAlpha, sparkAlpha));
            return float4(saturate(gw_gw30_glass_encode_srgb(outside) + gw_gw30_dither_triangular(uint2(pixel)) * need), 1.0);
        }
        const uint2 cell = uint2(pixel) & 3u;
        const float3 encoded = saturate(gw_gw30_glass_encode_srgb(outside) + ((gw_gw30_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
        return float4(encoded, 1.0);
    }

    const float depth = max(-distance, 0.0);
    const float rim = uniforms.bezelWidth > 0.0 ? saturate(1.0 - depth / uniforms.bezelWidth) : 0.0;
    const float2 normal = gw_gw30_panel_normal(q, uniforms.normalRadius, uniforms);
    // Presence (refined look): the level, 0 for every other panel.
    const float presenceLevel = (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone && uniforms.lighting.tint.w > 1.5)
        ? gw_gw30_presence_level(uniforms.lighting) : 0.0;
    float displacement = uniforms.maxDisplacement * rim * rim;
    if (presenceLevel > 0.0) {
        // The plain rim refraction is feathered: 0 at the outline, so the
        // backdrop joins the glass without a step; never above the plain value.
        displacement *= smoothstep(0.0, 0.22 * uniforms.bezelWidth, depth);
    }
    // A travelling ring bends the backdrop the glass shows (GW-12).
    float2 samplePixel = pixel;
    if (gw_gw30_touched) {
        samplePixel += gw_gw30_touch_offset(pixel, depth, uniforms, touch);
    }
    float3 glass;
    // Frost (GW-24b): how much of the pyramid this pixel shows.
    GWBaselineGW30FrostPixel frostPixel;
    frostPixel.sigma = 0.0;
    frostPixel.lod = 0.0;
    frostPixel.weight = 0.0;
    if (gw_gw30_frosted) {
        float heightFraction = 1.0;
        if (frost.thickness > 0.0 && gw_gw30_optics && uniforms.lensProfile != GWLensProfileRim && uniforms.lensThickness > 0.0) {
            heightFraction = saturate(gw_gw30_lens_host(gw_gw30_shape_sample(q, uniforms), uniforms).height / uniforms.lensThickness);
        }
        frostPixel = gw_gw30_frost_pixel(depth, q.y, heightFraction, frost);
    }
    if (gw_gw30_frosted && frostPixel.weight > 0.0) {
        if (gw_gw30_optics && gw_gw30_lens_active(uniforms)) {
            glass = gw_gw30_lens_glass_frosted(pixel, q, normal, displacement, frostPixel, uniforms, source, frost, pyramid);
        } else {
            glass = gw_gw30_frost_color(pixel - normal * displacement, frostPixel, uniforms, source, frost, pyramid);
        }
        glass = gw_gw30_frost_grade(glass, pixel, frostPixel, frost, cleanLevel);
    } else if (gw_gw30_optics && gw_gw30_lens_active(uniforms)) {
        // The thick lens (GW-22) replaces the rim refraction.
        glass = gw_gw30_lens_glass(samplePixel, q, normal, displacement, uniforms, source);
    } else {
        glass = gw_gw30_glass_sample(samplePixel - normal * displacement, uniforms, source);
    }
    // What the glass shows of the backdrop, before the tint and the fill: the
    // presence compares it with the undisturbed surroundings.
    const float3 shown = glass;

    glass = mix(glass, uniforms.tint.xyz, uniforms.tint.w);
    float innerShadow = 0.0;
    if (grounded && (uniforms.grounding.flags & GWGroundingFlagInner) != 0u) {
        // The inner shadow: the rim nearest the light shades the glass just
        // inside it, as an inset shadow moved away from the light.
        constant GWGroundingUniforms &g = uniforms.grounding;
        const float d = gw_gw30_panel_distance(q - g.shadowDirection * g.innerOffset, uniforms);
        const float s = g.innerColor.w * gw_gw30_blur_edge(d, g.innerSigma);
        glass = glass * (1.0 - s * (1.0 - g.innerColor.xyz));
        innerShadow = s;
    }
    // The liquid or gel fill (GW-28), seen through the shell, under every
    // light that follows.
    float fillAlpha = 0.0;
    if (gw_gw30_filled) {
        glass = gw_gw30_fill_apply(glass, pixel, q, normal, displacement, depth, uniforms, fill, fillAlpha);
    }
    // Presence (refined look): the body's backdrop pickup, the inner edge glow
    // and the inlays' shade, under the edge lights that follow.
    if (presenceLevel > 0.0) {
        glass = gw_gw30_presence_apply(glass, shown, pixel, q, depth, normal, presenceLevel, gw_gw30_frosted && frostPixel.weight > 0.0, uniforms, source);
    }
    // The edge light: the upper left, or the key light with the light model.
    const float2 edgeLight = (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone)
        ? uniforms.lighting.edgeDirection : gw_gw30_light_direction;
    const float facing = saturate(dot(normal, edgeLight));
    const float highlight = uniforms.edgeHighlight * rim * rim * rim * (0.4 + 0.6 * facing);
    glass = glass + (1.0 - glass) * highlight;
    if (gw_gw30_optics && uniforms.lensInlayCount > 0u) {
        glass = glass + (1.0 - glass) * gw_gw30_lens_inlay_highlight(q, edgeLight, uniforms);
    }

    float glowAlpha = 0.0;
    // Beyond the rim band and the inner glow's radius, with no center fill,
    // the glow layer's opacity is exactly zero. The 0.01 px margin keeps
    // pixels where approximate division might leave a residue in the
    // computed path, so the result is the same as always evaluating it.
    const float rimReach = uniforms.glowRimIntensity > 0.0 ? uniforms.glowRimWidth + uniforms.glowRimFeather : 0.0;
    const float glowReach = max(rimReach, uniforms.glowInnerRadius) + 0.01;
    if (uniforms.glowStopCount > 0u && (uniforms.glowCenterOpacity > 0.0 || depth < glowReach)) {
        const float4 glow = gw_gw30_glow(q, depth, uniforms);
        glowAlpha = glow.w;
        glass = mix(glass, glow.xyz, glowAlpha);
    }

    // The interior, light screened over the glowing glass (GW-19).
    float interiorAlpha = 0.0;
    if (uniforms.interiorEffect != GWInteriorEffectNone) {
        const float w = saturate(depth / gw_gw30_panel_inscribed(uniforms));
        const float fade = 1.0 - uniforms.interiorCenterFade * smoothstep(0.3, 0.85, w);
        if (fade > 0.0) {
            const float e = gw_gw30_interior_value(q, w, uniforms);
            interiorAlpha = e * uniforms.interiorIntensity * fade;
            if (interiorAlpha > 0.0) {
                glass = glass + gw_gw30_interior_ramp(e, uniforms) * interiorAlpha * (1.0 - glass);
            }
        }
    }

    // Inner light, over the glass, the glow, and the interior (GW-21).
    float lightAlpha = 0.0;
    if (uniforms.lightEmitterCount > 0u) {
        const float minHalf = max(gw_gw30_panel_inscribed(uniforms), 1e-3);
        float w = saturate(depth / minHalf);
        if (triangular) {
            w = gw_gw30_light_smooth_w(q, minHalf, uniforms);
        }
        const float fade = (1.0 - uniforms.lightCenterFade * smoothstep(0.3, 0.85, w)) * uniforms.lightBodyScale;
        const float pipeBand = uniforms.lightPipingWidth > 0.0 ? gw_gw30_light_falloff(depth / uniforms.lightPipingWidth) : 0.0;
        const float pipeScale = pipeBand * uniforms.lightPiping;
        if (fade > 0.0 || pipeScale > 0.0) {
            for (uint i = 0u; i < min(uniforms.lightEmitterCount, 4u); ++i) {
                constant GWLightEmitter &emitter = uniforms.lightEmitters[i];
                float pipe = 0.0;
                const float4 emitted = gw_gw30_light_emitter(q, depth, w, emitter, uniforms, pipe);
                const float body = emitted.w * emitter.intensity * fade;
                const float piping = pipe * pipeScale * emitter.intensity;
                const float alpha = 1.0 - (1.0 - body) * (1.0 - piping);
                if (alpha > 0.0) {
                    if (uniforms.lightComposite == GWLightCompositePaint) {
                        glass = mix(glass, emitted.xyz, min(alpha, gw_gw30_light_paint_cap));
                    } else {
                        glass = glass + emitted.xyz * alpha * (1.0 - glass);
                    }
                    lightAlpha = max(lightAlpha, alpha);
                }
            }
        }
    }

    // The touch response (GW-12): the finger's light, the ring's catch light and
    // the rim gleam, over everything below, under the light model.
    float touchAlpha = 0.0;
    if (gw_gw30_touched) {
        const float finger = gw_gw30_touch_light(pixel, touch);
        const float gleam = gw_gw30_touch_gleam(pixel, depth, facing, touch);
        const float shine = gw_gw30_touch_ring_light(pixel, edgeLight, touch);
        touchAlpha = 1.0 - (1.0 - finger) * (1.0 - gleam) * (1.0 - shine);
        if (touchAlpha > 0.0) {
            // The finger lifts the glass's own color toward white (a glass that
            // passes more light, not a gray fog laid over it); the gleam and the
            // ring's catch light are white.
            glass = glass + (1.0 - glass) * (finger * (0.3 + 0.9 * glass));
            const float white = 1.0 - (1.0 - gleam) * (1.0 - shine);
            glass = glass + (1.0 - glass) * white;
        }
    }

    // The light model (GW-23), over everything below, inside its band.
    float lightingAlpha = 0.0;
    if (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone) {
        // CLEAN: the contrasting hairline's polarity follows a wide average of
        // the backdrop around the pixel, taken only where the hairline draws.
        float localLuma = -1.0;
        if (cleanLevel > 0.0 && uniforms.lighting.contrast > 0.0 && depth < uniforms.lighting.bandWidth) {
            float sum = 0.0;
            const float reach = max(0.6 * uniforms.bezelWidth, 6.0);
            for (uint i = 0u; i < 6u; ++i) {
                sum += dot(gw_gw30_glass_sample(pixel + reach * gw_gw30_presence_inner[i], uniforms, source), gw_gw30_presence_luma);
            }
            // The glass around the pixel is the backdrop through the tint: for
            // an opaque panel (Reduce Transparency) it is the tint's luminance
            // and the contrasting hairline goes dark on it again (the soft gray
            // edge shade of the opaque look); following the backdrop alone put
            // a light line on a light panel and the shade disappeared.
            localLuma = mix(sum * (1.0 / 6.0), dot(uniforms.tint.xyz, gw_gw30_presence_luma), uniforms.tint.w);
        }
        glass = gw_gw30_light_model(glass, q, depth, uniforms, localLuma, lightingAlpha);
    }

    // The legibility scrim (GW-24b) is the last stage before the dither and the
    // encode, after every light term. Under a grounded caustic, which is added
    // to the encoded color, it runs after the caustic.
    bool frostTouched = gw_gw30_frosted && frostPixel.weight > 0.0;
    bool scrimmed = false;
    if (gw_gw30_frosted && (frost.flags & GWFrostFlagScrim) != 0u) {
        const bool caustic = grounded && haloAlpha <= 0.0 && sparkAlpha <= 0.0 && (uniforms.grounding.flags & GWGroundingFlagCaustic) != 0u;
        if (!caustic) {
            bool changed = false;
            glass = gw_gw30_frost_scrim(glass, pixel, frost, changed);
            frostTouched = frostTouched || changed;
            scrimmed = true;
        }
    }
    // CLEAN-2: how much of the triangular dither this pixel needs. A dither
    // hides the steps of a smooth gradient, so it goes where the shader makes
    // one (a glow, an interior, an inner light, a fill, the touch, an inner
    // shadow, a caustic, a frosted body, the halo) and not on a flat body: the
    // system glass's body is flat (its neighbours differ by 0.1 to 0.2 levels)
    // and one 8-bit step of noise on it read as grain. The rim of the thin look
    // is steep (it changes by tens of levels in a pixel or two), so it needs
    // none either.
    float ditherNeed = 1.0;
    if (triangular) {
        const float thinRim = (gw_gw30_lighting && uniforms.lighting.finish != GWLightingFinishNone) ? gw_gw30_thin_rim(uniforms.lighting) : 0.0;
        float synthetic = max(max(glowAlpha, interiorAlpha), max(max(lightAlpha, touchAlpha), fillAlpha));
        synthetic = max(max(synthetic, innerShadow), lightingAlpha * (1.0 - thinRim));
        float glassNeed = frostTouched ? 1.0 : smoothstep(0.0, 0.03, synthetic);
        if (grounded && haloAlpha <= 0.0 && sparkAlpha <= 0.0 && (uniforms.grounding.flags & GWGroundingFlagCaustic) != 0u) {
            const float3 causticLight = gw_gw30_grounding_caustic(pixel, uniforms);
            glassNeed = max(glassNeed, smoothstep(0.0, 0.01, max(causticLight.x, max(causticLight.y, causticLight.z))));
        }
        const float outsideNeed = smoothstep(0.0, 0.03, max(haloAlpha, sparkAlpha));
        ditherNeed = max(glassNeed * coverage, outsideNeed * (1.0 - coverage));
    }
    if (grounded && haloAlpha <= 0.0 && sparkAlpha <= 0.0) {
        // Composited over the target by premultiplied alpha (see above).
        float3 encodedGlass = gw_gw30_glass_encode_srgb(glass);
        const float3 caustic = (uniforms.grounding.flags & GWGroundingFlagCaustic) != 0u ? gw_gw30_grounding_caustic(pixel, uniforms) : float3(0.0);
        bool causticScrimmed = false;
        if (gw_gw30_frosted && !scrimmed && (frost.flags & GWFrostFlagScrim) != 0u) {
            bool changed = false;
            const float3 lit = gw_gw30_glass_decode_srgb(saturate(encodedGlass + caustic));
            encodedGlass = gw_gw30_glass_encode_srgb(gw_gw30_frost_scrim(lit, pixel, frost, changed));
            frostTouched = frostTouched || changed;
            causticScrimmed = true;
        }
        if (triangular) {
            encodedGlass += gw_gw30_dither_triangular(uint2(pixel)) * ditherNeed;
        } else if (glowAlpha > 0.0 || interiorAlpha > 0.0 || lightAlpha > 0.0 || lightingAlpha > 0.0 || any(caustic > 0.0) || frostTouched || fillAlpha > 0.0 || touchAlpha > 0.0 || presenceLevel > 0.0) {
            const uint2 cell = uint2(pixel) & 3u;
            encodedGlass += ((gw_gw30_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0;
        }
        encodedGlass = causticScrimmed ? saturate(encodedGlass) : saturate(encodedGlass + caustic);
        return float4(encodedGlass * coverage, coverage);
    }
    float3 encoded = gw_gw30_glass_encode_srgb(mix(outside, glass, coverage));
    if (triangular) {
        encoded = saturate(encoded + gw_gw30_dither_triangular(uint2(pixel)) * ditherNeed);
    } else if (glowAlpha > 0.0 || haloAlpha > 0.0 || interiorAlpha > 0.0 || sparkAlpha > 0.0 || lightAlpha > 0.0 || lightingAlpha > 0.0 || frostTouched || fillAlpha > 0.0 || touchAlpha > 0.0 || presenceLevel > 0.0) {
        const uint2 cell = uint2(pixel) & 3u;
        encoded = saturate(encoded + ((gw_gw30_bayer[cell.x + 4u * cell.y] + 0.5) / 16.0 - 0.5) / 255.0);
    }
    return float4(encoded, 1.0);
}
