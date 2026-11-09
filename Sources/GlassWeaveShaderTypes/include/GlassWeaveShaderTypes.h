#ifndef GLASSWEAVE_SHADER_TYPES_H
#define GLASSWEAVE_SHADER_TYPES_H

// Records uploaded to the GPU. This header is the single definition: Swift
// imports it through the GlassWeaveShaderTypes module and Metal shaders
// include it by relative path. Fields use fixed-width scalars or documented
// simd vector types only (no Swift Int, Bool, optionals, or references).
//
// Host layout is asserted at compile time in GlassWeaveShaderTypes.c and by
// the package tests; the shader view of the same bytes is checked by a GPU
// round-trip test with distinctive values.

#include <simd/simd.h>
#ifndef __METAL_VERSION__
// Metal's standard library defines the fixed-width integer types itself.
#include <stdint.h>
#endif

/// Argument-table indices for the background presentation pass.
typedef enum GWBackgroundBindingIndex {
    /// Fragment buffer index of `GWBackgroundUniforms`.
    GWBackgroundBindingIndexUniforms = 0,
    /// Fragment texture index of the source texture.
    GWBackgroundBindingIndexSourceTexture = 0,
} GWBackgroundBindingIndex;

/// Per-draw parameters for presenting one background source frame.
///
/// Coordinate spaces:
/// - Destination UV: the render target, origin at its top-left corner,
///   x to the right, y downward, both in [0, 1].
/// - Source UV: the full source texture, normalized by its pixel extent,
///   origin at the top-left of texture memory (Metal's texture origin).
///
/// Matrix convention: an affine map stored as three column vectors,
///     sourceUV = uvFromDestinationX * d.x + uvFromDestinationY * d.y + uvOrigin
///
/// `sampleClampMin` and `sampleClampMax` bound the source UV, half a texel
/// inside the frame's valid rectangle, so linear filtering never reads a
/// texel outside that rectangle.
///
/// Layout in bytes: uvFromDestinationX 0, uvFromDestinationY 8, uvOrigin 16,
/// sampleClampMin 24, sampleClampMax 32. Size 40, alignment 8, stride 40.
typedef struct GWBackgroundUniforms {
    simd_float2 uvFromDestinationX;
    simd_float2 uvFromDestinationY;
    simd_float2 uvOrigin;
    simd_float2 sampleClampMin;
    simd_float2 sampleClampMax;
} GWBackgroundUniforms;

/// Argument-table indices for the glass panel pass. The panel pass reads the
/// same record from its vertex and fragment functions.
typedef enum GWGlassBindingIndex {
    /// Vertex and fragment buffer index of `GWGlassUniforms`.
    GWGlassBindingIndexUniforms = 0,
    /// Fragment texture index of the source texture.
    GWGlassBindingIndexSourceTexture = 0,
} GWGlassBindingIndex;

/// The procedural interior a glass panel draws (GW-19), stored in
/// `GWGlassUniforms.interiorEffect`. 0 draws no interior.
typedef enum GWInteriorEffect {
    GWInteriorEffectNone = 0,
    GWInteriorEffectEnergy = 1,
    GWInteriorEffectRays = 2,
    GWInteriorEffectEmbers = 3,
} GWInteriorEffect;

/// Per-draw parameters for one rounded glass panel, in target pixels.
///
/// Coordinate space: target pixels, origin at the top-left corner of the
/// render target, x to the right, y downward. A fragment's pixel center is
/// at (column + 0.5, row + 0.5). Points from the UI are converted to pixels
/// on the CPU before upload; nothing in this record is in points.
///
/// - `background`: the same destination-to-source mapping and sample clamp
///   the background pass uses, so the panel samples exactly the produced
///   frame the background shows.
/// - `targetSize`: render-target width and height in pixels.
/// - `panelCenter`, `panelHalfSize`: the panel rectangle.
/// - `cornerRadius`: outline corner radius, at most the smaller half size.
/// - `bezelWidth`: width of the curved rim inside the outline. Refraction
///   and edge illumination happen only inside it.
/// - `normalRadius`: corner radius of the field that orients the rim
///   normals, `max(cornerRadius, bezelWidth)`, so the refraction direction
///   has no seam where the rim is wider than the corner.
/// - `maxDisplacement`: refraction displacement at the outline, in pixels.
/// - `edgeHighlight`: peak edge illumination, as a fraction of the way to
///   white (already scaled by the documented maximum).
/// - `tint`: tint color in linear light (`xyz`) and tint strength (`w`).
///
/// Glow (GW-17), appended after the GW-05 fields, which keep their layout.
/// `glowStopCount` 0 disables the whole glow; every other glow field is then
/// zero. See docs/glow.md for the math.
/// - `glowColor0` … `glowColor3`: stop colors in linear light (`xyz`, `w`
///   zero), ordered by angle; unused stops are zero.
/// - `glowStopTurns`: stop angles in turns (0 at the top, clockwise), each in
///   [0, 1), ascending; unused lanes are zero.
/// - `glowLightDirection`: unit vector toward the light, y down.
/// - `glowStopCount`: number of stops, 0 to 4.
/// - `glowRimWidth`, `glowRimFeather`: rim band width and the width of its
///   soft inner edge, in pixels (the feather is at least 1 when the rim is
///   drawn).
/// - `glowRimIntensity`, `glowInnerIntensity`, `glowCenterOpacity`,
///   `glowDirectionality`: normalized, 0...1. The rim intensity is zero when
///   there is no rim.
/// - `glowInnerRadius`: inner glow reach, in pixels.
/// - `glowNormalRadius`: corner radius of the field that orients the light,
///   in pixels.
///
/// Halo (GW-18), appended after the GW-17 fields, which keep their layout.
/// - `glowHaloRadius`: how far the halo reaches outside the outline, in
///   pixels. 0 draws no halo and keeps the panel's quad at one pixel around
///   the outline; above 0 the quad grows by this much.
/// - `glowHaloIntensity`: halo opacity at the outline, 0...1, with the pulse
///   level at the draw's effect time already applied (the pulse also scales
///   `glowRimIntensity` and `glowInnerIntensity` on the CPU; the shader sees
///   no time).
///
/// Interior (GW-19), appended after the GW-18 fields, which keep their
/// layout. `interiorEffect` 0 disables the whole interior; every other
/// interior field is then zero. See docs/glow.md for the math.
/// - `interiorColor0` … `interiorColor2`: the color ramp in linear light
///   (`xyz`, `w` zero), faintest first; unused colors are zero.
/// - `interiorEffect`: a `GWInteriorEffect` value.
/// - `interiorColorCount`: 0 to 3.
/// - `interiorSeed`: picks the pattern; mixed into every hash.
/// - `interiorIntensity`: opacity of the brightest parts, 0...1.
/// - `interiorPhase`: interior time in seconds, in [0, 64): the effect time
///   times the speed, reduced on the CPU in double precision (every effect
///   repeats after 64 s of interior time).
/// - `interiorCenterFade`: 0...1, how much the interior fades toward the
///   middle.
/// - `interiorPixelsPerPoint`: the display scale, so the pattern is sized in
///   points.
/// - `interiorSparks`: embers only, the twelve sparks at this interior time,
///   computed on the CPU from the seed: center x and y in points from the
///   panel's center (y down), radius in points, and brightness 0...1 (0 is
///   not drawn). Zero for the other effects.
///
/// Layout in bytes: background 0 (40 bytes), targetSize 40, panelCenter 48,
/// panelHalfSize 56, cornerRadius 64, bezelWidth 68, normalRadius 72,
/// maxDisplacement 76, edgeHighlight 80, explicit padding 84, 88, 92 (set
/// to zero), tint 96; glowColor0 112, glowColor1 128, glowColor2 144,
/// glowColor3 160, glowStopTurns 176, glowLightDirection 192,
/// glowStopCount 200, glowRimWidth 204, glowRimFeather 208,
/// glowRimIntensity 212, glowInnerRadius 216, glowInnerIntensity 220,
/// glowCenterOpacity 224, glowDirectionality 228, glowNormalRadius 232,
/// explicit padding 236 (set to zero); glowHaloRadius 240,
/// glowHaloIntensity 244, explicit padding 248, 252 (set to zero);
/// interiorColor0 256, interiorColor1 272, interiorColor2 288,
/// interiorEffect 304, interiorColorCount 308, interiorSeed 312,
/// interiorIntensity 316, interiorPhase 320, interiorCenterFade 324,
/// interiorPixelsPerPoint 328, explicit padding 332 (set to zero),
/// interiorSparks 336 (12 × 16 bytes).
/// Size 528, alignment 16, stride 528.
typedef struct GWGlassUniforms {
    GWBackgroundUniforms background;
    simd_float2 targetSize;
    simd_float2 panelCenter;
    simd_float2 panelHalfSize;
    float cornerRadius;
    float bezelWidth;
    float normalRadius;
    float maxDisplacement;
    float edgeHighlight;
    float padding0;
    float padding1;
    float padding2;
    simd_float4 tint;
    simd_float4 glowColor0;
    simd_float4 glowColor1;
    simd_float4 glowColor2;
    simd_float4 glowColor3;
    simd_float4 glowStopTurns;
    simd_float2 glowLightDirection;
    uint32_t glowStopCount;
    float glowRimWidth;
    float glowRimFeather;
    float glowRimIntensity;
    float glowInnerRadius;
    float glowInnerIntensity;
    float glowCenterOpacity;
    float glowDirectionality;
    float glowNormalRadius;
    float padding3;
    float glowHaloRadius;
    float glowHaloIntensity;
    float padding4;
    float padding5;
    simd_float4 interiorColor0;
    simd_float4 interiorColor1;
    simd_float4 interiorColor2;
    uint32_t interiorEffect;
    uint32_t interiorColorCount;
    uint32_t interiorSeed;
    float interiorIntensity;
    float interiorPhase;
    float interiorCenterFade;
    float interiorPixelsPerPoint;
    float padding6;
    simd_float4 interiorSparks[12];
} GWGlassUniforms;

#endif // GLASSWEAVE_SHADER_TYPES_H
