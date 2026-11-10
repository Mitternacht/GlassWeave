# Overlay mode (GW-30)

Experimental. Everything here is unreleased and can change. This note covers
GlassWeave's glass drawn **over live UIKit content**: a transparent surface that
composites its own light, tint and shade over whatever UIKit draws behind it,
without bending or frosting it.

## What it is, and what it cannot be

Apple's glass reads the pixels behind it, so it can bend and frost anything. A
Metal surface in a UIKit hierarchy cannot read what is behind it (the only route
is a private backdrop layer, which is not used). So the overlay does the part of
the glass that needs no backdrop, and says so:

| Term | Overlay | Why |
|---|---|---|
| Tint (the veil of the panel's color) | drawn | its own color; under Reduce Transparency it is the opaque body |
| Rim light (`edgeHighlight`) and the light model's rim, reflections, bloom | drawn | the panel's own light; the lens's bevel still shapes the surface normal |
| Glow (rim, inner glow, center fill) and halo | drawn | the panel's own light |
| Interior effects and embers' sparks | drawn | the panel's own light |
| Inner light (`GlassLight`) | drawn | the panel's own light |
| Inner shadow | drawn | a shade inside the rim |
| Drop and contact shadows, caustic | drawn, outside the outline only | the translucent body is not darkened by a shadow it does not cast on itself |
| Liquid and gel fill | drawn (its absorption becomes alpha) | its own material; an opaque fill is alpha 1 |
| Refraction, lens bend, dispersion | **unavailable** | needs the pixels behind the surface |
| Frost and its scrim | **unavailable** | same |
| Presence (the body's pickup of the backdrop) | **unavailable** | same |
| Touch response | **unavailable** | its ring bends the backdrop; the surface presents `touch` as none |

A panel's `frost` and `touch` are presented as none by the surface
(`presentedPanels`), so no touch is tracked and no clock runs for them. A lens is
kept (the light model follows its bevel), but nothing is refracted.

## API (experimental)

```swift
let renderer = try GlassRenderer(commandQueue: queue, mode: .overlay)
let surface = GlassSurfaceView(renderer: renderer)   // transparent: isOpaque == false
try surface.setPanels([GlassPanel(frame: bar, parameters: parameters)])
```

- `GlassRenderer.Mode` is `.opaque` (the default, everything before GW-30) or
  `.overlay`. `GlassRenderer.mode` and `GlassSurfaceView.mode` report it.
- An overlay renderer has no background pass and takes no source:
  `draw(targetPixelSize:displayScale:acquireTarget:)` clears the target to
  transparent black itself and draws each panel. `drawProducing` skips with
  `.missingSource`; `GlassSurfaceView.setSource`, `setFrameProducer` and
  `clearSource` do nothing on an overlay.
- `PipelineVariant.overlay` is what `drawnVariants` reports.
- The surface is drawn on demand like any other: as soon as it has a panel, a
  size and a window (no source is needed), and again only when something changes.
  A still overlay is **not redrawn while the content under it scrolls**; Core
  Animation composites it (the lab's status line stays at one frame).

## How a pixel is made

The shader (`gw_overlay_fragment`, `gw_overlay_shadow_fragment`,
`gw_overlay_caustic_fragment` in `Glass.metal`) is separate from the opaque one,
which is not touched: the opaque surface renders what it always did, byte for byte
(`GlassBaselineGW30Tests`, against the frozen `GlassBaselineGW30.metal`, in the
`base`, `optics`, `lighting`, `grounded`, `shaped`, `frosted`, `filled` and
`touched` variants). The overlay pipelines are built at renderer initialization,
only in overlay mode (a rounded rectangle and a freeform shape, each with and
without the fill record, plus the shadow and caustic pre-pass for each shape), and
never in the draw path.

Every term of the opaque stack is an "over" of some color. The overlay keeps the
stack as a layer instead of a color: the premultiplied (sRGB-encoded) color it adds
to the display, and, per channel, how much of what is behind it shows through.
A step that is affine in the glass color (the light model's and the fill's) is
evaluated over black and over white, which gives both exactly. The output then
needs one alpha, because Core Animation's premultiplied compositing is
`color + (1 - alpha) * behind`:

- alpha is the mean opacity of the three channels;
- the color is shifted by `(through - mean) * 0.5`, so a colored light is exact over
  a mid gray (and per channel over black before the shift). A light therefore
  stays brighter than its alpha where its channels differ, which is how a colored
  light adds to the page behind it instead of covering it;
- the shadow and caustic pre-pass draw outside the outline only; the halo and the
  body are layers over them; the antialiased ring mixes by coverage;
- the triangular dither (the clean look's) goes on color and alpha wherever the
  shader makes a gradient, so a soft glow or shadow has no steps in either.

### Premultiplied output with color above alpha, in Core Animation

The proposal marked this [A: untested in Core Animation]. Tested in the iOS
Simulator's compositor with the lab's probe (`-lab.overlay.probe YES`): black,
mid-gray and white stripes behind one panel that adds only a saturated orange
light (premultiplied red above alpha). Read back from the capture at one row
(8-bit values):

| Behind | R | G | B |
|---|---|---|---|
| black (0) | 173 | 60 | 49 |
| mid gray (128) | 254 | 141 | 129 |
| white (255) | 255 | 221 | 209 |
| outside the light's reach (all three stripes) | 0 / 128 / 255, untouched | | |

Over white the green channel gains 161 and the blue 160, so the single alpha is
0.37 (`1 - 161 / 255`); the stripe over gray follows the same line
(`60 + 0.63 * 128 = 141`). The red premultiplied value over black, 173
(0.68), is above that alpha (0.37) and is not clamped: red over gray is 254
(`173 + 0.63 * 128`), where a clamp to alpha would give 175. So color above alpha
composites as `color + (1 - alpha) * behind`, additively, as intended, and alpha is
exactly 0 (the page untouched) outside a panel's reach. **Simulator only**: the
same on a device is expected (it is one compositing rule) but not verified.

## Accessibility and input

| Setting | Behavior |
|---|---|
| VoiceOver | The surface is decorative: it and its Metal view expose no accessibility elements (the same as the opaque surface). |
| Hit testing | The surface and its Metal view take no touches, so every touch reaches the native content under or above it. |
| Reduce Transparency | The panel presents the policy's opaque body: a tint of `GlassAccessibilityPolicy.opaqueSurfaceTint(for:)` at full strength, which is alpha 1, so the content behind it is hidden; the policy's thin crisp rim stays, and the pooled light, the halo and the pulse go (the table in `GlassAccessibilityPolicy`). |
| Increase Contrast | The policy applies as it does to the opaque surface: the rim, an evenly lit hairline, the contact shadow; the body light, the caustic and the inner shadow are removed. |
| Reduce Motion | A glow's pulse and an interior or light stop at their still frame, so the effect clock stops. |

The hairline's polarity follows the panel's own tint (light on a dark panel, dark
on a light one): an overlay cannot sample the backdrop to choose it.

## Honest limits

- No bend and no frost: text under an overlay stays sharp. A tint veil is how the
  lab keeps a label legible (0.80 for the light bar, 0.74 for the dark one); the
  twin beside it, `UIGlassEffect`, shows what the system does that this cannot.
- The channel shift is exact over a mid gray, 0.5 encoded; over black or white the
  error of a strongly colored light is up to about 0.1 in one channel.
- Layers are combined in sRGB-encoded space (what Core Animation does with the
  layer and the page), not in linear light as the opaque surface does.
- Simulator compositor only; not measured on a device. Cost on a device is not
  measured.

## The lab page

`-lab.overlay YES` (or the menu's Overlay button) opens a native, scrolling
`UITableView` with one `GlassSurfaceView` (overlay mode) over it holding a glass
bar and a capsule with colored light pooled along its bottom edge and a halo, and
a `UIGlassEffect` twin bar. `-lab.overlay.offset <points>` sets the scroll offset
for captures; `-lab.overlay.auto YES` scrolls the list slowly by itself;
`-lab.overlay.flow YES` lets the pooled light drift (it is still by default, so the
surface is drawn once); `-lab.overlay.probe YES` is the Core Animation probe above;
`-lab.appearance light|dark`, `-lab.reduceTransparency YES`,
`-lab.increaseContrast YES` and `-lab.reduceMotion YES` apply the settings.

Captures (iPhone 18 Pro and iPad Pro 13-inch simulators, in
`docs/evidence/captures/`): `gw-30-overlay-light-offset330-*`,
`gw-30-overlay-dark-offset40-*`, the zoomed bars beside the twin and the zoomed
capsule, Reduce Transparency, Increase Contrast and the probe.
