# GlassWeave

An Apple-native glass framework for custom optical surfaces and native interaction.

GlassWeave puts one custom refractive glass panel into a UIKit app, beside
Apple's own Liquid Glass, over a background the app owns, while text,
controls, gestures, and accessibility stay native.

## Status

**Pre-alpha: a v0.1 candidate, not released.** There is no version tag and no
release. Every API is experimental and may change. Nothing has been measured
on a physical iPhone or iPad yet, so no device is qualified and no
performance budget is met or failed; see
[the Milestone 1 report](docs/evidence/milestone-1.md) and
[the pre-alpha notes](docs/evidence/pre-alpha.md).

### What exists

- **`GlassWeave`** (core, iOS 26 and macOS 26): the explicit background-source
  contract (`BackgroundFrame`, `BackgroundFrameLease`), the background
  renderer, `GlassRenderer` with one rounded refractive panel
  (`GlassPanel`, `GlassParameters`, `GlassTint`), a bounded producer texture
  pool (`FrameTexturePool`), the text legibility rule for tinted glass,
  `FrameStatistics`, `RenderCapabilities`, and opt-in `RenderMetrics`. Swift
  and Metal Shading Language; no UIKit or SwiftUI.
- **`GlassWeaveUIKit`** (iOS): `NativeGlassView` (native mode: a public
  `UIGlassEffect`, no GlassWeave renderer) and `GlassSurfaceView` (custom mode:
  an `MTKView` host that draws on demand, per window scene, with at most two
  frames in flight, hidden from assistive technologies, opaque under Reduce
  Transparency), plus `GlassAccessibilityPolicy`.
- **Experimental glow** (after the v0.1 candidate, GW-17 to GW-19):
  `GlassGlow` colors a custom panel's edge in any color or an angular
  gradient, with an inner glow that fades to a see-through middle, a halo of
  light outside the shape, and a pulse; `GlassInterior` adds animated
  energy, rays, or embers inside the shape, fading to a see-through middle.
  `GlassSurfaceView` animates them only while they are visible and Reduce
  Motion is off; see [the glow design](docs/glow.md).
- **The laboratory** (`Examples/GlassWeaveLab`): a UIKit app with the native
  reference beside the custom panel over a deterministic moving background,
  lifecycle and accessibility controls, and the GW-09 benchmark scenario
  (`-lab.benchmark <mode>`).
- **Tests**: Swift Testing for contracts, GPU render-and-readback,
  lifecycle, accessibility policy, metrics, and the documentation examples;
  XCUITest for the laboratory; an offscreen characterization of the fixed
  workload. CI is written (`.github/workflows/build.yml`) but has not run on
  GitHub yet.
- **Documentation**: a DocC catalog (`Sources/GlassWeave/GlassWeave.docc`)
  whose examples are compiled and run by the tests, the
  [architecture](docs/architecture.md), the
  [validation protocol](docs/validation.md), and the
  [support matrix](docs/support.md).

### What is planned, not built

Physical-device qualification (GW-09), a Metal 4 backend experiment (GW-11),
a touch-driven ripple (GW-12), merging of two custom surfaces (GW-13), a
SwiftUI adapter (GW-15), and external texture interoperability (GW-16). None
of these is part of v0.1. The glow work (experimental, after v0.1) is
described below. See [the task list](tasks/todo.md).

## Glow (experimental)

Added after the v0.1 candidate at the user's request: glass whose edges take
a tint and a glow in any color while the middle stays see-through or fades.
Every API here is experimental, and nothing has been measured on a physical
device.

What works (simulator and Mac evidence):

- **Custom panels** (`GlassGlow`, `GlassInterior` on `GlassParameters`): a
  rim, an inner glow that fades toward an exactly see-through middle, an
  optional center fill, a halo outside the shape, and a pulse, in one sRGB
  color or an angular gradient of up to four, blended in linear light; and
  animated energy, rays, or embers inside, fading toward the middle.
- **Several shapes in one pass**: `GlassRenderer.setPanels(_:)` and
  `GlassSurfaceView.setPanels(_:)` draw up to eight panels over one frame.
- **Native glass** (`EnhancedNativeGlassView`): the same rim and halo around
  genuine `UIGlassEffect` glass, whose material stays Apple's; they move with
  interactive glass as it grows under a press.
- **On demand and accessible**: animation runs only while something moves
  and the surface is visible; Reduce Motion, Reduce Transparency, and
  Increase Contrast follow a documented mapping.
- **The laboratory's glow gallery**: a light/dark switch with a glass knob,
  three element capsules, an energy orb, and native glass for comparison,
  all with native controls (`-lab.gallery YES`).

Not measured: device GPU cost, display appearance, frame pacing, and energy
on any iPhone or iPad; live VoiceOver; the cost of several panels in one
pass. The clean-consumer check still pins the v0.1 candidate and covers no
glow. See [the glow design](docs/glow.md) and the evidence in
[the task list](tasks/todo.md#glow-effects-user-requested-2026-11-09).

## Modes

- **Native:** genuine Apple glass, configured through public API, with no
  GlassWeave Metal work.
- **Custom:** GlassWeave renders its own optical panel over a background
  texture the app produces and hands over explicitly. A transparent Metal
  view cannot read arbitrary UI behind it, and GlassWeave does not capture
  the screen.
- **Enhanced-native (experimental, GW-14):** genuine Apple glass with a
  colored rim and halo that Core Animation layers draw around it
  (`EnhancedNativeGlassView`); no GlassWeave Metal work, and the glass keeps
  its own material.

The two are separate materials: GlassWeave does not merge its panel optically
with Apple's glass.

## Using the candidate

Add the package by its repository URL. With no tag yet, depend on a specific
revision and expect breaking changes:

```swift
.package(url: "<this repository's URL>", revision: "<commit>")
```

Then depend on the `GlassWeave` product (core) and, for the views,
`GlassWeaveUIKit`. Build with Xcode: SwiftPM's command-line `swift build`
cannot compile the package's Metal shaders. Start with the DocC catalog's
overview and the laboratory.

| Requirement | Value |
| --- | --- |
| Deployment floor | iOS/iPadOS 26, macOS 26 (core only) |
| Toolchain used | Xcode 27.2, Swift 6.4.2, Swift 6 language mode, tools version 6.2 |
| Background source | One format in v0.1: `bgra8Unorm_srgb`, opaque, on the renderer's device and queue |
| Dependencies | None |

## Documentation

- [Support matrix](docs/support.md)
- [Architecture](docs/architecture.md)
- [Validation protocol](docs/validation.md) and
  [Milestone 1 report](docs/evidence/milestone-1.md)
- [Pre-alpha notes](docs/evidence/pre-alpha.md) and [changelog](CHANGELOG.md)
- [Language strategy](docs/language-strategy.md)
- [Implementation plan](tasks/plan.md) and [tasks](tasks/todo.md)
- [Laboratory guide](Examples/README.md)
- [Contributing](CONTRIBUTING.md) and [agent handoff](HANDOFF.md)

## Companion project

[Frostfield](https://github.com/Mitternacht/Frostfield) is the companion creative graphics
framework. GlassWeave has no Frostfield dependency and must remain usable
without a scene engine. A shared low-level Metal product is a later option, subject to
measurements and demonstrated common requirements.

## License

[MIT](LICENSE).
