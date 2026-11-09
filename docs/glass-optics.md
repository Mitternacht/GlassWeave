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
