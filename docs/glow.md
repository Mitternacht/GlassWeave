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
center fill. Later tasks add a halo outside the shape (GW-18), animated
interiors (GW-19), the same colors around native glass (GW-14), and a
gallery of original demos (GW-20).

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

Implemented for GW-17's rows. `GlassAccessibilityPolicy` applies these to the
presented panel (the app's panel is kept unchanged); the GW-18 and GW-19 rows
are the plan:

| Feature | Reduce Transparency | Increase Contrast | Reduce Motion |
| --- | --- | --- | --- |
| Body (GW-05/GW-08) | Opaque `secondarySystemBackground`, no refraction or edge light (GW-08) | Unchanged; the app's tint keeps text at 7:1 through the GW-08 legibility rule | Unchanged (no motion) |
| Rim (GW-17) | Kept with its colors as a crisp, evenly lit band: its width plus softness, capped at `GlassAccessibilityPolicy.reducedTransparencyRimWidth` (2 pt), so the shape keeps its color identity on the opaque body | Kept with its width and softness, evenly lit (directionality 0), a clearer boundary | Unchanged |
| Inner glow, center fill (GW-17) | Removed: the body is exactly the opaque legible surface | Removed: the interior is exactly the GW-08 glass, so the legibility rule for text still holds | Unchanged |
| Halo (GW-18) | Removed | Kept (outside the shape, behind no text) | Steady at its mean level |
| Pulse (GW-18) | Not drawn (no halo; rim steady) | Kept | Off: steady at the mean level |
| Interiors (GW-19) | Removed | Removed (they would move behind text) | A fixed still frame (effect time 0) |

The legibility rule (`GlassTint.minimumStrength`) covers the interior when
the center fill is 0, which Increase Contrast enforces. A center fill above 0
mixes the glow colors into the interior; extending the rule to it is left to
GW-20, where text first sits on a filled body.

## GW-18 plan: halo outside the shape

- The panel's quad grows from "panel + 1 px" to "panel + halo radius + 1 px"
  (clipped by the rasterizer to the target), so the halo can extend anywhere
  inside the surface. The surface owns its whole drawable, so a halo is
  clipped only by the surface's bounds; an app gives its surface a margin of
  at least the halo radius around each shape (the GW-20 gallery uses one
  full-screen surface).
- Outside the outline, `halo = haloIntensity × (1 − distance / haloRadius)² × light(n)`,
  with `n` the outline's own normal (radial at the corners) and the same
  light and colors as the rim, composited in linear light over the
  background sample and dithered. Pixels with nothing to draw use
  `discard_fragment()`, so they keep the background pass's bytes exactly.
  A halo radius of 0 keeps the GW-17 quad and output.

## GW-18 and GW-19 plan: one clock, on demand

- **One shared clock per surface.** `GlassSurfaceView` will own an effect
  clock: a `UIUpdateLink` created for the surface's own view (so it follows
  that window's display and never a global link), enabled only while (1) a
  presented panel has something animated (a pulse with non-zero depth or an
  interior), (2) the surface is visible by the GW-07 rule, and (3) Reduce
  Motion is off. Each tick advances one effect time and calls
  `requestFrame()`, so ticks merge with the app's own requests and obey the
  in-flight bound: a tick at the bound is coalesced, never queued.
- **The renderer stays a function of its inputs.** The effect time is a
  uniform (seconds, wrapped to a long period to keep float precision), set by
  the host per draw; tests set it directly, so pulses and interiors are
  deterministic and readback-testable.
- **Settling.** Removing the pulse or interior, hiding the surface, or
  turning on Reduce Motion disables the link at once; the next draw (one
  frame) shows the steady state, and then nothing is submitted. Tests count
  `FrameStatistics.submitted` while animating, after settling, while hidden,
  and under Reduce Motion, and `FrameLedgerTests` stay unchanged.
- **Transitions** (for example the theme toggle in GW-20) are app-driven
  parameter changes: the app interpolates panel parameters for a short time
  with its own update link and requests a frame per step; under Reduce
  Motion it jumps to the end. Each step updates uniforms only; no renderer or
  texture is rebuilt.
- GW-04's open item (the main-thread drawable wait in
  `GlassSurfaceView`) is not changed by this plan. Animation adds frames but
  keeps the two-frame bound, so the wait stays bounded the same way; it is
  not fixed here.

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

## Enhanced-native glow (GW-14)

Genuine native glass cannot carry this glow inside itself: `UIGlassEffect`
exposes a `tintColor` for the whole material and `isInteractive`, and no
public API recolors its edge separately, makes its middle transparent, or
injects a shader. GW-14 therefore draws the colored rim and halo *around*
the native view with Core Animation and no Metal: a ring (`CAShapeLayer`
path from the native view's corner configuration) filled by a
`CAGradientLayer` of type `.conic` for the angular gradient, and a halo from
a shadow or blurred layer behind the glass. The native glass keeps its own
material and optional tint; a pulse is a Core Animation opacity animation
that is removed under Reduce Motion, so a settled native glow runs no
animation at all. It uses the same `GlassGlow` color model so one value can
style both modes.

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
