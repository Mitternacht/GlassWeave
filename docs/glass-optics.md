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

## GW-23: Light model

> Experimental. `GlassLighting`, `GlassRenderer.setLightOffset(azimuth:elevation:)`
> and the `lighting` pipeline variant may change before a stable release.

One movable light gives the glass a Fresnel outline, a specular streak, an
analytic photo studio reflected on the rim, a chrome or prismatic finish, and
a soft bloom. The shader (`Glass.metal`, "Light model") is the reference of
the model; there is **no CPU mirror** of the per-pixel code (fast pass).

### API

`GlassParameters.lighting: GlassLighting`, default `.legacy`: no light model,
the original edge highlight, byte for byte (see "Off by default" below).
Otherwise:

| Field | Meaning |
| --- | --- |
| `key`, `rim?` | `Light`: azimuth (0 = top, clockwise, degrees), elevation (0...90), color, intensity, size (0 pinpoint, 1 broad). The key light also turns the studio. The rim light adds a specular streak only. |
| `environment` | `.studioLight` (pale sky, dark floor, white boxes) or `.studioDark` (near-black room, gray boxes). |
| `finish` | `.dielectric`, `.chrome(tint:)`, `.prismatic(spread:saturation:phase:)`. |
| `indexOfRefraction` | 1...2.4; sets `F0 = ((n - 1) / (n + 1))^2`. |
| `fresnel`, `specular`, `reflection`, `bloom` | strengths, 0...1. |
| `bloomWidth` | 0...24 pt. `bandWidth`: how deep the light terms reach; `nil` is the surface's bevel. |
| `drivesGlow` | the glow's `lightAngle` follows the key light (default `true`). |
| `crispOutline` | the Fresnel outline is a hairline that contrasts with the glass (used by the accessibility rows). |

`GlassRenderer.setLightOffset(azimuth:elevation:)` adds an offset (degrees) to
the key and rim lights each draw (a dragged light, tilt, or a sweep); it turns
the studio, the original edge highlight and the glow's light with the key
light, and nothing a panel without lighting draws depends on it. A non-finite
value throws `GlassParameterError.nonFiniteLighting(_:)` naming
`lightOffsetAzimuth` or `lightOffsetElevation` and leaves the offset as it was.
Every other field follows the normalization rule: non-finite values throw
`nonFiniteLighting(_:)` with the field's name; finite values clamp (azimuths
and the prismatic phase reduce into one turn).

### The model

The surface is the panel's own height field: the lens's (host profile and
inlays) or, with no lens profile, a quarter-round edge as wide as `bezelWidth`.
`N = normalize(-grad h, 1)`, viewer `V = (0, 0, 1)`, `L = (sin az cos el,
-cos az cos el, sin el)` (x right, y down, z toward the viewer).

- **Fresnel.** Schlick, `F = F0 + (1 - F0)(1 - N.z)^5`. The outline is
  `fresnel * (1 - N.z)^5` in the key color, a thin line where the surface turns
  edge-on, a little stronger on the lit side.
- **Specular.** Blinn-Phong `(N.H)^p` with `H = normalize(L + V)`, `p` from
  `size` (400 for 0, 12 for 1). The lobe is never narrower than one pixel's
  change of normal: with `f = 1.2 / bevelPixels` radians per pixel,
  `p' = 1 / (1/p + f^2)` and the peak is scaled by `(p' + 2) / (p + 2)`, so the
  widened lobe keeps its energy (no derivatives are used). With the default
  50 degree elevation a top light draws its streak about two thirds of the way
  into the bevel along the top edge.
- **Studio.** `R = reflect(-V, N) = (2 N.z N.xy, 2 N.z^2 - 1)` indexes a
  sky/horizon/floor gradient and three softboxes in (azimuth, elevation): a
  wide key box above (azimuth 0) and two tall strips at +-96 degrees, all turned
  by the key light's azimuth. Across a bevel `R` runs from the floor at the
  outline, through a bright horizon line, to the sky.
- **Dielectric.** `glass = glass (1 - a) + knee(studio) a`, with
  `a = saturate(F0 + (F - F0)(1 + 4 reflection)) reflection`: the part of the
  reflectance that grows toward the outline is boosted up to five times, so a
  studio shows on glass as in a photograph of it. At `N.z = 1` it is `F0`.
- **Chrome.** `glass = mix(glass, knee(studio * tint * (0.85 + 0.15 F)), a)`
  with `a = reflection * smoothstep(0.005, 0.08, 1 - N.z)`: it covers the
  tilted rim and fades into the flat face. It can darken, as polished metal
  does.
- **Prismatic.** The chrome finish with the thin-film palette
  `0.5 + 0.5 cos(2 pi (h + (0, 1/3, 2/3)))` multiplying the softboxes (the
  strips fully, the key box half, the base faintly, by `saturation`), where
  `h = phase + spread * (angle of N around the rim, relative to the light) +
  0.5 (1 - N.z)`. With the strips at the sides, glints appear left and right
  of a round ring, each a different hue.
- **Soft knee.** `K(x) = x` up to 0.8 and `0.8 + 0.2 (1 - e^(-5 (x - 0.8)))`
  above: C1 at 0.8, monotonic, below 1. The lines (Fresnel outline,
  specular) and the bloom pass through it as `G + (1 - G) K(E)`, which never
  darkens a channel and never exceeds 1.
- **Bloom.** The bright lines are re-evaluated at three distances
  (`bloomWidth * 1/4, 2/4, 3/4`) on either side along the outline's normal,
  weighted `(1 - k/4)^2`, taps outside the outline skipped, and added at
  `0.6 * bloom`: distance-based, in the same pass, exactly zero beyond
  `3/4 bloomWidth` from a line, and it spreads only inside the panel (the quad
  does not grow).
- **Legibility.** Every light term lives inside `bandWidth` of the outline
  (smoothly cut over its outer quarter); the bloom reaches `bloomWidth` past
  it. The panel's flat interior is untouched, so the tint bound of
  `GlassLegibility` holds there; a `.dome` lens has no flat interior, so its
  band is the whole dome.

### Off by default

The light code exists only in the `lighting` pipeline variant, built with
function constant 1 (`gw_lighting_constant`; the variant also sets constant 0,
the thick-lens code, which stays dormant for a rim profile). `.legacy` panels
are drawn by the `base` and `optics` variants, which are compiled without the
code, so their output is the GW-22 shader's, byte for byte
(`GlassBaselineGW22Tests`, against the frozen `GlassBaselineGW22.metal`).
`GlassRenderer.PipelineVariant.lighting` is new; all three pipelines are built
at initialization. With the light model on, the original edge highlight's and
the inlays' rim-line light follow the key light (they come from the upper left
otherwise).

### GPU record

`GWGlassUniforms` grows from 1152 to 1312 bytes, append-only: one
`GWLightingUniforms` (160 bytes, alignment 16) at offset 1152, with its own
size and offset asserts in C (`GlassWeaveShaderTypes.c`), MSL (`Glass.metal`)
and Swift (`ShaderLayoutTests` checks the new record size). Enums:
`GWLightingFinish`, `GWLightingEnvironment`.

### Accessibility

| Setting | Light model |
| --- | --- |
| Reduce Transparency | a thin crisp rim: the Fresnel outline as a contrasting hairline (light on dark, dark on light) within 2 pt of the outline, no reflections, specular, rim light, finish or bloom (the panel is the opaque surface) |
| Increase Contrast | the same hairline in the bevel band, evenly lit; reflections, specular, rim light, finish and bloom removed |
| Reduce Motion | no change: the light moves only when the app moves it |

Implemented in `GlassAccessibilityPolicy.presentedLighting`. Under Increase
Contrast the hairline replaces an additive outline that would not show on a
white surface; the glow's rim is still the other way to mark a boundary.

### Lab

`-lab.chrome YES` (or the lab's "Chrome and light" button) opens the chrome
page: one new bench page of three original backdrops (a pale studio plate, the
orbs, black with glowing orange liquid) and three panels: a round ring button
with a chrome rim and prismatic glints, a thick lens pill with a warm top
streak, bloom, a pooled colored light and an inlaid dome, and a dark smoky dome
with gray studio strips on its rim. Drag anywhere to move the light
(`setLightOffset`); `-lab.lightAzimuth <deg>` and `-lab.lightElevation <deg>`
start with an offset. Captures: `docs/evidence/captures/gw-23-*` (the page, the
light turned 90 degrees, Increase Contrast, Reduce Transparency, the ring in
detail). Tuned in three rounds: the first showed an overexposed liquid and no
strips on the dome (fixed by the reflection boost and a smaller, darker
liquid), the second a dark outer band and weak glints on the ring (lighter
floor, brighter and wider strips), the third added the contrasting hairline,
because the first accessibility captures showed no rim at all on an opaque or
white surface.

### Deviations and limits

- **`drivesGlow` instead of "unless the glow sets `lightAngle`".** `lightAngle`
  is a plain `Double` (0 is a valid explicit value), so the glow cannot tell
  "unset"; a flag on the lighting says whether it follows the key light.
- **`crispOutline`** is new (not in the proposal): the accessibility rows
  needed a rim that shows on a white or opaque surface.
- **No `GlassOptics.h`, no `GlassLegibility` change:** the code is in
  `Glass.metal`, and the light stays in the band, so the legibility functions
  are unchanged.
- **Rim lights are specular only**; an HDR or EDR path and caustic bloom
  (GW-25) are not here.
- **Not done:** the CPU mirror, every numeric acceptance test (reflected
  fraction, specular peak, 90 degree rotation, prismatic hue, knee, bloom
  bound, `setLightOffset` rejection, glow following), the legibility
  sweep, the UIKit accessibility tests, the M5 cost runs, the "Light studio"
  light and dark captures, and device sign-off (see the checklist).
