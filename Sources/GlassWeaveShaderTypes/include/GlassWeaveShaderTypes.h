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
/// Layout in bytes: background 0 (40 bytes), targetSize 40, panelCenter 48,
/// panelHalfSize 56, cornerRadius 64, bezelWidth 68, normalRadius 72,
/// maxDisplacement 76, edgeHighlight 80, explicit padding 84, 88, 92 (set
/// to zero), tint 96.
/// Size 112, alignment 16, stride 112.
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
} GWGlassUniforms;

#endif // GLASSWEAVE_SHADER_TYPES_H
