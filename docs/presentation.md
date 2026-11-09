# Presentation, pacing and quality tiers (GW-27)

Experimental. This note describes what `GlassSurfaceView` does to get a drawable,
how an app declares motion, and the quality tiers. The decision behind the
acquisition model is in [decisions/metal-backend.md](decisions/metal-backend.md).

## No main-thread drawable wait

`CAMetalLayer.nextDrawable()` blocks until a drawable is free or the layer's
one-second timeout passes. The surface used to call it on the main thread, so a
layer whose drawables were held elsewhere froze the UI for a second.

Now (`GlassPresentationHost.swift`, `GlassSurfaceView.swift`):

1. A request makes a frame pending (`FrameScheduler`, unchanged).
2. If the surface is in a window, visible, below the in-flight bound of 2, and
   the draw needs a drawable (a source or producer, a target with area), a
   serial background queue takes a drawable from the layer.
3. The main actor receives it and draws: producer, encoding, commit, as before,
   all on the main thread. A drawable of a stale size, or one that arrives when
   nothing can draw, is released and the pending frame asks again.
4. If the wait times out, `drawableTimeouts` counts it and the surface asks
   again after 100 ms, while the frame is pending and can draw.

Unchanged: on demand (no request, no draw), coalescing, visibility, the bound,
the defined skips that return before a drawable is requested. A surface that is
not in a window never draws by itself; the unit tests draw it with `renderNow()`,
which still asks the layer synchronously on the calling thread.

`.skipped(.drawableUnavailable)` is now reached only by that synchronous path.

### The proof

`PresentationUITests.testHeldDrawablesNeverStallTheMainThreadAndTheRequestDrawsOnRelease`
(lab UI test). The presentation screen (`-lab.presentation YES`) takes every
drawable of the surface's layer that the display does not show, from a
background thread, then requests a frame at once, while a main-actor heartbeat
(10 ms) records the worst lateness. The surface has to be on screen, and a
unit-test process has no scene, so it is a UI test.

- On the code before this change the run failed: `worstMs=1009.7 beats=200`
  against a limit of 50 (xcodebuild, iPhone 18 Pro simulator, iOS 27.2).
- After the change the same screen shows `worstMs` of 2 to 4 ms in every look
  (see Evidence in `tasks/todo.md` for the run).

The stall only appears if the request comes while the display still shows its
drawable: a request half a second after the hold found a free drawable on the
simulator, and after one timed-out wait the simulator's layer hands out further
drawables without waiting. That is why the lab's one action holds and requests
in the same turn, and why the test does not assert that no frame is drawn while
the drawables are held.

## Pacing

A surface takes no touches, so the app declares motion.

| Class | Range (Hz, min / preferred / max) | How |
|---|---|---|
| `.interaction` | 80 / 120 / 120 | `beginInteraction()` / `endInteraction()` (nest) |
| `.transition` | system default | `motionClass = .transition` |
| `.ambient` | 30 / 60 / 60 | the default `motionClass` |
| `.slow` | 15 / 30 / 30 | `motionClass = .slow` |

The range goes to the surface's one `UIUpdateLink`, which runs while the effect
clock runs or an interaction is open. During an interaction with nothing
animating the link only asks the display for the high rate; it requests no
frames, the app still does. `effectFrameRate` reports the range in force;
`activeMotionClass` the class.

The effect clock runs while a presented panel's `GlassParameters.isAnimated`
is true (a glow pulse, a moving interior, an animated inner light, or a
wobbling shape), the surface has a source or producer and is visible, and the
panel can change a pixel of the drawable. `isEffectClockPaused` (experimental)
holds it still, for showing one moment through the `timeOffset` fields.

An iPhone above 60 Hz needs the app's `CADisableMinimumFrameDurationOnPhone`
Info.plist key (documented for `CADisplayLink` and `CAAnimation`; its effect on
an update link is not measured). The laboratory sets it.

## Quality tiers

`GlassQuality` is `.full` (default), `.balanced` or `.minimal`: fixed reductions
the app chooses (`surface.quality`). There is no automatic governor, because a
loop that trades quality for refresh rate oscillates.

| | full | balanced | minimal |
|---|---|---|---|
| Effect clock rate | 60 Hz | 60 Hz | 30 Hz |
| Interaction rate | 120 Hz | 60 Hz | 60 Hz |
| Interior speed | as set | at most 1 | 0 (still frame; the clock stops for it) |

Environment (`GlassQualityResolution`): Low Power Mode caps the tier at
`.balanced`; a serious thermal state forces `.minimal`; critical forces
`.minimal` with no rate above 30 Hz. The environment never raises the tier. It
comes from `ProcessInfo` and its two notifications when the app sets
`qualityEnvironmentSource = .system`; the default is `.fixed(.nominal)`, so
nothing changes for an app that does not ask (and the shipped tests do not
depend on the machine's power state). `.fixed(...)` also serves tests and
previews. A
change that arrives during an interaction waits for `endInteraction()`.

The accessibility policy is applied after the tier: Reduce Transparency and
Increase Contrast draw their opaque body at every tier, Reduce Motion stills
what the tier left moving.

### Tier hooks (not implemented)

These do not exist yet and are not simulated; each gets its row when it lands.

| Feature | full | balanced | minimal |
|---|---|---|---|
| Dispersion | 6-tap | 3-tap | off |
| Frost | 1/2-res base, 2 levels | 1/4-res base, 1 level | one level, 1 tap |
| Lighting | environment + specular + finishes + bloom | Fresnel + specular | legacy |
| Light emitters | 4 | 2 | 1, no flow |
| Fill / interiors | 4 sheets, 16 bubbles | 2 sheets, 8 bubbles | flat fill, no bubbles |

## Laboratory

`-lab.presentation YES` opens the presentation screen: a surface with an
animated interior panel, a tier switcher, an environment switcher (nominal, low
power, serious, critical), an interaction toggle, and a report (quality,
effective tier, class, rate, drawable timeouts, heartbeat, frame counts).
Launch arguments for captures: `-lab.presentation.auto YES` (the stress without
a tester), `-lab.presentation.quality minimal|balanced|full`,
`-lab.presentation.environment lowpower|serious|critical`,
`-lab.presentation.interact YES`.

## Not done in this pass

Listed with reasons in `tasks/todo.md` (GW-27): the frame-rate-follows-class,
effect-time and per-tier readback tests and the Low Power Mode notification test
(fast pass: not tested), native/panel skew for `presentsWithTransaction`, and the
device items.
