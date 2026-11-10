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

- **Surface clock (closed by the merge of GW-27).** `GlassSurfaceView` runs
  its effect clock while a presented panel's `GlassParameters.isAnimated` is
  true, which includes the inner light and a wobbling shape as well as the
  glow and the interior (it reads the panels after the quality tier and the
  accessibility policy, so Reduce Motion stills all of them). The lab's light
  fields and shapes pages no longer have an update link of their own; a still
  `-lab.lightTime` or `-lab.shapesTime` pauses the clock with
  `GlassSurfaceView.isEffectClockPaused` and sets the `timeOffset`.
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

## GW-25: Grounding: shadows and colored caustics

> Experimental. `GlassGrounding`, `GlassParameters.grounding`,
> `GlassRenderer.PipelineVariant.grounded` and `groundingDrawCount` may change
> before a stable release.

A glow or a halo is screened light and cannot show on white. On a light page,
depth comes from the opposite: the glass darkens what is around it and focuses
a little light. `GlassParameters.grounding: GlassGrounding` (default `.none`)
adds a drop shadow, a contact shadow, an inner shadow and a colored caustic, all
analytic from the panel's rounded-rectangle field and all driven by one
direction: away from the key light. The shader (`Glass.metal`, "Grounding") is
the reference; there is **no CPU mirror** of the per-pixel code (fast pass).

### API

| Part | Fields | Meaning |
| --- | --- | --- |
| `drop` | `offset` (0...64 pt), `blur` (0...64), `spread` (-32...32), `opacity`, `color` | The outline moved away from the light with a Gaussian edge of standard deviation `blur / 2`; multiplies the page. |
| `contact` | `width` (0...3 pt), `opacity`, `color` | A tight line at the outline, `(1 - d / width)^2`, offset `0.3 width` away from the light; multiplies the page. |
| `inner` | `offset`, `blur`, `opacity`, `color` | An inset shadow moved away from the light: it shades the glass just inside the outline on the side nearest the light, under the highlights (linear light). |
| `caustic` | `offset` (-32...64), `radius` (0...48), `intensity`, `color`, `dispersion`, `spectrum` | A band of colored light along the outline moved away from the light, `exp(-(d / radius)^2)`, weighted `facing^2` by how far the outline faces away from the light. `dispersion` parts its red, green and blue bands (0.55 radius each way at 1); `spectrum` turns its hue around the band. Added to the page and to the glass; never darkens a channel. |
| `lightAzimuth`, `lightElevation` | degrees | The light when `lighting` is off. With `lighting` on, its key light (and `setLightOffset`) sets the direction and the elevation. |

Offsets scale with the light's elevation by `tan 50 / tan elevation`, clamped
to 0.35...3, so a lower light throws a longer shadow. Colors are sRGB-encoded.
Normalization follows the rule: a non-finite value throws
`GlassParameterError.nonFiniteGrounding(_:)` naming the field
(`dropBlur`, `causticRadius`, ...); finite values are clamped, azimuths reduced
into one turn.

### Two passes

1. **Pre-pass.** After the background and before any panel body, each grounded
   panel gets one quad (the panel rectangle grown by `grounding.reach`, which
   covers the offsets and three standard deviations) that is *blended* onto
   the target: the shadows multiply (`destination * source`), then the caustic
   adds. The target is the encoded `bgra8Unorm`, so these are **encoded-space**
   operations; a multiply there approximates a multiply in linear light (the
   sRGB toe error was not measured, fast pass). A shadow never raises a
   channel; a caustic never lowers one.
2. **Body.** The `grounded` pipeline variant (function constants 0, 1 and 2
   true) writes premultiplied `(encoded * coverage, coverage)` over the target
   with `one, oneMinusSourceAlpha` blending. Pixels outside the outline write
   nothing, so **the body quad does not need to grow and a neighbour's shadow is
   never erased**; the antialiased ring mixes with whatever the pre-pass left,
   other panels' shadows included. Inside, the inner shadow multiplies the
   glass in linear light, and the caustic is added (encoded) over everything,
   continuing the pre-pass's across the outline. This is why the drop shadow is
   outside the outline only: it is never drawn through translucent glass.

Why a pre-pass and not a bigger body quad: a body quad is computed from the
background sample, not from what is under it, so two quads that overlap erase
each other. A round button 8 pt from a pill, each with a 16 pt shadow, would
lose the pill's edge or the button's shadow. With the pre-pass the paper desk
capture shows both bodies whole and the button's shadow falling on the page
between them.

### Off by default

The grounding code exists only in the `grounded` variant. `.none` (or any
grounding with all opacities and the caustic intensity at 0) is drawn by the
`base`, `optics` or `lighting` variant, which are built without function
constant 2, and no pre-pass quad is drawn (`groundingDrawCount` is 0), so the
output is the GW-23 shader's, byte for byte (`GlassBaselineGW23Tests` against
the frozen `GlassBaselineGW23.metal`; the frozen file defines its own record
types and uses a `gw_gw23_` prefix). `GlassPanelGeometry.quadOutset` includes
`grounding.reach`, so a panel whose shadow reaches the target is not skipped.

### GPU record

`GWGlassUniforms` grows from 1312 to 1440 bytes, append-only: one
`GWGroundingUniforms` (128 bytes, alignment 16) at offset 1312, with its own size
and offset asserts in C, MSL and Swift (`ShaderLayoutTests`). Flags:
`GWGroundingFlagActive`, `Shadow`, `Caustic`, `Inner`.

### Accessibility

| Setting | Grounding |
| --- | --- |
| Reduce Transparency | drop and contact kept (they ground the opaque surface); caustic and inner shadow removed |
| Increase Contrast | contact only, at least 0.45 dark and 1.5 pt wide, as a clearer boundary; drop, inner and caustic removed |
| Reduce Motion | no change: grounding is static |

Implemented in `GlassAccessibilityPolicy.presentedGrounding`; no new
accessibility tests (fast pass).

### Lab

`-lab.paper YES` (or the lab's "Paper desk" button) opens the paper desk: a new
bench backdrop (page 7, `BenchPage.paperDesk`: warm paper, a faint graph grid,
printed colored dots, fine grain) with a 76 pt chrome-ring button and a lens
pill 8 pt apart, and a glass marble below, lit from the upper left (key
azimuth 315). Drag anywhere to move the light (`setLightOffset`; the shadows and
caustics swing with it); `-lab.lightAzimuth <deg>` starts with an offset.
Captures: `docs/evidence/captures/gw-25-paper-desk-*` (the page, the ring and
pill in detail, Reduce Transparency, Increase Contrast, the light turned).
Tuned in three rounds after the first render: (1) the first caustic was a neon
glow that hid the shadow, because a wide, strong additive band sits where the
shadow is darkest, so the caustic was narrowed to a fringe; (2) the shadows were
too faint (a 30 pt blur at 0.45 opacity darkened the page by about 11 % at the
body), so opacity and offset went up and blur down; (3) the caustic was widened
a little and given the full hue turn so it reads as colored light pooled in the
shadow, not a rainbow line.

### Compared with the picture it targets

Reference 3 is a polished chrome-banded ring on a light surface with a soft
shadow. What matches: a soft, bluish shadow under and to one side, a dark
contact line where the glass meets the page, bodies that stay whole beside a
close neighbour, prismatic glints on the ring (GW-23). What does not: the ring
button here is a thin ring around a white face, not a thick banded chrome ring
(the lens or finish does not model a flat embossed band); the shadow is a
Gaussian of the outline, with no ambient-occlusion lobe under the whole body;
the caustic is a thin colored fringe, not a bright patch with a sharp core.

### Deviations and limits

- **Premultiplied blending in the body** instead of the proposal's "body
  applies its shadow to its antialiasing ring": the body leaves outside pixels
  alone and the hardware composites the ring over the pre-pass, which also
  keeps a close neighbour's shadow under the ring.
- **The drop shadow is outside the outline only.** The proposal's "evaluate the
  shadow at the refracted position inside" was dropped: darkening a translucent
  body by its own shadow looks like dirty glass. The inner shadow and the
  caustic are the inside cues.
- **Other panels' shadows are not seen through a body**, and a panel with a halo
  draws the halo opaque over its own shadow (other panels' shadows under the
  halo are replaced).
- **`lightAzimuth` and `lightElevation`** are new (the proposal says "the light
  comes from GW-23"): they carry the direction for a panel with `lighting`
  off.
- **Two draws per panel** (shadow multiply, caustic add) instead of one,
  because a per-channel multiply and an add need different blend factors; a
  caustic-only or shadow-only panel draws one.
- **Not done:** the CPU mirror, every numeric acceptance test (channel
  monotonicity, darkening centroid, seam, two-neighbour readback, CPU
  encoded-space mirror), the M5 cost run, and the device-only light-mode check
  (see the checklist).

## GW-26: Freeform shapes: ellipses, squircles and smooth blobs

> Experimental. `GlassShape`, `GlassBlob`, `GlassParameters.shape`,
> `GlassPanel.shapeBounds`, `GlassParameterError.nonFiniteShape(_:)` and
> `GlassRenderer.PipelineVariant.shaped` may change before a stable release.

Native glass takes a shape from a fixed set. `GlassParameters.shape:
GlassShape` (default `.roundedRectangle`, the original path, byte for byte)
adds `.ellipse`, `.superellipse(exponent:)` (2...10; `.squircle` is 4) and
`.blob(GlassBlob)`: a smooth union of up to six circles, capsules and rotated
rounded boxes, with an optional loop-locked wobble. **Every** effect follows
the outline: the antialiased edge, the rim refraction, the thick lens (height,
normal, dispersion, inlays), the glow's rim, inner glow and halo, the interior
and the inner light, the light model's Fresnel line, reflections and bloom,
and the grounding's drop, contact and inner shadows and caustic. The shader
(`Glass.metal`, "Freeform shapes") is the reference; the CPU mirror is only the
trivial one (`GlassShapeField` types, used for the quad and the inscribed
radius).

### The shape field

Every shape answers the four things of the GW-22 interface (`GWShapeSample`):

| Quantity | Ellipse and squircle | Blob |
| --- | --- | --- |
| distance | first-order `(k0 - 1) / abs(grad k0)` of the homogeneous `k0 = (abs(x/a)^n + abs(y/b)^n)^(1/n)`; exact on the outline and on the axes; the gradient has unit length | polynomial smooth minimum of the primitives' distances, `min - k h^2 / 4` with `h = max(k - abs(a - b), 0) / k`, folded in order; renormalized by `max(abs(grad), 0.3)` so the antialiased edge is one pixel wide, the renormalization fading out deeper than 35 % of the inscribed radius |
| normal | `grad / abs(grad)` | the blended gradient, `(1 - h/2) grad(min) + (h/2) grad(other)`, normalized: C1 through a neck |
| lens depth | `max(-distance, 0)` | the same |
| inscribed radius | the shorter half side | sampled on the CPU (a lower bound: the raw field is 1-Lipschitz) |

The lens depth is C1 only while the bevel is narrower than the outline's
smallest radius of curvature (for a blob, its smallest convex part); a wider
bevel creases along the medial axis, where the rounded rectangle's
`lensFieldRadius` would have rounded it. The renderer clamps the bevel to the
inscribed radius.

### Coordinates, bounds, normalization

Blob coordinates are **frame units**: origin at the frame's center, y down, 1
is half the frame's shorter side, so a blob scales with its frame and a circle
stays a circle. The quad is the outline's bounding box, not the frame: the CPU
takes the union of the primitives' own extents and the sampled extent of the
blob (48 x 48 samples, 1.5 cells of margin, inside the largest bulge
`(n - 1) k / 4` a smooth union can add), plus the wobble's amplitude, and the
shader's `panelCenter` and `panelHalfSize` are that box. `GlassPanel.shapeBounds`
reports it in points; `reachesTarget` uses it. The glow's angle (turns around
the box, panel scaled to a square) and the light emitters' unit space stay
those of the box; the interior's and the light's depth fraction use the
inscribed radius (`min(halfSize)` for the rounded rectangle, unchanged). A
blob's bounds and inscribed radius are cached by shape and frame size.

Normalization follows the rule. A non-finite value throws
`GlassParameterError.nonFiniteShape(_:)` naming the `GlassShape.Field`;
finite values are clamped: exponent 2...10, positions -4...4, radii and half
sizes 0...4, corner radius to the smaller half size, smoothness 0...2, wobble
amplitude 0...0.1, wobble speed 0...3; an empty blob becomes one circle of
radius 1; primitives past six are dropped (a non-finite value in a dropped one
still throws). A blob's lengths (bezel, rim, reach) are capped at its
inscribed radius instead of half the shorter side. `cornerRadius` is ignored by
the other shapes; lens inlays are placed relative to the quad's center.

### Pipeline

The shape code exists only in the `shaped` pipeline variant, built with
function constant 3 (`gw_shape_constant`). A panel with a shape draws in it
whatever else it draws: the variant has the lens, light-model and grounding
code too, each gated at run time by the panel's own record (a zero record is
the effect off). The grounding pre-pass has shaped shadow and caustic
pipelines, so the shadow is the shape's. Rounded-rectangle panels keep their
four variants with the constant set to false, so the shader is the GW-25 one
(a frozen copy, `GlassBaselineGW25.metal`, proves it). The panel record grows
by `GWShapeUniforms` (336 bytes) to 1776; sizes asserted in C, MSL and Swift.

### Wobble

Three plane waves (amplitude `amplitude / 3` each, wavelength 1.6 frame units)
whose phases turn 6, 9 and 13 times per 64 s of wobble time
`(effectTime + timeOffset) x speed`, so the shape repeats exactly every 64 s.
The raw distance and its gradient both include the waves, so the normal and
every effect follow. The surface's effect clock runs for it (and for
`GlassLight`) because `GlassParameters.isAnimated` includes both; a host
needs no clock of its own and leaves `timeOffset` at 0 unless it shows a still
moment.
Reduce Motion: `GlassAccessibilityPolicy.presentedShape` sets `speed` 0, a
still, slightly irregular outline. Reduce Transparency and Increase Contrast
keep the shape.

### Overlapping quads (rule 10)

`GlassRenderer.overlappingQuads(displayScale:)` (package) lists every pair of
panels whose quads share area; the quad is the bounding box grown by one pixel,
the halo and the grounding's reach. The lab's shapes page computes the same
from `shapeBounds` (the package API is not visible to the app) and prints
`quads overlap: none`.

### Lab: the shapes page

`-lab.shapes YES` (or the "Shapes" button) opens an ellipse with a pooled
light band, a squircle with an orb, a pebble blob (a smooth union of two
circles and a capsule) and a wobbling triple (three circles and a tilted box)
joined by smooth necks, each with a glow, an inner light, a thick lens with
six-tap dispersion, and the light model. `-lab.shapesBackdrop <page>` picks
the bench page (default charcoal); `-lab.shapesTime <s>` freezes the wobble.
Captures: `docs/evidence/captures/gw-26-shapes-charcoal-iphone18pro-sim.png`
and `gw-26-shapes-orbs-iphone18pro-sim.png`.

### Deviations and limits

- **Fast pass.** One safety test (a rounded rectangle is byte-identical to the
  frozen GW-25 shader in the four variants and the grounding pre-pass, and an
  ellipse draws in the `shaped` variant and differs). Not done, and unchecked:
  the circle and capsule distance tests, the 360-direction outline and ellipse
  area tests, the neck smoothness measurements, the blob CPU mirror of the
  glow, halo and light, the antialiasing and quad-containment tests, the wobble
  period test, the M5 cost run, the "pebble garden" capture, and the
  device-only cost.
- **One superset variant instead of a shape flag on each variant**: a panel
  with a shape always pays for the lens, light-model and grounding code in its
  pipeline (four more pipelines at init). Cheaper per variant would need
  sixteen pipelines.
- **The renormalization fades out deep inside** (35 % of the inscribed radius):
  a primitive's medial lines, where its gradient jumps, jumped the depth in
  the middle of a blob (a hard-edged wedge in the first capture).
- **An arc light is an angular fan from the box's center**: on a blob it
  draws a wedge; the lab's pebble uses a band.
- **A shaped panel's `inscribedRadius` is a lower bound**, so a depth fraction
  reaches 1 slightly early, and the ellipse's distance is first order (exact at
  the outline and on the axes' ends), so depth deep inside an elongated
  ellipse is clamped to the shorter half side.
- **`PipelineVariant` gained a case** and `GlassParameterError` a case;
  `ShaderLayoutTests` changed only the record size, the new offset and the
  record's new memberwise argument.

## GW-28: Liquid and gel fill

`GlassParameters.fill` (`GlassFill`, default `.none`) puts a luminous liquid or
gel inside the glass. Source: `GlassFill.swift` (API, normalization,
`GlassFillSlosh`), `GlassFillModel.swift` (CPU model and bubbles), the "Liquid
and gel fill" section of `Glass.metal`. Experimental.

**Pipeline.** A panel with an active fill is drawn by the `filled` variant:
function constant 5 (`gw_fill_constant`), two pipelines (rounded rectangle and
freeform shape), all built at initialization. The fill is its own record,
`GWFillUniforms` (784 bytes, bound at fragment buffer 2 to those variants only),
so `GWGlassUniforms` keeps its 1776 bytes and every frozen shader still
compiles. With `.none` the code is compiled out: byte for byte the shader
before GW-28, proved by `GlassBaselineGW28Tests` against a frozen copy that
includes the GW-24b frost. A panel with a fill draws no frost (the variant
excludes it).

**Seen through the shell.** The fill's field is read at the position the shell
sends the pixel to (`q' = q + offset`, the thick lens's or the rim's
refraction), so the wall magnifies and bends it. The coverage is cut in pixel
space by the inset shell (`outline distance + wallThickness`), so no liquid is
shallower than the wall. The wall line and the glow outside the liquid are also
drawn in pixel space.

**Regions.** `.level(level:tilt:)`: below a waved surface line
`y = y0 + tan(tilt) x + waves - meniscus`, the meniscus climbing the inset wall
as `m exp(-d / reach)`; level 1 is exactly the inset shell. `.gel(shape)`: its
own GW-26 field (frame units, any shape but the rounded rectangle, which becomes
a squircle), `max(gel distance, inset distance)`. A blob's wobble is its
loop-locked motion.

**Body (enhance pass).** The thickness is a parabolic dome `h = 1 - (1 - s)^2`
over the depth `s` into the region (the depth over a dome radius: 55 % of the
gel's inscribed radius, 60 % of a level vessel's inset depth), plus a slow field
of luminous masses (two octaves of value noise, cells 1.25 dome radii wide,
drifting on small loops: `region.w` carries the flow phase, two turns per 64 s
divided by `surface.waveSpeed`). The gradient of that height, with the dome's
slope scaled by 0.55, is a surface normal. One key light (the light model's, or
the upper left, set low over the screen) shades it: `shade = 1 + 0.55 (n.l - n.l
flat)`, so the lit side is brighter and yellower (the ramp parameter takes
`0.30 facing`) and the far side a deeper amber. Beer-Lambert absorbs what is
behind: `T = exp(-sigma h R)`. The liquid's own light is
`ramp(t) (0.08 + 0.92 (1 - exp(-2.4 h))^1.3) emission`: dark amber toward the
walls, a calm glow in the thick middle, and a core that saturates at the dome
radius (so the distance field's ridges never show as creases; the depth of a
gel clipped by the inset wall, and a level's depth against its surface, are
blended with a smooth minimum for the same reason). **Gloss** (`GlassFill.gloss`,
record `padding0`): a Blinn specular `0.85 cos^30 + 0.07 cos^6` against the half
vector, which tilts 33 degrees toward the light, so a soft streak follows the lit
wall about 0.4 dome radii inside it, plus a narrow golden line a little inside
the far edge (light through the thin liquid), a glossy meniscus line with a
brighter band just under it, and the edge line. What is inside the liquid is seen
through its curved surface: the masses, the sheets and the bubbles are read at
`q - n.xy 0.14 R`, so near the edge they stretch and the sheets crowd toward the
wall (the edge magnifies like a lens). The liquid's index is 1.33 (record field
`ior`, which sets that bend).

**Edges.** Up to four contour sheets (the balanced tier two): iso-offsets of the
depth seen through the surface, bent by noise, spaced 22 % tighter on the lit side
than on the far one and faded out toward the distance field's middle. Each is a
thin edge (sharp outside, 2.4 times softer inside), a weak bloom in a saturated
gold (not the pale of the thin lines, which washed the amber to beige), a soft
dark gap just outside it, and a slightly lifted inside; all weighted toward the
side that faces the light (`0.10 + 0.90 facing^1.6`) and added through the light
model's soft knee (so nothing exceeds 1). In the glass: a thin wall line at the
inset boundary, a tight glow and a wide faint one that warm the dark wall near the
liquid, a soft long gradient on the lit wall (a gaussian band centered 0.42 bezel
widths inside the outline) and a faint secondary rim on the far wall (the wall's
inner face, 0.16 bezel widths inside), both a cool gray warmed a third toward the
liquid.

**Bubbles.** Up to 16, computed on the CPU per draw (`placeBubbles`): candidate
points from a hash of the seed, kept only if inside the region with room for
their radius, their drift, a gel's wobble and a level's waves; each drifts on a
small loop of whole turns per 64 s, so none is ever outside the liquid and the
motion repeats exactly. Drawn as a tiny disc of air (a little darker) with a micro
highlight toward the light and a fainter one opposite: no ring, no crescent.

**Slosh.** `GlassFillSlosh` is a deterministic damped spring in fixed 1/240 s
steps. `nudge(velocity:)` reports the vessel's horizontal velocity (the surface
swings the other way); the rest angle is `-vesselTilt`; `isSettled` is within
0.1 degrees and 0.5 degrees per second, after which nothing needs redrawing. The
app passes `tilt` into the region and may scale the waves by `agitation`.

**Tiers and accessibility.** Balanced: at most 2 sheets and 8 bubbles. Minimal: no
sheets, no bubbles, flat surface. Reduce Transparency: a flat opaque fill
(`opaque`: one color, no ramp, sheets, lines, gloss, wall reflections, bubbles or
waves). Reduce Motion: bubbles, waves, the body's flow (`waveSpeed`) and a gel's
wobble at speed 0, a still frame. Increase Contrast keeps the fill; no text over
a fill (it has no legibility bound).

**Look and limits.** First pass: four rounds against Apple's own glass (the native
Close and Nudge buttons on the same stage): a dark, mostly clear smoky body (tint
strength 0.5), a thin crisp rim from the refined light model, a calm gel. Enhance
pass (ENHANCE-VESSEL): five rounds against the private reference of thick smoky
glass with orange liquid, with a real `UIGlassEffect` twin in the same frame. The
large vessel is now an organic GW-26 shell (a smooth union of two round masses and
a soft box) holding a gel that wets the lower and right walls; the picture reads
as the same family as the native glass (dark smoky body, one thin rim) with a
liquid that has volume. Tuning notes: lobes at amplitude 0.7 on small cells read
as mottled cheese (now 0.55 on 1.25 dome radii, read through the dome); three
equal-spaced sheets read as a topographic map (now two or three, tighter on the
lit side, faded near the middle); the pale line color washed the lit side to
beige (broad terms now use a saturated gold); distance-field ridges showed as
straight seams, in the depth, the normal (blended now), the core (saturates at the
dome radius) and the sheets' plate (no lit weighting). Still missing against the
reference: white-hot sheet edges, a real specular spot on the liquid's curved
surface, parallax, and the gray studio reflections on the thick rims (left out
on purpose: the user asked for restraint). A level fill has no second tap for the
background seen through the liquid (the lens's single refraction is all the
background gets). Quads of panels must not overlap, as always.

## Apple-grade defaults (REFINE)

> Experimental. `GlassLighting.Look`, `GlassLighting.look`, and
> `GlassLighting.refined(azimuth:environment:finish:)` may change before a
> stable release.

The phase 1 pictures looked bubbly and fake: soap-bubble rings and crescents on
the smoky dome, gray wedge-shaped studio strips, a round glare spot, thick
jelly outlines, neon halos, a ring button that read as a thin white face. The
goal of this pass is glass that looks like Apple's Liquid Glass, with more
capability: a mostly clear body, real edge refraction, a thin crisp rim that is
brighter on the lit side, calm frost and shadow, color as a quiet pooled tint.
One light direction (the upper left, azimuth 315) lights every highlight.

### How it was compared

The lab's "Native vs refined glass" page (`-lab.compare YES`,
`-lab.compareBackdrop charcoal|orbs|paper`) draws a real `UIGlassEffect` view
(`.regular`, and `.clear` for the last row) above the same GlassWeave surface
that draws our panels, so both sample one backdrop: a dark charcoal stage, the
colorful soft-pebble scene (the orbs), and light paper. Four matched shapes per
row: capsule, circle, rounded rectangle, and a clear capsule against our thick
lens. Captures: `docs/evidence/captures/gw-refine-compare-*`. I measured the
native rim on the charcoal stage (pixel rows through the capsule) and matched
its structure: a 1 to 2 pixel bright hairline at the outline, a soft gradient
about 10 points deep, and no second ring inside; on paper a faint gray
hairline and a soft low shadow, body slightly lighter than the page.

### What looked fake, and the cause

| Phase 1 capture | What looked fake | Cause |
| --- | --- | --- |
| Smoky dome (chrome page) | Soap-bubble rings and crescents, a glare dot, gray wedges | The classic studio's horizon line (a bright ring where the reflection vector crosses the horizon), its two tall strips and wide key box, a Blinn-Phong lobe that is a round spot on a dome; ring-and-speck "bubbles" drawn in the backdrop |
| Lens pill (chrome, lens pages) | A hot yellow streak, magenta bloom, a bright inlay ring | Specular 0.9 with bloom 0.6 and a warm key; light intensity 0.85; inlay `rimLine` 0.6 to 0.9 |
| Ring button | A thin white-faced ring, not a polished edge | A 6 pt bevel with a white tint: the chrome band replaced the glass on a face-wide band |
| Ring profile demo | A soap-bubble ring | The `.ring` lens profile as a default demo shape |
| Fold pair, orbs | Gritty streaks | A felt grain of 22 % on the orbs backdrop, magnified by the lens |
| Shapes page | A thick gray jelly outline, orange and pink halos, wobbling edges | Outline from the horizon ring; halo intensity 0.5 with a colored rim 2.5 pt wide and an inner glow; wobble amplitude 0.03 to 0.035 |
| Paper desk | Heavy dark outline, a cyan neon caustic | Contact shadow 0.65 and drop 0.75; caustic intensity 0.5 with full spectrum |
| Light fields | Neon bands and a fully saturated field | Emitter intensity 0.95 with piping 0.85 to 1 |

### The refined look (shader)

`GlassLighting.look` is `.classic` by default: the GW-23 model, byte for byte
(the frozen-shader safety tests still compare it). `.refined` switches the
`lighting` pipeline variant to new code in `Glass.metal` ("Refined look"); the
look travels in `GWLightingUniforms.tint.w` (0 classic, 1 refined), which was
zero padding the GW-23 shader never reads, so the record keeps its 160 bytes
and its offsets. Everything stays inside the existing `bandWidth` (the bevel by
default), so the legibility bound still holds.

- **Rim hairline.** A fixed 1 to 2 pixel line at the outline (`1 - smoothstep(0.4, 1.8, depth)`),
  independent of the lens profile (a tilt-based line was too faint at the last
  pixel). It mixes toward a gradient color: sky on the lit side, floor on the far
  side, so it shows as a thin gray line on a light page and a light line on a
  dark one. Weight `0.55 + 0.30 lit + 0.45 back`: a little stronger toward
  the light and on the echo opposite it. Strength: `fresnel`.
- **Soft Fresnel body.** `f0 + (1 - f0) tilt^3.5`, mixed toward the same gradient
  at `0.5 × reflection`: the rim reads as the edge of a thick clear body. It is
  confined to the outermost part of the bevel by the exponent, so there is no
  inner ring.
- **One soft highlight.** A window in the surface tilt (`1 - N.z`) placed by the
  key light's elevation (a low light lands near the wall) and at least 0.14 wide
  (and never narrower than a pixel and a half), times `lit³`, the cube of the
  angular factor `(0.5 + 0.5 cos)²`: it runs along the rim, fades over a
  quarter turn to either side of the light, and is not a spot. Peak
  `0.16 × specular` before the knee. The optional `rim` light adds a second one at
  60 %.
- **Edge gradient.** Sky toward the light and floor away from it, smooth, no
  horizon line, no boxes. `.studioLight`: sky (0.97, 0.975, 1), floor (0.40, 0.41,
  0.46); `.studioDark`: sky (0.30, 0.31, 0.35), floor (0.07, 0.07, 0.08), in
  linear light.
- **Polished glass edge** (`.chrome`, `.prismatic`). Across the bevel: a darker
  wall at the outline (the floor color, ×0.62 on light pages), one soft bright
  band at tilt 0.26, then the clear face; alpha `reflection × (0.30 + 0.42 band +
  0.38 wall)`, at most 0.85, so the backdrop still shows through. The thin-film
  hue multiplies the band and half of the wall only.
- **Bloom.** The same three-tap spill, but at `0.4 × bloom` instead of 0.6, from
  the refined lines (neutral, short).
- **Accessibility.** The policy copies the whole `GlassLighting` and zeroes
  `reflection`, `specular`, `rim`, `bloom` and the finish, then sets
  `crispOutline`; the refined path reads exactly those fields, so Reduce
  Transparency and Increase Contrast give the same thin contrasting hairline
  as before (`GlassAccessibilityPolicy.presentedLighting`, unchanged). Reduce
  Motion: the light does not move, as before. Captures:
  `gw-refine-compare-charcoal-increase-contrast-*`, `gw-refine-compare-paper-reduce-transparency-*`,
  `gw-23-chrome-reduce-transparency-*`.
- **`GlassLighting.refined(azimuth:environment:finish:)`** returns the tuned
  starting values: key 50° (size 0.3), `fresnel` 0.55, `specular` 0.5,
  `reflection` 0.4, `bloom` 0.12 over 3 pt.

### Demo defaults that changed

`RefinedLook.swift` (lab) holds the shared starting values; every page builds
from it and adds only what the page is about.

| Value | Phase 1 | Now | Why |
| --- | --- | --- | --- |
| Light | classic studio, key 315 to 330, size 0.25 to 0.45 | `.refined`, 315, 50°, size 0.3 | one light, no wedges or rings |
| `edgeHighlight` | 0.3 to 0.8 | 0 on lit panels | the lighting model draws the rim; two rims read as a plastic bevel |
| `fresnel` / `specular` / `reflection` | 0.5 to 0.9 | 0.55 / 0.5 / 0.4 (buttons and the marble 0.8 / 0.5 / 0.9 for a crisper edge on paper) | restraint |
| `bloom`, `bloomWidth` | 0.25 to 0.6, 3 to 8 pt | 0.12, 3 pt (0.1 on the dome) | neutral, no neon |
| Body tint | none, or smoky 0.3 to 0.62 | 0.10 of a quiet gray on dark pages (matches the measured native body), 0.25 white on light pages, 0.15 on the ring | a calm material, not a gel |
| Lens | thickness 40 to 60, ior 1.5 to 1.9, offset 80 to 120, dispersion 0.7 to 1 six-tap | thickness 24 to 34, ior 1.45, offset 44, dispersion 0.3 three-tap (0.45 to 0.5 six-tap on the large pill and the round lens), squircle 3 | dispersion at the bevel only (the profile is flat in the middle) and low; the fold pair keeps ior 1.7, thickness 44, offset 100 so the fold still shows |
| Inlay `rimLine` | 0.6 to 0.9 | 0.25 | subtle dome |
| Default shapes | blobs, ring profile | capsule, circle, rounded rectangle, ellipse, squircle; the ring profile demo became a round lens | clean by default |
| Blob wobble | amplitude 0.03 to 0.035 | 0.012, speed 0.5 to 0.6 | slow, small motion |
| Glow on the shapes page | rim 2.5 pt, softness 5, inner glow 26 pt at 0.5, halo 9 pt at 0.5 | rim 1.5 pt at 0.45, softness 3, no inner glow, no halo | no halos |
| Pooled light | intensity 0.85 to 0.95, piping 0.6 to 1 | 0.42 to 0.7, piping 0.35 to 0.5, reach 0.8 to 0.9, softer hues | a quiet pooled tint with a falloff |
| Grounding (paper, light pages) | drop 0.72 to 0.78 over 18 to 26 pt, contact 0.6 to 0.65, caustic 0.5 to 0.55 spectrum 1 | drop 0.16 to 0.22 over 18 to 28 pt, contact 1 pt at 0.05 to 0.06, caustic 0.1 to 0.16 spectrum 0.5, warm | soft, low-contrast shadow; no hard outline |
| Orbs backdrop grain | 22 % | 5 % | the grain turned into streaks under the lens |
| Liquid backdrop bubbles | a ring with a bright speck | a tiny soft speck, no ring | no soap-bubble rings |

### Result

Rounded rectangles, capsules and circles now read as the same family as the
native glass on all three backdrops (compare captures), with a thin rim, a
calm body and a soft shadow on paper. What GlassWeave adds shows without
effects: the thick lens bends and magnifies the backdrop at the edge, light
pools inside the body, the polished edge carries a faint thin-film glint.

### Deviations and limits

- **Opt-in, not a new default.** The frozen-shader safety tests render the
  classic light model with its default values, so `look` defaults to
  `.classic`. A host asks for the Apple-grade look with `.refined(...)`.
- **No frost yet.** Native `.regular` glass is strongly frosted over the orbs;
  ours is clear there until GW-24b wires the frost pyramid. The compare page
  shows the gap honestly.
- **Native glass is not an exact target.** It is an adaptive system material;
  the comparison matches its structure (hairline, soft inner gradient, shadow,
  body value), not every pixel. The compare captures are iPhone 18 Pro
  simulator renderings.
- **The refined highlight is tuned by eye** in four rounds of captures; the
  numbers above are the shipped values, not derived constants. No CPU mirror
  and no numeric test (fast pass).
- **The classic model is untouched** and still draws gray wedges when asked
  for; it exists for byte-compatibility.

### Enhanced pass (ENHANCE)

> Experimental. `GlassLighting.edgeDepth`, `.banding`, `.glints` and
> `GlassLighting.enhanced(azimuth:environment:finish:)` may change before a
> stable release.

The refined look made the glass calm, and in the side-by-side captures it read
flat and grey next to Apple's. This pass adds richness without bringing back
the bubbly look: the same one light, a thin rim, no halos, no strips, no
glare dot. Everything is opt-in; with the new values at 0 the refined look is
drawn exactly as before (the classic model never reads them).

**What looked flat (the baseline captures, one line each).**

| Picture | Flat, grey, thin or weak |
| --- | --- |
| Pearl study | The ring was a thin pale band with soft grey bands and no glints; the milky capsule was white on white with no thickness. |
| Pill study (the best one) | The bevel bent little, the pooled light was a thin pastel line (added light over a dark page washes out), and the shadow side of the rim looked like the lit side, so the slab did not read thick. |
| Shelf study | A flat blue-grey body, the rainbow arc above the capsule instead of behind it, an even frost that blurred the rim too, so no dispersion was readable. |
| Frost page | The capsule was a flat grey; only its ends showed the rainbow. |
| Chrome page | A white-faced ring with a faint band, a smoky dome with a single hairline. |
| Lens page | The bevel bent modestly and every body read flat. |
| Versus screen | Our rims were thin and equal all round; the finish row's ring was a loud hologram (saturation 1). |

**Shader (refined look only, inside the light model's band, so the legibility
bound holds).** Three opt-in terms, in `Glass.metal` ("Enhanced edge"):

- `edgeDepth` (0...1), the thick slab. Across the tilt window between the flat
  top and the hairline the glass is darkened toward the side away from the
  light (up to `0.52 × edgeDepth`, 16 % of that on the lit side) and carries a
  faint inner light on the lit side (a soft bump in the tilt, `0.13` on light
  pages, `0.20` on dark ones), so the shadow side reads as a deeper rim.
- `banding` (0...1), for `.chrome` and `.prismatic`: the polished band is
  multiplied by stripes that are even in the surface angle
  (`acos(N.z)`, 10 radians per turn), and the band is more opaque so they read
  (alpha up to `1.55×`, at most 0.9, the backdrop still shows through).
- `glints` (0...1), for `.chrome` and `.prismatic`: narrow lobes around the rim
  at fixed angles from the key light (one facing it, a weaker one opposite, two
  faint ones at the sides) in a narrow window of the tilt, added through the
  soft knee. White for chrome; the thin-film hue turns across each glint under
  the prismatic finish.

**Record layout unchanged.** The three values ride in `GWLightingUniforms.prism.w`,
which was zero padding that no shader read, as three 8-bit fields of one
exactly representable integer (depth bits 0 to 7, banding 8 to 15, glints 16
to 23); the record stays 160 bytes with its offsets, and `GWGlassUniforms` stays
1776 bytes (the layout tests are unchanged). The host packs them only for the
refined look and only when one is nonzero. Normalization: a non-finite value is
rejected with `GlassParameterError.nonFiniteLighting` naming the field
(`.edgeDepth`, `.banding`, `.glints`); a finite value is clamped to 0...1.
Accessibility: Reduce Transparency and Increase Contrast zero all three (the
policy already removes the finish); Reduce Motion changes nothing (the glints
move only when the key light does).

**Demos and studies** (`RefinedLook.swift` holds the shared values;
`enhance(_:)` upgrades a page's existing panel, `chromeRing(diameter:azimuth:)`
is the polished ring):

| Value | Before | Now |
| --- | --- | --- |
| Rim line and highlight (`fresnel`, `specular`) | 0.55 / 0.5 | at least 0.7 / 0.6 |
| `edgeDepth` | 0 | 0.6 |
| Lens (pill, shelf) | squircle 3, thickness 26, ior 1.45, offset 44, dispersion 0.3 to 0.42 | squircle 2.4, thickness 42 (34 on the shelf), ior 1.5, offset 64, six-tap dispersion 0.7 |
| Lens on the other pages | as authored | thickness × 1.25, offset at least 64, six-tap dispersion at least 0.55 |
| Shadow on dark pages | none | drop 7 pt, blur 18, 0.30, deep ink, a 1 pt contact line |
| Pill pool | `.light` composite, intensity 1, reach 1.3, amber | `.paint` composite, intensity 0.7, reach 1.7, blue to violet to rose to coral |
| Chrome ring | prismatic spread 2, saturation 0.75, light bevel | ring profile (center 6.5, width 11), thickness 14, prismatic spread 1.2 at saturation 0.3, `banding` 1, `glints` 0.9 |
| Shelf frost | uniform, sigma 6, grain 0.04 | clear rim, sigma 8 over a 30 pt transition, grain 0.06 |
| Shelf backdrop | arc above the capsule, faded ends, opacity 0.5 | arc through the capsule's upper half, wider, opacity 0.78, scrim 3:1 on the title (large text) |
| Pill backdrop | soft limbs | a thin light on each sphere's lit limb, a crisp edge for the bevel to bend |
| Versus finish row | spread 3, saturation 1 or 0.65 | spread 2, saturation 0.55 or 0.4 |

**Result.** The pill study is still the calm picture it was, with a visibly
thicker slab, a deeper pool and a soft drop shadow. The pearl ring reads as a
polished chrome ring with stripes and small glints. The shelf shows the
rainbow bending at a clear rim and softening through the frost. Captures
(iPhone 18 Pro simulator, inspected, four rounds):
`gw-29-study-{pearl,pill,shelf}-vs-native-*`, `gw-24b-frost-*` (the frost page),
`gw-23-chrome-page-*`, `gw-22-lens-orbs-*`, `gw-29-versus-lens-light-*` and
`gw-29-versus-pooled-finish-light-*`, replaced under the same names.

**Limits.**

- The lensing is far stronger on paper than in the pictures: the study
  backdrops are soft, so the bend shows as a smear and the dispersion shows only
  where a crisp edge (a sphere limb, a rainbow band) passes behind the bevel.
- The ring's glints are small and quiet at 84 points; on a larger ring they
  are easier to see. The stripes and glints are tuned by eye, no CPU mirror.
- The other pages that call `RefinedLook.lens` or `panel` directly (shapes, the
  vessel page and study, the paper desk, the comparison page) are unchanged,
  and their captures are the REFINE ones.
- The legibility scrim still turns a pale pebble under the shelf's title into
  a grey-teal smudge, a little less than before (3:1 instead of 3.5:1).
- Not tested: no new test; the frozen-baseline tests still pass because the
  new terms are in the refined path only.

## Touch response (GW-12)

Experimental. The interaction side (observer, pacing, tiers, accessibility) is in
[interaction](interaction.md#touch-response-gw-12); this is the optics.

**Pipeline.** Function constant 6 (`gw_touch_constant`) builds the `touched`
variants: the optics, lighting, grounding and shape code (the shape constant set
for a rounded rectangle or a freeform outline), without frost and fill. The
touch record `GWTouchUniforms` (128 bytes: a header and two 48-byte
`GWTouchPoint`s) is its own fragment buffer (index 3), so `GWGlassUniforms` stays
at 1776 bytes. With the constant unset every line below is compiled out; the
frozen `GlassBaselineGW12.metal` proves the bytes.

**Ring.** With `d = pixel - origin`, `r = |d|`, the ring's crest at radius `R`
and width `w`, `x = (r - R) / w` and `g(x) = x exp(1/2 - x^2/2)` (peak 1 at
`|x| = 1`), the sample position moves by `-(d / r) * A * g(x) * edge`, where `A`
is the ring's amplitude in pixels (at most `8 pt x ripple`, from the CPU) and
`edge` runs from 0.35 at the outline to 1 at the bevel's inner edge, so the ring
flows out through the bevel without fighting the rim's own refraction. The sign
makes the crest a convex lens (it magnifies). The shifted position goes into
the lens or rim refraction in place of the pixel; with the constant unset the
position is the pixel.

**Finger light.** A Gaussian, `exp(-2 (|p - finger| / radius)^2)`, combined over
touches like light. It adds `(1 - glass) * (finger * (0.3 + 0.9 glass))` per
channel: the glass's own color lifted toward white, which keeps a colored glass
colored (white added over it read as a gray fog in the first capture).

**Catch light and gleam.** The ring tilts the surface by `g(x)` along the radial
direction; the shine is `saturate(dot(g * dir, key light))` times the ring's
strength times 0.10, white. The gleam is `exp(-(max(|p - finger| - rimDistance, 0)
/ 7pt)^2)` (how much farther than the nearest rim point the pixel is from the
finger), times a proximity term that falls from 1 at the rim to 0 at 1.3 finger
radii, in a band 2.4 points deep inside the outline, times `0.35 + 0.65 facing` so
the lit side is brighter; `rimDistance` is computed on the CPU from the shape's
distance field. All three are composited after the inner light and before the
light model, and the pixels they change are dithered like the glow.

## Merging two surfaces (GW-13)

Experimental. The interaction side (the spring, the clock, the hit-test policy,
Reduce Motion) is in [interaction](interaction.md#merging-two-surfaces-gw-13);
this is the shape and the shader.

**A merge is a blob.** `GlassSurfaceMerge` (`SurfaceField.swift`) holds two
surfaces, each a circle or a capsule at progress 0 and another at progress 1, in
frame units. `blob(progress:)` blends the poses linearly and returns an ordinary
`GlassBlob` of two primitives, so the GW-26 path draws it: one panel, one
outline, the lens, dispersion, light, frost, glow, liquid and shadow all follow
it, and there is no second surface to leave a seam. Nothing about the shape
changes in the renderer: the app moves the blob. The progress follows the rule: a
NaN throws `GlassParameterError.nonFiniteShape(.mergeProgress)`, a finite value
clamps to 0...1. The CPU cost is the blob's bounds sampling (48 x 48 samples of
two primitives) once per distinct progress; the cache holds the last 64.

**The neck.** The outline blends with the blob's polynomial smooth union, whose
distance `min(a, b) - k h^2 / 4` swells wherever the two distances are about
equal. A smooth union cannot avoid that (a symmetric blend that is smooth where
`a = b` must dip below `a`), so the blend distance is a curve of the progress
(`smoothness x sin^2(pi t)`, `t = progress / neckEnd`): 0 at the start (two exact
circles), widest while the gap closes, 0 from `neckEnd` on, when the two arms
overlap along a line and their union is an exact stadium with no swelling. The lab
chooses poses whose segments overlap at `neckEnd` (each arm reaches past the
middle), so the pill is one exact outline from there on.

**The seam, and the interior blend.** The first pictures (the narrow neck blend
alone) showed a thin vertical streak through the join. Its cause is not the
outline: inside the glass the lens depth is `-distance`, and for two overlapping
parts that is the larger of two cones, which has a V-shaped valley along their
bisector. The lens and the rim read the valley's slope jump, and a narrow blend
rounds it only over a few pixels. A wider blend would round it, but at the outline
it would swell the neck (a hump on the top edge, the first retune). So the blob
gets a second blend distance for the inside only: `GlassBlob.interiorSmoothness`
(frame units, 0...2, default 0), uploaded in `GWShapeUniforms.depthSmoothness`
(the explicit padding word at byte 28 of GW-26, so the record keeps its 336
bytes and the panel record its 1776). In `gw_shape_field` a blob with a value
above 0 takes `gw_shape_blob_soft_interior`: the outline distance and gradient
of `gw_shape_blob` (wobble included), mixed with the same primitives blended at
`depthSmoothness`, by a smoothstep weight that is 0 at the outline and 1 at
`0.3 x depthSmoothness` inside. At 0 it is `gw_shape_blob`, unchanged: the safety
test shows every other blob byte-identical. The merge scales it with the same
curve as the neck, so it is 0 again once the pill is exact (a constant interior
blend would raise the depth along the whole overlap, a visible patch).

**Lab pose.** Two 56 pt circles 104 pt apart become one 168 x 64 pt pill: each
surface becomes an arm from its own center to 22 pt past the middle, its radius
growing from 28 to 32 pt. Neck 0.35, interior 0.9, `neckEnd` 0.7. The native
buttons stay at the two centers, which are inside the glass at every progress.

**Tuning record (three rounds, beside a `UIGlassEffect` in a
`UIGlassContainerEffect` twin that the same progress drives).** Round 1: arms that
only met at the center left a notch until the very end, and the narrow blend
showed a streak and a flat bump on the top edge. Round 2: arms that overlap and a
wide neck blend gave a clean pill from 0.7 but humps on the top edge while the
parts merged (a swelling of `k/4`, 4 to 5 points) and still a streak. Round 3: the
interior blend, with a narrow neck blend (0.35) for the outline: no streak and no
hump at any progress sampled (0.3 to 0.75); the thinnest neck (0.3) keeps a tiny
wedge at its middle.

**Limits.** Fast pass: one safety test. No CPU mirror of the interior blend (the
CPU `BlobField` is the plain union, used for bounds and the inscribed radius, a
lower bound that the interior blend can slightly exceed: the depth is clamped to
it), no measurement of the seam, no M5 cost run. The interior blend and a wobble
combine (the wobble is added to the outline distance only). Frost and liquid fill
follow the merged outline through their own shaped variants but were not captured
on a merge.

## Polish: subtle, blended bends, a calm touch, the chrome ring and the liquid finish (POLISH)

The user's feedback on the enhanced pictures: "the bends are way too visible, not well blended". The cause was in the numbers and in the shape of the falloff, and both are fixed inside the opt-in paths and the demo values. Everything here is additive and off by default; the off paths are the frozen shaders' bytes (the baseline tests check this).

**Why the bend showed.** A squircle bevel is vertical at the outline, so the raw refraction offset climbs from 0 to its peak (about 9 points on a 34-point glass) within the first pixel or two, then falls away to 0 at the flat top with a kink in its slope. A dot grid shows the first as stretched petals at the rim, a soft backdrop shows it as a smear, and the second as a visible start line where the bevel ends. The demos also used 30 to 60 point glasses, offsets of 44 to 100 points and strong six-tap fringes.

**`GlassLens.softness` (0...1, default 0, experimental).** Above 0 the host profile's offset is multiplied by a quintic window that is 0 at the outline, rises over the first quarter of the bevel and fades out from under a fifth of the way in to the flat top, with zero slope and curvature at both ends (`gw_lens_smoother`, `GlassLensModel.window(t:)`), and the longest offset is a smooth fourth-power knee (`offset / (1 + (offset / max)^4)^(1/4)`, never above `maximumOffset`) in place of the hard clamp. An inlay brings a rise-only window of its own (the host's falls to 0 over the flat top where the inlay stands); a ring profile has no window (it stands on a flat) and only the smooth ceiling. The window lives in the offset, not in the surface normal, so the rim light keeps the slope the thickness gives it. Packed in the integer part of `lensOffsetScale` as `2 * round(softness * 255)`, the fraction stays the fold-free scale: the uniform record has the same size (1776) and offsets, and a lens with softness 0 reads exactly the value it read before (`x - 2 * floor(x / 2)` is `x` for `x < 2`). Normalization: non-finite rejected with `GlassParameterError.nonFiniteLens(.softness)`, finite clamped to 0...1. Accessibility: Reduce Transparency removes the lens (and so the softness), Increase Contrast keeps it and removes the dispersion, Reduce Motion changes nothing (the lens is static).

**The lab's values (`RefinedLook.blend`).** Softness 1, a squircle of at least exponent 3.5, index 1.42, an offset ceiling of 7 points (11 on the lens page, which exists to show a lens; 5.5 on the touch page), dispersion capped at 0.2 (0.25 in `enhancedLens`), the thickness left alone because it also gives the rim light its slope. Every page that builds its glass through `RefinedLook.lens`, `enhancedLens` or `enhance` has it; the hand-built dome and marble demos get it through `enhance`.

**Touch (GW-12).** Standard style: light 0.55 with a 58-point radius (it was 0.60 at 44), ripple 0.32 (at most 2.6 points of displacement, was 6.4) with a wider ring (`22 + 0.2 R` points against `16 + 0.14 R`, reach 140), gleam 0.45, the ring's catch light 0.06 (was 0.10) and the gleam strength 0.45 (was 0.6). A still frame shows the soft pool and, on a dot grid, a slight crowding of the dots under the ring; the ring is not visible as a ring on a soft backdrop.

**Chrome ring (`RefinedLook.chromeRing`).** About 0.17 of the diameter wide (it was 0.13), 98 points in the pearl study and 96 on the chrome page (84 before). The stripes are deeper (dark stripe level 0.16, a wider gap between the dark and bright levels), five glint groups (a main glint, two side ones, and two pairs of small ones near the key light and the far side) that are narrower, a prismatic hue that turns faster with the angle, and a polished wall that is a little brighter on a light page. The fringes of its lens stay faint (0.25).

**Liquid (`GlassFill.richness`, 0...1, default 0, experimental).** Packed in bits 8...15 of the fill record's `flags` (zero without it, so the layout and an unset fill's bytes are unchanged); an opaque fill ignores it. Above 0, in proportion: a soft, elongated specular window a fixed depth inside the lit boundary of the liquid, fading out along it over a quarter turn (a reflection on a curved skin, never a spot), warmer and brighter thin sheet edges (bright, not white-hot), fine internal structure (a slow two-octave grain stretched along the contour and a few faint veins), and a long, wide, smooth reflection along the lit outer wall of the vessel. The vessel study uses 1 and 0.8.

**Legibility scrim.** A darkened color now keeps its chroma: the scrim scales luminance, and the chroma about the unchanged luminance grows with the dimming (as far as no channel goes below 0), so a bright cyan becomes a deep blue-teal and not a gray-teal. The contrast bound is unchanged (the luminance is exactly what the plain scaling gave). The shelf study's feather is 22 points and the rect hugs the text, so the scrim stays even where a pale pebble sits above the title.

**Merge page.** The merged pill is mostly flat middle, where each round button is all bevel, so it read dimmer on the dark page; as the surfaces merge the tint gains 0.02 and a quiet band of sheen along the top inside rises to 0.10 (both 0 at progress 0).

**Limits.** Tuned by eye in three rounds beside a real `UIGlassEffect` twin on the studies; the lens page and the touch page on a dot grid still show a small, smooth stretch of the dots in the first few points inside the rim (that is what a lens does; it has no start line, kink or petal). The CPU mirror of the window covers the host profile without inlays only. No new tests beyond the frozen-baseline safety tests; no device run; no M5 cost run.


## Presence: a livelier body and edge, with no extra bend (PRESENCE)

> Experimental. `GlassLighting.presence` may change before a stable release.

The last independent review said the restraint cost presence: over the orbs the
refined capsule and rounded rectangle read as a clear, slightly gray panel next to
the native glass, whose body and edge carry the colors behind it, and the thick-lens
capsule with its inlaid dome was nearly flat. The user's rule stands: bends stay as
soft as they were. So every term here is a color or a light term; no lens thickness,
maximum offset, dispersion or touch ring was raised, and one refraction term was
lowered.

**What made the gray cast.** The lab's tint mixed 10 percent of a mid gray into the
body in linear light. Over a dark saturated color (a shaded red orb) that more than
doubles the green and blue channels, which is a desaturation, not a veil. The same
holds for any "lift" that adds a gray. The fix is to take the gray out (`RefinedLook.tint`
is 0.02 on dark pages, was 0.10; 0.20 on light, was 0.25) and to lift by gain, which
keeps the hue.

**`GlassLighting.presence` (0...1, default 0).** Refined look only, ignored by
`.classic`. Packed with the look in `GWLightingUniforms.tint.w` as `1 + level`
(level 0...255); the shader reads `w > 0.5` as refined and `w - 1` as the level, so a
refined panel without presence keeps the value 1 and the record keeps its 160 bytes
and its offsets. Normalization: a non-finite value is rejected with
`GlassParameterError.nonFiniteLighting(.presence)`, a finite one is clamped to 0...1.
At 0 nothing below runs and the picture is the shader's old bytes (the frozen-baseline
suites check this). Shader: `Glass.metal`, "Presence (refined look)".

| Term | What it does | Values (at level 1) |
| --- | --- | --- |
| Backdrop pickup | The body mixes toward a soft, slightly more vivid average of the backdrop around the pixel (13 bilinear samples on two rings, radius 0.7 of the bevel, at most half the inscribed radius), times a flatness gate (below). No sample is moved: it only colors the body. | 14 % in the middle, 28 % at the rim, times the gate; the average is 1.3 times more saturated than the backdrop |
| Saturation | The body's own color. | + 14 % |
| Luminance gain | A gain, so the hue is kept; a little more toward the light. | + 12 % on dark pages (+ 4 % on light), times 1 +- 0.5 across the panel, and a trace (1.2 %) of the sky |
| Inner edge glow | A thin glow just inside the outline in the backdrop's own hue, brightened (the sky's color where the backdrop is nearly black), brighter toward the light. | falls off over an eighth of the bevel plus 1.5 px; 6 % all round and 38 % more on the lit side (half on light pages; half over a nearly black backdrop) |
| Deeper far side | A soft shade just inside the hairline on the side away from the light. | up to 30 %, from 0.4 px in, over 0.3 of the bevel plus 2 px |
| Inlay shade | A lens inlay (the dome button) gets a shade on its far side that grows toward its base, a lift on its lit side, and a faint contact shade on the glass beside it, away from the light. Its rim light is the existing `rimLine` (0.3 in the lab, was 0.25). | far side 32 %, lit side 22 % of the sky, contact 22 % |
| Feathered rim refraction | A plain rim refraction (no lens) is multiplied by `smoothstep(0, 0.22 bezel, depth)`. It is never above the plain value. | see the cap below |

**The flatness gate (VERIFY-ROUND4).** The independent check put the panels over a
dot grid, a checkerboard and small colored dots on paper, and found a defect the smooth
backdrops hide: thirteen taps are an average only where the backdrop is smooth. Across
an edge, a dot or a character they leave faint ghost copies (a lattice of dim dots
between the real dots, small dark rectangles at the checker corners), they wash a small
colored dot out toward the paper, and under a thick lens they pull in the *undisturbed*
backdrop, which shows as a second, paler copy of a dot beside its bent image (the
marble on the paper desk). The pickup and the glow's color and strength now follow a
gate `w` (0...1) that is 1 where the backdrop is flat and 0 where it is not: the
largest distance of any one of the thirteen samples, and of what the glass itself shows
of the backdrop (before the tint and the fill), from the average, relative to
`0.06 + luma(average)`, through `1 - smoothstep(0.10, 0.32, .)`. Grain and slow shading
stay below 0.10; one sample on an edge or a dot is far above 0.32. Where the gate is 0
the body gets no pickup and the glow uses what the glass shows, so no tap pattern can
appear. The cost is a trace of the pickup beside orb edges (against the first presence
build the lab pages changed in at most 6.4 percent of their pixels, by at most 63 of 255). Captures:
`gw-presence-verify-ghost-dots-*` (the old build, the presence before the gate, the
presence with it) and `gw-presence-verify-ghost-marble-*` (same three, 2 times zoom).

**Bends, measured (VERIFY-ROUND4).** The geometry of every bend is unchanged or smaller:
no lens, offset, dispersion or touch term was edited, the plain rim refraction is only
multiplied by a factor of at most 1 (and a lens panel, which ignores it, is untouched);
on the checkerboard the positions of the checker edges inside the glass agree with the
previous build within 0.3 px, and the rim shapes look alike
(`gw-presence-verify-bend-checker-*`, the previous build on the left). What changed is
how much the same bend shows on a hard-edged pattern: the old tint's gray haze is gone,
so black and white seen through the circle now span 180 levels of luma (50 to 230)
where they spanned 151 (64 to 215), 19 percent more contrast on the same bend. On smooth
backdrops the difference is not visible.

**The cap artifact (item 4).** The plain rim refraction moves the sample by
`maxDisplacement x (1 - depth / bezel)^2`, which is its largest, about 5 points on the
capsule of the comparison page, exactly at the outline, while outside the outline
nothing moves. That is a step in the displacement at the silhouette: where an orb's
edge crosses the end of the capsule, the orb's edge outside and inside the glass
differ by about 4 points, joined by a straight diagonal, with a small gray wedge
(the backdrop showing through where the sample came from the other side of the edge).
It is not the lens falloff or the soft window (those start at 0 at the outline); it was
the legacy rim path. The feather brings the displacement to 0 at the outline over the
first fifth of the bevel, so the orb edge bends in smoothly. Captures:
`gw-presence-cap-before-*`, `gw-presence-cap-after-*` (4 times zoom of the same
region). The feather rides on `presence`, so panels without it keep the old rim.

**Accessibility (written in `GlassAccessibilityPolicy.presentedLighting`).** Reduce
Transparency and Increase Contrast set `presence` to 0 (with the other decoration):
the surface reads as before, with the crisp hairline (captures
`gw-presence-compare-reduce-transparency-*`, `gw-presence-compare-increase-contrast-*`).
That also returns the plain rim's step under Increase Contrast, which keeps the panel as
authored; Reduce Transparency draws an opaque surface. Reduce Motion changes nothing.
The glow and the shades stay inside a tenth of the panel or follow `bandWidth` terms;
the body gain is at most 12 percent and the label contrast is the frost scrim's
business.

**Amber vessel (item 5).** The sheets read as contour lines because each sheet is an
iso-offset of the gel's distance field with its own thin bright edge, so three of them
look like nested outlines. `GlassFill.richness` now also softens the sheets (the edge
2 times wider at richness 1 with 28 % less brightness, the glow behind it wider) and
its veins (ridge width 5 instead of 9, strength 0.07 instead of 0.13); the study uses
two sheets, 24 points apart, edge 0.34, wobble 0.85. The specular window and the warm
thin edges are unchanged.

**Lab changes.** `RefinedLook`: `presence` 0.85 in `lighting` and `enhancedLighting`,
the lighter tint, `enhance` raises `edgeDepth` to 0.75 on a lens panel (0.6 on a plain
one) and sets the presence. The paper desk's two captions are placed on one line under
the row (the button's under the button, the pill's after it); they used to overlap
(each was at least 300 points wide).

**Result and limits.** On the orbs the capsule, circle and rounded rectangle keep
their colors (a red orb stays a saturated red under the glass), carry a thin lit rim and
a soft far side, and the thick-lens capsule reads as thick glass with a visible dome.
Next to the native glass they are the same family, with a clearer body (the native body
is frosted). Tuned by eye in four rounds beside a real `UIGlassEffect` twin; no CPU
mirror; no new test (fast pass); no device run; the 13 samples per pixel are measured by
no one yet (the M5 run is a later step). The paper-desk marble is a little milky at its
lit upper left. The presence is not a substitute for frost: a sharp backdrop edge still
shows sharp.

## Clean pass: match the system glass's cleanliness (CLEAN)

The user's feedback: "Apple's implementation is way cleaner than ours. Ours has some bands and streaks which I don't like. I want to match Apple's, but at the same time have those glow capabilities that Apple cannot do." This pass removes marks. It adds no edge detail, no hairline and no bend (no lens thickness, offset, dispersion or touch ring was raised; the chrome ring's dispersion went from 0.25 to 0.12). Everything is opt-in and experimental: `GlassLighting.clean` (0...1, default 0, refined look) and `GlassParameters.dither` (`.ordered` by default, `.triangular`; it also smooths the glow and light palettes between their stops). With both at their defaults the shader draws the same bytes as before (the frozen-baseline suites prove it).

**How it was compared.** A real `UIGlassEffect` twin and the refined panels on the same backdrops (the Apple vs GlassWeave page on charcoal, orbs and paper; the pill, pearl, shelf and vessel studies; lens, chrome, paper desk, shapes, merge, touch, frost, light fields), iPhone 18 Pro simulator at full 3x resolution, cropped at 2x to 8x with a small PNG tool and, to expose bands, with the contrast stretched five times about the crop's mean.

**What ours had and Apple's did not, and the cause.**

| # | Mark | Where | Cause | Change under `clean` |
| --- | --- | --- | --- | --- |
| 1 | A doubled line: a second bright ridge a few points inside the hairline | every refined panel (the circle and the capsule's left cap most) | `gw_refined_highlight` used a bump window of the surface tilt (a ring at the depth where the tilt equals its center), on top of the hairline and the soft Fresnel term | the window is one-sided (it rises smoothly with the tilt and stays up to the outline), so the highlight is one gradient that falls from the rim inward |
| 2 | A dark crease just inside the glow | the far side of every panel with presence | `inner = smoothstep(0.4, 2.5, depth) * exp(...)` starts at zero and peaks a few pixels in | the shade starts at the outline and falls off from there |
| 3 | A lighter notch inside the slab shade, and an inner light ring | enhanced panels (`edgeDepth`) | the wall window fell off again toward the outline, and the inner light was a bump | both are monotone in the tilt |
| 4 | An ordered-dither cross-hatch (alternating 48/50 luminance, 100 direction reversals along a 150 px line) | every dithered body and gradient | the 4 x 4 Bayer matrix at most 0.47 of a step, applied only where a light term changed the pixel; the lab's own backdrops carried the same matrix and it showed through the glass | `GlassDither.triangular`: a static, isotropic triangular-PDF dither of one 8-bit step per channel, from an integer hash of the pixel, on every pixel inside the outline, in the halo and in the shadows and caustics (their multiplier or added light carries it, faded in over the first three steps so the quad's edge stays exact); the lab's bench and gallery backdrops use the same dither |
| 5 | Thin chrome stripes and a hue notch | the pearl ring and the chrome page's ring | `gw_enhance_bands` used 10 periods per radian (about five thin stripes), the thin-film hue was a multiple of a wrapped angle (a jump of 0.4 turn at the seam, a visible notch), and the glint's hue swept 3.4 turns across the steep wall (a thin rainbow stripe) | about one and a quarter periods, soft-edged and 0.52...1.3 in level; a periodic hue (`0.5 - 0.5 cos`); the film confined to the soft band; the glint's hue turns 0.9 across the bevel at 0.7 saturation, the lobes twice as wide and 40 percent calmer |
| 6 | Dashes where a bright backdrop edge meets the rim under Increase Contrast | the refined rounded rectangle at the cyan orb's edge | the contrasting hairline chose its polarity with a hard `luminance > 0.5` test per pixel | the polarity follows a smooth step of the glass's luminance mixed with a six-tap average of the backdrop around it (reach `0.6 * bezel`), with a floor on the strength where the two polarities meet |
| 7 | Speckle in the frost | frosted panels | a white hash grain, about 4 percent of the color | scaled by `1 - clean`; the dither takes its place |
| 8 | Contour sheets, veins and a hairline across the vessel's shell | the amber vessel | thin gaussian edges at the sheets, at the inset boundary (`wallLine`) and a faint secondary rim | the hairline and the secondary rim 2.5 times wider at 0.6 of the strength, the sheet edges about 1.5 times wider at half the strength, the grain and the veins 70 percent calmer |
| 9 | Kinks in a color gradient | glow stops, pooled-light palettes | linear interpolation between stops has a corner at each stop | a smooth step between stops under either dither mode |

**Not found.** Edge-depth rings and light-piping lines beyond item 3, a visible start of the bevel (the POLISH window already removes it), lens-window rings, antialiasing stair-steps on the curved panel outlines (the outline coverage is a one-pixel linear ramp of an exact distance; the circle's 45 degree profile shows one intermediate pixel). VERIFY-CLEAN corrected this for the chrome and pearl rings: inside the outline, the ring's dark outer band meets a 2 point bright lip in a hard one-pixel step of about 70 levels with no intermediate pixel, a staircase at 8x to 16x that is not visible at 1x to 3x; it is in the previous build too and was not changed, and ghosting or doubled copies under a refined panel on a text page (see below).

**Text backdrop.** The lab has a bench page `text` (`-lab.compare YES -lab.compareBackdrop text`): 42 short original sentences of dark type on warm paper, drawn by the lab with CoreGraphics into the texture the bench background binds. Over it the refined panels show the type crisp, at about half contrast (the 0.2 white tint and the clear body), bent a little at the bevel, with no second copy and no halo; the native twins blur it. Nothing needed fixing; the presence's flatness gate (VERIFY-ROUND4) keeps the backdrop pickup at zero where the type is.

**Objective check** (`scratchpad` script, not a test): luminance profiles, each the mean of nine parallel lines (which removes the dither noise), then smoothed over three pixels; "reversals" counts changes of direction of at least 0.3 levels, "d2" is the largest second difference (levels of 0...255).

| Profile | before (reversals / d2) | after (reversals / d2) | native |
| --- | --- | --- | --- |
| rim, charcoal capsule left cap | 100 / 1.94 | 2 / 1.98 | 0 / 6.45 |
| rim, charcoal rounded rectangle left | 2 / 2.81 | 0 / 2.82 | 0 / 15.73 |
| rim, orbs capsule left cap | 2 / 1.38 | 0 / 1.44 | |
| rim, orbs circle left | 13 / 3.26 | 3 / 3.35 | |
| pooled light, vertical through the pill bottom | 65 / 0.98 | 1 / 0.63 | |

The 100 and 65 reversals were the ordered dither's cross-hatch; the remaining ones on the circle are the backdrop's own orb edges. The pooled-light gradient's largest step drops by a third. The dither's isotropy on a flat body patch of the charcoal capsule (rms of the difference between neighbours: horizontal / vertical / diagonal / anti-diagonal, in luminance levels): before 0.87 / 0.99 / 0.59 / 0.58 (a cross-hatch), after 0.78 / 0.77 / 0.80 / 0.79; on the pooled-light patch before 0.74 / 0.83 / 0.53 / 0.53, after 0.66 / 0.66 / 0.65 / 0.66. The captures are `gw-clean-*-before-*` and `gw-clean-*-after-*` in `docs/evidence/captures` (the rim at 4x, also with the contrast stretched five times, the compare pages, the four studies, the chrome page, the pooled light, the text page and Increase Contrast).

**Is the rim stronger?** No hairline, streak or frost was added. The one-sided highlight lies behind the hairline: on the charcoal capsule's left cap the outermost pixel's luminance is 98.5 against 95.2 before (3 percent), and the rim's total excess light over the body, summed over 40 pixels, is 527 against 563 (6 percent less); with the first version of the window (0.55 instead of 0.36) the totals were equal and the peak 99.9, so it was cut back.

**Accessibility.** Reduce Transparency and Increase Contrast keep `clean` (it only removes marks and adds no transparency); Increase Contrast's contrasting hairline is the one that changes (item 6). Reduce Motion: nothing moves in this pass.

**Packing.** `lighting.tint.w` is `1 + presence + 256 * clean` (two 8-bit levels in one exactly representable float); the dither mode rides in `GWGlassUniforms.padding0` (0 ordered, 1 triangular), which every earlier shader ignores. Sizes and offsets are unchanged.

**Limits.** Tuned by eye in four rounds against the real glass. The clean rim is a little wider and softer than the native one (a gradient over about ten points where the native rim is a thin line); making it thinner would trade against the PRESENCE look and was not done. No CPU mirror; no new test beyond the existing frozen-baseline suites (fast pass); no device run.

**VERIFY-CLEAN (independent check).** Fresh builds of this pass and of the commit before it, 28 pages and the same launch arguments, crops at 2x to 16x: the rim, the dither and the chrome claims above hold. Re-measured (own windows): the grain on a flat body is about one 8-bit step (neighbour difference rms 0.8 on charcoal, 1.2 on paper, isotropic: horizontal and vertical agree within 2 percent), the native body 0.1 to 0.2; the pooled light's largest second difference fell from 0.43 to 0.23 (the light-field orb) and from 0.38 to 0.27 (the pill study). Corrections: the hard ring step above, and the four-corner light field's diagonal crease (not in the nine causes; a distance field's medial axis shows at the inner corners of the field's pooled light, before and after this pass). Per-page verdicts: [studies](studies.md#clean-pass-and-its-independent-check-clean-verify-clean-experimental-unreleased).
