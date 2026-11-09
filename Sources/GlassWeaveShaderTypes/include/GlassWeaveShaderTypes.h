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

// The frost pyramid's records (GW-24a) live in their own header.
#include "GlassWeaveFrostTypes.h"

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

/// The placement of one inner light emitter (GW-21), stored in
/// `GWLightEmitter.kind`. 0 draws nothing.
typedef enum GWLightKind {
    GWLightKindNone = 0,
    /// A half-plane in panel unit space that hugs one edge.
    GWLightKindBand = 1,
    /// A stretch of the outline, seen from the panel's center, that lights
    /// inward.
    GWLightKindArc = 2,
    /// A soft orb.
    GWLightKindPoint = 3,
    /// A four-corner color field, warped by noise.
    GWLightKindField = 4,
} GWLightKind;

/// How inner light combines with the glass (GW-21), stored in
/// `GWGlassUniforms.lightComposite`.
typedef enum GWLightComposite {
    /// Screen: never darkens a channel.
    GWLightCompositeLight = 0,
    /// Source-over at a capped opacity, so it also shows on white.
    GWLightCompositePaint = 1,
} GWLightComposite;

/// The height profile of a thick lens (GW-22), stored in
/// `GWGlassUniforms.lensProfile` and in a lens inlay. 0 is the GW-05 rim:
/// the shader's original refraction, with no height field. The others are
/// profiles `s(t)` of a height field `h = H * s(t)`, `t` the depth into the
/// bevel over the bevel width (0 at the outline, 1 where the bevel ends):
/// `s(0) = 0`, and `s(1) = 1` except for the ring, which is a bump.
typedef enum GWLensProfile {
    /// The GW-05 rim. For an inlay: no inlay.
    GWLensProfileRim = 0,
    /// A quarter circle, `s = sqrt(1 - (1 - t)^2)`.
    GWLensProfileCircular = 1,
    /// A superellipse, `s = (1 - (1 - t)^n)^(1/n)`, `n` in `profileA`.
    GWLensProfileSquircle = 2,
    /// A straight 40 degree face that rounds into the flat top.
    GWLensProfileChamfer = 3,
    /// A circular profile whose bevel is the panel's inscribed radius (the
    /// CPU resolves the bevel; the shader reads it as circular).
    GWLensProfileDome = 4,
    /// A bump `sqrt(1 - ((t - c) / w)^2)` around `t = c` (`profileA`) of
    /// half-width `w` (`profileB`), both as fractions of the bevel.
    GWLensProfileRing = 5,
} GWLensProfile;

/// One inner light emitter (GW-21), resolved on the CPU for one draw: angles
/// become direction vectors, lengths become pixels, and the motion at the
/// draw's effect time is already applied to the colors and `motion`.
///
/// - `color0` ... `color3`: the stops in linear light (`xyz`, `w` zero).
///   For a field they are the corners: top-left, top-right, bottom-left,
///   bottom-right. Unused stops are zero.
/// - `shape`: by kind.
///   Band: unit direction toward the lit edge in panel unit space (`xy`),
///   reach in unit-space lengths (`z`), pixels per unit along that direction
///   (`w`).
///   Arc: center angle in turns (`x`), half the span in turns (`y`), reach
///   in pixels (`z`), `w` zero.
///   Point: center in panel unit space (`xy`), radius in pixels (`z`), the
///   horizontal stretch (`w`).
///   Field: warp 0...1 (`x`), the position on the warp's loop (`yz`), `w`
///   zero.
/// - `motion`: palette shift in palette units (`x`); the drift offset
///   `drift * (cos, sin)` of the loop phase (`yz`); the reach of the
///   piping from this emitter in pixels (`w`, 0 for none).
/// - `kind`: a `GWLightKind` value. `colorCount`: 1 to 4. `intensity`:
///   0...1. `seed`: mixed into a field's warp noise.
///
/// Layout in bytes: color0 0, color1 16, color2 32, color3 48, shape 64,
/// motion 80, kind 96, colorCount 100, intensity 104, seed 108.
/// Size 112, alignment 16, stride 112.
typedef struct GWLightEmitter {
    simd_float4 color0;
    simd_float4 color1;
    simd_float4 color2;
    simd_float4 color3;
    simd_float4 shape;
    simd_float4 motion;
    uint32_t kind;
    uint32_t colorCount;
    float intensity;
    uint32_t seed;
} GWLightEmitter;

/// One lens inlay (GW-22): a bump of glass added to the panel's height field,
/// such as a dome button standing on a pill. Lengths are in pixels.
///
/// - `geometry`: the center in pixels from the panel's center, y down (`xy`),
///   the radius (`z`), and the height of the bump (`w`).
/// - `shape`: the bevel width, measured inward from the base (`x`), the
///   profile's two parameters (`yz`, as for `GWLensProfile`), and the
///   strength of the rim line, 0...1 (`w`).
/// - `profile`: a `GWLensProfile` value; 0 is no inlay.
///
/// Layout in bytes: geometry 0, shape 16, profile 32, explicit padding 36,
/// 40, 44 (set to zero). Size 48, alignment 16, stride 48.
typedef struct GWLensInlay {
    simd_float4 geometry;
    simd_float4 shape;
    uint32_t profile;
    uint32_t padding0;
    uint32_t padding1;
    uint32_t padding2;
} GWLensInlay;

/// The finish of the light model's reflections (GW-23), stored in
/// `GWLightingUniforms.finish`. 0 draws no light model at all: the panel keeps
/// its original edge highlight.
typedef enum GWLightingFinish {
    GWLightingFinishNone = 0,
    /// Glass: the environment reflected with Schlick's Fresnel term.
    GWLightingFinishDielectric = 1,
    /// A neutral (or tinted) polished metal band on the rim.
    GWLightingFinishChrome = 2,
    /// Chrome whose bright reflections carry a thin-film rainbow.
    GWLightingFinishPrismatic = 3,
} GWLightingFinish;

/// The analytic studio the glass reflects (GW-23), stored in
/// `GWLightingUniforms.environment`.
typedef enum GWLightingEnvironment {
    /// A bright cyclorama: pale sky and floor, white softboxes.
    GWLightingEnvironmentStudioLight = 0,
    /// A dark room: near-black sky and floor, bright gray strips.
    GWLightingEnvironmentStudioDark = 1,
} GWLightingEnvironment;

/// The light model of one panel (GW-23), resolved on the CPU for one draw:
/// angles are unit vectors, lengths are pixels, colors are linear light, and
/// the draw's light offset is already applied. All zero (`finish` 0) for a
/// panel with the original highlight.
///
/// - `key`: unit direction toward the key light in panel space (x to the
///   right, y down, z toward the viewer) in `xyz`, intensity 0...1 in `w`.
/// - `keyColor`: its color (`xyz`) and Blinn-Phong exponent (`w`).
/// - `rim`, `rimColor`: the optional second light as `key`, `keyColor`;
///   intensity 0 draws no rim light.
/// - `tint`: the chrome tint in linear light (`xyz`, `w` zero).
/// - `prism`: the prismatic finish's spread in turns of hue around the rim
///   (`x`), saturation 0...1 (`y`), phase in turns (`z`), `w` zero.
/// - `finish`: a `GWLightingFinish` value. `environment`: a
///   `GWLightingEnvironment` value.
/// - `azimuth`: the key light's azimuth in radians (0 at the top, clockwise),
///   offset included; the studio rotates with it.
/// - `f0`: reflectance at normal incidence, `((n - 1) / (n + 1))^2`.
/// - `fresnel`, `specular`, `reflection`, `bloom`: strengths, 0...1.
/// - `bloomWidth`: the most the bloom reaches along the surface, in pixels.
/// - `bevel`, `fieldRadius`: the quarter-round edge the light model uses when
///   the panel has no lens profile: its width and the corner radius of the
///   field whose inward distance is the depth.
/// - `bandWidth`: how deep into the glass the light terms reach, in pixels.
/// - `footprint`: the angle, in radians, one pixel spans on the surface's
///   normal; the specular lobe is never narrower than it.
/// - `contrast`: nonzero draws the Fresnel outline as a crisp hairline that
///   contrasts with the glass under it (light on dark, dark on light) instead
///   of adding light; zero adds light.
/// - `edgeDirection`: the unit vector toward the key light in the panel's
///   plane (x right, y down), which also orients the original edge highlight.
///
/// Layout in bytes: key 0, keyColor 16, rim 32, rimColor 48, tint 64,
/// prism 80, finish 96, environment 100, azimuth 104, f0 108, fresnel 112,
/// specular 116, reflection 120, bloom 124, bloomWidth 128, bevel 132,
/// fieldRadius 136, bandWidth 140, footprint 144, contrast 148,
/// edgeDirection 152. Size 160, alignment 16, stride 160.
typedef struct GWLightingUniforms {
    simd_float4 key;
    simd_float4 keyColor;
    simd_float4 rim;
    simd_float4 rimColor;
    simd_float4 tint;
    simd_float4 prism;
    uint32_t finish;
    uint32_t environment;
    float azimuth;
    float f0;
    float fresnel;
    float specular;
    float reflection;
    float bloom;
    float bloomWidth;
    float bevel;
    float fieldRadius;
    float bandWidth;
    float footprint;
    float contrast;
    simd_float2 edgeDirection;
} GWLightingUniforms;

/// The grounding of one panel (GW-25): its drop, contact and inner shadows
/// and its colored caustic, resolved on the CPU for one draw. Lengths are
/// pixels. `flags` 0 (all zero record) means the panel has no grounding and
/// is drawn by a pipeline variant that does not contain the grounding code.
///
/// Colors: the drop, contact and caustic colors are sRGB-encoded (the pre-pass
/// blends on the encoded target); the inner shadow's color is linear light
/// (the body works in linear light). Opacities and intensities are 0...1.
///
/// - `dropColor`, `contactColor`, `innerColor`: shadow color in `xyz`, opacity
///   in `w`.
/// - `causticColor`: color in `xyz`, intensity in `w`.
/// - `shadowDirection`: the unit vector, in target pixels (x right, y down),
///   from the panel toward where its shadow falls (away from the light).
/// - `dropOffset`, `dropSigma`, `dropSpread`: how far the drop shadow moves
///   along the direction, its Gaussian standard deviation, and how far it
///   grows past the outline (negative shrinks).
/// - `contactWidth`, `contactOffset`: the contact shadow's reach beyond the
///   outline and its small offset along the direction.
/// - `innerOffset`, `innerSigma`: the inner shadow's offset along the
///   direction and its standard deviation.
/// - `causticOffset`, `causticWidth`: the caustic band's distance from the
///   outline along the direction (negative moves it inside) and its width.
/// - `causticDispersion`: 0...1, how far the red, green and blue bands part.
/// - `causticSpectrum`: 0...1, how far the hue turns around the band.
/// - `reach`: how far the pre-pass quad reaches past the panel rectangle.
/// - `flags`: `GWGroundingFlag` bits.
///
/// Layout in bytes: dropColor 0, contactColor 16, innerColor 32,
/// causticColor 48, shadowDirection 64, dropOffset 72, dropSigma 76,
/// dropSpread 80, contactWidth 84, contactOffset 88, innerOffset 92,
/// innerSigma 96, causticOffset 100, causticWidth 104, causticDispersion 108,
/// causticSpectrum 112, reach 116, flags 120, explicit padding 124 (set to
/// zero). Size 128, alignment 16, stride 128.
typedef struct GWGroundingUniforms {
    simd_float4 dropColor;
    simd_float4 contactColor;
    simd_float4 innerColor;
    simd_float4 causticColor;
    simd_float2 shadowDirection;
    float dropOffset;
    float dropSigma;
    float dropSpread;
    float contactWidth;
    float contactOffset;
    float innerOffset;
    float innerSigma;
    float causticOffset;
    float causticWidth;
    float causticDispersion;
    float causticSpectrum;
    float reach;
    uint32_t flags;
    float padding0;
} GWGroundingUniforms;

/// `GWGroundingUniforms.flags`: which parts of the grounding draw.
typedef enum GWGroundingFlag {
    /// The panel is grounded: its body is drawn by the grounded variant.
    GWGroundingFlagActive = 1,
    /// The pre-pass draws a drop or contact shadow.
    GWGroundingFlagShadow = 2,
    /// The pre-pass and the body draw the caustic.
    GWGroundingFlagCaustic = 4,
    /// The body draws the inner shadow.
    GWGroundingFlagInner = 8,
} GWGroundingFlag;

/// The outline a glass panel has (GW-26), stored in `GWShapeUniforms.kind`.
/// The shader's rounded-rectangle code and the shaped pipeline variant never
/// meet: a rounded-rectangle panel is drawn by a variant without any shape
/// code, and its shape record is all zero.
typedef enum GWShapeKind {
    GWShapeKindRoundedRectangle = 0,
    /// The ellipse of half sizes `panelHalfSize`.
    GWShapeKindEllipse = 1,
    /// The superellipse `|x/a|^n + |y/b|^n = 1`, half sizes `panelHalfSize`,
    /// exponent `n` in `GWShapeUniforms.exponent`.
    GWShapeKindSuperellipse = 2,
    /// A smooth union of up to six primitives.
    GWShapeKindBlob = 3,
} GWShapeKind;

/// One primitive of a blob (GW-26), stored in `GWShapePrimitive.kind`.
typedef enum GWShapePrimitiveKind {
    GWShapePrimitiveCircle = 0,
    GWShapePrimitiveCapsule = 1,
    GWShapePrimitiveBox = 2,
} GWShapePrimitiveKind;

/// One primitive of a blob (GW-26), in pixels from the panel's center (y
/// down).
/// - circle: `geometry` = center x, center y, radius, 0.
/// - capsule: `geometry` = end a x, a y, end b x, b y; `shape.x` = radius.
/// - box: `geometry` = center x, center y, half width, half height;
///   `shape` = corner radius, cosine and sine of the rotation, 0.
///
/// Layout in bytes: geometry 0, shape 16, kind 32, explicit padding 36, 40,
/// 44 (set to zero). Size 48, alignment 16, stride 48.
typedef struct GWShapePrimitive {
    simd_float4 geometry;
    simd_float4 shape;
    uint32_t kind;
    uint32_t padding0;
    uint32_t padding1;
    uint32_t padding2;
} GWShapePrimitive;

/// The outline of one panel (GW-26), resolved on the CPU for one draw, all
/// lengths in pixels. `kind` 0 (an all-zero record) is the rounded rectangle:
/// that panel is drawn by a pipeline variant that does not contain the shape
/// code. For the other kinds `panelCenter` and `panelHalfSize` are the
/// outline's bounding box (the panel's quad), not the layout frame.
/// - `kind`: a `GWShapeKind` value.
/// - `primitiveCount`: 1 to 6 for a blob.
/// - `exponent`: the superellipse's `n`, 2 to 10.
/// - `smoothness`: the blob's smooth-union blend distance `k`.
/// - `inscribedRadius`: a lower bound of the radius of the largest circle
///   inside the outline; depth fractions and the dome's bevel use it.
/// - `wobbleAmplitude`, `wobbleWavelength`: the blob's wobble, a sum of three
///   plane waves, in pixels; amplitude 0 draws none.
/// - `wobblePhases`: the three waves' phases in radians, resolved on the CPU
///   from the effect time so the wobble loops exactly (the shader sees no
///   time).
/// - `primitives`: the blob's primitives; unused ones are zero.
///
/// Layout in bytes: kind 0, primitiveCount 4, exponent 8, smoothness 12,
/// inscribedRadius 16, wobbleAmplitude 20, wobbleWavelength 24, explicit
/// padding 28 (set to zero), wobblePhases 32, primitives 48 (6 x 48 bytes).
/// Size 336, alignment 16, stride 336.
typedef struct GWShapeUniforms {
    uint32_t kind;
    uint32_t primitiveCount;
    float exponent;
    float smoothness;
    float inscribedRadius;
    float wobbleAmplitude;
    float wobbleWavelength;
    float padding0;
    simd_float4 wobblePhases;
    GWShapePrimitive primitives[6];
} GWShapeUniforms;

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
/// Inner light (GW-21), appended after the GW-19 fields, which keep their
/// layout. `lightEmitterCount` 0 disables the whole light; every other light
/// field is then zero. See docs/glass-optics.md for the math.
/// - `lightEmitterCount`: 0 to 4.
/// - `lightComposite`: a `GWLightComposite` value.
/// - `lightCenterFade`: 0...1, how much the body light fades toward the
///   middle (as `interiorCenterFade`).
/// - `lightPiping`: 0...1, how strongly an emitter lights the rim band near
///   it.
/// - `lightPipingWidth`: the width of the lit rim band in pixels; 0 draws no
///   piping.
/// - `lightBodyScale`: 0...1, the factor on the light inside the rim band's
///   reach (0 leaves only the piping).
/// - `lightEmitters`: the emitters, in drawing order; unused ones are zero.
///
/// Thick lens (GW-22), appended after the GW-21 fields, which keep their
/// layout. `lensProfile` 0 disables the whole lens (the shader's GW-05 rim
/// refraction stays); every other lens field is then zero. A panel with no
/// lens is drawn by the pipeline variant that does not contain the lens code
/// at all. See docs/glass-optics.md for the math. Lengths are in pixels.
/// - `lensProfile`: a `GWLensProfile` value.
/// - `lensThickness`: the glass height `H` at its thickest.
/// - `lensBevel`: the bevel width, over which the height rises.
/// - `lensFieldRadius`: corner radius of the rounded rectangle whose inward
///   distance is the lens depth (a C1 field), `max(cornerRadius, bevel)` but
///   at most half the shorter side.
/// - `lensIOR`: index of refraction, 1 to 2.4.
/// - `lensMaximumOffset`: the longest a sample moves, in pixels.
/// - `lensOffsetScale`: 0...1, scales every offset; below 1 only when the
///   lens may not fold (see `GlassLens.allowsFold`).
/// - `lensProfileA`, `lensProfileB`: the profile's parameters (see
///   `GWLensProfile`).
/// - `lensDispersion`: 0...1, how far the wavelengths' indices of refraction
///   spread (and, for the rim profile, how far their displacements spread);
///   0 draws no dispersion.
/// - `lensTapCount`: the wavelength samples per pixel where the colors
///   separate: 0 (no dispersion), 3 or 6.
/// - `lensInlayCount`: 0 to 2.
/// - `lensInlays`: the inlays; unused ones are zero.
///
/// Light model (GW-23), appended after the GW-22 fields, which keep their
/// layout. `lighting.finish` 0 disables the whole light model (every other
/// field of the record is then zero); the panel is then drawn by a pipeline
/// variant that does not contain the light model, as it was in GW-22. See
/// docs/glass-optics.md for the math.
/// - `lighting`: a `GWLightingUniforms` record.
///
/// Grounding (GW-25), appended after the GW-23 fields, which keep their
/// layout. `grounding.flags` 0 disables it (every other field of the record is
/// then zero); the panel is then drawn by a pipeline variant that does not
/// contain the grounding code, as it was in GW-23. See docs/glass-optics.md.
/// - `grounding`: a `GWGroundingUniforms` record.
///
/// Shape (GW-26), appended after the GW-25 fields, which keep their layout.
/// `shape.kind` 0 is the rounded rectangle (every other field of the record is
/// then zero); the panel is then drawn by a pipeline variant that does not
/// contain the shape code, as it was in GW-25. See docs/glass-optics.md.
/// - `shape`: a `GWShapeUniforms` record.
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
/// interiorSparks 336 (12 × 16 bytes); lightEmitterCount 528,
/// lightComposite 532, lightCenterFade 536, lightPiping 540,
/// lightPipingWidth 544, lightBodyScale 548, explicit padding 552, 556 (set
/// to zero), lightEmitters 560 (4 × 112 bytes); lensProfile 1008,
/// lensThickness 1012, lensBevel 1016, lensFieldRadius 1020, lensIOR 1024,
/// lensMaximumOffset 1028, lensOffsetScale 1032, lensProfileA 1036,
/// lensProfileB 1040, lensDispersion 1044, lensTapCount 1048, lensInlayCount 1052,
/// lensInlays 1056 (2 × 48 bytes); lighting 1152 (160 bytes); grounding 1312
/// (128 bytes); shape 1440 (336 bytes). Size 1776, alignment 16, stride 1776.
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
    uint32_t lightEmitterCount;
    uint32_t lightComposite;
    float lightCenterFade;
    float lightPiping;
    float lightPipingWidth;
    float lightBodyScale;
    float padding7;
    float padding8;
    GWLightEmitter lightEmitters[4];
    uint32_t lensProfile;
    float lensThickness;
    float lensBevel;
    float lensFieldRadius;
    float lensIOR;
    float lensMaximumOffset;
    float lensOffsetScale;
    float lensProfileA;
    float lensProfileB;
    float lensDispersion;
    uint32_t lensTapCount;
    uint32_t lensInlayCount;
    GWLensInlay lensInlays[2];
    GWLightingUniforms lighting;
    GWGroundingUniforms grounding;
    GWShapeUniforms shape;
} GWGlassUniforms;

#endif // GLASSWEAVE_SHADER_TYPES_H
