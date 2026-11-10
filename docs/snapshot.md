# Snapshot source: bend and frost static real UI (GW-31)

Experimental. `UIKitSnapshotSource` (`Sources/GlassWeaveUIKit/UIKitSnapshotSource.swift`) captures a
region of a UIKit view hierarchy into an ordinary source frame, so the custom glass can refract and
frost real, **static** UI. Custom glass can only read pixels it is given; it cannot read what UIKit
draws behind it. A snapshot is the opt-in answer for content that holds still (a list, a card, a
screen at rest). It is a copy taken on demand, not a live view.

```swift
let source = try UIKitSnapshotSource(renderer: surface.renderer)
try source.refresh(surface, from: tableView)        // once, after scrolling ends
```

## The contract

| Row | Value |
| --- | --- |
| Region | A rectangle in the captured view's own coordinate space (what `UIView.convert(_:from:)` returns), in points. `refresh` defaults to the surface's bounds converted into the view: the part of the view the surface covers. A region partly outside the view shows the backdrop color there. A scroll view's `bounds.origin` (its content offset) is honored. |
| Size and scale | `round(region x scale)` pixels, at least 1. The scale defaults to the view's `displayScale`, is clamped to 0.25...8, and is lowered further so the texture holds at most `Configuration.maximumPixelCount` pixels (4,194,304 by default) and 8192 in either dimension (`Report.wasScaledDown`). The two axes round separately and the content is scaled to fill the texture exactly. |
| Orientation | Upright: texture row 0 is the top of the region, column 0 its left edge, `SourceOrientation.up`. The valid rectangle is the whole texture. The draw flips UIKit's top-left origin into the buffer, so no transform is left for the renderer. |
| Mapping | The surface aspect-fills the source like any source. Give the surface the size of the region, point for point, and the snapshot lies under the glass pixel for pixel; a different aspect crops. |
| Color and alpha | `BackgroundColorConvention.sRGBOpaque`: `bgra8Unorm_srgb`, sRGB-encoded, opaque. Content is converted to sRGB (a wide-gamut color clips) and composited over the opaque `Configuration.backdrop` (the system background of the view's traits by default, alpha ignored), so no pixel is transparent and the alpha byte is 255. |
| Device and queue | The renderer's device. The upload is a blit committed to the renderer's own queue before the frame is handed over, `BackgroundFrameReadiness.committed(on:)`. Nothing waits for it. |
| Frame identity | IDs increase by one per capture, starting after the renderer's current frame; timestamps are the time since the source was made, on top of the renderer's current frame's timestamp, so they never go backwards. Use one source per renderer. |
| Ownership | Textures come from a `FrameTexturePool` (3 by default, 2 to 6). A texture returns to the pool only when GlassWeave releases the frame, after the last GPU use, so a capture never writes into a texture the GPU can still read. When every texture is in use a capture throws `UIKitSnapshotError.noFreeTexture`: it does not wait and does not allocate past the pool. `refresh` ends the producer's hold (`retire()`) as soon as the surface has the frame; `capture` hands the caller the lease and the caller retires it. |
| Normalization | A non-finite region number, scale or budget is rejected with `UIKitSnapshotError.nonFinite` naming the field (`regionX`, `regionY`, `regionWidth`, `regionHeight`, `scale`, `budgetMilliseconds`). Finite values are clamped (the scale and the configuration counts); a rectangle with a negative size is standardized; no area is `emptyRegion`. |

## How it renders

`UIKitSnapshotSource.capture` makes a `CGContext` (sRGB, 8-bit BGRA, premultiplied first with 32-bit
little-endian byte order) over the memory of one shared `MTLBuffer`, fills it with the opaque
backdrop, flips the origin to UIKit's, makes the context UIKit's current context, and draws the view
into it with one of two techniques:

- `.drawHierarchy` (`UIView.drawHierarchy(in:afterScreenUpdates:)`): what the view shows on screen:
  the presentation state, blurs and visual effects, system controls. The view must be in a window.
  `afterScreenUpdates: true` commits pending changes first (the lab's scroll-end refresh uses it).
- `.layerRender` (`CALayer.render(in:)`): the layer tree. It needs no window, ignores running
  animations, and leaves out what a layer tree cannot draw (visual effect views, Metal layers, video).
  The unit test uses it.
- `.automatic` (the default) uses `.drawHierarchy` when the view is in a window and falls back to
  `.layerRender` when that cannot draw; `Report.technique` says which ran.

One blit then moves the buffer into the pooled private texture and the command buffer is committed.
The buffer is retained by the command buffer and freed when the copy completes (one allocation of the
texture's size per refresh; a refresh is on demand, so this is not a steady-state path).

Capture a view that does **not** contain the glass surface, or the glass would refract itself. The
lab captures the list, a sibling under the surface.

## Cost and the stated bound

A refresh runs on the main thread in one synchronous pass (the draw, then one blit encoded and
committed). It never waits for the GPU. It is for use on demand, for example once when scrolling
ends, never per frame.

**Bound.** `Configuration.budgetMilliseconds`, 33 ms by default (two frames at 60 Hz). The library
cannot interrupt a draw once `drawHierarchy` has started, so it does not enforce the bound by
cutting the draw short: every refresh returns its measured time (`Report.drawMilliseconds`,
`uploadMilliseconds`, `totalMilliseconds`) and `Report.exceededBudget` says it ran over. A capture
that is slow says so and is not hidden. The pixel limit (`maximumPixelCount`, `wasScaledDown`)
bounds the texture's memory, not the time.

Measured on the iPhone 18 Pro simulator (a macOS-hosted simulator on this Mac: the numbers are
the simulator's, not a device's), the lab's "Over real UI" page, `-lab.snapshot.measure 40` (40
refreshes of each size, medians with p95 and max, committed capture
`gw-31-snapshot-measure-iphone18pro-sim.png`):

| Captured | Pixels | Median | p95 | Max |
| --- | --- | --- | --- | --- |
| The bar's region of the list view | 1014 x 180 | 9.5 ms | 12.7 ms | 13.2 ms |
| The whole list view (370 x 209 pt) | 1110 x 627 | 19.0 ms | 21.6 ms | 23.1 ms |
| The whole page (a full screen) | 1206 x 2622 | 40.6 ms | 44.2 ms | 45.7 ms |

The first capture in a process costs more than the later ones (24 to 44 ms for the bar's region,
the warm-up of the render server's first snapshot). The upload is 0.0 to 0.4 ms of each figure. So on
the simulator a list-sized refresh stays well inside two frames; a full-screen refresh does not (about
2.5 frames) and reports `exceededBudget`. The draw grows roughly with the pixels drawn. Main-thread
time on a device was not measured (no device in this run); an app that needs the bound there should
measure its own view with `Report` and capture a view as small as the glass needs.

## Refresh policy

The source refreshes on demand only: `refresh` and `capture` are the only calls that draw. The lab
refreshes when scrolling ends (`scrollViewDidEndDecelerating`, `didEndDragging(willDecelerate: false)`,
`scrollViewDidEndScrollingAnimation`), when the page's appearance changes, on a resize, and from a
button. Until the next refresh the texture shows the view as it was. When a scroll view moves, the
snapshot under the glass is stale; the page's honest answer is to fade the glass out while the list
moves and back in with the new snapshot (an app that prefers a stale image keeps showing it; a
Reduce Motion setting makes the fade a cut).

The renderer is never recreated: a refresh is `GlassSurfaceView.setSource` with the next frame on the
same renderer. The frost pyramid is keyed by frame, so one refresh rebuilds it once and unchanged
frames reuse it (`docs/frost.md`).

## Accessibility and privacy

- The snapshot is decorative. The live views remain the accessibility elements and receive every
  touch; the surface takes none. Nothing in the snapshot is announced.
- Reduce Transparency: the surface's own policy presents an opaque panel and suppresses the frost
  whatever the source (`gw-31-snapshot-reduce-transparency-iphone18pro-sim.png`).
- Increase Contrast: the surface's own policy; the source has nothing to follow.
- Reduce Motion: the source has no motion. The lab page's fade of the bar is a cut.
- Privacy: a snapshot is a pixel copy of what the view draws. It lives in GPU memory only, is never
  written to disk or sent, and `trim()` (called when the surface becomes hidden) releases the free
  textures. What `drawHierarchy` draws for a protected view is whatever UIKit draws for it.

## The lab page: "Over real UI"

`-lab.snapshot YES` (or the "Over real UI" menu button; `SnapshotBenchViewController.swift`). A native
`UITableView` of colored rows with text and symbols; over it a capsule of GlassWeave glass, a surface the
size of the capsule, clipped to it, showing the snapshot of the list region under it, bent at the rim
(`RefinedLook.enhancedLens`) and frosted (`GlassFrost`, uniform, sigma 8 points, no grain). Below it, the
same rows under a real `UIGlassEffect` capsule (live). Honest labels say so on the page: ours is a
static snapshot refreshed when scrolling ends and fades while the list moves; Apple's is live. The lower
list mirrors the upper one's offset.

Launch arguments: `-lab.snapshot.offset <pt>`, `-lab.snapshot.scrollTo <pt>` (an animated scroll
after a second: the refresh at its end), `-lab.snapshot.hold <pt>` (moves the list without ending the
scroll, for the stale state), `-lab.snapshot.frost 0|1`, `-lab.snapshot.dark YES|NO`,
`-lab.snapshot.sigma <pt>`, `-lab.snapshot.measure <n>`.

### Look, and what the zoomed comparison showed

Captures (iPhone 18 Pro simulator) in `docs/evidence/captures/gw-31-snapshot-*`, inspected at zoom beside
the `UIGlassEffect` twin. Three tuning rounds, all on this page:

1. **Presence echoes text.** The refined and enhanced lighting's `presence` picks up the backdrop's
   color with a few soft taps around each pixel. Over a smooth backdrop that is a gentle color; over
   real text it drew faint, repeated, pale copies of the lettering inside the glass (found by turning the
   lighting off, then presence alone). The page turns `presence` off: the snapshot already is the
   backdrop and the frost its blurred color. The body is then a smooth blur with no echoes.
2. **Frost.** Sigma 3 to 10 points looked alike at first because the echoes dominated; with presence
   off, sigma 8 is a calm frost in which text is gone and colors stay. The lens at the rim bends
   the icon at the left end by a few points (`gw-31-snapshot-clear-bend-zoom-*` shows the clear glass:
   the wave icon curves at the rim, the text inside is untouched), the bend is faint and blends into the
   flat middle.
3. **Dark tint.** A first dark page used `isDark` from the view controller's own traits, which does not
   follow the view's appearance override, so a light tint (white, 30 percent) veiled a dark page in
   gray: fixed by reading the view's traits. Two attempts to lift dark glass further (a mid-gray veil, a
   stronger saturation grade) made it muddy gray or an over-saturated gel and were dropped.

The result sits in the same family as the twin: a clear, even, lightly frosted capsule with one thin
rim and pooled color from the row below. Differences left: Apple's glass keeps faint blurred shapes
of the text behind it and a lifted body on dark pages; ours is calmer (no residual text) and a little
darker on dark pages; a white symbol under the rim leaves a pale blurred smudge at the capsule's end
(Apple's is dimmer); ours draws a hairline gray rim on light pages where Apple's is a faint green-white
line.

## Limits

- **Static.** The glass shows the snapshot until the next refresh. While a list moves the glass is
  stale and the lab fades it out. Live content needs the overlay mode (GW-30), which cannot bend.
- **One region per surface at the surface's size.** The surface aspect-fills the snapshot; a region of
  another aspect crops. The lab sizes the surface to the region.
- **No content outside the layer tree with `.layerRender`;** `drawHierarchy` needs a window.
- **The cost is on the main thread** and is not bounded by the library: see the table. Captures are on
  demand, never per frame.
- **Simulator only.** No device, no iOS 26 run, no HDR or wide color (clipped to sRGB), no video or
  Metal layers under `.layerRender`.
