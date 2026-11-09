#ifndef GLASSWEAVE_GLASS_FROST_H
#define GLASSWEAVE_GLASS_FROST_H

// Reading the frost pyramid and finding the blur radius of a frosted shape
// (GW-24a). Frost.metal builds the pyramid and uses these functions in its
// probe and atlas kernels; Glass.metal includes this file to sample it.
// Experimental. The math is described in docs/frost.md.

#include <metal_stdlib>
#include "../../GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h"

/// The blur standard deviation, in destination pixels, of the filtered image
/// at pyramid level `level` (0 is half resolution). Each level is the 13-tap
/// downsample of the one before it: a step has a variance of 1.75 texels of
/// its input (taps at 0, +-1 and +-2 texels, each a 2x2 bilinear average),
/// and the texel doubles every level, so the variance after level L is
/// 1.75 * (4^(L+1) - 1) / 3: 1.32, 2.96, 6.06, 12.2 and 24.4 pixels.
static inline float gw_frost_level_sigma(uint level) {
    return metal::sqrt(1.75 * (metal::pow(4.0, float(level) + 1.0) - 1.0) / 3.0);
}

/// The level of detail that filters with standard deviation `sigma` pixels:
/// the level index, interpolated in log sigma between the two levels around
/// it, clamped to the levels the pyramid has. Below `gw_frost_level_sigma(0)`
/// it is 0: a caller takes its single-sample path instead of blending toward
/// level 0.
static inline float gw_frost_lod(float sigma, uint levelCount) {
    float lod = 0.0;
    for (uint level = 0; level + 1 < levelCount; ++level) {
        const float low = metal::log2(gw_frost_level_sigma(level));
        const float high = metal::log2(gw_frost_level_sigma(level + 1));
        const float position = metal::log2(metal::max(sigma, 1.0e-4)) ;
        if (position >= high) {
            lod = float(level + 1);
        } else {
            lod = float(level) + metal::saturate((position - low) / (high - low));
            break;
        }
    }
    return lod;
}

/// One level of the pyramid at a destination-pixel position, reconstructed
/// with the cubic B-spline in four bilinear fetches (smooth, never negative,
/// and uniform stays uniform because the weights sum to one).
static inline float3 gw_frost_bspline(metal::texture2d<float> pyramid, uint level, float2 uv) {
    constexpr metal::sampler linearClamp(
        metal::filter::linear, metal::mip_filter::nearest, metal::address::clamp_to_edge);
    const float2 size = float2(pyramid.get_width(level), pyramid.get_height(level));
    const float2 coord = uv * size - 0.5;
    const float2 base = metal::floor(coord);
    const float2 f = coord - base;
    const float2 f2 = f * f;
    const float2 f3 = f2 * f;
    const float2 w0 = (1.0 - 3.0 * f + 3.0 * f2 - f3) / 6.0;
    const float2 w1 = (4.0 - 6.0 * f2 + 3.0 * f3) / 6.0;
    const float2 w2 = (1.0 + 3.0 * f + 3.0 * f2 - 3.0 * f3) / 6.0;
    const float2 w3 = f3 / 6.0;
    const float2 g0 = w0 + w1;
    const float2 g1 = w2 + w3;
    // Fetch positions that put the bilinear weights where the spline wants them.
    const float2 p0 = (base + 0.5 + w1 / g0 - 1.0) / size;
    const float2 p1 = (base + 0.5 + w3 / g1 + 1.0) / size;
    const float lod = float(level);
    const float3 c00 = pyramid.sample(linearClamp, float2(p0.x, p0.y), metal::level(lod)).rgb;
    const float3 c10 = pyramid.sample(linearClamp, float2(p1.x, p0.y), metal::level(lod)).rgb;
    const float3 c01 = pyramid.sample(linearClamp, float2(p0.x, p1.y), metal::level(lod)).rgb;
    const float3 c11 = pyramid.sample(linearClamp, float2(p1.x, p1.y), metal::level(lod)).rgb;
    return g0.y * (g0.x * c00 + g1.x * c10) + g1.y * (g0.x * c01 + g1.x * c11);
}

/// The filtered image at a destination-pixel position (pixel centers at
/// +0.5, the convention of `GWGlassUniforms`) and a level of detail: the
/// two levels around `lod`, blended. Positions outside the pyramid read its
/// edge. The color is in linear light.
///
/// With dispersion, take single taps at the shared level instead of calling
/// this once per channel.
static inline float3 gw_frost_sample(
    metal::texture2d<float> pyramid, GWFrostPyramidLayout layout, float2 position, float lod)
{
    const float2 uv = (position - layout.regionOrigin) / layout.coverSize;
    const float top = float(layout.levelCount - 1);
    const float clamped = metal::clamp(lod, 0.0, top);
    const uint lower = uint(metal::floor(clamped));
    const uint upper = metal::min(lower + 1u, layout.levelCount - 1u);
    const float3 a = gw_frost_bspline(pyramid, lower, uv);
    if (upper == lower) { return a; }
    return metal::mix(a, gw_frost_bspline(pyramid, upper, uv), clamped - float(lower));
}

/// One trilinear fetch of the pyramid at a destination-pixel position and a
/// level of detail: a single tap, for the dispersion paths that read the
/// pyramid several times per pixel at the one shared level of detail (GW-24b).
/// The levels are exact halves of each other, so the hardware's mip filter
/// blends the two around `lod`.
static inline float3 gw_frost_tap(
    metal::texture2d<float> pyramid, GWFrostPyramidLayout layout, float2 position, float lod)
{
    constexpr metal::sampler trilinear(
        metal::filter::linear, metal::mip_filter::linear, metal::address::clamp_to_edge);
    const float2 uv = (position - layout.regionOrigin) / layout.coverSize;
    const float top = float(layout.levelCount - 1);
    return pyramid.sample(trilinear, uv, metal::level(metal::clamp(lod, 0.0, top))).rgb;
}

/// How far a pixel is inside a rounded rectangle, in pixels (negative
/// outside). `p` is relative to the rectangle's center.
static inline float gw_frost_depth(float2 p, float2 halfSize, float cornerRadius) {
    const float radius = metal::min(cornerRadius, metal::min(halfSize.x, halfSize.y));
    const float2 q = metal::abs(p) - halfSize + radius;
    return radius - (metal::length(metal::max(q, 0.0)) + metal::min(metal::max(q.x, q.y), 0.0));
}

/// The same blur radius from a pixel's depth inside the shape (pixels, zero
/// outside) and its height `relativeY` below the shape's center, for shapes
/// that are not rounded rectangles (GW-24b): the glass shader passes its own
/// shape field's depth. The vertical ramp uses the profile's `panelHalfSize.y`.
static inline float gw_frost_sigma_at(GWFrostProfileUniforms frost, float depth, float relativeY) {
    const float ramp = metal::smoothstep(0.0, metal::max(frost.transition, 1.0), depth);
    switch (frost.profile) {
    case GWFrostProfileClearCenter:
        return frost.sigma * (1.0 - ramp);
    case GWFrostProfileClearRim:
        return frost.sigma * ramp;
    case GWFrostProfileVerticalRamp: {
        const float t = metal::saturate(relativeY / metal::max(2.0 * frost.panelHalfSize.y, 1.0) + 0.5);
        return frost.sigma * metal::mix(frost.rampTop, frost.rampBottom, t);
    }
    default:
        return frost.sigma;
    }
}

/// The blur standard deviation, in destination pixels, at `pixel` for a
/// frosted shape: `.uniform` is `sigma` everywhere; `.clearCenter` is `sigma`
/// at the outline and falls to zero `transition` pixels inside; `.clearRim`
/// is the reverse; `.verticalRamp` interpolates `rampTop` to `rampBottom`
/// (fractions of `sigma`) from the shape's top edge to its bottom edge.
static inline float gw_frost_sigma(GWFrostProfileUniforms frost, float2 pixel) {
    const float2 relative = pixel - frost.panelCenter;
    return gw_frost_sigma_at(frost, gw_frost_depth(relative, frost.panelHalfSize, frost.cornerRadius), relative.y);
}

#endif // GLASSWEAVE_GLASS_FROST_H
