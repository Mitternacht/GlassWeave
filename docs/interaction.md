# Interaction (GW-12, GW-13, GW-32)

Experimental. Everything here is unreleased and can change. This note covers how
GlassWeave's own glass answers a finger (GW-12) and how two of its surfaces merge
and separate under a spring (GW-13, [below](#merging-two-surfaces-gw-13)); GW-32 adds a panel spring and
merging by proximity ([below](#glass-springs-and-proximity-merge-gw-32)).

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

## Glass springs and proximity merge (GW-32)

Experimental. Two parts: a spring that moves a panel's frame, and a merge that
follows the distance between panels. Both are meant for glass that a finger drags.

### Panel spring (`PanelSpring`, GlassWeaveUIKit)

```swift
let spring = try PanelSpring(surface: surface, frame: pillFrame)   // .follow: 0.28 s, damping 0.86
spring.frameHandler = { frame in /* build the panels from every spring's frame */ }
try spring.setTarget(fingerFrame)   // retargets in flight: position AND velocity carry over
try spring.jump(to: frame)          // place it now: no spring, no velocity
```

`setTarget` is what a pan gesture calls on every move: the glass follows on a
spring and never snaps or stops when the finger changes course. The state is the
frame as four numbers (x, y, width, height) and their rates, advanced by the
surface's effect time (clock deltas clamped to 0.1 s, 1/240 s substeps, the same
maths as `SurfaceTransition`). A `NaN` or infinite component throws
`PanelSpringError.nonFiniteFrame(_:)` naming it; a finite value clamps (sizes at
0, everything within 100 000 points).

**Clock and pacing.** A moving spring is an effect-clock client, like the merge
transition of GW-13: the surface runs its clock and asks the display for the
interaction rates while any spring moves, and the tick that settles the last one
is the final frame, after which the surface draws nothing (on demand again). Any
number of springs on one surface share the one clock. A pan gesture opens
`surface.beginInteraction()` for its length so the display keeps the high rate
while the finger is held still.

| | Behavior |
|---|---|
| Full and balanced tiers | The spring runs on the clock at the tier's rate. |
| Minimal tier | A new target is reached at once: no clock, no velocity. |
| Reduce Motion | The same jump; a setting that changes in flight jumps the spring to its target. |
| Reduce Transparency, Increase Contrast | The material changes (the opaque body), the motion does not; the surface applies the policy to every panel. |

### Proximity merge (`GlassProximityMerge`, GlassWeave)

`GlassProximityMerge.progress(gap:isMerged:)` maps the gap between two panels'
outlines (points; 0 when they touch, negative when they overlap) to a merge
progress from 0 to 1. A pure function: the same inputs give the same value; for
one state it never decreases as the gap closes; it is clamped to 0...1. The ramp
is smooth (smoothstep) between `startGap` (default 40: progress 0 at and beyond)
and `fullGap` (default 6: progress 1 at and inside).

**Hysteresis.** A pair that has merged holds on: its ramp moves outward by
`release` (default 14 points). The state flips to merged when the gap reaches
`fullGap` and back to apart when it passes `startGap + release` (54), and the two
curves agree at both flips, so progress is continuous there and a finger hovering
on a threshold cannot flicker: it merges once and lets go once. Measured: the
same 28-point gap is progress 0.29 for a pair that is approaching and 0.86 for a
pair that was merged and pulled out (captures below).

`GlassProximityMerge.Tracker` holds the merged state of every pair of a list of
panels and returns the clusters (connected groups) for each update. A cluster is
one `GlassBlob` (`blob(for:of:in:)`: up to six circles, capsules and rounded
rectangles, blend distance `blend` x progress, 56 points at 1, interior blend 72)
that the app puts in `GlassParameters.shape` of one panel, so a merged group has
one lens, one rim and one shadow with no seam. Nothing in the shader, the
renderer or the shape types changed. Two panels are connected only once the gap
between them is under the blob's blend distance (the distance at which a smooth
union starts to bend one shape toward the other), so a third panel that comes
into range joins from nothing, with no pop.

`Outline` is the shape vocabulary: `.circle`, `.capsule` and `.roundedRectangle`
(axis aligned), or `Outline.panel(frame:cornerRadius:)` to pick the exact one for
a frame. `gap(to:)` is exact for all of them (each is a convex core, a point, a
segment or a rectangle, grown by its radius, so the gap is the distance between
the cores less both radii). Rounded rectangles use the blob's existing
rounded-box primitive (GW-26), so **no shape-field or shader change was needed**;
`GlassSurfaceMerge` (GW-13's pose-to-pose merge of a stepper) still takes circles
and capsules only. The progress also drives that transition: `SurfaceTransition.scrub(to:)`
takes the same 0...1.

**Normalization rule.** A `NaN` or infinite gap, coordinate or parameter throws
`GlassProximityMergeError.nonFinite(_:)` naming the field (`gap`, `outline`,
`startGap`, `fullGap`, `release`, `blend`, `interiorBlend`); finite parameters
clamp (`startGap` 1...400, `fullGap` -100...`startGap` - 0.5, `release` 0...200,
`blend` and `interiorBlend` 0...400).

### Native content and hit testing

The surface takes no touches; the glass is decorative. In the lab each panel
carries a native `UIButton` at the panel's own spring frame (the app moves it from
`frameHandler`, so its frame and accessibility frame are the glass's frame in
every state), and a `UIPanGestureRecognizer` on the button carries the drag.
Policy: a panel's hit area is its own frame, apart or merged; the neck between
merged panels belongs to nobody (a tap there reaches whatever the app put
behind); a tap on a button works at every progress. Checked on the simulator with
real touches: a tap on the pill while it was merged with the round button counted
(`taps 1`); a tap in the neck counted nothing.

### Laboratory

`-lab.drag YES` (or the "Drag" button on the main screen) opens the page. Top: a
pill, a round button and a rounded square of GlassWeave's clean refined glass
(`RefinedLook.enhancedLens`, `GlassLighting.clean`, triangular dither) on the stage
(`-lab.dragBackdrop stage|orbs`), draggable with a finger, merging by proximity.
Bottom: the same three shapes as `UIGlassEffect` views in a
`UIGlassContainerEffect` (spacing 40), dragged the same way: **Apple's merge,
which is Apple's glass with Apple's glass; ours merges GlassWeave glass with
GlassWeave glass**, and the page says so. `-lab.drag.pin "pill:0.3:0.28;round:0.63:0.28;square:0.5:0.78"`
pins centers (fractions of the area) with no spring and no clock;
`-lab.drag.latched YES` shows a pinned frame as a pair that merged first would see
it; `-lab.drag.auto YES` brings the round button to the pill and pulls it away,
through the same code a finger uses. The status line shows each pair's gap,
progress and state, the spring and clock state, and `after settle +N`.

Captures (iPhone 18 Pro simulator):
[apart](evidence/captures/gw-32-drag-stage-apart-iphone18pro-sim.png),
[gap 16 beside Apple's container](evidence/captures/gw-32-drag-stage-merging-gap16-vs-native-iphone18pro-sim.png),
[gap 28 approaching](evidence/captures/gw-32-drag-stage-gap28-approaching-strip-iphone18pro-sim.png) and
[gap 28 after a merge (hysteresis)](evidence/captures/gw-32-drag-stage-gap28-latched-hysteresis-strip-iphone18pro-sim.png),
[three panels as one shape](evidence/captures/gw-32-drag-stage-three-merged-strip-iphone18pro-sim.png),
[orbs](evidence/captures/gw-32-drag-orbs-merging-gap16-strip-iphone18pro-sim.png),
[a real finger drag and pull, settled](evidence/captures/gw-32-drag-finger-pulled-settled-iphone18pro-sim.png)
(`spring idle | clock off | after settle +0`),
[Reduce Motion jump](evidence/captures/gw-32-drag-reduce-motion-jump-iphone18pro-sim.png)
(`spring idle | clock off`, 2 frames submitted) and
[merge then separate, settled](evidence/captures/gw-32-drag-auto-apart-settled-iphone18pro-sim.png)
(`panels 3`, 52 frames, `after settle +0`).

### Tuning record

Three rounds, by eye, against the system's container twin. Round 1: the neck
formed too late (it showed at a 16-point gap, where Apple's is already a peanut),
so the ramp widened (36/4/12 to 44/6/14) and the blend grew (44 to 68). Round 2: a
third panel 40 points from a merged pair was pulled 2 points by the group's one
blend distance, so a panel now joins a group only once it is closer than that
distance. Round 3: the three-panel blob read lumpy at blend 68; it is 56 (start
gap 40, interior 72), and the page opens on the stage, where the clear glass reads.

### Limits

- Apple's merge is the benchmark and its look is its own (a flat gray on the
  stage, pearly on the orbs); ours is the clearer, calmer material of the other
  pages. Same family by the neck shape and rim, not by the fill.
- One blend distance serves a whole group, so in a group of three the weaker pair
  shares the stronger pair's blend (a joined panel starts from nothing, but a
  weakly coupled one is bent as if it were close).
- Before the neck bridges, and after a pulled-out neck lets go, the two shapes
  lean toward each other for a few points (the polynomial smooth union's bend,
  about 25 to 45 points of gap for a merged pair). It is short, but at a still
  frame it reads as a teardrop; the capture "gap 28 after a merge" shows it.
- A round panel taller than the pill next to it (64 against 56 points) leaves a
  gentle swell along the merged edge; equal heights would not.
- Springs and merge were exercised on the iPhone 18 Pro simulator, by real touches
  for a drag and a tap and by the lab's scripted run; no device, no cost
  measurement. Retargeting without a jump rests on the spring's construction (one
  state of position and velocity, only the target changes); no run logged a
  velocity trace (fast pass: not tested).
- Apple's twin is dragged with a UIKit spring animation (`usingSpringWithDamping`),
  not the system's own follow; its container merge is whatever the system does.

## Tilt-driven light (GW-33)

> Experimental. `GlassMotionSource`, `GlassMotionSample`, `GlassInjectedMotionSource`,
> `GlassCoreMotionSource` and `GlassTiltLight` (all `GlassWeaveUIKit`) may change
> before a stable release.

The light of GlassWeave glass can follow the tilt of the device: the highlights on
the rim slide a few degrees the way a lamp's reflection does on a real piece of
glass in the hand. Only the light moves. No panel, bend or shape changes and nothing
is rebuilt: the helper makes one call, `GlassRenderer.setLightOffset(azimuth:elevation:)`
(GW-23), on the surface's existing renderer and asks for one frame. Apple's glass has
no such control; its light is the system's own.

### Parts

| Type | What it is |
|---|---|
| `GlassMotionSample` | One reading of gravity in the device frame (Core Motion's: x right, y up the screen, z out of it; units of g) with a timestamp. `init(rollDegrees:leanDegrees:timestamp:)` builds one from angles; `rollDegrees` and `leanDegrees` read them back. |
| `GlassMotionSource` | The protocol: `isAvailable`, `isRunning`, `sampleHandler`, `start()`, `stop()`. It delivers samples on the main thread, only while running. |
| `GlassCoreMotionSource` | The real one: `CMMotionManager` device motion, gravity only, 30 Hz by default (`updateInterval` clamped to 1/60...1/10 s), delivered on the main queue, between `start()` and `stop()`. iOS only (`#if canImport(CoreMotion) && os(iOS)`). Device motion needs no permission. |
| `GlassInjectedMotionSource` | The injectable one, for tests and the simulator: `send(_:)` hands a sample to the handler, only while running, and says whether it did; it counts starts, stops and deliveries. |
| `GlassTiltLight` | The helper that maps the samples to the light, filters them, applies them, and starts and stops the source. |

### The mapping

A fixed lamp in the room lights a screen from a direction that changes when the
screen turns. Gravity alone gives two angles: **roll** (how far the right edge is down,
`asin(gx)`) and **lean** (how far the screen is leaned back from upright, `atan2(-gz, -gy)`:
0 upright, 90 flat and face up).

- Azimuth offset `= -clamp(roll / fullTilt, -1, 1) * maximumAzimuth`. Right edge down
  swings the lamp toward the left of the screen (counter-clockwise; azimuth 0 is the top,
  as in the light model).
- Elevation offset `= clamp((lean - neutralLean) / fullTilt, -1, 1) * maximumElevation`. A
  flatter screen raises the lamp over it. A normal grip (lean 40) leaves the authored light.

`GlassTiltLight.Configuration` and its bounds (every field is normalized: a NaN or
infinite value throws `GlassTiltLightError.nonFiniteConfiguration(_:)` naming the field,
a finite one is clamped):

| Field | Default | Range |
|---|---|---|
| `maximumAzimuth` | 30 degrees (the tilt itself at full tilt) | 0...60 (`azimuthLimit`) |
| `maximumElevation` | 12 degrees | 0...30 (`elevationLimit`) |
| `fullTilt` | 30 degrees | 5...90 |
| `neutralLean` | 40 degrees | 0...90 |
| `timeConstant` | 0.25 s | 0.02...2 |

**Documented bounds.** Whatever the device does (and whatever nonsense a sample holds), the
azimuth offset stays within `maximumAzimuth` (never above 60) and the elevation offset within
`maximumElevation` (never above 30). The mapping is clamped, and the filter is a convex
combination of clamped values, so it cannot leave the range either. A NaN or infinite sample
component throws `GlassTiltLightError.nonFiniteSample(_:)` from `ingest(_:)` (a source's own
non-finite sample is ignored).

### Smoothing and frequency

The offsets go through an exponential low-pass filter with the configured time constant
(`blend = 1 - exp(-dt / timeConstant)` per sample, `dt` the step between timestamps, never more
than 0.25 s, 1/30 s for the first sample after a start): 95 percent of a new target in about 0.75
s by default. The filter starts from the authored light (0, 0), so the light glides in
instead of jumping to the first reading. The renderer is given the new offset only when it has
moved by `applyThreshold` (0.02 degrees) since the last time, so a device lying still applies
nothing and requests no frames: the light adds no clock and no steady draw, and a settled light
leaves the surface on demand.

### Lifetime and accessibility

The light starts the source only while it is needed: the surface is visible
(`GlassSurfaceView.isVisible`: in a window, not hidden, scene in the foreground) and no setting
pins the light. It stops it when the surface hides. It does this by wrapping the surface's
`visibilityHandler` and `accessibilitySettingsHandler` (the handlers that were there are still
called) and by registering for the Increase Contrast trait; an app that replaces a handler
afterwards calls `refresh()` from its own. `invalidate()` stops the source and gives the light
back; a deinitialized light stops its source too.

| Setting | Behavior |
|---|---|
| Reduce Motion | The light is **pinned** at the authored direction: the source stops, the offset returns to (0, 0) at once (no glide), and samples are ignored. A surface that starts under Reduce Motion never starts the source. |
| Reduce Transparency, Increase Contrast | The policy already removes the light terms the tilt moves (or draws them as an even hairline), so nothing visible would change: the same pin applies and the sensor does not run. |
| Quality tiers | Not affected: one frame per change, none at rest. |

### Laboratory

`-lab.tilt YES` (or the "Tilt" menu button) opens the page: a pill, a round button and the chrome
ring (`RefinedLook.chromeRing`) on one surface, and the same three shapes in `UIGlassEffect`
below, so the two can be compared on the same backdrop. The simulator has no motion hardware, so
**Roll** and **Lean** sliders play the device: a 30 Hz timer hands the light a sample built from
them through a `GlassInjectedMotionSource`, as the sensor would. The Core Motion segment is enabled
only where the hardware is (it reads "n/a" on the simulator). `-lab.tilt.roll <deg>` and
`-lab.tilt.lean <deg>` set the start (`m30` means -30: a launch argument cannot start with a minus
sign), `-lab.tiltBackdrop orbs|stage|paper` the backdrop, `-lab.reduceMotion YES` and
`-lab.increaseContrast YES` the pins. The status line shows the light offset, how many times it
was applied, free or pinned, whether the sensor runs, the clock, the frames submitted and how long
ago the last one was.

Captures (`docs/evidence/captures/gw-33-tilt-*`, iPhone 18 Pro simulator): roll -30, 0 and +30 on
the orbs, the stage and the paper desk; lean 10, 40 and 70; the page beside the `UIGlassEffect`
twin; Reduce Motion (a roll of -30 requested, light pinned at 0.0 and 0.0, `applied 0`, sensor off)
and Increase Contrast. At roll +30 the status read `light az -30.0 el +0.0 | applied 45 | clock
off`, and the last frame was 1.9 s old when the capture was taken: the light had settled and drew
nothing more.

### Tuning record

By eye on the orbs, the stage and the paper desk, beside the system glass. The amplitude started at
20 degrees of azimuth and was raised to 30 (the tilt itself at full tilt: the ring's highlights
moved too little to read at 20). The ring, whose prismatic bands and glints turn with the key
light, shows the movement clearly. The pill and the round button carry the shared refined look,
whose rim is a thin hairline that is a little brighter on the lit side; it shifts only slightly.
Three attempts to make them show it more: a stronger Fresnel and specular, and a lower, tighter
key, each changed nothing visible; a faint prismatic film showed the movement but turned the pill
into a soap-bubble ring, which the style direction rules out. All three were dropped: the pill and
the round button stay the shared look.

### Limits

- **Device only, not verified:** `GlassCoreMotionSource` is wired (device motion, gravity,
  30 Hz, main queue, started and stopped by visibility) but nothing ran it: the simulator has no
  motion hardware. Feel and battery cost on a device are open.
- Gravity alone cannot see a turn about the vertical axis of an upright phone, so the light does
  not follow that gesture; it follows roll and lean.
- The pill and the round button show only a faint shift of their rim; the chrome ring shows it
  clearly (see the tuning record).
- The renderer's light offset is one value per renderer, so every lit panel on a surface moves
  together, and the light owns that offset while it is attached (a page that also drags the light
  by hand would fight it).
- The light installs itself on two single-closure handlers of the surface (chained, not
  replaced), and an app that sets them again must call `refresh()`.
- The simulator slider's timer is the lab's, not the library's; the library's only source is Core
  Motion.
