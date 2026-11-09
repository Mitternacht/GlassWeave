# Interaction (GW-12, GW-13)

Experimental. Everything here is unreleased and can change. This note covers how
GlassWeave's own glass answers a finger (GW-12) and how two of its surfaces merge
and separate under a spring (GW-13, [below](#merging-two-surfaces-gw-13)).

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

Round 4 (POLISH, "the bends are way too visible"): the response is quieter and
better blended. The standard style is now light 0.55 with a 58-point radius, ripple
0.32 (at most about 2.6 points of displacement) with a wider ring (`22 + 0.2 R`
points, reach 140), gleam 0.45, the ring's catch light 0.06 and the gleam strength
0.45. A still frame shows the soft pool; on the dot grid the dots under the ring
crowd a little; on a soft backdrop the ring is not visible as a ring. See
[glass-optics](glass-optics.md#polish-subtle-blended-bends-a-calm-touch-the-chrome-ring-and-the-liquid-finish-polish).

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

## Merging two surfaces (GW-13)

Two surfaces of GlassWeave's own glass, for example a minus and a plus button,
that merge into one pill and separate again under a progress from 0 to 1.

**Custom to custom.** GlassWeave owns both surfaces: they are two parts of one
blob, drawn as one panel (the shape field is in
[glass-optics](glass-optics.md#merging-two-surfaces-gw-13)). Apple's
`UIGlassEffect` merges too, through the system's `UIGlassContainerEffect` (glass
views inside one container blend when closer than its `spacing`). That is a
separate material system with its own look and its own rules; GlassWeave does not
drive it, and nothing here changes it. The lab shows it beside ours, driven from
the same progress, only as the benchmark for restraint.

### API (all experimental)

Core (`GlassWeave`): `GlassSurfaceMerge` (two `Surface`s, each a `Pose` apart and
a `Pose` merged; `blob(progress:)`, `shape(progress:)`, `normalizedProgress(_:)`),
`GlassBlob.interiorSmoothness`, `GlassShape.Field.mergeProgress`. A progress that
is NaN or infinite throws `GlassParameterError.nonFiniteShape(.mergeProgress)`;
a finite one clamps to 0...1. Off is the default: no merge, no shape change, no
new pipeline; every existing shape is byte-identical.

UIKit (`GlassWeaveUIKit`): `SurfaceTransition`.

```swift
let transition = try SurfaceTransition(
    surface: surface, merge: merge, frame: stepperFrame, parameters: parameters
)
try transition.setTarget(1)   // merge; a spring on the effect clock
transition.reverse()          // turn around, even in flight
try transition.scrub(to: 0.4) // a slider: set it directly, no spring
```

`SurfaceTransition` calls the app's panel closure (or builds the one merged panel
from `merge`, `frame` and `parameters`) each time the progress changes and gives
the result to the surface. The surface keeps it weakly; the app owns it.

### The spring

A critically damped spring by default (`Spring`: response 0.5 s, damping 0.9;
about 0.8 s to settle). `setTarget` and `reverse` retarget **without a jump**: the
spring's value and velocity carry over, the glass coasts the way it was going for a
moment, then comes back. The lab's status line reads `largest dv`, the largest
change of velocity between two frames: 2.6 per second after a merge that was
reversed 0.2 s in, which is the spring's acceleration times one frame (a jump
would flip the velocity, a change of about 8). The state advances by the effect
time (the sum of the clock's deltas, clamped to 0.1 s a tick, in 1/240 s
substeps), so it follows the clock, not the wall.

### Clock and settling

The surface runs its effect clock while the spring moves (a transition is a clock
client: `GlassEffectClockClient`, internal), asks the display for the interaction
rates (`GlassMotionClass.interaction`: 80 to 120 Hz at the full tier, 60 Hz
below), and stops the clock on the tick that settles the spring, which presents
the last frame. After that the surface draws nothing more: on demand again. The
lab's status line reads `after settle +0` and `clock off` (capture
[settled after a reversal](evidence/captures/gw-13-merge-settled-after-reverse-iphone18pro-sim.png):
50 frames submitted during the motion, none after). A surface that is hidden or
has no source does not run its clock; the spring waits and resumes where it was.

### Reduce Motion and the quality tiers

| | Behavior |
|---|---|
| Full and balanced tiers | The spring runs; the clock's rate and the interaction rate follow the tier (60 Hz at balanced). |
| Minimal tier | A change of target jumps to the end state: no clock, no velocity. |
| Reduce Motion | The same jump. A setting that changes in flight jumps the spring to its target. [Capture](evidence/captures/gw-13-merge-reduce-motion-jump-iphone18pro-sim.png): one frame, `clock off`, velocity 0. |
| Reduce Transparency, Increase Contrast | These change the material (the opaque body), not the motion; the outline still moves. |

### Layout and hit-test policy for native content

The glass is decorative; it moves nothing but itself.

1. **Native controls keep their frames for the whole transition.** The minus and
   plus buttons are ordinary UIKit buttons at fixed frames (52 x 52 pt, centered
   on the two surfaces' centers). The merge never moves, resizes or
   re-parents a view. The poses should keep each button inside the glass at every
   progress (the lab's arms start under the buttons and grow toward each other).
2. **Native controls keep their own hit testing.** The surface takes no touches
   (`isUserInteractionEnabled` is `false`), so every tap goes to the view
   underneath as before. A button's hit area does not follow the outline: it is the
   same frame apart, merging and merged. A tap on the glass between the buttons
   goes to whatever the app put there (nothing, in the lab). Verified in the lab
   under Reduce Motion by tapping the plus button in the merged state
   (quantity 2 to 3) and the reverse button (a native control with its own frame).
3. **Text and controls that appear or leave use ordinary UIKit animation.** The
   lab fades the value between the buttons in with `UIView.animate` (0.4 s, 0.12 s
   delayed, so it appears as the glass closes around it) and out again, on
   `setMerged`, `reverse()` and the slider, and drops the animation under Reduce
   Motion. A view that fades is hidden from accessibility while it is not shown
   (`isAccessibilityElement`), so VoiceOver reads what is visible. `progressHandler`
   (every change of progress) and `didSettleHandler` are there for content that
   should follow the progress itself.
4. **Accessibility frames stay put.** The buttons' accessibility frames are their
   view frames, so they do not move during the transition either.

### Laboratory

`-lab.merge YES` (or the "Merge" button on the main screen) opens the page: native
text, a stepper of two GlassWeave surfaces (minus, a value, plus), a native switch
that merges them, a native "Reverse" button that turns the flight around, a native
slider that scrubs the progress, and below it the same two shapes as
`UIGlassEffect` views inside a `UIGlassContainerEffect` driven from the same
progress. `-lab.mergeBackdrop stage|orbs` picks the backdrop (default stage);
`-lab.merge.progress <0...1>` pins a progress (no spring, no clock) for captures;
`-lab.merge.auto YES` merges, reverses 0.22 s later, and lets it settle apart.

Captures (iPhone 18 Pro simulator, progress 0, 0.25, 0.5, 0.75, 1):
[orbs](evidence/captures/gw-13-merge-orbs-progress-strip-iphone18pro-sim.png),
[stage](evidence/captures/gw-13-merge-stage-progress-strip-iphone18pro-sim.png),
and [beside the system's merge](evidence/captures/gw-13-merge-vs-native-container-iphone18pro-sim.png)
(progress 0.45).

### Limits

- The native twin's look is Apple's: pearlier and brighter than ours on the orbs,
  flat gray on the stage; ours is the calmer, clearer material of the other pages,
  and the two read as the same family by their shapes and rims, not by their
  fill.
- The interrupt claim rests on the spring's construction and on one logged run
  (`largest dv`); no UI test or device run drove a reversal.
- The merge is two parts. More than two, other primitives (boxes), or a merge of
  a surface with a frost map or a fill were not tried. Frost and fill follow the
  merged outline through their shaped variants but were not captured on a merge.
- The touch response (GW-12) answers a merged panel like any shaped panel; it was
  not exercised during a transition.
- No cost measurement; simulator only.
