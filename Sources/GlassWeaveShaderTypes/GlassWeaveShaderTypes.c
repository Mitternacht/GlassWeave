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

_Static_assert(sizeof(GWGlassUniforms) == 1008, "GWGlassUniforms size");
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
_Static_assert(offsetof(GWGlassUniforms, glowColor0) == 112, "glowColor0 offset");
_Static_assert(offsetof(GWGlassUniforms, glowColor1) == 128, "glowColor1 offset");
_Static_assert(offsetof(GWGlassUniforms, glowColor2) == 144, "glowColor2 offset");
_Static_assert(offsetof(GWGlassUniforms, glowColor3) == 160, "glowColor3 offset");
_Static_assert(offsetof(GWGlassUniforms, glowStopTurns) == 176, "glowStopTurns offset");
_Static_assert(offsetof(GWGlassUniforms, glowLightDirection) == 192, "glowLightDirection offset");
_Static_assert(offsetof(GWGlassUniforms, glowStopCount) == 200, "glowStopCount offset");
_Static_assert(offsetof(GWGlassUniforms, glowRimWidth) == 204, "glowRimWidth offset");
_Static_assert(offsetof(GWGlassUniforms, glowRimFeather) == 208, "glowRimFeather offset");
_Static_assert(offsetof(GWGlassUniforms, glowRimIntensity) == 212, "glowRimIntensity offset");
_Static_assert(offsetof(GWGlassUniforms, glowInnerRadius) == 216, "glowInnerRadius offset");
_Static_assert(offsetof(GWGlassUniforms, glowInnerIntensity) == 220, "glowInnerIntensity offset");
_Static_assert(offsetof(GWGlassUniforms, glowCenterOpacity) == 224, "glowCenterOpacity offset");
_Static_assert(offsetof(GWGlassUniforms, glowDirectionality) == 228, "glowDirectionality offset");
_Static_assert(offsetof(GWGlassUniforms, glowNormalRadius) == 232, "glowNormalRadius offset");
_Static_assert(offsetof(GWGlassUniforms, padding3) == 236, "padding3 offset");
_Static_assert(offsetof(GWGlassUniforms, glowHaloRadius) == 240, "glowHaloRadius offset");
_Static_assert(offsetof(GWGlassUniforms, glowHaloIntensity) == 244, "glowHaloIntensity offset");
_Static_assert(offsetof(GWGlassUniforms, padding4) == 248, "padding4 offset");
_Static_assert(offsetof(GWGlassUniforms, padding5) == 252, "padding5 offset");
_Static_assert(offsetof(GWGlassUniforms, interiorColor0) == 256, "interiorColor0 offset");
_Static_assert(offsetof(GWGlassUniforms, interiorColor1) == 272, "interiorColor1 offset");
_Static_assert(offsetof(GWGlassUniforms, interiorColor2) == 288, "interiorColor2 offset");
_Static_assert(offsetof(GWGlassUniforms, interiorEffect) == 304, "interiorEffect offset");
_Static_assert(offsetof(GWGlassUniforms, interiorColorCount) == 308, "interiorColorCount offset");
_Static_assert(offsetof(GWGlassUniforms, interiorSeed) == 312, "interiorSeed offset");
_Static_assert(offsetof(GWGlassUniforms, interiorIntensity) == 316, "interiorIntensity offset");
_Static_assert(offsetof(GWGlassUniforms, interiorPhase) == 320, "interiorPhase offset");
_Static_assert(offsetof(GWGlassUniforms, interiorCenterFade) == 324, "interiorCenterFade offset");
_Static_assert(offsetof(GWGlassUniforms, interiorPixelsPerPoint) == 328, "interiorPixelsPerPoint offset");
_Static_assert(offsetof(GWGlassUniforms, padding6) == 332, "padding6 offset");
_Static_assert(offsetof(GWGlassUniforms, interiorSparks) == 336, "interiorSparks offset");
_Static_assert(GWInteriorEffectNone == 0 && GWInteriorEffectEnergy == 1 && GWInteriorEffectRays == 2 && GWInteriorEffectEmbers == 3, "GWInteriorEffect values");
_Static_assert(offsetof(GWGlassUniforms, lightEmitterCount) == 528, "lightEmitterCount offset");
_Static_assert(offsetof(GWGlassUniforms, lightComposite) == 532, "lightComposite offset");
_Static_assert(offsetof(GWGlassUniforms, lightCenterFade) == 536, "lightCenterFade offset");
_Static_assert(offsetof(GWGlassUniforms, lightPiping) == 540, "lightPiping offset");
_Static_assert(offsetof(GWGlassUniforms, lightPipingWidth) == 544, "lightPipingWidth offset");
_Static_assert(offsetof(GWGlassUniforms, lightBodyScale) == 548, "lightBodyScale offset");
_Static_assert(offsetof(GWGlassUniforms, padding7) == 552, "padding7 offset");
_Static_assert(offsetof(GWGlassUniforms, padding8) == 556, "padding8 offset");
_Static_assert(offsetof(GWGlassUniforms, lightEmitters) == 560, "lightEmitters offset");

_Static_assert(sizeof(GWLightEmitter) == 112, "GWLightEmitter size");
_Static_assert(_Alignof(GWLightEmitter) == 16, "GWLightEmitter alignment");
_Static_assert(offsetof(GWLightEmitter, color0) == 0, "color0 offset");
_Static_assert(offsetof(GWLightEmitter, color1) == 16, "color1 offset");
_Static_assert(offsetof(GWLightEmitter, color2) == 32, "color2 offset");
_Static_assert(offsetof(GWLightEmitter, color3) == 48, "color3 offset");
_Static_assert(offsetof(GWLightEmitter, shape) == 64, "shape offset");
_Static_assert(offsetof(GWLightEmitter, motion) == 80, "motion offset");
_Static_assert(offsetof(GWLightEmitter, kind) == 96, "kind offset");
_Static_assert(offsetof(GWLightEmitter, colorCount) == 100, "colorCount offset");
_Static_assert(offsetof(GWLightEmitter, intensity) == 104, "intensity offset");
_Static_assert(offsetof(GWLightEmitter, seed) == 108, "seed offset");
_Static_assert(GWLightKindNone == 0 && GWLightKindBand == 1 && GWLightKindArc == 2 && GWLightKindPoint == 3 && GWLightKindField == 4, "GWLightKind values");
_Static_assert(GWLightCompositeLight == 0 && GWLightCompositePaint == 1, "GWLightComposite values");
