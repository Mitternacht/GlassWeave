# Changelog

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
- No macOS view; no SwiftUI adapter.
- The CI workflow has not run on GitHub.

### Not included in v0.1

Touch ripple, custom/custom merging, enhanced-native effects, a SwiftUI
adapter, external producer or texture interoperability, and a Metal 4 backend.
