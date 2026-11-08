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
