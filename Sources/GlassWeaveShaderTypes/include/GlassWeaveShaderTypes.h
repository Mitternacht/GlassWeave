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

#endif // GLASSWEAVE_SHADER_TYPES_H
