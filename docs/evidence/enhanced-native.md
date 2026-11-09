# Enhanced-native glow (GW-14): measurements

Recorded 2026-11-09 on the iPhone 18 Pro simulator (iOS 27.2) hosted by an
Apple M5 Mac, Xcode 27.2. **Not device evidence:** the simulator's render
server runs on the Mac, and no iPhone or iPad was measured. The design is in
[the glow design](../glow.md#enhanced-native-glow-gw-14-implemented).

## What runs while the glow is shown

`EnhancedNativeGlassView` adds, under one host layer in its glass's content
view's layer, two groups of Core Animation layers: the halo (a layer masked by the outline's complement,
holding a conic `CAGradientLayer` masked by a layer whose shadow is the
grown outline) and the rim (a layer clipped to the outline, holding a conic
`CAGradientLayer` masked by the band and, when soft, the band's shadow). That
is eight layers and four masks. Nothing in the app process runs per frame:
there is no renderer, display link, update link, or timer, and a pulse is one
`CABasicAnimation` on each group's opacity, evaluated by the render server.

## Composition cost (CPU time)

Method: the laboratory launched over the still pattern (`-lab.source pattern`,
so the custom surface submits nothing after its first frame), 4 s to settle,
then the CPU time of the laboratory process and of the simulator's render
server (`backboardd`) read with `ps -o time=` before and after 10 s. Three
interleaved runs per configuration.

| Configuration | Render server, s per 10 s | App, s per 10 s |
| --- | --- | --- |
| No glow (`-lab.source pattern`) | 0.00, 0.00, 0.00 | 0.00, 0.00, 0.00 |
| Static glow, halo without a pulse (`-lab.nativeGlow ember`) | 0.00, 0.01, 0.00 | 0.01, 0.00, 0.00 |
| Pulsing glow (`-lab.nativeGlow energy`) | 1.35, 1.35, 1.37 | 0.00, 0.00, 0.00 |
| Pulsing glow under Reduce Motion (`… -lab.reduceMotion YES`) | 0.01, 0.00, 0.00 | 0.00, 0.00, 0.00 |
| For context: the same preset on the custom panel, GW-18 Metal pulse (`-lab.glow energy`) | 1.70, 1.74, 1.70 | 0.90, 0.92, 0.91 |

A settled glow costs nothing after it is drawn. A pulsing glow costs the
render server about 13.5 % of one Mac core on the simulator (it recomposites
the screen, including Apple's glass, at the display rate) and the app
nothing. The simulator reports no GPU time for this composition.

## Layout cost

`EnhancedNativeGlassViewTests` measures 120 resizing layout passes of a
220 × 64 point capsule (Debug build, simulator), twice each, with and
without the `energy` glow: median 0.10 ms without a glow and about 0.55 ms
with it (p95 about 0.60 ms). The cost is paid once per change of frame,
corners, display scale, accessibility settings, or glow; a layout pass that
changes none of them rebuilds nothing (checked by test).

## Pixels on screen

From `EnhancedNativeGlowUITests`, screenshots of the running laboratory over
the still pattern, glow on versus the Native glow switch off:

| Check | Dark | Light |
| --- | --- | --- |
| Halo opacity at 2, 7, 14, 21, 28 pt above the top edge (documented 0.815, 0.618, 0.226, 0.030, 0.001) | 0.819, 0.625, 0.233, 0.032, 0.000 | 0.822, 0.623, 0.233, 0.030, 0.000 |
| Change beyond the halo's layers (40 pt out, three points) | 0 steps | 0 steps |
| Rim color one point inside the top edge, against the gradient at the pixel's angle | within 2 steps | within 2 steps |
| Glass middle from 6 pt in, rim-only glow (`aurora`) | at most 2 steps | at most 2 steps |
| Glass middle from 6, 12, 18 pt in, with the 28 pt halo (`energy`) | 0, 0, 0 steps | 0, 0, 0 steps |

The halo lies over Apple's material outside the outline only, so the glass
neither covers nor samples it. (When the layers were siblings of the glass,
with the halo below it, the last row read 20, 14, 10 steps dark and 43, 32,
24 steps light: Apple's glass picking up the halo beside it.) A deliberate
mutation that removed the halo's hole mask changed the same region by 228
steps. Rim colors next to a stop whose neighbour rises steeply in an
encoded channel (yellow's blue toward cyan) measured up to 9 steps off: Core
Animation's conic gradient, not the color model.

## Press (interactive glass)

Method: `-lab.nativeGlow aurora` (rim only) and `-lab.nativeGlow ember`
(rim and halo), dark appearance, still pattern; a touch held for 8 s on the
native button with Xcode's device-interaction tool while `simctl io
screenshot` captured the screen every 1.5 s. Pixels at 3 per point along the
capsule's middle row and center column:

| | Rest | Pressed |
| --- | --- | --- |
| Glass's left edge (darkened pixel), first rim pixel | 357, 358 | 334, 335 |
| Last rim pixel, glass's right edge | 848, 849 | 871, 872 |
| First rim pixel at the top | 1112 | 1105 |

The glass grows about 7.7 points at each end and 2.3 points at the top and
bottom, and the rim moves with its edge; the halo stays outside the pressed
outline ([capture, rest above and pressed below](captures/gw-14-native-ember-rest-and-pressed-dark-iphone18pro-sim.png)).
Before the layers moved into the glass's content, the same press left the
rim on the resting outline, about 23 pixels inside the pressed edge. XCUITest
cannot take a screenshot during a press, so this is a recorded manual check.

## Open

- Device GPU and render-server cost, display appearance, and energy on an
  iPhone or iPad (physical devices are out of scope here).
- A comparison under GW-09's workload with `RenderMetrics`: the native path
  has no GlassWeave command buffers to time, so a device comparison needs
  Instruments' Core Animation or GPU tracks.
