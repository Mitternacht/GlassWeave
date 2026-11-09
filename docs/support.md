# Support policy

Status: updated for GW-03 through GW-09, 2026-11-09. This page states what the package
declares and what it checks at runtime. It is not a list of qualified devices.
No physical-device measurement has been made yet; see
[the validation protocol](validation.md).

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
