# Changelog

## Unreleased: glass beyond native (experimental, GW-21 to GW-29, GW-12, GW-13, GW-15)

Requested by the user on 2026-11-09, on the branch `implement/glass-beyond`
(nothing merged into `main`, nothing tagged). Every API is experimental, every
new parameter is off by default and renders the previous shader's bytes when
off (frozen-shader readback tests), and the evidence is simulator and Mac
only. Design notes: [glass optics](docs/glass-optics.md),
[frost](docs/frost.md), [presentation](docs/presentation.md),
[studies](docs/studies.md), [interaction](docs/interaction.md),
[the SwiftUI adapter](docs/swiftui.md).

### Added

- Touch response (GW-12): `GlassTouch` (`GlassParameters.touch`, default
  `.none`, `.standard`), `GlassTouchPoint`, `GlassTouchState` (a pure function of
  the touch and the time), `GlassRenderer.setTouches(_:)` (up to two), a soft
  finger light, one travelling ring that moves the backdrop sample by at most
  `ripple x 8` points, and a rim gleam. `GlassTouchObserver` (a gesture
  recognizer that never recognizes, delays or cancels, so native controls keep
  their taps) and `GlassSurfaceView.beginTouch/moveTouch/endTouch/cancelTouch`.
  The effect clock stops when the touch settles. New records `GWTouchUniforms`
  (128 bytes) and `GWTouchPoint` (48), with size asserts in C and MSL.
- Merging two surfaces (GW-13): `GlassSurfaceMerge` (two surfaces, each a
  circle or capsule apart and merged; `blob(progress:)`), drawn as one blob
  panel through the GW-26 path so lens, light, frost, fill and shadow follow
  the merged outline; `GlassBlob.interiorSmoothness`, `GlassShape.Field.mergeProgress`,
  and `SurfaceTransition` (UIKit): an interruptible, reversible spring on the
  effect clock that settles to on-demand rendering and jumps under Reduce
  Motion. `GWShapeUniforms` keeps its 336 bytes (`depthSmoothness` takes the
  padding word).
- `GlassWeaveSwiftUI` (GW-15), a new optional library product: `GlassSurface`
  (a SwiftUI view over `GlassSurfaceView`), `GlassSurfaceConfiguration` and
  `GlassSurfaceContent`. Configuration updates reach the UIKit host without
  recreating the renderer; a new view identity builds a new one; the
  accessibility policy is the host's. It compiles to nothing on macOS. The
  core gained one read-only SPI (`@_spi(Census) GlassRendererCensus`) that
  the example and the test use to count renderers. The core and UIKit
  products do not import the adapter.
- Laboratory pages: Touch (`-lab.touch YES`), Merge (`-lab.merge YES`) and the
  SwiftUI example (`-lab.swiftui YES`), each with a menu button (see the
  README for the other arguments).

- `GlassLight` (`GlassParameters.light`): up to four emitters of colored
  light inside the glass (edge band, arc, orb, four corners), with piping,
  slow flow and drift, `.light` and `.paint` blends; the middle stays clear
  (GW-21). `GWGlassUniforms` grew append-only from 528 to 1776 bytes
  (GW-21 to GW-26), with size asserts in C, MSL and Swift.
- `GlassLens`: thick-lens profiles (rim, dome, ring), index of refraction,
  thickness, optional fold, chromatic dispersion with three or six taps, and
  up to two inlays, such as a dome button on a pill (GW-22).
- `GlassLighting`: one movable key light (`GlassRenderer.setLightOffset`),
  Fresnel, specular, studio reflections, chrome and prismatic finishes,
  bloom, a refined look and an enhanced look (`edgeDepth`, `banding`,
  `glints`) (GW-23, REFINE, ENHANCE-LOOK).
- `GlassFrost` (`GlassParameters.frost`): a blur pyramid with uniform,
  clear-center, clear-rim and vertical-ramp profiles, grain, saturation and
  a legibility scrim that guarantees a text contrast ratio (GW-24).
- `GlassGrounding`: drop, contact and inner shadows and a colored caustic
  (GW-25).
- `GlassShape` and `GlassBlob`: ellipses, superellipses and smooth blobs of
  up to six primitives with a loop-locked wobble; every effect follows the
  outline (GW-26).
- `GlassFill` and `GlassFillSlosh`: a luminous liquid or gel inside a glass
  vessel, curved and lit by the key light, with contour sheets, bubbles, a
  meniscus and a deterministic slosh; its own 784-byte record (GW-28).
- Presentation (GW-27): `GlassSurfaceView` takes its drawable on a
  background queue (a held drawable no longer stalls the main thread),
  `GlassMotionClass` with `beginInteraction()` and `endInteraction()`, and
  `GlassQuality` tiers with Low Power Mode and thermal downgrades through an
  injectable environment (default: no change).
- `NativeGlassView.Configuration.style` (`.regular`, `.clear`) maps to
  `UIGlassEffect.Style`.
- `GlassAccessibilityPolicy` rows for every new effect under Reduce
  Transparency, Increase Contrast and Reduce Motion.
- The laboratory: Apple vs GlassWeave, four material studies (Focus, Camera,
  Open Air, Amber), the material bench, light fields, thick lens, chrome and
  light, paper desk, shapes, liquid vessels, frosted glass, frost pyramid,
  native vs refined glass, and presentation pages, each with a launch
  argument (see the README).

### Changed

- `GlassSurfaceView` runs its effect clock while any presented panel is
  animated (`GlassParameters.isAnimated`: glow, interior, light, wobble,
  fill), and `isEffectClockPaused` holds it for pinned captures.
- GW-04 item 3 (the drawable stall) is closed by the GW-27 heartbeat test.
- The `EnhancedNativeGlassViewTests` check "The pulse resumes where it stopped" measures how long the pulse ran instead of assuming 0.3 s, so a busy main actor no longer fails it.

### Known issues

- `GlowGalleryUITests.testAccessibilityAuditPassesInLightAndDark` fails in the
  dark audit (the Energy orb header) on this simulator, identically on the
  shipped glow tip: the system appearance does not reach the app. Two more
  timing-sensitive package tests (`EnhancedNativeGlassViewTests` "A new corner
  configuration..." and `FrameLifecycleTests` "100 hide and show cycles...",
  a race in the test itself) fail now and then. `GlassRenderer` now builds 16 pipeline
  variants at creation (about 6 to 15 ms, 1 to 4 ms before); see HANDOFF.md.
- The touch response draws no ring on frost and fill panels (those pipeline
  variants carry no touch code), and the observer was never driven by a real
  finger. Merging was captured without frost, fill or touch on the merged panel.
- No physical device, no M5 cost run, no live VoiceOver pass; the acceptance
  items that need them or a test beyond the one safety test per task stay
  unchecked in `tasks/todo.md`.

## Unreleased: after the v0.1 candidate (experimental glow)

Requested by the user on 2026-11-09 and outside the v0.1 candidate's scope;
see [the glow design](docs/glow.md). Not released; simulator and Mac
evidence only.

### Added

- `GlassGlow`, a colored glow on a custom panel's edge: a rim band, an inner
  glow fading toward the middle, and an optional center fill, in one color or
  an angular gradient of up to four stops, lit from a chosen side; documented
  units, ranges, and normalization; `GlassParameters.glow`, default `.none`,
  which renders byte-identical output to the earlier shader (GW-17).
- `GlassAccessibilityPolicy` maps the glow: a thin crisp rim on the opaque
  body under Reduce Transparency, no inner glow or center fill under Increase
  Contrast; `GlassGlow.ColorStop(_:angle:traits:)` reads a stop from a
  `UIColor` (GW-17).
- The laboratory's `-lab.glow amber|aurora` launch argument (GW-17).
- A halo and a pulse for `GlassGlow` (GW-18): `haloRadius` and
  `haloIntensity` spill the glow colors outside the shape as light screened
  over the background, fading to exactly zero at the radius;
  `pulsePeriod` and `pulseDepth` modulate the rim, inner glow, and halo by
  `pulseLevel(at:)` at `GlassRenderer.effectTime` (`setEffectTime(_:)`).
  `GWGlassUniforms` grows to 256 bytes; glows without a halo render
  byte-identical output to the GW-17 shader.
- `GlassSurfaceView` runs an effect clock (`isAnimating`) only while a
  visible glow pulses, through its usual scheduler; `GlassAccessibilityPolicy`
  removes the halo and pulse under Reduce Transparency, keeps them under
  Increase Contrast, and holds the glow at the pulse's mean level under
  Reduce Motion (GW-18).
- The laboratory's `-lab.glow ember|energy` presets with a Pulse switch, and
  a glow mode in the Mac characterization (GW-18).
- `GlassInterior` (`GlassParameters.interior`, default `.none`): an animated
  energy, rays, or embers pattern inside a custom panel's outline, in a ramp
  of one to three colors, with intensity, speed, a seed, and a center fade
  that keeps the middle exactly see-through; deterministic for a seed and
  time, repeating every 64 s of interior time, screened over the glass as
  light; embers' sparks may rise into the glow's halo. `GWGlassUniforms`
  grows to 528 bytes; panels without an interior render byte-identical
  output to the GW-18 shader (GW-19).
- `GlassSurfaceView` runs its effect clock while a visible interior moves;
  `GlassAccessibilityPolicy` removes interiors under Reduce Transparency and
  Increase Contrast and shows the still frame under Reduce Motion;
  `GlassInterior.Color(_:traits:)` reads a `UIColor` (GW-19).
- The laboratory's `-lab.interior energy|rays|embers` with an Interior
  motion switch, and interior modes in the Mac characterization (GW-19).
- `EnhancedNativeGlassView` (GW-14, pulled forward with the glow work): a
  `GlassGlow`'s rim and halo, and its pulse, drawn with Core Animation around
  a genuine `NativeGlassView`, whose material stays Apple's; the laboratory's
  `-lab.nativeGlow <preset>` with a Native glow switch. (Added to this list
  with GW-20; it was missing.)
- Several panels in one pass (GW-20): `GlassRenderer.setPanels(_:)`,
  `panels`, and `maximumPanelCount` (8) draw an ordered list of panels over
  one frame, each as its own quad (where quads overlap, the later panel
  wins); `setPanel(_:)` is the one-panel case and renders the same bytes.
  `GlassSurfaceView.setPanels(_:)`, `panels`, and `presentedPanels` apply the
  accessibility policy to each panel and run the effect clock while any
  presented panel animates.
- The laboratory's glow gallery (GW-20), from its Glow gallery button or
  `-lab.gallery YES`: a light/dark switch with a glass knob, three element
  capsules with their own edge colors and interiors (and a check under the
  selected one, which shows the selection without the glow), an energy orb, and
  native glass with a colored rim, drawn by one surface in one pass under
  native controls, submitting no frames at rest.

## Unreleased: v0.1 pre-alpha candidate

Not released and not tagged. Every API is experimental. No physical device
has been measured; see [the pre-alpha notes](docs/evidence/pre-alpha.md).

### Added

- Swift package (tools 6.2, Swift 6 language mode) with the `GlassWeave` core
  and `GlassWeaveUIKit` products. Declared floors: iOS/iPadOS 26 and macOS 26,
  neither of which has been run; tests ran on the iOS 27.2 simulator and on
  macOS 27.2, where the core is compiled and GPU-tested (GW-01).
- `RenderCapabilities`, a runtime survey of the rendering `MTLDevice`'s GPU
  families, kept separate from the OS deployment floor (GW-01).
- The UIKit laboratory app, `GlassWeaveLab`, consuming the package through a
  local reference, in a combined workspace (GW-02).
- Native mode: `NativeGlassView`, a `UIVisualEffectView` with a public
  `UIGlassEffect` (tint, interaction), creating no GlassWeave renderer (GW-03).
- The explicit background-source contract: `BackgroundFrame`,
  `BackgroundFrameLease`, `BackgroundFrameRelease`, `SourceUVTransform`
  mapping, `BackgroundSourceError`, defined skips, and `BackgroundRenderer`;
  `GlassSurfaceView`, an `MTKView` host sized from its own bounds and display
  scale; a shared C layout target for GPU records (GW-04).
- One rounded refractive panel: `GlassRenderer`, `GlassPanel`,
  `GlassParameters`, `GlassTint`, with documented units, ranges, and
  normalization (GW-05).
- Frames produced inside the draw's own command buffer
  (`GlassRenderer.drawProducing`, `GlassSurfaceView.setFrameProducer`), so
  the background and the refraction show the same frame (GW-06).
- On-demand, per-scene, bounded rendering: at most two frames in flight,
  coalesced requests, visibility per host and window scene,
  `FrameStatistics`, and `FrameTexturePool` (GW-07).
- Accessibility: a decorative surface hidden from assistive technologies,
  `GlassAccessibilityPolicy` (opaque surface under Reduce Transparency; Reduce
  Motion reported to the app), and the tinted-glass legibility rule
  (`GlassTint.worstCaseContrast`, `minimumStrength`) (GW-08).
- `RenderMetrics`, opt-in per-renderer measurement of CPU encode, producer,
  and drawable-acquisition time, GPU start/end per command buffer, counts, and
  allocated bytes; the laboratory's benchmark scenario
  (`-lab.benchmark baseline|native|custom|idle|lifecycle`); and an offscreen
  characterization test with a Release scheme (GW-09).
- A DocC catalog whose examples are compiled and run by the tests, a support
  matrix, and these notes (GW-10).

### Known limitations

- No physical iPhone or iPad has been measured; no device is qualified and
  every performance budget is unmeasured on hardware.
- Results so far come from the iOS 27.2 Simulator and an Apple M5 Mac on
  macOS 27.2; no iOS 26 runtime was available and macOS 26 was not run.
- iPad presentation is not claimed: only the iPad Pro 13-inch (M5) simulator
  ran, in full-screen apps mode, and no physical iPad.
- `GlassSurfaceView` acquires drawables on the main thread, which can wait
  for a free drawable (normally at most about one display refresh, up to one
  second when none is free).
- One source format (`bgra8Unorm_srgb`, opaque); no wide color, HDR,
  transparency, or video.
- Same-queue ordering only; no cross-queue or external producer.
- No macOS view; no SwiftUI adapter (in the v0.1 candidate; the experimental adapter is a later addition, above).
- The CI workflow has not run on GitHub.

### Not included in v0.1

Touch ripple, custom/custom merging, enhanced-native effects, a SwiftUI
adapter, external producer or texture interoperability, and a Metal 4 backend.
(Later, experimental and unreleased: enhanced-native effects, the touch
ripple, custom/custom merging and the SwiftUI adapter exist on the glow and
glass-beyond branches, described above.)
