# Frost pyramid (GW-24a)

Experimental. This note describes a blur that varies over a glass shape: the
parameters (`GlassFrost`), the pyramid of filtered backgrounds (`FrostPyramid.swift`,
`Shaders/Frost.metal`), and how a draw builds, reuses and releases it (GW-24a); and
how the glass shader samples the pyramid, grades it, and guarantees text contrast
over it (GW-24b, the last section). Set it as `GlassParameters.frost`.

## What a pyramid is

One mipmapped `rgba16Float` texture in *destination space* (the render target's
pixels), holding the background in linear light at 1/2, 1/4, 1/8, 1/16 and, for
large blurs, 1/32 of the destination resolution. Four levels cover a blur of up to
12 px, five up to 24 px (a larger `sigma` saturates at the top level).

- Region: the area a pyramid covers, in destination pixels. A request with a region
  (the frosted shape, in points) is clipped to the target and grown by
  `3 * sigma + margin` on every side; without one it is the whole target. It may
  extend past the target, where the source continues (aspect-fill crop) or clamps at
  its valid rectangle.
- Level 0 has `ceil(width / 2)` texels, rounded up to a multiple of `2^(levels-1)`,
  so each level is exactly half the one before and a texel of level L is exactly
  `2^(L+1)` destination pixels wide. Every level covers the same rectangle, so one
  normalized coordinate addresses all of them (`GWFrostPyramidLayout`).
- Memory: the sum over levels of `width * height * 8` bytes. `frostMemoryBytes`
  reports this computed size, not the device's: the iOS Simulator reports no
  allocation sizes. A 1116 x 636 pixel region with five levels is 1,909,600 bytes.

### Building

`gw_frost_downsample_source` writes level 0 from the source frame; `gw_frost_downsample_level`
writes each later level from the one before. Both use the 13-tap downsample (center,
four diagonals, four edge midpoints, four corners; weights sum to 1). Level 0 takes
each tap position in destination pixels, maps it through the background pass's
`SourceUVTransform` and clamps it half a texel inside the valid rectangle, so no tap
reads outside it. Later levels clamp at their edge (the region is grown so this is
rarely visible).

The filtered blur of level L has standard deviation `sqrt(1.75 * (4^(L+1) - 1) / 3)`
destination pixels: 1.32, 2.96, 6.06, 12.2, 24.4. (A step has a variance of 1.75
input texels; the texel doubles every level.) `gw_frost_lod(sigma, levels)` turns a
blur into a level of detail by interpolating in log sigma between those values; below
1.32 px a caller takes its single-sample path.

### Reading (`Shaders/GlassFrost.h`)

For the later wiring in `Glass.metal`, `#include "GlassFrost.h"`:

- `gw_frost_sample(pyramid, layout, position, lod)`: the two levels around `lod`,
  each reconstructed with a cubic B-spline in four bilinear fetches, blended. With
  dispersion, take single `gw_frost_bspline` taps at the shared level.
- `gw_frost_sigma(profile record, pixel)`: the blur radius at a pixel of a rounded
  rectangle for `.uniform`, `.clearCenter` (frosted at the outline, clear `transition`
  pixels inside), `.clearRim` (the reverse) and `.verticalRamp`.
- `GlassFrost.uniforms(...)` fills the `GWFrostProfileUniforms` record (converted to
  pixels, limited to the pyramid's top level).
- `GlassRenderer.frostPyramids.current` is the pyramid the draw's pre-render step
  encoded, to bind in the overlay (texture and layout).

## Ordering with the draw

`BackgroundRenderer.draw` keeps GW-27's order: checks, target acquisition, command
buffer, then encoding. Frost adds two steps through `PreRender`:

1. `admit`, after the source checks and **before** the target is requested: can a
   pyramid be served without waiting? If not, the draw skips with
   `.skipped(.frostUnavailable)` (a provided command buffer still commits its
   produced frame's writes, as for any skip), and no drawable was taken.
2. `encode`, after the command buffer exists and **before** the render encoder: the
   pyramid is built (or reused) in the same command buffer that reads it. A produced
   frame encoded earlier in that command buffer is therefore sampled after its writes,
   which is what `BackgroundFrameReadiness.encoded(in:)` promises.

Because the target is acquired first, a target-unavailable skip never encodes pyramid
work, and there is no cache entry to invalidate: the proposal's "create the command
buffer ahead of acquisition" is not needed with GW-27's acquisition model.
If `encode` succeeded but the render encoder cannot be made, a command buffer that
the draw created is still committed, because the pyramid's completion handler is
attached to it.

## The ring and the cache

`FrostPyramidRing` owns up to 3 pyramids. A pyramid is *in flight* from the moment a
draw encodes work that reads it until that command buffer completes (a completion
handler, on a Metal thread, releases it under a lock).

- Key: source frame ID, plan (region and level count), target size. The maximum blur
  enters through the level count, so an animated blur rebuilds only when it crosses
  the step between four and five levels (a deviation from keying on the exact value,
  which would rebuild every frame of a focus pull for identical texels).
- A draw whose key matches a built pyramid **reuses** it, in flight or not: it only
  reads, and the build is ahead of it on the same queue. `pyramidReuses` counts it.
- Otherwise it **builds** into a free pyramid (none in flight), preferring one whose
  texture already has the size, then an empty one, then the least recently used one
  of another size (reallocated). `pyramidBuilds` counts it. A pyramid in flight is
  never written.
- If every pyramid is in flight, the draw takes the skip above and never waits. A
  host that respects the surface's in-flight bound of 2 never meets it.
- A build whose command buffer fails drops its key.
- No texture allocation in steady state: the ring counts allocations (`allocations`);
  they happen only for the first pyramid of a size.

### Rule for producers

A producer whose content did not change returns `nil` from `drawProducing` (or the
app uses `setSource`): the frame ID stays, the pyramid is reused. A producer that
returns a new frame on every effect tick rebuilds the pyramid every tick. The lab's
frost screen shows both: a pulsing glow over a static source gives `builds=1` and a
climbing `reuses`; "New source frame" gives exactly one more build.

### Trim and accessibility

- `GlassRenderer.trimFrostResources()` releases the pyramids (a draw in flight keeps
  its texture until it completes). `GlassSurfaceView` calls it when it stops being
  visible; the next draw builds again.
- Reduce Transparency presents any frost as none (`GlassRenderer.isFrostSuppressed`,
  set by the surface from the accessibility settings): the body is already opaque, so
  no pyramid is built and the existing ones are released. Increase Contrast and Reduce
  Motion leave the frost as it is: it is static, and the 7:1 scrim ratio belongs to
  GW-24b's legibility scrim.
- Quality tiers: the frost level count and blur cap become a row in `GlassQuality`'s
  table when the shader lands (a hook, as `GlassQuality` documents).

## Metrics

`RenderMetrics.counts.pyramidBuilds` and `pyramidReuses` (per window, reset with it),
`RenderMetrics.frostMemoryBytes` (a gauge, kept across `reset()`),
`GlassRenderer.frostMemoryBytes` (live).

## API surface

- Public, experimental: `GlassFrost` (+ `Profile`, `GlassFrostError`),
  `GlassRenderer.frostMemoryBytes`, `trimFrostResources()`,
  `BackgroundRenderSkipReason.frostUnavailable`, and the two metrics fields above.
- SPI (`@_spi(FrostLab)`), for the laboratory and tests until panels carry their own
  frost: `GlassRenderer.setFrost(_:region:margin:)` and `frostAtlasImage(tileHeight:columns:)`.
- Internal: `FrostPyramid`, `FrostPyramidRing` (including `probe`, which reads the
  pyramid at points and levels through the same shader function, and suspends rather
  than blocks), `FrostRequest`, `GWFrost*` records in `GlassWeaveFrostTypes.h`
  (layouts asserted in C, MSL and the Swift test).

## Limits of GW-24a

- (Superseded by GW-24b below: the shader now samples the pyramid.) The proposal's
  pixel criteria (dot anisotropy, step edges, magenta, scrim, `.sixTap`) were not
  measured in either round.
- The 13-tap blur is a calibration by arithmetic (the table above), not a measured
  fit; the proposal's "fitted sigma within 15%" check is open.
- Source frames larger than the target are not prefiltered before level 0 (taps are
  one destination pixel apart), as for the single-sample path.
- No device or M5 numbers: simulator and My Mac only.


# Frost in the glass shader (GW-24b)

Experimental. A panel's `GlassParameters.frost` is a `GlassFrost`: the profile, the
blur `sigma` (points), `transition`, the vertical ramp, `grain`, and from this round
`thickness`, `saturation`, `brightness` and an optional `scrim`. `GlassFrost.none`
(the default) is the clear glass; every new field has a neutral default and the
normalization rule (a non-finite value throws `GlassParameterError.nonFiniteFrost`
naming the field, a finite one is clamped).

## What the shader does

The `frosted` pipeline variant (function constant 4, `gw_frost_constant`, on top of
every other variant's code, for a rounded rectangle and for a freeform shape; both
built at initialization) reads the pyramid texture and a `GWFrostPanelUniforms`
record (128 bytes, its own fragment buffer 1 and texture 1; `GWGlassUniforms` keeps
its layout). A panel with an active frost (a blur, a scrim, or both) draws in it; any
other panel draws in the variant it always did.

- **Radius.** `sigma(p)` comes from the profile at the pixel, using the panel's own
  shape field for the depth (so a blob's rim is the blob's), scaled by
  `1 - thickness + thickness * h / H` where `h` is the lens height at the pixel and
  `H` the lens thickness (so with `thickness` 1 the glass is clear where it is thin).
- **Level of detail.** `LOD = gw_frost_lod(sigma)`, the log-sigma interpolation of
  GW-24a (`log2(sigma / sigma0)` between levels). The pixel's weight is
  `saturate(sigma / sigma0)` with `sigma0` the finest level's own blur (1.32 px): at 0
  the shader takes the unfrosted single sample (a clear region is the exact sample of
  the unfrosted shader), at 1 and above the pyramid, and between them a mix, so there
  is no seam at the threshold.
- **Sampling.** At the lens-refracted position: the two levels around the LOD, each a
  four-fetch cubic B-spline, blended. With dispersion each wavelength is **one
  trilinear tap at the shared LOD** (three taps, or six blended by the lens's weights),
  not 6 x 4.
- **Grade and grain.** Saturation (about the pixel's luminance) and brightness in linear
  light, then a static multiplicative grain (one pixel, about +-4 % of the color at
  `grain` 1), both weighted by the pixel's blur weight so a clear part is untouched.
  Frosted pixels are dithered like the other effects.
- **Pyramid.** The panels' frosts ask for one pyramid: the union of the blurring panels'
  frames, the largest `sigma`, and a margin of 1.4 times the longest refraction offset
  (lens `maximumOffset`, or the rim's displacement) plus 2 points. It is cached by the
  GW-24a key, so a static panel over a static source builds once (`pyramidBuilds` 1,
  then `pyramidReuses` per draw); a moving panel or a new frame rebuilds, as the
  producer rule says. `GlassRenderer.setFrost` (diagnostic SPI) still works when no
  panel asks.

## The legibility scrim

`GlassFrost.legibility(text:contrast:rect:feather:)` returns the frost with a scrim:
text of color `text` over `rect` (points, the panel frame's coordinate space) keeps
the WCAG 2 contrast `contrast` (1...21). It is the last stage before the dither and
the encode, after every light term (a grounded caustic, which is added to the encoded
color, is applied first). With `L` the pixel's relative luminance and a target ratio
of `contrast * 1.03`: for light text (luminance above 0.179) the largest allowed `L` is
`(Lt + 0.05) / ratio - 0.05`; for dark text the smallest is `ratio * (Lt + 0.05) - 0.05`.
A pixel past the limit is moved toward it, never past: luminance below 60 % of the
limit is untouched and above that it approaches the limit exponentially (so the result
is always inside it and there is no corner), by scaling the color (darkening) or mixing
toward white (lightening), which keeps the hue. The effect is full inside `rect` and
fades over `feather` points (default 12) beyond it; farther pixels are exactly as
without it. A scrim works with `sigma` 0 too (no pyramid is built).

Measured on the simulator capture with the label hidden (`-lab.frostNoText YES`, the
pixels of the label's rectangle, white text, 240,408 pixels): the lowest contrast is
4.577 for a 4.5 request, and 7.106 under Increase Contrast (requested 4.5, raised to 7).
With the scrim off the lowest, among the pixels darker than 0.55 in luminance, is 1.75.

## Accessibility

| Setting | Behavior |
| --- | --- |
| Reduce Transparency | `GlassAccessibilityPolicy.presentedFrost` presents `.none`, scrim included: the body is the opaque surface, no pyramid is built (`frostMemoryBytes` 0, no builds in the lab capture) and `GlassSurfaceView` releases the existing ones. |
| Increase Contrast | The blur stays (static, the source's own colors) and a scrim is raised to at least 7 to 1 (`increasedContrastScrimRatio`); the lens row removes the dispersion. |
| Reduce Motion | No change: frost is static. |

## Lab

`-lab.frostBench YES` (or the lab menu's "Frosted glass") opens a bench page over the
"prism" backdrop (two soft rainbow arcs, colored glows, small lights; original):
(a) a capsule, `.clearRim` frost with sigma 7 pt, grain, saturation 1.15, a clear bevel
with six-tap dispersion and a thin Fresnel rim; (b) the thick lens pill of GW-22/23
with a lightly frosted body that follows the glass thickness (`thickness` 1), a clear
edge, and the pooled colored light; (c) a card with a large white label and a 4.5 to 1
scrim (a switch turns it off; `-lab.scrimOff YES` starts it off). `-lab.frostOff YES`
draws the same panels clear, `-lab.frostNoText YES` hides the label (for measuring),
and `-lab.frostNative YES` swaps the three panels for Apple's `UIGlassEffect` in the same
frames. Captures: `docs/evidence/captures/gw-24b-frost-*.png`.

## Tuning notes

- Over the dark prism page a gray tint lifts the black to a visible gray (the veil in the
  first round was the tint, not the frost); the page's panels use a tint of 3 to 5 %.
- A 2.4 pt blur on 9 pt rainbow bands barely reads as frost; 7 pt does, and the page
  keeps its color. Apple's `.regular` glass blurs more and mutes the color; ours is
  frosted but keeps the hues (saturation 1.15), which is the point.
- Dispersion is blurred away when the bevel is frosted: the capsule uses `.clearRim` so the
  bevel keeps the unfrosted sample (and the fringes) and the body is frosted.
- A scrim feather of 12 points left a visible edge below the label; 28 points does not.

## Limits of GW-24b

- The shader's blur is not calibrated beyond the GW-24a arithmetic; no fitted-sigma, dot
  anisotropy, step-edge, magenta or temporal tests.
- The scrim is measured on one capture, not on 1,000 backgrounds; `.sixTap` neutrality of
  white with frost is not measured.
- The pyramid region is the union of the frosted panels' frames, so panels far apart
  share one large pyramid (9.4 MiB in the lab's page, five levels over most of the
  screen); the quality tiers have no frost row yet.
- Sampling is evaluated at the output pixel's `sigma`, not at the sampled position's.
- A frosted panel's antialiased outline pixel mixes the frosted glass with the unfrosted
  background, as the other effects do.
- Simulator and My Mac only; no M5 numbers, no device sign-off.
