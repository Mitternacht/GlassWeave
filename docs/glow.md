# Glow effects: design

Status: design for the user-requested glow work (2026-11-09), tasks GW-17 to
GW-20 and the color extension of GW-14 in [the checklist](../tasks/todo.md#glow-effects-user-requested-2026-11-09).
Sections marked **Implemented** describe code in the repository; everything
else is the plan. The work is experimental and post-v0.1: it does not change
the v0.1 candidate's scope, and nothing here has been measured on a device.

## The request

The user asked for glass that can "obtain tints and glows in the edges in
whatever colors, but still … have a fade or transparency in the middle". The
design therefore has one core idea: a **glow layer** whose color comes from
one color or an angular gradient, strongest at the outline and fading toward
the middle, where the glass stays see-through unless the app asks for a
center fill. GW-18 adds a halo outside the shape and a pulse driven by one
effect clock; later tasks add animated interiors (GW-19), the same colors
around native glass (GW-14), and a gallery of original demos (GW-20).

## Where the glow lives in the API

`GlassParameters` gains one stored property, `glow: GlassGlow`, which
defaults to `GlassGlow.none`. A separate top-level type passed beside the
panel was considered and rejected:

- The glow is drawn from the panel's own shape: the same frame, corner
  radius, and signed-distance field. Keeping it inside `GlassParameters`
  means one value describes everything a panel looks like.
- It inherits the panel's normalization, in one place: lengths are clamped
  to half the panel's shorter side like the corner radius, and
  `GlassRenderer.panel` reports the glow it actually draws.
- `GlassAccessibilityPolicy.presentedPanel(for:settings:traits:)` already
  maps one `GlassPanel` to what is drawn; the glow mapping joins it without
  a second policy entry point.
- Existing callers are unaffected: the initializer's new argument has a
  default, and the default draws no glow.

`GlassTint` keeps its meaning (a uniform color mixed into the whole panel);
the glow is drawn over the tinted, refracted, edge-lit glass.

## GW-17: rim, inner glow, and center fade

### Public types (implemented)

`GlassGlow` (`Sources/GlassWeave/GlassGlow.swift`) is `Hashable` and
`Sendable`. Lengths are in **points**, converted with the host's display
scale like the rest of the panel; coefficients are normalized.

| Field | Unit | Range | Default | Meaning |
| --- | --- | --- | --- | --- |
| `colors` | `[GlassGlow.ColorStop]` | 0 to 4 stops | none | The glow color: one stop is a solid color; two to four stops form an angular gradient around the panel's center. No stops draws no glow. |
| `ColorStop.red`, `.green`, `.blue` | sRGB-encoded | 0...1 | — | Like `GlassTint`: a UIKit color's sRGB components. Decoded to linear light on the CPU. |
| `ColorStop.angle` | degrees | any finite value, reduced modulo 360 | 0 | Where the stop sits around the center: 0 at the top, increasing clockwise (90 right, 180 bottom, 270 left). |
| `rimWidth` | points | 0 to half the shorter side | 1.5 | Width of the solid rim band just inside the outline. |
| `rimSoftness` | points | 0 to half the shorter side | 1.5 | Width over which the rim's inner edge fades out (at least one pixel, so the band never aliases). The rim is absent when both width and softness are 0. |
| `rimIntensity` | normalized | 0...1 | 1 | Opacity of the rim band. At 1 and full light the rim pixel is exactly the glow color. |
| `innerGlowRadius` | points | 0 to half the shorter side | 24 | How far inward the inner glow reaches; it is exactly zero beyond. |
| `innerGlowIntensity` | normalized | 0...1 | 0.5 | Opacity of the inner glow at the outline. |
| `centerOpacity` | normalized | 0...1 | 0 | Opacity of the glow color everywhere inside, including the middle. 0 keeps the middle see-through: pixels deeper than the rim and inner glow are exactly the glow-off glass. |
| `lightAngle` | degrees | any finite value, reduced modulo 360 | 0 | The side the light comes from, in the stop-angle convention: 0 lights the top edge. |
| `directionality` | normalized | 0...1 | 0 | 0 lights the rim and inner glow evenly all around; 1 lights only the side facing the light (the opposite side gets none). |

**Normalization rule** (the `GlassParameters` rule, extended): a NaN or
infinite value anywhere in the glow is rejected with
`GlassParameterError.nonFinite(field)` naming the field (`glowColorRed`,
`glowColorAngle`, `glowRimWidth`, …) and leaves the current panel in place.
Finite values out of range are clamped: lengths to 0...half the panel's
shorter side, coefficients and color components to 0...1. Angles are reduced
modulo 360 into 0..<360. Only the first four stops are kept, then they are
ordered by angle (stably, so two stops at one angle make a hard edge). A
glow with no stops normalizes to `GlassGlow.none`. `GlassRenderer.panel`
reports the normalized glow. In GlassWeaveUIKit,
`GlassGlow.ColorStop(_:angle:traits:)` reads a stop from a `UIColor`
resolved for a trait collection (alpha ignored; `nil` for a color without
RGB components, such as a pattern).

### Shader math (implemented)

Everything below is evaluated per pixel in target pixels (y down) by
`gw_glass_fragment` and mirrored on the CPU by `GlassPanelGeometry`, which
the tests compare with the GPU output.

1. **Shape field.** `d` is the signed distance to the rounded rectangle
   (negative inside), as in GW-05; `depth = max(-d, 0)`. Circles and
   capsules are rounded rectangles whose corner radius is half the shorter
   side (the normalization clamps any larger radius there).
2. **Gradient angle.** `p = (pixel − center) / halfSize` (the panel scaled
   to a square, so 45° always points at the top-right corner);
   `θ = atan2(p.x, −p.y)` in turns, wrapped to 0..<1; at the exact center
   `θ = 0`. The shader uses `precise::atan2`: on the axis through the center
   `−p.y` is a signed zero, and the fast-math `atan2` put such pixels in the
   wrong half-plane (a GPU test found it; the CPU model was right). The
   glow color `C(θ)` interpolates linearly, in linear light, between the
   two neighbouring stops around the circle (cyclically, so the last stop
   blends back into the first). One stop is a solid color.
3. **Light.** `L = (sin λ, −cos λ)` for light angle `λ`. `n` is the outward
   normal of a rounded rectangle with radius
   `max(cornerRadius, rimWidth + feather, innerGlowRadius)` (capped at half
   the shorter side), which turns smoothly everywhere the glow reaches.
   `f = (1 + n·L) / 2` and `light = (1 − k) + k f²` for directionality `k`.
4. **Rim band.** `feather = max(rimSoftness, 1 px)`;
   `rim = rimIntensity × (1 − smoothstep(rimWidth, rimWidth + feather, depth)) × light`.
5. **Inner glow.** `t = depth / innerGlowRadius` clamped to 0...1;
   `inner = innerGlowIntensity × (1 − t)² × light`, so it reaches zero with
   zero slope at the radius and leaves no seam.
6. **Composite.** The three layers share the color `C(θ)`, so they combine
   into one premultiplied layer `(C·a, a)` with
   `a = 1 − (1 − centerOpacity)(1 − inner)(1 − rim)`, composited source-over
   on the finished glass in linear light: `glass = C·a + glass·(1 − a)`. The
   glass underneath is the GW-05 result (refraction, tint, edge
   illumination), so the glow never changes where the panel samples.
7. **Edge.** The one-pixel antialiased outline mixes the glowing glass with
   the undisplaced background, as in GW-05. Every pixel stays opaque; outside
   the outline's half-pixel band nothing changes in GW-17.
8. **Dither.** Where `a > 0`, a 4 × 4 ordered (Bayer) offset of at most
   ±0.47 of one 8-bit step is added to the encoded output, breaking up bands
   in soft glow over flat backgrounds. Where `a = 0` no offset is added, so
   the see-through middle is bit-exact.
9. **Numerical safety.** Every division is guarded (zero radius, zero
   gradient span, the center pixel); inputs are finite after normalization,
   so no NaN or infinity reaches the output.

With `glow = .none` (no stops) the record says so and the shader skips the
whole block, so the default panel renders exactly what it rendered before.
The tests keep a frozen copy of the pre-glow (GW-05) shader and compare
bytes.

### GPU record (implemented)

`GWGlassUniforms` keeps its first 112 bytes unchanged (the GW-05 layout) and
appends the glow, all in target pixels or normalized:

| Offset | Field | Meaning |
| --- | --- | --- |
| 112, 128, 144, 160 | `glowColor0` … `glowColor3` (`simd_float4`) | Stop colors in linear light (`xyz`), sorted by angle; `w` unused, zero. |
| 176 | `glowStopTurns` (`simd_float4`) | Stop angles in turns, 0..<1, ascending. |
| 192 | `glowLightDirection` (`simd_float2`) | Unit vector toward the light, y down. |
| 200 | `glowStopCount` (`uint32_t`) | 0 to 4; 0 disables the glow block. |
| 204 | `glowRimWidth` | Pixels. |
| 208 | `glowRimFeather` | Pixels, at least 1 when the rim is present. |
| 212 | `glowRimIntensity` | 0...1; 0 when the rim is absent. |
| 216 | `glowInnerRadius` | Pixels. |
| 220 | `glowInnerIntensity` | 0...1. |
| 224 | `glowCenterOpacity` | 0...1. |
| 228 | `glowDirectionality` | 0...1. |
| 232 | `glowNormalRadius` | Pixels: the radius of the field that orients the light. |
| 236 | `padding3` | Zero. |

Size 240, alignment 16, stride 240. As for every record: C
`_Static_assert`s, MSL `static_assert`s, Swift `MemoryLayout` checks, and a
compute-shader round trip with distinctive values.

### Extent

GW-17 changes only pixels the panel covers (coverage above zero). With
`centerOpacity` 0 it changes only pixels within
`max(rimWidth + feather, innerGlowRadius)` of the outline. Pixels outside the
outline's antialiasing band are byte-identical to the glow-off output.

### Laboratory (implemented)

`-lab.glow amber` (one warm system color lit from the top, directionality
0.7) and `-lab.glow aurora` (cyan, indigo, pink, and yellow at 0°, 90°,
180°, and 270°, evenly lit) give the laboratory's custom panel a glow
(`Examples/GlassWeaveLab/GlassWeaveLab/LabGlow.swift`). Both keep center
opacity 0 and an inner glow no deeper than the panel's 22-point rim, where
the laboratory places no text, so the tint's legibility rule still describes
the text area. The diagnostics print a `Glow:` line with the presented
values.

## Accessibility mapping

Implemented for the GW-17 and GW-18 rows. `GlassAccessibilityPolicy` applies
these to the presented panel (the app's panel is kept unchanged) and, through
the same function, to the rim and halo of `EnhancedNativeGlassView` (GW-14);
the GW-19 row is the plan:

| Feature | Reduce Transparency | Increase Contrast | Reduce Motion |
| --- | --- | --- | --- |
| Body (GW-05/GW-08) | Opaque `secondarySystemBackground`, no refraction or edge light (GW-08) | Unchanged; the app's tint keeps text at 7:1 through the GW-08 legibility rule | Unchanged (no motion) |
| Rim (GW-17) | Kept with its colors as a crisp, evenly lit band: its width plus softness, capped at `GlassAccessibilityPolicy.reducedTransparencyRimWidth` (2 pt), so the shape keeps its color identity on the opaque body | Kept with its width and softness, evenly lit (directionality 0), a clearer boundary | Unchanged, or steady at the pulse's mean level when it pulses |
| Inner glow, center fill (GW-17) | Removed: the body is exactly the opaque legible surface | Removed: the interior is exactly the GW-08 glass, so the legibility rule for text still holds | Unchanged (the inner glow steady at the pulse's mean level) |
| Halo (GW-18) | Removed (`haloRadius` 0) | Kept (outside the shape, behind no text), evenly lit like the rim | Kept, steady at the pulse's mean level |
| Pulse (GW-18) | Removed (`pulseDepth` 0); the rim stays at its own intensity | Kept | Removed: the rim, inner glow, and halo opacities are multiplied by `1 − pulseDepth / 2` and the depth becomes 0, so the surface runs no clock |
| Interiors (GW-19) | Removed | Removed (they would move behind text) | A fixed still frame (effect time 0) |

The legibility rule (`GlassTint.minimumStrength`) covers the interior when
the center fill is 0, which Increase Contrast enforces. A center fill above 0
mixes the glow colors into the interior; extending the rule to it is left to
GW-20, where text first sits on a filled body.

## GW-18: halo and pulse (implemented)

### Public fields

`GlassGlow` gains four fields, documented and normalized like the GW-17
ones; a NaN or infinity is rejected naming `glowHaloRadius`,
`glowHaloIntensity`, `glowPulsePeriod`, or `glowPulseDepth`.

| Field | Unit | Range | Default | Meaning |
| --- | --- | --- | --- | --- |
| `haloRadius` | points | 0 to `GlassGlow.maximumHaloRadius` (128) | 0 | How far the halo reaches outside the outline; exactly zero at and beyond it. 0 is no halo, so every existing glow keeps its GW-17 output. Not limited by the panel's size. |
| `haloIntensity` | normalized | 0...1 | 0.5 | Halo opacity at the outline. |
| `pulsePeriod` | seconds of effect time | `minimumPulsePeriod` (0.5) to `maximumPulsePeriod` (60) | 2 | One pulse cycle. The floor keeps a pulse at two cycles a second or slower, below the three flashes a second that WCAG 2.3.1 treats as a seizure risk. |
| `pulseDepth` | normalized | 0...1 | 0 | How far the pulse dims the rim, inner glow, and halo at its lowest point. 0 is no pulse. |

The halo uses the glow's own colors (one color or the angular gradient);
a separate halo color was not added. `GlassGlow.hasHalo` and
`GlassGlow.isAnimated` (visible, a pulse, and something it can dim; the
center fill does not pulse) say what a glow draws, and
`GlassGlow.pulseLevel(at:)` gives the pulse's factor at an effect time.
`GlassRenderer` keeps an effect time (`effectTime`, set with
`setEffectTime(_:)`, finite only, rejected as `.nonFinite(.effectTime)`);
it has no clock of its own, so every draw is a function of its inputs.

### Shader math

1. **Pulse.** `level(t) = 1 − pulseDepth × (1 − cos(2π t / pulsePeriod)) / 2`,
   evaluated on the CPU in double precision (the phase is reduced to one
   period first, so a long-running clock keeps its accuracy) and folded into
   the uploaded rim, inner glow, and halo intensities. The shader sees no
   time. Level 1 at `t = 0` and every whole period, `1 − pulseDepth` half a
   period later; mean `1 − pulseDepth / 2`.
2. **Quad.** The panel's quad grows from "panel + 1 px" to
   "panel + 1 px + halo radius" on every side (unchanged when the radius is
   0). The rasterizer clips it to the target.
3. **Halo opacity.** For the part of a pixel outside the outline, at
   distance `s = max(d, 0)`:
   `a = haloIntensity × (1 − s / haloRadius)² × light`, exactly zero for
   `s ≥ haloRadius` (the shader skips the halo there). `light` is the rim's
   light factor with the same normal field (`glowNormalRadius`), which is
   continuous across the outline, so the halo and rim brighten the same side.
   The color is `C(θ)` at the pixel's angle, continuous across the outline.
4. **Composite: the halo is light.** Its premultiplied light `L = C × a` is
   screened over the background `B` in linear light:
   `B + L × (1 − B)` per channel. This was chosen over source-over (the
   rim's composite): source-over moves the background toward the glow color
   and so darkens any channel the color has less of, which over a mid-gray
   or colored background reads as a shadow, not a glow. Screen never darkens
   a channel, never exceeds 1, equals `L` over black, and is what a designer's
   "outer glow" uses. Trade-off: over a background brighter than the glow
   color (white, or a bright saturated color) a halo adds little and its hue
   washes toward white, as light does; it shows best on dark backgrounds.
5. **Antialiased outline.** The covered part of an edge pixel is the glowing
   glass; the uncovered part is the haloed background, so rim and halo meet
   with no gap or dark seam.
6. **Dither.** Halo pixels get the GW-17 ordered dither; pixels with no
   glow and no halo get none.
7. **Nothing is discarded.** Pixels in the grown quad beyond the halo write
   the background as the panel pass samples it (as the one-pixel ring did in
   GW-17); readback shows those bytes equal the background pass's in a 1:1
   and a scaled presentation, on the Apple M5 and on the simulator. The plan
   used `discard_fragment()`; short Release runs on the Apple M5 showed it
   cost about 0.1 ms per frame even for a panel without a halo, because a
   pipeline that may discard keeps the GPU from skipping the background
   fragments under the opaque panel quad.
8. **Skipped work.** The glow's color and light (with `precise::atan2`) are
   evaluated only where the layer can be non-zero: inside the outline, within
   the rim's and inner glow's reach (plus 0.01 px) or wherever a center fill
   is set; outside, within the halo radius. A single color needs no angle.
   Elsewhere the layer is exactly transparent, so the bytes are unchanged
   (the GW-17 byte-identity tests still pass).

### GPU record

`GWGlassUniforms` keeps its first 240 bytes (the GW-17 layout, which keeps
the GW-05 layout) and appends `glowHaloRadius` (240, pixels; 0 is no halo),
`glowHaloIntensity` (244, with the pulse level applied), and zero padding at
248 and 252. Size 256, alignment 16. The C, MSL, and Swift layout checks and
the distinctive-value GPU round trip cover the new fields.

### Near the surface's edge

The surface owns its whole drawable, so a halo is cut off only where the
surface ends, with a hard edge there. Give each shape at least its halo
radius of surface on every side (the GW-20 gallery plans one full-screen
surface); a halo that reaches past the surface is simply not drawn beyond it
(a readback test renders a panel 6 points from the target's edge with a
40-point halo: the halo reaches the edge pixels, every pixel is written, and
the image matches the CPU model).

### One clock, on demand

- **One clock per surface.** `GlassSurfaceView` owns an effect clock: a
  `UIUpdateLink` created for the surface itself (`UIUpdateLink(view:)`), so
  it follows that view's window and display, never a global link, and
  activates only while the view is in a visible window. Its handler holds the
  view weakly (a test shows a surface with a running clock is freed). It
  exists only while (1) the presented glow `isAnimated` and (2) the surface
  is visible by the GW-07 rule; Reduce Motion removes the pulse from the
  presented panel, so it covers (3). It asks for continuous updates at
  30 to 60 Hz (60 preferred): a slow pulse gains nothing from 120 Hz.
  `isAnimating` reports it. MTKView's own timer was not used: an unpaused
  `MTKView` draws continuously, outside the GW-07 scheduler.
- **Ticks are ordinary requests.** Each update advances the effect time by
  the model time since the previous update (`UIUpdateInfo.modelTime`; the
  first update after a start only sets the base, and time never goes back)
  and calls `requestFrame()`. Ticks therefore coalesce with other requests,
  wait while hidden, and never exceed the two-frame in-flight bound: a tick at
  the bound leaves one pending frame, drawn when a frame completes.
  `FrameLedger` and `FrameScheduler` are unchanged.
- **The draw uses the clock's time.** `render(in:)` hands the clock's time
  to the renderer (`setEffectTime`) before each draw.
- **Settling.** Removing the pulse, hiding the surface (or an ancestor),
  backgrounding its scene, removing it from its window, or turning on Reduce
  Motion removes the link at once; a changed panel is drawn once (one
  frame), and then nothing is submitted. The effect time stays where it was
  and continues from there, so a pulse resumes where it stopped instead of
  jumping.
- **Transitions** (for example the theme toggle in GW-20) remain app-driven
  parameter changes, as planned: the app interpolates panel parameters with
  its own update link and requests a frame per step; under Reduce Motion it
  jumps to the end.
- **GW-04's open item** (the main-thread drawable wait in `GlassSurfaceView`)
  is unchanged: a running clock draws more often but within the same bound,
  so the wait stays bounded the same way; it is not fixed here.

### Laboratory

`-lab.glow ember` (the warm system orange, lit from the top, directionality
0.75, a 28-point halo at 0.9) and `-lab.glow energy` (system cyan at the top
and purple at the bottom, a 28-point halo at 0.9, and a 1.8 s pulse of depth
0.55) give the custom panel a halo; `energy` adds a native Pulse switch
(`lab.glowPulse`) that settles the pulse. The diagnostics' `Halo:` line
reports the radius, intensity, pulse, whether the effect clock runs, and the
effect time; while the pulse draws, the diagnostics refresh about four times
a second. In portrait on the iPhone 18 Pro simulator the stage leaves 41
points of surface beside the panel and more above and below it, so the
28-point halos are not cut off (see the captures).

### Cost (Apple M5 Mac offscreen characterization, not device evidence)

`GlassWeaveCharacterizationTests` gained a glow mode: the GW-09 workload's
320 × 180 pt panel at scale 3 (1206 × 2622 px target) with the `energy`
preset's lengths and intensities (stand-in fixed colors), a 28-point halo
(a 1130 × 710 px quad instead of 962 × 542), and the pulse advancing with
the 60 Hz ticks. Scheme `GlassWeaveCharacterization` (Release, no Metal API
Validation), three interleaved runs of 60 s per mode after 10 s warm-ups,
thermal state nominal: nearest-rank p95 GPU time per frame (one command
buffer: the producer's background, the background pass, and the panel)
0.743 ms background, 0.876 ms panel, 1.136 ms glow. The increments were
stable across runs: panel − background +0.131 to +0.135 ms (pooled +0.133),
glow − panel +0.258 to +0.263 ms (pooled +0.260). Every run drew all 3,600
ticks with no deferral at the bound. The full report is in
[the glow characterization record](evidence/glow-characterization.md).
This describes an Apple M5 Mac rendering offscreen, not an iPhone or iPad.

## GW-20 plan: several shapes in one pass

The gallery draws **all its shapes in one `GlassSurfaceView` pass**:
`GlassRenderer` will accept an ordered list of panels (a small fixed maximum)
and draw each as one quad after the background, in the same render pass,
sampling the same source frame. One surface per shape was rejected:

- One produced frame then serves every shape, so the background, every
  refraction, and every halo always show the same frame (GW-06's guarantee),
  with one scheduler, one in-flight bound, one drawable pool, and one clock.
- Separate surfaces would each need their own source (a cropped lease of a
  shared texture kept in step across renderers), their own three drawables,
  their own command buffers, and extra margins for halos, multiplying memory
  and submissions for no visual gain.

Each panel's fragment composites its body and halo over the background
sample, so where two panels' quads overlap the later one wins. The gallery
lays out its shapes so that quads (shape, halo, and one pixel) never
overlap; merging shapes optically is GW-13's subject, not this one. The faint
floor reflection under the element capsules is part of the laboratory's own
background producer, which the app owns anyway.

## Enhanced-native glow (GW-14, implemented)

Genuine native glass cannot carry this glow inside itself: `UIGlassEffect`
exposes a `tintColor` for the whole material and `isInteractive`, and no
public API recolors its edge separately, makes its middle transparent, or
injects a shader. GW-14 therefore draws the colored rim and halo *around* the
native view, with Core Animation only.

### API

`EnhancedNativeGlassView` (GlassWeaveUIKit) is one new public view; it adds
no new value type. It holds a `NativeGlassView` (`glass`, the genuine
`UIVisualEffectView` with a public `UIGlassEffect`) pinned to its bounds.
The app configures the glass as before (`glass.configuration`,
`glass.cornerConfiguration`, controls in `glass.contentView`) and sets the
glow with `setGlow(_:)`, which takes the same `GlassGlow` as a custom panel
and follows the same normalization rule (a non-finite value throws naming
its field and keeps the current glow; finite values are clamped). `glow`
reports the normalized glow, `presentedGlow` the glow drawn (after
`GlassAccessibilityPolicy`, with the parts native mode does not draw at 0
and the rim's lengths limited to half the shorter side of the bounds),
`accessibilitySettingsSource` and `accessibilitySettings` work as on
`GlassSurfaceView` (the same `AccessibilitySettingsSource` type), and
`isAnimating` reports whether the pulse animation is attached. An option on
`NativeGlassView` was rejected: a `UIVisualEffectView` should not get
sublayers of its own, and a halo must not be clipped by, or sampled under,
the glass, so the glow lives in a container beside it.

### What is drawn

| `GlassGlow` field | Native mode |
| --- | --- |
| `colors` | The color model of custom mode (`GlowColorModel`, shared with `GlassPanelGeometry`): one color, or the stops interpolated in linear light around the center with the shape scaled to a square, 0° at the top, clockwise. Sampled every 2° (and on both sides of every stop) into conic `CAGradientLayer`s, whose angle runs in the layer's unit square like custom mode's. The halo's layer is larger than the glass, so its samples are placed at the angle of the same ray in its own square; a ray's color is the same in the rim and the halo. |
| `lightAngle`, `directionality` | Custom mode's light, `(1 − k) + k((1 + n·L)/2)²`, with `n` the outward normal of the outline point on each ray from the center (found in closed form: the rectangle's edge, or the corner's circle), on custom mode's normal field (corners at least `rimWidth + max(rimSoftness, 1 px)` round). Exact for the rim on every shape; along each ray for the halo. |
| `rimWidth`, `rimIntensity` | A band from the outline to `rimWidth` inside it, over the glass's edge, filled crisply (opacity `rimIntensity × light`), clipped to the outline. |
| `rimSoftness` | Under the band, a Core Animation shadow (radius `s/4`) of the band extended by `s/2` on both sides, clipped at the outline: the rim is opaque to `rimWidth` and fades over about `s` beyond it (half at `rimWidth + s/2`, as in custom mode). |
| `haloRadius`, `haloIntensity` | A Core Animation shadow of the outline grown by `0.355 R`, with `shadowRadius` `0.216 R` (`R` the halo radius), as the mask of a conic gradient (opacity `haloIntensity × light`). It is a Gaussian stand-in for custom mode's `(1 − s/R)²`: `Φ((0.355 R − s)/0.216 R)`, which is 0.95 at the outline, 0.25 at `R/2`, and 0.0014 at `R`. A second mask removes it everywhere inside the outline but its outermost pixel, so it never lies under the glass's middle. Its layers reach `ceil(1.22 R + 1)` points beyond the bounds. |
| `pulsePeriod`, `pulseDepth` | One `CABasicAnimation` of `opacity` per layer (rim and halo), from 1 to `1 − depth` over half a period and back (autoreversing, repeating), eased with the sine curve `(0.37, 0, 0.63, 1)`, which follows `(1 − cos πx)/2` within 0.5 %: the level is custom mode's `1 − depth(1 − cos 2πt/period)/2`. |
| `innerGlowRadius`, `innerGlowIntensity`, `centerOpacity` | Not drawn: the inside is Apple's material. `presentedGlow` reports them as 0. |

Layers: below the glass, the halo (a layer masked by the outline's
complement, holding the conic gradient masked by the shadow); above the
glass, the rim (a layer clipped to the outline, holding the conic gradient
masked by the band and its shadow). They are sublayers of the container,
not of the glass, and not views: they take no touches and add no
accessibility element. Core Animation composites them source-over in the
window's color space, as every layer; GlassWeave picks their colors in linear
light, not the blend (custom mode screens its halo in linear light). A halo
therefore shows best on darker backgrounds; over a light one a color darkens
the channels it lacks.

What "the middle stays Apple's glass" means here: GlassWeave draws nothing
inside the outline but the rim band. Apple's glass blurs and lenses its own
backdrop, which now includes the halo beside it, so with a halo the glass's
middle picks up a little of that light by itself (measured below); with a
rim-only glow it is unchanged.

### Layout, animation, and visibility

- **Geometry.** At every layout pass the view lays the glass out first,
  then reads its resolved corners with `effectiveRadius(corner:)` (fixed,
  per-corner, capsule, or container-concentric), so the glow matches the
  frame just set; reading them in `layoutSubviews` also lays the view out
  again when only the glass's `cornerConfiguration` changes. A pass that
  changes nothing the glow depends on (frame, corners, display scale,
  presented glow) rebuilds nothing.
- **Animated frames.** When the glass's frame is animated (a `UIView`
  animation, rotation), the glow's bounds, positions, and paths get
  animations with the glass's own `bounds.size` timing (duration, begin
  time, curve, or spring parameters).
- **Scale and traits.** Every layer renders at `traitCollection.displayScale`
  (the halo's one-pixel overlap follows it); Increase Contrast is re-applied
  on its trait change. Colors are sRGB values the app sets; to follow light
  and dark with dynamic colors, set the glow again from
  `registerForTraitChanges` (the laboratory does).
- **No clipping.** The container does not clip. Callers keep about
  `haloRadius` (the layers reach `1.22 × haloRadius + 1`) of unclipped space
  around it; a scroll view or a view with `clipsToBounds` cuts the halo.
- **Pulse only while visible.** The pulse is attached only while the view is
  in a window, neither it nor an ancestor is hidden or transparent, and its
  window scene is in the foreground, by `GlassSurfaceView`'s rule
  (`SurfaceVisibility`); it is removed when the pulse goes, the glow
  settles, Reduce Motion is on, the view is hidden, its scene goes to the
  background, or it leaves its window, and it resumes where it stopped
  (`timeOffset`). The view looks again on window, `isHidden`, `alpha`, and
  scene changes and at every layout pass; UIKit reports no change to an
  ancestor's `isHidden`, so after hiding an ancestor the app lays the view
  out (`setNeedsLayout()`, `layoutIfNeeded()`), as the laboratory's Stage
  switch does. No display link, update link, renderer, Metal device, or
  `MTKView` exists on this path.

### Accessibility

The glow rows of the [mapping](#accessibility-mapping) apply through the
same `GlassAccessibilityPolicy` function as the custom panel's: Reduce
Transparency keeps a crisp, evenly lit rim at most 2 points wide and removes
the halo and pulse; Increase Contrast keeps the rim (evenly lit), the halo,
and the pulse; Reduce Motion holds the rim and halo at the pulse's mean
level, `1 − pulseDepth/2`, with no animation. The glass applies the system's
own settings to its material.

### Laboratory

`-lab.nativeGlow <preset>` (`amber`, `aurora`, `ember`, `energy`, the custom
panel's presets) gives the native reference glass the same glow; without it
the reference is plain native glass in a host that draws nothing. A Native
glow switch (`lab.nativeGlowEnabled`) turns it off for comparison, the Pulse
switch settles `energy`, and the diagnostics' `Native glow:` line reports
what is drawn and whether its animation runs. The stack spacing grows by the
halo radius so the halo clears the caption and the custom panel.

### Measured (iPhone 18 Pro simulator on an Apple M5 Mac, not device evidence)

- **Halo profile**, read from screenshots over the still pattern (the
  `energy` preset, pulse settled, opacity from the blue channel over yellow):
  0.819, 0.625, 0.233, 0.032, 0.000 at 2, 7, 14, 21, 28 points outside the
  top edge, against 0.815, 0.618, 0.226, 0.030, 0.001 documented (dark;
  light within 0.007 as well); no change from the layers' reach on.
- **The glass's middle**, glow on versus off: with the rim-only `aurora`
  glow at most 2 steps from 6 points in (the rim band and its soft edge
  cover 0 to about 4.5 points); with the `energy` halo, 20, 14, 10 steps
  (dark) and 43, 32, 24 steps (light) from 6, 12, 18 points in, which is
  Apple's glass picking up the halo beside it; a halo left under the glass
  (a deliberate mutation) changed it by 192 to 195 steps.
- **Rim colors**: within 2 steps of the gradient at the pixel's angle on a
  straight edge, and within 9 next to a stop whose neighbour differs steeply
  in an encoded channel (Core Animation's conic gradient).
- **Layout cost** (Debug build, simulator): a resizing layout pass takes
  0.10 ms without a glow and about 0.55 ms with a two-color rim and halo;
  unchanged passes rebuild nothing.
- **Composition cost** (CPU time over 10 s, still pattern, three runs each):
  no glow and a static glow (`ember`) 0.00 to 0.01 s for both the app and
  the simulator's render server (`backboardd`); the pulsing `energy` glow
  1.35 to 1.37 s in the render server and 0.00 s in the app; under Reduce
  Motion 0.00 to 0.01 s. For context, the same preset on the custom panel
  (GW-18, Metal) used 1.70 to 1.74 s in the render server and 0.90 to 0.92 s
  in the app. GPU time of the composition is not reported by the simulator.
  Device GPU, display, and energy cost are not measured.

## Testing strategy (GW-14)

- UIKit tests on the iPhone 18 Pro simulator (`EnhancedNativeGlassViewTests`):
  the layers' frames, paths, shadow radii, and masks against the glass's
  frame and resolved corners (capsule, fixed, per-corner) through resizes,
  corner-configuration changes, an animated frame change (matching
  animations with the glass's timing), and display-scale changes; gradient
  colors and alphas against the color model and the light (including the
  outline's own normal on a wide capsule, and the halo's remapped angles);
  rim pixels rendered on the CPU with `CALayer.render(in:)` (which draws
  masks and gradients but no shadows); the glass's effect, tint, and layer
  order; hit testing through the halo to a view behind and onto the native
  button; the renderer census and no `MTKView`; the pulse animation, when it
  is attached and removed, and where it resumes; the accessibility mapping;
  the normalization rule; the cost of a resizing layout pass and the skip of
  unchanged passes.
- Laboratory UI tests (`EnhancedNativeGlowUITests`) reading screenshots of
  the running app over the still pattern, glow on versus off: rim colors at
  four angles and the unchanged middle (rim-only), the halo's profile and its
  reach, the middle's change with a halo (bounded, against a mutation), the
  rim through rotation and the largest text size, taps during the pulse with
  no custom submissions, settling (Pulse switch, hidden stage, background,
  Reduce Motion, Reduce Transparency), and the accessibility audit in light
  and dark.

## Testing strategy (GW-18)

- Parameter tests: defaults, clamping (the halo radius is not limited by the
  panel), rejection naming each new field, the pulse level at chosen times
  (including a long-running clock and the mean over a period), and the
  steady (Reduce Motion) glow.
- GPU readback on My Mac (Apple M5) with Metal API Validation: byte identity
  with a frozen copy of the GW-17 shader
  (`Tests/GlassWeaveTests/Shaders/GlassBaselineGW17.metal`) for glows without
  a halo, including a pulse at a whole period; the halo's linear-light hue;
  monotonic falloff along rays from the sides and corners and exact zero from
  the radius on; unchanged background bytes beyond the halo in 1:1 and scaled
  presentations; no darkened channel and no dark seam at the outline; every
  halo pixel between the background and the background screened with the full
  color; the halo lit like the rim; whole images within one step of the CPU
  model (four cases); a halo cut off at the target's edge; scale
  independence; the pulse at chosen instants (periodic, mirrored, and equal to
  the dimmed steady glow at its trough, with the middle unchanged); and
  determinism.
- UIKit tests on the iPhone 18 Pro simulator with a controlled clock: when the
  clock runs, one frame per tick, nothing between ticks, settling, hiding,
  Reduce Motion, coalescing at the in-flight bound, the surface freed with a
  running clock, and the accessibility mapping (including offscreen renders
  under Increase Contrast and Reduce Transparency).
- A laboratory UI test counting submissions while pulsing, settled, with the
  stage hidden, in the background, and under Reduce Motion.

## Testing strategy (GW-17)

- Parameter tests: every field's range, clamping, angle reduction, stop
  limit and order, `.none` for no stops, and rejection of NaN and ±infinity
  naming each field.
- Record tests: host layout, the shader's view through a compute probe with
  distinctive values and nonzero padding sentinels.
- GPU readback on My Mac (Apple M5) with Metal API Validation: rim colors
  (several solid colors and a four-stop gradient sampled at the stop
  angles), the center-equals-glow-off property, the extent limit, the CPU
  model for width, softness, intensity, inner radius, light angle, and
  directionality, and bit-identity with the frozen GW-05 shader for default
  and non-default GW-05 parameters.
- UIKit tests on the iPhone 18 Pro simulator for the accessibility mapping.
- Simulator captures of the laboratory panel (`-lab.glow`), inspected for
  color, smoothness, seams, and banding.
