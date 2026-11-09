# Decision: how the surface gets its drawable (GW-27 spike, input to GW-11)

Status: decided for GW-27 on 2026-11-09. Experimental; GW-11 may revisit.

## Question

`GlassSurfaceView` used to acquire its drawable on the main thread
(`MTKView.currentRenderPassDescriptor` calls `CAMetalLayer.nextDrawable()`),
which waits until a drawable is free or the layer's one-second timeout passes.
The proposal's preferred fix is a `CAMetalLayer` host driven by
`CAMetalDisplayLink`, whose update carries the drawable. Its fallback is a
render thread that calls `nextDrawable()`, which would make `FrameProducer`
`@Sendable` and off-main (a public API change).

## Spike (about 20 minutes)

A throwaway screen in the laboratory (iPhone 18 Pro simulator, iOS 27.2) and a
throwaway AppKit program (My Mac, macOS 27.2, Apple M3 Max, 120 Hz display)
each created a `CAMetalDisplayLink` on a `CAMetalLayer`, added it to the main
run loop, encoded a clear pass into the update's drawable and presented it with
`MTLCommandBuffer.present(_:)`. Neither program is in the repository; the
numbers are what they printed.

| Question | iOS 27.2 simulator | My Mac |
|---|---|---|
| Does the link deliver updates? | Yes: 45 updates in 1 s while running (callback interval min 15.5 / median 22.3 / max 33.4 ms; `targetPresentationTimestamp` delta min 16.7 / median 16.7 / max 33.3 ms; the simulator reports 60 fps) | Yes: 111 updates in 1 s (callback median 8.3 ms, target delta median 8.3 ms) |
| Is `present(_:)` accepted with the link's drawable? | Yes: 44 of 44 command buffers completed, no error | Yes: 111 of 111 completed, no error |
| Does pause stop updates? | Yes: 0 updates in 0.5 s | Yes: 0 updates in 0.5 s |
| Does resume give one update promptly? | Yes: resuming and pausing inside the first update gave exactly 1 update, after 0.4, 11.6 and 3.3 ms | Yes: exactly 1 update, after 8.4, 1.6 and 1.9 ms |
| Does the link follow its layer's display? | Not testable (one display); the link is created from the layer, which is the documented binding | Not testable (one display) |
| Is `nextDrawable()` allowed on the same layer? | **No.** The call raises `CAMetalLayerInvalidOperation`: "-nextDrawable should not be called when using CAMetalDisplayLink." It is an Objective-C exception, which Swift cannot catch: the app aborts. | Same API, not run |

Not measured: a 120 Hz iPhone, the effect of `CADisableMinimumFrameDurationOnPhone`
on a `CAMetalDisplayLink`, and what the link does when every drawable is
held (it cannot be provoked, see the last row).

## Decision

**Do not adopt `CAMetalDisplayLink` in this change. Take the drawable on a
background queue instead, and keep encoding and the producer on the main
thread.**

Why the link is not adopted now:

- The last row. A layer with a link attached cannot give a drawable to anyone
  else. `MTKView` itself, the package's synchronous test hook (`renderNow()`),
  the laboratory's drawable stress and any app code that asks the surface's
  layer for a drawable would crash instead of getting one. The surface's
  layer is reachable (`MTKView.layer`), so this is a trap for users of the
  hosted view, not only for tests.
- The signature test for this task needs to hold every drawable of the layer
  and watch the main thread. With a link attached that is impossible from
  outside, so the stall could not have been shown to fail first.
- Replacing `MTKView` by a bare layer host would also touch the shipped
  surface tests (`hostedMetalView` is an `MTKView` with `isPaused` and
  `enableSetNeedsDisplay`), which must keep passing unmodified.

What was built (the narrow form of the proposal's fallback):

- `DrawableAcquirer` (`GlassPresentationHost.swift`) calls `nextDrawable()` on
  a serial background queue and hands the drawable to the main actor. The
  surface starts an acquisition when a frame is pending, the surface is
  visible and below the in-flight bound, draws on the main thread when the
  drawable arrives, and releases a drawable it no longer wants. A timed-out
  wait is counted (`drawableTimeouts`) and retried after 100 ms.
- `FrameProducer` keeps its type and runs on the main thread. **No existing
  public API changes.** Added (experimental): `motionClass`,
  `beginInteraction()`, `endInteraction()`, `quality`, `qualityEnvironmentSource`
  and friends, `drawableTimeouts`, `GlassQuality`, `GlassMotionClass`,
  `GlassFrameRate`, `GlassQualityEnvironment`, `GlassQualityResolution`.
- Effect time still comes from the view's `UIUpdateLink` (`modelTime`); the
  `targetPresentationTimestamp` clock seam was not built.

## Open for GW-11

- A host that owns its layer exclusively (no `MTKView`, no other
  `nextDrawable()` caller) can use the link: the spike says the link, present,
  pause and resume all work. It would give effect time from
  `targetPresentationTimestamp` and remove the update link.
- Whether `presentsWithTransaction` is needed to keep native views and panels
  in step during a drag was not measured; the surface keeps the previous
  behavior (unsynchronized presentation). Recorded as open in `tasks/todo.md`.
- Device items: 120 Hz iPhone, the `CADisableMinimumFrameDurationOnPhone`
  effect, Instruments trace.
