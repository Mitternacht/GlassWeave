#include "GlassWeaveShaderTypes.h"

#include <stddef.h>

// Host-side layout of every uploaded record. A change here must be matched by
// the documented layout in the header, the Swift layout tests, and the
// shader round-trip test.
_Static_assert(sizeof(GWBackgroundUniforms) == 40, "GWBackgroundUniforms size");
_Static_assert(_Alignof(GWBackgroundUniforms) == 8, "GWBackgroundUniforms alignment");
_Static_assert(offsetof(GWBackgroundUniforms, uvFromDestinationX) == 0, "uvFromDestinationX offset");
_Static_assert(offsetof(GWBackgroundUniforms, uvFromDestinationY) == 8, "uvFromDestinationY offset");
_Static_assert(offsetof(GWBackgroundUniforms, uvOrigin) == 16, "uvOrigin offset");
_Static_assert(offsetof(GWBackgroundUniforms, sampleClampMin) == 24, "sampleClampMin offset");
_Static_assert(offsetof(GWBackgroundUniforms, sampleClampMax) == 32, "sampleClampMax offset");

_Static_assert(sizeof(GWGlassUniforms) == 112, "GWGlassUniforms size");
_Static_assert(_Alignof(GWGlassUniforms) == 16, "GWGlassUniforms alignment");
_Static_assert(offsetof(GWGlassUniforms, background) == 0, "background offset");
_Static_assert(offsetof(GWGlassUniforms, targetSize) == 40, "targetSize offset");
_Static_assert(offsetof(GWGlassUniforms, panelCenter) == 48, "panelCenter offset");
_Static_assert(offsetof(GWGlassUniforms, panelHalfSize) == 56, "panelHalfSize offset");
_Static_assert(offsetof(GWGlassUniforms, cornerRadius) == 64, "cornerRadius offset");
_Static_assert(offsetof(GWGlassUniforms, bezelWidth) == 68, "bezelWidth offset");
_Static_assert(offsetof(GWGlassUniforms, normalRadius) == 72, "normalRadius offset");
_Static_assert(offsetof(GWGlassUniforms, maxDisplacement) == 76, "maxDisplacement offset");
_Static_assert(offsetof(GWGlassUniforms, edgeHighlight) == 80, "edgeHighlight offset");
_Static_assert(offsetof(GWGlassUniforms, tint) == 96, "tint offset");
