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
- **Experimental glass beyond native** (GW-21 to GW-29, branch
  `implement/glass-beyond`): light fields, a thick lens with dispersion, one
  light with chrome and prismatic finishes, frost, shadows, freeform shapes,
  a liquid fill, presentation tiers, four studies and an Apple vs GlassWeave
  screen; see [Glass beyond native](#glass-beyond-native-experimental-unreleased).
- **Experimental interaction and SwiftUI** (GW-12, GW-13, GW-15): a touch
  response (finger light, one travelling ring, a rim gleam), two custom
  surfaces that merge into one pill under a spring, and an optional
  `GlassWeaveSwiftUI` product with a `GlassSurface` view; see
  [interaction](docs/interaction.md) and [the SwiftUI adapter](docs/swiftui.md).
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

Physical-device qualification (GW-09) and external texture interoperability
(GW-16). Neither is part of v0.1. The glow work, the glass-beyond work, the touch
response (GW-12), merging of two custom surfaces (GW-13), the SwiftUI adapter
(GW-15) and the Metal 4 submission experiment (GW-11) are experimental and built
after v0.1; they are described below. GW-11 is built and decided: on My Mac
Metal 4 was no faster than conventional Metal on the same workload, so the
conventional path is the only shipped backend and the Metal 4 code is a
characterization arm that no host reaches
([the record](docs/decisions/metal-backend.md#decision)); no device was
measured. See [the task list](tasks/todo.md).

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
  animated energy, rays, or embers inside, fading toward the middle. The
  halo is light screened over the background: it glows on dark and
  mid-tone backgrounds, washes toward white over bright colors, and does
  not show over white or near-white ones (the gallery's knob halo is
  invisible on its light page). No halo mode for light interfaces exists yet.
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

## Glass beyond native (experimental, unreleased)

Built after the glow work, on the branch `implement/glass-beyond` (GW-21 to
GW-29, then GW-12, GW-13 and GW-15; nothing is merged into `main`, nothing is tagged or released). The aim:
glass in the same family as Apple's Liquid Glass (a mostly clear body, one
light, a thin rim, calm shadows), with things native glass cannot show.
Every new parameter is off by default, and a panel that does not use one
renders exactly what it rendered before; frozen-shader readback tests check
that. Every API below is experimental. Evidence is simulator and My Mac only:
no physical device, no M5 cost run, no live VoiceOver pass.

| Capability | API | Design note |
| --- | --- | --- |
| Colored light inside the glass: pooled along an edge or arc, an orb, or four corners; it flows slowly and the middle stays clear (GW-21) | `GlassLight` | [glass-optics](docs/glass-optics.md) |
| Thick lens: rim, dome and ring profiles, index of refraction, thickness, dispersion with three or six taps, an inlaid dome button (GW-22) | `GlassLens` | [glass-optics](docs/glass-optics.md) |
| One light: Fresnel outline, specular, studio reflections, chrome and prismatic finishes, bloom; a refined look and an enhanced look (slab depth, polished bands, glints) (GW-23) | `GlassLighting` | [glass-optics](docs/glass-optics.md) |
| Depth on light pages: drop, contact and inner shadows, a colored caustic (GW-25) | `GlassGrounding` | [glass-optics](docs/glass-optics.md) |
| Ellipses, squircles and smooth blobs that every effect follows (GW-26) | `GlassShape`, `GlassBlob` | [glass-optics](docs/glass-optics.md) |
| Frost: variable blur with a clear center or a clear rim, grain, and a legibility scrim (GW-24) | `GlassFrost` | [frost](docs/frost.md) |
| A luminous liquid or gel in a glass vessel, with a surface that sloshes (GW-28) | `GlassFill`, `GlassFillSlosh` | [glass-optics](docs/glass-optics.md) |
| Drawables taken off the main thread, interaction frame rates, quality tiers (GW-27) | `GlassMotionClass`, `GlassQuality`, `GlassSurfaceView.beginInteraction()` | [presentation](docs/presentation.md) |
| Native glass in the `.clear` style for comparison (GW-29) | `NativeGlassView.Configuration.style` | [studies](docs/studies.md) |
| Touch response: a soft finger light, one travelling ring that bends the backdrop by at most `ripple x 8` points, a rim gleam; an observer that never takes the touch from native controls (GW-12) | `GlassTouch` (`GlassParameters.touch`), `GlassTouchObserver`, `GlassSurfaceView.beginTouch(id:at:)` | [interaction](docs/interaction.md) |
| Two custom surfaces that merge into one pill and separate again, drawn as one panel so every effect follows the outline; an interruptible spring on the effect clock (GW-13) | `GlassSurfaceMerge`, `SurfaceTransition` | [interaction](docs/interaction.md#merging-two-surfaces-gw-13), [glass-optics](docs/glass-optics.md) |
| Bends that blend: a smooth window and a soft ceiling on the lens offset, so refraction fades in from the rim with no start line, kink or smear; a calmer touch response; a restrained surface finish for the liquid (POLISH) | `GlassLens.softness`, `GlassFill.richness`, the touch defaults | [glass-optics](docs/glass-optics.md#polish-subtle-blended-bends-a-calm-touch-the-chrome-ring-and-the-liquid-finish-polish) |
| A SwiftUI view over the UIKit host, in an optional product (GW-15) | `GlassSurface`, `GlassSurfaceConfiguration`, `GlassSurfaceContent` (product `GlassWeaveSwiftUI`) | [swiftui](docs/swiftui.md) |

Reduce Transparency, Increase Contrast and Reduce Motion each have a
documented row for every effect in `GlassAccessibilityPolicy`.

### Open the lab pages

Build the `GlassWeaveLab` scheme for an iPhone simulator. Every page opens
from a button on the lab's main screen, and each also opens at launch with a
launch argument (Xcode scheme arguments, or `xcrun simctl launch <device>
dev.glassweave.GlassWeaveLab <arguments>`):

| Page (button on the main screen) | Launch arguments |
| --- | --- |
| Apple vs GlassWeave | `-lab.versus YES` (`-lab.versusAnimate NO`, `-lab.versusScroll <points>`) |
| Material studies menu: Focus (pill), Camera (pearl), Open Air (shelf), Amber (vessel) | `-lab.study pill`, `pearl`, `shelf` or `vessel` (`-lab.studyTime <seconds>` pins the script, `-lab.studyTwin YES` adds a real `UIGlassEffect` beside it, `-lab.studyDiagnostics YES`) |
| Material bench | `-lab.bench dots`, `checkerboard`, `ribbons`, `charcoal`, `paper`, `orbs`, `chrome`, `paperdesk`, `prism` or `stage` |
| Light fields | `-lab.lightFields YES` (`-lab.lightBackdrop <page>`, `-lab.lightTime <seconds>`) |
| Thick lens | `-lab.lens YES` (`-lab.lensBackdrop <page>`) |
| Chrome and light | `-lab.chrome YES` (`-lab.lightAzimuth`, `-lab.lightElevation`) |
| Paper desk | `-lab.paper YES` |
| Shapes | `-lab.shapes YES` (`-lab.shapesBackdrop <page>`, `-lab.shapesTime <seconds>`) |
| Liquid vessels | `-lab.vessel YES` (`-lab.vesselNudge <seconds>`) |
| Frosted glass | `-lab.frostBench YES` |
| Frost pyramid | `-lab.frost YES` |
| Native vs refined glass | `-lab.compare YES` (`-lab.compareBackdrop <page>`) |
| Presentation | `-lab.presentation YES` |
| Glow gallery | `-lab.gallery YES` |
| Touch (GW-12) | `-lab.touch YES` (`-lab.touchBackdrop orbs`, `stage` or `grid`; `-lab.touch.pin "pill:0.3:0.55:0.18;round:0.55:0.5:0.12"` freezes synthetic touches for a capture; `-lab.touch.boost <factor>`; `-lab.touch.auto YES` taps once through the surface API) |
| Merge (GW-13) | `-lab.merge YES` (`-lab.mergeBackdrop stage` or `orbs`; `-lab.merge.progress <0...1>` pins the progress; `-lab.merge.auto YES` merges, reverses and settles) |
| GlassSurface in SwiftUI (GW-15) | `-lab.swiftui YES` (`-lab.swiftui.strength <0...1>`, `-lab.swiftui.light NO`, `-lab.swiftui.quality balanced` or `minimal`) |

`-lab.reduceMotion YES`, `-lab.reduceTransparency YES`, `-lab.increaseContrast
YES` and `-lab.appearance dark|light` fix the accessibility settings for a
capture, on the pages that read them. Inspected captures are in `docs/evidence/captures/`; the newest are
named `gw-final-*`.

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
`GlassWeaveUIKit`. `GlassWeaveSwiftUI` is an optional third product
(experimental, GW-15): a SwiftUI view over the UIKit host that nothing else
in the package imports. Build with Xcode: SwiftPM's command-line `swift build`
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
- [Architecture](docs/architecture.md), with the design notes
  [glass optics](docs/glass-optics.md), [frost](docs/frost.md),
  [presentation](docs/presentation.md), [studies](docs/studies.md),
  [interaction](docs/interaction.md) (touch response, merging) and
  [the SwiftUI adapter](docs/swiftui.md)
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
