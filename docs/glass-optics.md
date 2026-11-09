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
