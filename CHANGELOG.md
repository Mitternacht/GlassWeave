# Changelog

## Unreleased: v0.1 pre-alpha candidate

Not released and not tagged. Every API is experimental. No physical device
has been measured; see [the pre-alpha notes](docs/evidence/pre-alpha.md).

### Added

- Swift package (tools 6.2, Swift 6 language mode) with the `GlassWeave` core
  and `GlassWeaveUIKit` products for iOS/iPadOS 26, and core compilation and
  GPU tests on macOS 26 (GW-01).
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
- Results so far come from the iOS 27.2 Simulator and an Apple M5 Mac; no
  iOS 26 runtime was available.
- One source format (`bgra8Unorm_srgb`, opaque); no wide color, HDR,
  transparency, or video.
- Same-queue ordering only; no cross-queue or external producer.
- No macOS view; no SwiftUI adapter.
- The CI workflow has not run on GitHub.

### Not included in v0.1

Touch ripple, custom/custom merging, enhanced-native effects, a SwiftUI
adapter, external producer or texture interoperability, and a Metal 4 backend.
