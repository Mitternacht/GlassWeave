#ifndef GLASSWEAVE_FROST_TYPES_H
#define GLASSWEAVE_FROST_TYPES_H

// Records for the frost pyramid (GW-24a). Included by the umbrella header
// GlassWeaveShaderTypes.h, so Swift and Metal see them like every other
// record. This header depends on nothing but simd: the source mapping is
// repeated field by field instead of embedding GWBackgroundUniforms, so it
// can be included first. Host layout is asserted in GlassWeaveFrostTypes.c.
//
// Experimental: the records and the pyramid geometry can change.

#include <simd/simd.h>
#ifndef __METAL_VERSION__
#include <stdint.h>
#endif

/// Binding indices of the pyramid kernels (compute).
typedef enum GWFrostBindingIndex {
    /// Buffer index of the kernel's uniform record.
    GWFrostBindingIndexUniforms = 0,
    /// Buffer index of the probe's input points.
    GWFrostBindingIndexPoints = 1,
    /// Buffer index of the probe's output colors.
    GWFrostBindingIndexResults = 2,
    /// Texture index of what a kernel reads: the source frame, the previous
    /// level, or the whole pyramid.
    GWFrostBindingIndexInput = 0,
    /// Texture index of what a kernel writes.
    GWFrostBindingIndexOutput = 1,
} GWFrostBindingIndex;

/// How a frosted shape's blur radius varies over the shape (`GlassFrost.Profile`).
typedef enum GWFrostProfile {
    /// The same blur everywhere.
    GWFrostProfileUniform = 0,
    /// Frosted at the outline, clear toward the middle.
    GWFrostProfileClearCenter = 1,
    /// Clear at the outline, frosted toward the middle.
    GWFrostProfileClearRim = 2,
    /// A blur that ramps from the shape's top to its bottom.
    GWFrostProfileVerticalRamp = 3,
} GWFrostProfile;

/// Where the pyramid sits in destination space. Every level covers the same
/// rectangle, so one normalized coordinate addresses all of them:
///     uv = (destinationPixel - regionOrigin) / coverSize
/// `coverSize` is level 0's size in texels times 2 (so at least the region,
/// rounded up to a multiple of 2^levelCount destination pixels).
///
/// Layout in bytes: regionOrigin 0, coverSize 8, levelCount 16, explicit
/// padding 20 (set to zero). Size 24, alignment 8, stride 24.
typedef struct GWFrostPyramidLayout {
    simd_float2 regionOrigin;
    simd_float2 coverSize;
    uint32_t levelCount;
    uint32_t padding0;
} GWFrostPyramidLayout;

/// One downsample dispatch: writes level `level`.
///
/// Level 0 reads the source frame through the background pass's mapping
/// (`uvFromDestinationX`, `uvFromDestinationY`, `uvOrigin`, `sampleClamp*`,
/// the same values as `GWBackgroundUniforms`, so the valid-rectangle clamp
/// holds) with 13 taps spaced one destination pixel apart. Every later level
/// reads the level before it with 13 taps spaced one of its texels apart.
///
/// - `regionOrigin`: destination pixel at the pyramid's top-left corner.
/// - `targetSize`: destination (render target) size in pixels.
/// - `outputSize`: texels of the level written.
/// - `inputTexelSize`: UV size of one texel of the level read (zero for
///   level 0).
/// - `outputSpacing`: destination pixels per texel of the level written.
///
/// Layout in bytes: uvFromDestinationX 0, uvFromDestinationY 8, uvOrigin 16,
/// sampleClampMin 24, sampleClampMax 32, regionOrigin 40, targetSize 48,
/// outputSize 56, inputTexelSize 64, outputSpacing 72, level 76.
/// Size 80, alignment 8, stride 80.
typedef struct GWFrostBuildUniforms {
    simd_float2 uvFromDestinationX;
    simd_float2 uvFromDestinationY;
    simd_float2 uvOrigin;
    simd_float2 sampleClampMin;
    simd_float2 sampleClampMax;
    simd_float2 regionOrigin;
    simd_float2 targetSize;
    simd_uint2 outputSize;
    simd_float2 inputTexelSize;
    float outputSpacing;
    uint32_t level;
} GWFrostBuildUniforms;

/// What the shader needs to find the blur radius of one frosted shape and to
/// read the pyramid for it. Shape fields are in destination pixels, like
/// `GWGlassUniforms`.
///
/// - `panelCenter`, `panelHalfSize`, `cornerRadius`: the shape's rounded
///   rectangle.
/// - `sigma`: the largest blur standard deviation, in destination pixels,
///   already limited to what the pyramid can filter.
/// - `transition`: for the two rim profiles, the distance over which the
///   blur ramps between clear and frosted, in pixels (at least 1).
/// - `rampTop`, `rampBottom`: vertical ramp, blur as a fraction of `sigma` at
///   the shape's top and bottom edges.
/// - `grain`: static grain amplitude, 0...1.
/// - `profile`: a `GWFrostProfile` value.
/// - `layout`: where the pyramid is.
///
/// Layout in bytes: panelCenter 0, panelHalfSize 8, cornerRadius 16,
/// sigma 20, transition 24, rampTop 28, rampBottom 32, grain 36, profile 40,
/// explicit padding 44 (set to zero), layout 48 (24 bytes).
/// Size 72, alignment 8, stride 72.
typedef struct GWFrostProfileUniforms {
    simd_float2 panelCenter;
    simd_float2 panelHalfSize;
    float cornerRadius;
    float sigma;
    float transition;
    float rampTop;
    float rampBottom;
    float grain;
    uint32_t profile;
    uint32_t padding0;
    GWFrostPyramidLayout layout;
} GWFrostProfileUniforms;

/// One probe request: a destination-pixel position and a level of detail.
///
/// Layout in bytes: position 0, lod 8, explicit padding 12 (set to zero).
/// Size 16, alignment 8, stride 16.
typedef struct GWFrostProbePoint {
    simd_float2 position;
    float lod;
    float padding0;
} GWFrostProbePoint;

/// The probe kernel's uniforms: how many points, and the pyramid's layout.
///
/// Layout in bytes: layout 0 (24 bytes), pointCount 24, explicit padding 28
/// (set to zero). Size 32, alignment 8, stride 32.
typedef struct GWFrostProbeUniforms {
    GWFrostPyramidLayout layout;
    uint32_t pointCount;
    uint32_t padding0;
} GWFrostProbeUniforms;

/// The laboratory atlas kernel's uniforms: one tile per pyramid level, then
/// one tile per frost profile (a map of the blur radius over a capsule),
/// laid out left to right in rows of `columns` tiles. The tiles after the
/// levels use the profile record with its `profile` field replaced by the
/// tile's own profile.
///
/// Layout in bytes: profile 0 (72 bytes), tileSize 72, levelTiles 80,
/// profileTiles 84, columns 88, explicit padding 92 (set to zero).
/// Size 96, alignment 8, stride 96.
typedef struct GWFrostAtlasUniforms {
    GWFrostProfileUniforms profile;
    simd_uint2 tileSize;
    uint32_t levelTiles;
    uint32_t profileTiles;
    uint32_t columns;
    uint32_t padding0;
} GWFrostAtlasUniforms;

/// Which parts of `GWFrostPanelUniforms` a draw uses (stored in its `flags`).
typedef enum GWFrostFlag {
    /// The pyramid is bound and the glass samples it (the blur is on).
    GWFrostFlagSampling = 1,
    /// The legibility scrim is on (GW-24b).
    GWFrostFlagScrim = 2,
} GWFrostFlag;

/// Everything one frosted panel's draw reads besides `GWGlassUniforms`
/// (GW-24b): the blur's profile and the pyramid's layout, the grade, and the
/// legibility scrim. It travels in its own fragment buffer
/// (`GWGlassBindingIndexFrost`), next to the pyramid texture
/// (`GWGlassBindingIndexFrostPyramid`), so `GWGlassUniforms` keeps its layout
/// and the frost variants are the only pipelines that read either.
///
/// - `profile`: the blur radius over the shape and the pyramid layout
///   (`GWFrostProfileUniforms`); its `grain` is the static grain amplitude.
/// - `thickness`: how much the blur follows the glass thickness, 0...1: the
///   radius is scaled by `1 - thickness + thickness * h / lensThickness`.
/// - `saturation`, `brightness`: the grade of the frosted color, in linear
///   light, 1 for none.
/// - `scrimRatio`: the contrast ratio the scrim guarantees, already including
///   the 1.03 margin; 1 or less when there is no scrim.
/// - `scrimTextLuminance`: the text's WCAG relative luminance, 0...1.
/// - `scrimFeather`: pixels beyond the rect over which the scrim fades out.
/// - `scrimCenter`, `scrimHalfSize`: the text rectangle, in destination
///   pixels.
/// - `flags`: `GWFrostFlag` bits.
///
/// Layout in bytes: profile 0 (72 bytes), thickness 72, saturation 76,
/// brightness 80, scrimRatio 84, scrimTextLuminance 88, scrimFeather 92,
/// scrimCenter 96, scrimHalfSize 104, flags 112, explicit padding 116, 120
/// and 124 (set to zero). Size 128, alignment 8, stride 128.
typedef struct GWFrostPanelUniforms {
    GWFrostProfileUniforms profile;
    float thickness;
    float saturation;
    float brightness;
    float scrimRatio;
    float scrimTextLuminance;
    float scrimFeather;
    simd_float2 scrimCenter;
    simd_float2 scrimHalfSize;
    uint32_t flags;
    uint32_t padding0;
    uint32_t padding1;
    uint32_t padding2;
} GWFrostPanelUniforms;

#endif // GLASSWEAVE_FROST_TYPES_H
