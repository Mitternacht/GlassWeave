#include "GlassWeaveShaderTypes.h"

#include <stddef.h>

// Host-side layout of the frost records (GW-24a). A change here must be
// matched by the documented layout in GlassWeaveFrostTypes.h and by the
// Metal static_asserts in Frost.metal.
_Static_assert(sizeof(GWFrostPyramidLayout) == 24, "GWFrostPyramidLayout size");
_Static_assert(_Alignof(GWFrostPyramidLayout) == 8, "GWFrostPyramidLayout alignment");
_Static_assert(offsetof(GWFrostPyramidLayout, regionOrigin) == 0, "regionOrigin offset");
_Static_assert(offsetof(GWFrostPyramidLayout, coverSize) == 8, "coverSize offset");
_Static_assert(offsetof(GWFrostPyramidLayout, levelCount) == 16, "levelCount offset");

_Static_assert(sizeof(GWFrostBuildUniforms) == 80, "GWFrostBuildUniforms size");
_Static_assert(_Alignof(GWFrostBuildUniforms) == 8, "GWFrostBuildUniforms alignment");
_Static_assert(offsetof(GWFrostBuildUniforms, uvFromDestinationX) == 0, "build uvFromDestinationX offset");
_Static_assert(offsetof(GWFrostBuildUniforms, uvFromDestinationY) == 8, "build uvFromDestinationY offset");
_Static_assert(offsetof(GWFrostBuildUniforms, uvOrigin) == 16, "build uvOrigin offset");
_Static_assert(offsetof(GWFrostBuildUniforms, sampleClampMin) == 24, "build sampleClampMin offset");
_Static_assert(offsetof(GWFrostBuildUniforms, sampleClampMax) == 32, "build sampleClampMax offset");
_Static_assert(offsetof(GWFrostBuildUniforms, regionOrigin) == 40, "build regionOrigin offset");
_Static_assert(offsetof(GWFrostBuildUniforms, targetSize) == 48, "build targetSize offset");
_Static_assert(offsetof(GWFrostBuildUniforms, outputSize) == 56, "build outputSize offset");
_Static_assert(offsetof(GWFrostBuildUniforms, inputTexelSize) == 64, "build inputTexelSize offset");
_Static_assert(offsetof(GWFrostBuildUniforms, outputSpacing) == 72, "build outputSpacing offset");
_Static_assert(offsetof(GWFrostBuildUniforms, level) == 76, "build level offset");

_Static_assert(sizeof(GWFrostProfileUniforms) == 72, "GWFrostProfileUniforms size");
_Static_assert(_Alignof(GWFrostProfileUniforms) == 8, "GWFrostProfileUniforms alignment");
_Static_assert(offsetof(GWFrostProfileUniforms, panelCenter) == 0, "profile panelCenter offset");
_Static_assert(offsetof(GWFrostProfileUniforms, panelHalfSize) == 8, "profile panelHalfSize offset");
_Static_assert(offsetof(GWFrostProfileUniforms, cornerRadius) == 16, "profile cornerRadius offset");
_Static_assert(offsetof(GWFrostProfileUniforms, sigma) == 20, "profile sigma offset");
_Static_assert(offsetof(GWFrostProfileUniforms, transition) == 24, "profile transition offset");
_Static_assert(offsetof(GWFrostProfileUniforms, rampTop) == 28, "profile rampTop offset");
_Static_assert(offsetof(GWFrostProfileUniforms, rampBottom) == 32, "profile rampBottom offset");
_Static_assert(offsetof(GWFrostProfileUniforms, grain) == 36, "profile grain offset");
_Static_assert(offsetof(GWFrostProfileUniforms, profile) == 40, "profile profile offset");
_Static_assert(offsetof(GWFrostProfileUniforms, padding0) == 44, "profile padding0 offset");
_Static_assert(offsetof(GWFrostProfileUniforms, layout) == 48, "profile layout offset");

_Static_assert(sizeof(GWFrostProbePoint) == 16, "GWFrostProbePoint size");
_Static_assert(_Alignof(GWFrostProbePoint) == 8, "GWFrostProbePoint alignment");
_Static_assert(offsetof(GWFrostProbePoint, position) == 0, "probe position offset");
_Static_assert(offsetof(GWFrostProbePoint, lod) == 8, "probe lod offset");

_Static_assert(sizeof(GWFrostProbeUniforms) == 32, "GWFrostProbeUniforms size");
_Static_assert(_Alignof(GWFrostProbeUniforms) == 8, "GWFrostProbeUniforms alignment");
_Static_assert(offsetof(GWFrostProbeUniforms, layout) == 0, "probe layout offset");
_Static_assert(offsetof(GWFrostProbeUniforms, pointCount) == 24, "probe pointCount offset");

_Static_assert(sizeof(GWFrostAtlasUniforms) == 96, "GWFrostAtlasUniforms size");
_Static_assert(_Alignof(GWFrostAtlasUniforms) == 8, "GWFrostAtlasUniforms alignment");
_Static_assert(offsetof(GWFrostAtlasUniforms, profile) == 0, "atlas profile offset");
_Static_assert(offsetof(GWFrostAtlasUniforms, tileSize) == 72, "atlas tileSize offset");
_Static_assert(offsetof(GWFrostAtlasUniforms, levelTiles) == 80, "atlas levelTiles offset");
_Static_assert(offsetof(GWFrostAtlasUniforms, profileTiles) == 84, "atlas profileTiles offset");
_Static_assert(offsetof(GWFrostAtlasUniforms, columns) == 88, "atlas columns offset");
_Static_assert(GWFrostProfileUniform == 0 && GWFrostProfileClearCenter == 1 && GWFrostProfileClearRim == 2 && GWFrostProfileVerticalRamp == 3, "GWFrostProfile values");
