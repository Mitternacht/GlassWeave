# Interaction (GW-12, GW-13)

Experimental. Everything here is unreleased and can change. This note covers how
GlassWeave's own glass answers a finger (GW-12). The merge of two surfaces
(GW-13) adds its own section below when it lands.

## Touch response (GW-12)

Apple's interactive glass answers a touch with a light that gathers under the
finger. GlassWeave draws its own, in the same restraint, and the ring is real
refraction. The look comes from three parts, all of them off by default:

| Part | What you see | One light, one reason |
|---|---|---|
| Finger light | A soft pool of light, 44 points wide by default, under the finger. It lifts the glass's own color toward white (it does not lay a gray fog over it), comes up over 0.10 s, follows the finger, and fades over 0.35 s after it lifts. | The finger is a contact; glass passes more light there. |
| Ripple | One ring that starts where the touch began and travels 120 points over 0.85 s, thinning as it goes. It moves the sample of the backdrop by at most `ripple x 8` points (so a standard 0.8 is 6.4 points) and catches the key light on its lit side. | A bump travelling over glass is a thin lens; its slope bends the backdrop and the side that faces the light is brighter. |
| Gleam | A thin bright line on the outline just inside the rim nearest the finger, stronger the closer the finger is, brighter on the lit side. | The rim nearest the contact is the one that catches the light. |

### The state is a function

`GlassTouch.state(of:at:)` is a pure function of the style, the touch (origin,
position, when it began, when it ended) and the time on the effect clock. The
ring ends after `rippleDuration`; the light ends `fadeOut` after the touch
ends; `maximumRippleDisplacement` (8 points at `ripple` 1) bounds the bend at
every time and position. Nothing is random. The renderer resolves it on the CPU
for each draw and uploads positions, radii and levels (`GWTouchUniforms`, 128
bytes, with 48-byte `GWTouchPoint` records, bound at fragment buffer 3; size and
offsets asserted in C and MSL, and the size in the safety test), so the shader
sees no time.

### API (all experimental)

Core (`GlassWeave`): `GlassTouch` (the style, `GlassParameters.touch`, default
`.none`; `.standard`), `GlassTouchPoint`, `GlassTouchState`,
`GlassRenderer.setTouches(_:)` (up to two; a non-finite value throws
`GlassParameterError.nonFiniteTouch` naming the field; finite values clamp),
the `GlassRenderer.PipelineVariant.touched` variant.

UIKit (`GlassWeaveUIKit`): `GlassTouchObserver` (a gesture recognizer),
`GlassSurfaceView.beginTouch(id:at:)`, `moveTouch(id:to:)`, `endTouch(id:)`,
`cancelTouch(id:)`, `activeTouchCount`, and for captures `pinTouch(at:age:heldFor:)`
and `clearPinnedTouches()`.

### Observing without taking part

The surface takes no touches, and native controls above it keep theirs. The app
attaches one observer to the stage or to any ancestor of the glass and the
controls:

```swift
stage.addGestureRecognizer(GlassTouchObserver(surface: surface))
```

The observer never recognizes (its state stays `possible` and ends as `failed`
when the last touch lifts), so it never claims a touch; `cancelsTouchesInView`,
`delaysTouchesBegan` and `delaysTouchesEnded` are `false`; its delegate allows
simultaneous recognition with every recognizer and neither requires another to
fail nor is required to fail by one. It forwards each touch's begin, move, end
and cancel to the surface in the surface's coordinates. A button inside the glass
keeps its tap and its cancellation because its own tracking is untouched. This
has not been exercised on a device or in a UI test yet (see the limits).

### Pacing and settling

A touch that begins inside a panel whose presented touch style can draw opens one
`beginInteraction()` (the interaction rates, 80 to 120 Hz at the full tier). The
effect clock runs only while something moves: the ring, or a fade. A finger held
after the ring and the fade-in are over changes nothing without a move, so the
clock stops (the link stays for the interaction rate) and frames come from the
move events. When the finger lifts the clock runs for the fade, the touch is
removed when its response is over, `endInteraction()` closes, one last frame
shows the plain glass, and the surface draws nothing more (on demand again). The
lab's status line reads `after settle +0` and `clock off` after that, and the
capture [settled](evidence/captures/gw-12-touch-settled-iphone18pro-sim.png) shows it
after a tap made through the surface API (55 frames submitted during the
response, none after).

Two touches are answered at once. A third is ignored until one of the two has
lifted (a lifted one, still fading, makes room).

### Tiers and accessibility

| | Behavior |
|---|---|
| Balanced tier | Finger light and gleam; no ring. |
| Minimal tier | Off. |
| Reduce Transparency | Off (the opaque surface). |
| Increase Contrast | No ring and no gleam; the finger light stays as the state of the touch. |
| Reduce Motion | No ring and no fades: the finger light and the gleam show while the finger is down and are gone when it lifts. The surface runs no clock for them. |

The tier is applied first and the accessibility policy after it, like every
other effect (`GlassQuality.reduced(_:)`, `GlassAccessibilityPolicy.presentedTouch`).

### How the shader gets it

A function constant (index 6) and the `touched` pipeline variants (a rounded
rectangle and a freeform shape), built at initialization with the optics,
lighting, grounding and shape code and **without** the frost and fill code. A
panel draws in them only while a touch that began inside its outline has
something to show; otherwise it is drawn by the variant it would have used, with
the same bytes as before (the safety test
`GlassBaselineGW12Tests` compares seven cases against a frozen copy of the
previous shader, `Tests/GlassWeaveTests/Shaders/GlassBaselineGW12.metal`, on the
Mac and on the iPhone simulator, and also with an active style and no touch).
Control: an active touch differs. The ring moves the sample position before the
lens or rim refraction samples the backdrop; the finger light, the gleam and the
ring's catch light are added after the inner light and before the light model.
Design notes for the shader are in [glass-optics](glass-optics.md#touch-response-gw-12).

### Laboratory

`-lab.touch YES` (or the "Touch" button on the main screen) opens the page: a
clear GlassWeave pill with a native button in it and a round button, over a
backdrop (`-lab.touchBackdrop orbs|stage|grid`), and below them the same two
shapes in `UIGlassEffect` with `isInteractive`, as the benchmark for restraint.
`-lab.touch.pin "pill:0.3:0.55:0.18;round:0.55:0.5:0.12"` pins synthetic touches
(panel, position as a fraction of it, age in seconds, optionally how long it was
held) for captures; `-lab.touch.boost 2` scales the three strengths to inspect
the response; `-lab.touch.auto YES` taps the pill once through the surface's
own touch API.

Captures (iPhone 18 Pro simulator): [orbs](evidence/captures/gw-12-touch-orbs-iphone18pro-sim.png),
[stage](evidence/captures/gw-12-touch-stage-iphone18pro-sim.png),
[grid, which shows the ring bending the dots](evidence/captures/gw-12-touch-grid-ring-iphone18pro-sim.png).

### Tuning record

Three rounds, by eye. Round 1: the first light was a gray fog (white added over a
colored glass) and invisible at the standard strength on the orbs; the light now
lifts the glass's own color. Round 2: at the standard strength the response was
too faint to read; the standard became light 0.60, ripple 0.8, gleam 0.7. Round 3:
the ring's catch light and a two-Gaussian light read as a hard-edged disc on the
dark stage (a gel-disc look); the catch light dropped from 0.22 to 0.10, the ring
widened (`16 + 0.14 R` points) and the light became one Gaussian.

### Limits and deviations

- A panel with frost or a fill draws no touch response: the frost and fill
  variants are frozen byte-for-byte by earlier safety tests and carry no touch
  code. Adding it would need a second copy of each.
- The comparison with Apple's glass is at rest only: the captures show the
  `UIGlassEffect` twin idle. The pressed state of the twin was not captured (no
  touch injection into the simulator was available), so the match of the response
  to Apple's is a judgment by eye against the idle twin and against Apple's
  behavior as documented, not a side-by-side measurement.
- The gesture observer's no-interference claim rests on how it is built and on
  UIKit's documented rules; no UI test or device run exercised a tap or a cancel
  through it yet.
- No test of the state function's bounds, no per-tier or accessibility readback
  test, and no cost measurement: fast pass, not tested.
- The ring's catch light and the gleam are the least visible parts at the standard
  strength on a busy backdrop; they show on the dark stage and the grid.
