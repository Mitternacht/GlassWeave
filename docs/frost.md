# Frost pyramid (GW-24a)

Experimental. This note describes the infrastructure for a blur that varies over a
glass shape: the parameters (`GlassFrost`), the pyramid of filtered backgrounds
(`FrostPyramid.swift`, `Shaders/Frost.metal`), and how a draw builds, reuses and
releases it. The glass shader does not sample the pyramid yet (GW-24b); until it
does, requesting frost changes no pixel on screen.

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

## Limits of this round

- Nothing on screen samples the pyramid. The proposal's pixel criteria (dot
  anisotropy, step edges, magenta, scrim, `.sixTap`) belong to GW-24b.
- The 13-tap blur is a calibration by arithmetic (the table above), not a measured
  fit; the proposal's "fitted sigma within 15%" check is open.
- Source frames larger than the target are not prefiltered before level 0 (taps are
  one destination pixel apart), as for the single-sample path.
- No device or M5 numbers: simulator and My Mac only.
