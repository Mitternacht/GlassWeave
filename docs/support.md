# Support policy

Status: updated for the v0.1 pre-alpha candidate (GW-10), 2026-11-09, after review fixes. This
page states what the package declares, what it checks at runtime, and which
combinations have been tested. **No device is qualified.** No physical iPhone
or iPad has been measured; see [the Milestone 1 report](evidence/milestone-1.md).

## Operating systems versus GPU capabilities

These are separate questions and GlassWeave answers them separately.

| Question | Answered by | Example |
| --- | --- | --- |
| Can this OS load the package? | `Package.swift` deployment floor | iOS/iPadOS 26, macOS 26 |
| What can this GPU do? | `RenderCapabilities(device:)` at runtime | Metal 3 family, Metal 4 family, highest `appleN` family |

An OS version never implies a GPU feature. A device name is reported for
diagnostics only; no code path branches on it. Rendering decisions use the
capability survey of the `MTLDevice` that will actually render.

The iOS Simulator SDK in Xcode 27.2 does not declare the Metal 4 GPU family
(`MTLGPUFamily.metal4`). `RenderCapabilities` therefore reports Metal 4 as
unavailable in any simulator build. Simulator results are never evidence of
GPU support or performance on hardware.

## Support matrix

"Tested" means the named checks passed in that combination; it is never a
performance or device-quality claim. Every row without a physical device is
functional evidence only.

| Combination | Status | Evidence |
| --- | --- | --- |
| Physical iPhone, iOS 26.x | **Untested** | None. No baseline device has been selected. |
| Physical iPhone, iOS 27.x | **Untested** | None. |
| Physical iPad | **Untested** | None. No iPad presentation support is claimed. |
| iOS 26 Simulator | **Untested** | The iOS 26 runtime is not installed; the 26.0 floor is declared, not run. |
| iOS 27.2 Simulator, iPhone 18 Pro | Tested, functional | Package scheme: 155 test functions (core, UIKit, documentation examples, characterization). Laboratory: 18 UI tests passed, 1 iPad-only test skipped, including coexistence, rotation, lifecycle, accessibility, and the benchmark modes. |
| iOS 27.2 Simulator, iPad Pro 13-inch (M5) | Tested, functional | Laboratory: 18 UI tests passed, 1 skipped (the system-dark audit; system dark does not reach apps on that simulator), including two window scenes. Full-screen apps mode only; Stage Manager not exercised. |
| macOS 27.2, Apple M5, core | Tested | Package scheme: 126 test functions (core, documentation example, characterization) with Metal API Validation; the Release characterization in [the Milestone 1 report](evidence/milestone-1.md). There is no macOS view. |
| macOS 26.x | **Untested** | Declared floor; not run. |
| Clean consumer, SwiftPM git dependency | Tested | `Examples/ConsumerCheck`, run by `scripts/consumer_check.sh`, resolved the candidate revision and ran native and custom mode tests on My Mac and the iPhone 18 Pro simulator; see [the pre-alpha notes](evidence/pre-alpha.md#clean-consumer-check). |
| Xcode 27.2 (27B52), Swift 6.4.2 | Used for every result | Other toolchains are untested. |
| GitHub Actions `macos-26` | **Not run** | The workflow is written; it has not run on GitHub. It selects `/Applications/Xcode_27.2.app` and fails if that Xcode is missing or reports another version, so a hosted run uses the recorded toolchain or stops. Whether the hosted image provides Xcode 27.2 is not known. |
| Metal 4 | Not used | `RenderCapabilities` reports it; the renderer uses conventional Metal (GW-11 decides). |
| VoiceOver, live navigation | **Untested** | The Simulator has no VoiceOver; element structure and audits pass in UI tests. |

### API coverage

| API | Checked by | Not checked |
| --- | --- | --- |
| `NativeGlassView` | UIKit tests, laboratory UI tests, documentation example, clean consumer | Device appearance |
| `GlassSurfaceView` (custom mode) | UIKit tests (with a substituted scene state), laboratory UI tests (real scenes), documentation example; the clean consumer uses its public API but cannot make it visible in a test process | Device presentation, pacing, VoiceOver |
| `GlassRenderer`, `BackgroundRenderer`, source contract | GPU render-and-readback tests on My Mac and the simulator; clean consumer readback | Device GPUs |
| `FrameTexturePool`, `FrameStatistics` | Lifecycle tests, laboratory, characterization | Device memory instrumentation |
| `GlassAccessibilityPolicy`, legibility rule | UIKit and laboratory tests, documentation example | Live VoiceOver, device display |
| `RenderMetrics` | Package tests, laboratory benchmark, characterization | Device timings |
| `RenderCapabilities` | Package tests, laboratory diagnostics | Device GPU families |

## Platforms

| Platform | Status |
| --- | --- |
| iOS / iPadOS 26 or later | First presentation target. Not yet qualified on a physical device. |
| macOS 26 or later | Core compilation and GPU unit tests only. There is no macOS UI adapter and none is promised. |
| visionOS, tvOS, watchOS, Mac Catalyst | Not declared and not supported. |

## Rendering backend

GlassWeave renders through conventional Metal command submission. Metal 4 is a
later, measured experiment (GW-11). The capability survey reports Metal 4
availability so that experiment can choose a supported path; it does not switch
the backend today.

## Modules

| Product or target | Imports | Purpose |
| --- | --- | --- |
| `GlassWeave` | Metal, simd, os, CoreGraphics, Synchronization | Core types and rendering: the source-frame contract, its validation and lease, the background renderer, the glass renderer with its parameters (one rounded panel), the frame scheduler (package access), `FrameTexturePool`, a bounded pool of producer textures recycled only after GPU use, the text legibility rule for tinted glass (`GlassTint.worstCaseContrast`, `minimumStrength`), and opt-in `RenderMetrics` (CPU encode, producer, and drawable-acquisition time, GPU start/end per command buffer, counts, and allocated bytes). Never imports UIKit or SwiftUI; `CoreGraphics` supplies only `CGRect` for panel frames in points. |
| `GlassWeaveUIKit` | UIKit, MetalKit | UIKit presentation. `NativeGlassView` is native mode: a `UIVisualEffectView` with a public `UIGlassEffect` (tint, interactive) around native controls, creating no GlassWeave renderer. `GlassSurfaceView` hosts an `MTKView` for an explicit source and an optional glass panel given in the view's points; it draws on demand, only while visible in its own window scene, with at most two frames in flight (`frameStatistics` reports the counts); it is hidden from assistive technologies and applies `GlassAccessibilityPolicy` (an opaque legible panel under Reduce Transparency; Reduce Motion reported to the app). Compiled only where UIKit exists; on macOS the module is empty. |
| `GlassWeaveShaderTypes` (internal C target, not a product) | simd | The single definition of every record uploaded to the GPU, shared by Swift and the Metal shaders. |

GlassWeave never creates a Metal device or command queue. An app that uses
custom rendering passes its own command queue to `BackgroundRenderer` or
`GlassRenderer`.

## Source contract (v0.1)

`BackgroundRenderer` accepts exactly one source format: a single-sample 2D
`bgra8Unorm_srgb` texture with `shaderRead` usage on the renderer's device,
declared `.sRGBOpaque`. It samples in linear light and ignores source alpha.
Every other format, a texture from another device, or writes committed to
another queue is rejected with a `BackgroundSourceError` that names the fix.
Writes are ordered before sampling in one of two ways: committed earlier to the
renderer's queue, or encoded earlier in the draw's own command buffer through
`GlassRenderer.drawProducing` (or `GlassSurfaceView.setFrameProducer`).
Wide color, HDR, transparent sources, and video formats are not supported.
