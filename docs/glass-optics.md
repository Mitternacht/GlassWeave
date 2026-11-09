# Glass optics: design notes

Status: design notes for the optics lane of the "glass beyond native" round
([proposal](proposals/glass-beyond-native.md), tasks GW-21 to GW-29). One
section per task. Every API here is **experimental**. Native glass
(`UIGlassEffect`) cannot show a hue inside itself; these notes describe what
GlassWeave's own Metal glass adds. Native glass is only a comparison baseline.

## GW-21: Inner light fields and the material bench

**Implemented** (fast pass; see the checklist for what is not tested).

### What it is

`GlassParameters.light` (`GlassLight`, default `.none`) holds up to four
**emitters** of colored light inside the glass. Each emitter has a placement,
up to four color stops, an intensity, and optional flow and drift. The light
is drawn after the glass, the glow and the interior, so it also lights a
glowing or animated panel. With `.none` the panel pass writes exactly the
bytes of the frozen GW-20 shader (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW20.metal`).

### Space and falloff

Everything is evaluated in **panel unit space**, `u = q / panelHalfSize`
(the panel scaled to a square, x and y from -1 to 1, y down), so a placement
means the same for any shape. `w` is the depth inside the outline over half
the shorter side, as for interiors.

| Placement | Body light | Colors run along |
| --- | --- | --- |
| `.band(angle:reach:)` | `1 - smoothstep(0, 1, e / reach)`, with `e = max(1 - dot(u, d), 0)`, `d` the unit direction to the lit edge (angle 0 is the top, clockwise). Never rises with `e`; exactly 0 from `reach` on. | the edge, left to right for the bottom edge |
| `.arc(angle:span:reach:)` | an angular window (flat core, smooth ends, exactly 0 beyond `span / 2`) times `1 - smoothstep(0, 1, depth / reachPx)` | the arc |
| `.point(x:y:radius:stretch:)` | `(1 - d^2)^2` for the scaled distance `d` from the center (radius in fractions of half the shorter side) | radially, core to edge |
| `.field(warp:)` | `1 - smoothstep(0, 1, w)`; bilinear blend of the four stops (the corners: top-left, top-right, bottom-left, bottom-right) over `uv` warped by one octave of `gw_noise2` | the blend |

Colors are sRGB-encoded in the API, decoded to linear light on the CPU, and
interpolated in linear light. The palette folds back and forth (period 2), so
shifting it by 2 is the identity and a flowing palette never jumps.

**Composite.** `.light` screens: `G + c * a * (1 - G)`, which never lowers a
channel. `.paint` mixes toward the color by `min(a, 0.85)`, so it shows on
white. Several emitters apply in order. The center fade is the interiors':
`1 - centerFade * smoothstep(0.3, 0.85, w)`, so at 1 everything deeper than
85 % is exactly the glass without light (when the piping width does not reach
that deep).

**Light piping.** The rim band glows in the emitter's color:
`piping * intensity * pipe * (1 - depth / pipingWidth)^2`. `pipe` falls off as
`(1 - dist / (1.6 * reach))^2` with the **Euclidean** distance `dist` in pixels
from the emitter's source (the band's edge line, the arc segment, the point),
not along the outline, so it works for any shape. The width is the panel's
`bezelWidth` unless `pipingWidth` is set.

### Motion

All motion is computed on the CPU per draw and uploaded; the shader has no
time. The loop is `GlassInterior.loopDuration` = 64 s:
`phase = ((t + timeOffset) * speed mod 64) / 64`. Palette flow, noise flow
(fields) and hue drift are whole turns per loop (flow -8...8, hue drift
-16...16, both rounded), and drift (0...1: a band breathes, an arc sways, an
orb orbits) follows `(cos 2 pi phase, sin 2 pi phase)`, so `t` and
`t + 64 / speed` give the same frame with no seam. Hue drift rotates the
linear color about the gray axis. `speed` 0 is phase 0.

### GPU record

`GWGlassUniforms` grows from 528 to 1008 bytes, append-only: a 32-byte light
header at 528 and four `GWLightEmitter` records (112 bytes) at 560. The full
record is still bound to the vertex and fragment stages, so the frozen
baselines read their prefix. Sizes and offsets are asserted in C
(`GlassWeaveShaderTypes.c`), MSL (`Glass.metal`) and Swift
(`ShaderLayoutTests`, with a distinctive-value round trip through
`LayoutProbe.metal`).

### Normalization

A non-finite value anywhere (also in an emitter past the fourth) throws
`GlassParameterError.nonFiniteLight(_:)` naming a `GlassLight.Field`. Finite
values clamp: components, intensity, drift, warp, reach (arc) and the
normalized fields to 0...1; band reach 0...2; arc span 0...360; point
position -1...1, radius 0...2, stretch 0.25...4; angles reduce into
0..<360; speed 0...3; `pipingWidth` 0 to half the shorter side. Lists cap at
four emitters and four stops. An emitter without colors is dropped.
`GlassRenderer.panel` reports the normalized light that is drawn.

### Accessibility and legibility

| Setting | Light |
| --- | --- |
| Reduce Transparency | removed |
| Increase Contrast | body light removed (`body` 0); piping kept within `GlassAccessibilityPolicy.increasedContrastPipingWidth` (2 pt) of the outline |
| Reduce Motion | `speed` 0: phase 0 whatever the effect time |

`GlassLight.maximumOpacity(in:ofPanel:bezelWidth:)` bounds the most opacity
any emitter has inside a rectangle, and
`GlassTint.interiorLuminanceRange(with:in:ofPanel:bezelWidth:)` widens the
tint's luminance range by it, so an app can place text where light cannot
reach. Both are conservative (rounded corners only reduce light; hue drift
takes the brightest hue).

### Material bench and the light-fields demo

`-lab.bench <page>` opens the bench: `dots` (a 16 pt lattice of bright dots
for centroid measurements), `checkerboard`, `ribbons`, `charcoal`, `paper`
(index 0 to 4 also works), each a procedural 8-bit sRGB page
(`BenchBackgrounds.metal`), with a few plain panels over it. The lab's main
screen has buttons for the bench and for **Light fields**
(`-lab.lightFields YES`, `-lab.lightBackdrop charcoal|ribbons|paper`,
`-lab.lightTime <seconds>` for a still moment): a wide pill with light pooled
along its bottom edge (orange, pink, violet, cyan, flowing), an arc, an orb
and a four-corner field. Captures are in `docs/evidence/captures/gw-21-*`.

### Deviations and limits

- **Surface clock.** `GlassSurfaceView` decides whether to run its effect
  clock from `glow.isAnimated || interior.isAnimated`. It was not edited in
  this lane (the presentation lane owns that file), so the surface does not
  yet tick for light on its own. The one-line follow-up is to use
  `GlassParameters.isAnimated`, which already includes `light.isAnimated`.
  Until then the lab demo drives `GlassLight.timeOffset` from its own update
  link (stopped under Reduce Motion and when hidden).
- **Field corners.** The proposal's `.field(corners:warp:)` is
  `.field(warp:)` here, with the emitter's four stops as the corners.
- **Error field.** New light fields have their own `GlassLight.Field` and
  `GlassParameterError.nonFiniteLight(_:)`; `GlassParameterError.Field` is
  unchanged because an existing test switches over it exhaustively.
- **Pipelines.** The light is a uniform-guarded branch in the one panel
  pipeline; function-constant variants arrive with the first heavier path
  (GW-22).
- **Not done:** the CPU mirror, the property sweeps and the M5 cost run (see
  the checklist).

## GW-22: Thick-lens optics, chromatic dispersion and inlays

**Implemented** (fast pass; see the checklist for what is not tested).

### What it is

`GlassParameters.lens` (`GlassLens`, default `.none`) turns a panel from a
thin rim into a **piece of glass with a thickness**: a height field with an
index of refraction. Content bends hard toward the outline, a dome magnifies,
a ring stands up at its edge, bright edges split into colored fringes, and a
dome button can stand on a pill as part of the same glass. Apple's glass is
a fixed, system-defined shape; this is an authored one. With `.none` (the
`.rim` profile, no dispersion, no inlays) the panel is drawn by the `base`
pipeline variant, which is the shader of GW-21 byte for byte.

### The shape-field interface

The optics ask a panel's shape for four things and nothing else
(`GlassShapeField.swift` on the CPU, `GWShapeSample` and
`gw_shape_rounded_rect` in `Glass.metal`):

| Quantity | Meaning |
| --- | --- |
| `distance` | Signed distance to the outline in pixels, negative inside. Decides coverage. |
| `normal` | The unit direction in which `lensDepth` falls (outward). |
| `lensDepth` | Pixels inside the shape. **C1**: the inward distance of the rounded rectangle of radius `max(cornerRadius, bevel)` (at most the inscribed radius), the field `normalRadius` already uses, so its iso-contours keep a corner radius of at least the bevel and the height has no crease along the corner diagonals even when the bevel is wider than the corner. |
| `inscribedRadius` | Radius of the largest inside circle. A dome's bevel. |

The rounded rectangle is the only kind today. GW-26 adds ellipses, squircles
and blobs by returning the same four values.

### Profiles and the math

`GlassLens.profile`: `.rim` (default: the original refraction, uses
`refraction` and `bezelWidth`), `.circular`, `.squircle(exponent:)`,
`.chamfer`, `.dome`, `.ring(center:width:)`. For every profile but `.rim`,
`bezelWidth` is the bevel width and `refraction` is ignored (a dome's bevel is
the inscribed radius; a ring's is its outer edge).

1. `h = H s(t)`, `t = lensDepth / bevel`, `H` the thickness. The profiles:
   circular `sqrt(1 - (1 - t)^2)`; squircle `(1 - (1 - t)^n)^(1/n)`;
   chamfer a straight face (slope 1.18) that rounds into the top at
   `t = 0.7`; ring `sqrt(1 - ((t - c) / w)^2)`, a bump.
2. `N = normalize(-grad h, 1)`, `grad h = H s'(t) / bevel` along the inward
   direction; the slope is clamped to 12 (the circular profile is vertical at
   the outline, where `h` is 0 anyway).
3. `T = refract(-z, N, 1 / ior)`; the sample moves by `T.xy / (-T.z) * h`
   toward the interior, scaled by `lensOffsetScale` and at most
   `maximumOffset` long. IOR 1 leaves the ray straight.
4. **Fold.** With `allowsFold == false` the CPU samples the profile along the
   bevel and picks the scale (at most 1) that keeps the sampled depth
   `d + offset(d)` rising with slope of at least 0.05, so the content is
   magnified or compressed but never mirrored. With `allowsFold == true` a
   thick bevel mirrors the content at the edge, as in the fold demo on the
   lab's lens page.
5. A ring narrower than 2 pixels is widened to 2.

### Dispersion

`lens.dispersion` 0...1 and `lens.dispersionTaps` (`.threeTap`, `.sixTap`).
A wavelength `x` (-1 red to +1 blue) sees the index
`ior + x * dispersion * 0.12`; on the original rim profile, the rim's
displacement is scaled by `1 + x * dispersion * 0.35`. Three taps give red,
green and blue their own sample. Six taps sample wavelengths
-1, -0.6, -0.2, 0.2, 0.6, 1 and blend them with triangle weights centered on
red, green and blue, normalized so each channel's weights sum to 1 (11/21,
7/21, 3/21 for red; 0.15, 0.35, 0.35, 0.15 for green; mirrored for blue), so
white and gray stay neutral. Where red and blue land less than 0.25 pixel
apart (the flat middle) there is one sample. Every sample keeps the
valid-rectangle clamp. A dispersion above 0 on the `.rim` profile is the
rim's displacement split by wavelength, so the default panel can have fringes
too.

### Inlays

`lens.inlays` (at most 2): a bump of glass added to the panel's height field,
at `x`, `y` points from the panel's center, with a `radius`, a `height`, a
profile (`.dome` default; `.circular`, `.squircle`, `.chamfer`, `.ring`) and
a `rimLine`. The height and the slope add to the host's, so the dome bends
what is behind it and what the pill's thickness bends: a button on a pill in
one panel and one pass, with no overlapping quads (the quad is unchanged).
The height is 0 on the inlay's base, so height and offset are C0 across it;
outside its radius the field is exactly the host's. The `rimLine` is a line
about 1.5 px wide at the base plus a brighter inner bevel, both lit from the
upper left, and exactly 0 beyond half a pixel outside the base. The inlay
is a bump of the same glass, not a separate object refracting the pill
(stacking is Later).

### Pipelines

Function constant 0 (`gw_optics_constant`) selects the `optics` variant. Both
`base` and `optics` are built at initialization; `GlassRenderer.drawnVariants`
reports the variant that drew each panel of the last draw and
`pipelineCreationSeconds` the build time. A panel library without the
constant (a frozen earlier shader) has the one pipeline.

### GPU record

`GWGlassUniforms` grows from 1008 to 1152 bytes, append-only: a 48-byte lens
header at 1008 (profile, thickness, bevel, field radius, IOR, maximum offset,
offset scale, two profile parameters, dispersion, tap count, inlay count) and
two `GWLensInlay` records (48 bytes) at 1056. Sizes and offsets are asserted in
C, MSL and Swift (`ShaderLayoutTests`, with a distinctive-value round trip
through `LayoutProbe.metal`). The full record stays bound to both stages.

### Normalization

A non-finite value in the lens or in any inlay (also past the second) throws
`GlassParameterError.nonFiniteLens(_:)` naming a `GlassLens.Field`. Finite
values clamp: thickness 0...64 pt, IOR 1...2.4, maximum offset 0...512 pt,
dispersion 0...1, squircle exponent 1...8, ring center and width 0 to half
the shorter side; per inlay, position within +-4096 pt, radius 0 to half the
shorter side, height 0...64 pt, rim line 0...1; inlays with the `.rim`
profile or radius 0 are dropped; at most two are kept.
`GlassRenderer.panel` reports the lens that is drawn.

### Accessibility

| Setting | Lens |
| --- | --- |
| Reduce Transparency | removed: no profile, no dispersion, no inlays (the opaque surface) |
| Increase Contrast | dispersion removed; the profile and the inlays are kept (samples stay within the source's own colors) |
| Reduce Motion | no change; the lens is static |

### Lab

`-lab.lens YES` (or the lab's "Thick lens" button) opens the lens page;
`-lab.lensBackdrop orbs|dots|checkerboard|ribbons` picks the backdrop (default
orbs, a new original bench page of shaded spheres whose colored edges show the
dispersion; the dot grid shows the magnification). Panels: a squircle-bevel
pill with pooled light (GW-21), six-tap dispersion and an inlaid dome button;
a dome marble with three-tap dispersion; a ring; and the fold-off and fold-on
pair. Captures are in `docs/evidence/captures/gw-22-*`.

### Deviations and limits

- **No `GlassOptics.h`.** The optics live in `Glass.metal`, which is the one
  shader file the package compiles; a header there would only be a second
  file to keep in step. The profile functions are mirrored by
  `GlassLensModel.swift` (used for the fold scale and as a CPU reference of
  the height field), not compared with readback.
- **Rim line, not a light model.** The inlay's rim line and the panel's edge
  highlight are the only shading; Fresnel, specular streaks and studio
  reflections are GW-23.
- **Fold scale is a 1-D analysis** along a straight bevel (256 samples); a
  corner or an inlay on a thick pill is checked the same way, with the host
  height as the inlay's base. It is not proven for every 2-D configuration.
- **Not done:** the CPU mirror comparison, the corner-crease, monotonicity,
  centroid and magnification tests, dispersion tests beyond the lab pictures,
  the pipeline census, the temporal stability run and the M5 cost runs (see
  the checklist).
