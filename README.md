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
- **Experimental glow** (after the v0.1 candidate, GW-17 and GW-18):
  `GlassGlow` colors a custom panel's edge in any color or an angular
  gradient, with an inner glow that fades to a see-through middle, a halo of
  light outside the shape, and a pulse that `GlassSurfaceView` animates only
  while it is visible and Reduce Motion is off; see
  [the glow design](docs/glow.md).
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
a touch-driven ripple (GW-12), merging of two custom surfaces (GW-13), one
enhanced-native effect (GW-14), a SwiftUI adapter (GW-15), and external
texture interoperability (GW-16). None of these is part of v0.1. The glow
work continues with animated interiors (GW-19), a colored glow around native
glass (GW-14, pulled forward), and a laboratory gallery (GW-20). See [the task list](tasks/todo.md).

## Modes

- **Native:** genuine Apple glass, configured through public API, with no
  GlassWeave Metal work.
- **Custom:** GlassWeave renders its own optical panel over a background
  texture the app produces and hands over explicitly. A transparent Metal
  view cannot read arbitrary UI behind it, and GlassWeave does not capture
  the screen.

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
