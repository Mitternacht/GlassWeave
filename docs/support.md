# Support policy

Status: GW-01 baseline, recorded 2026-11-08. This page states what the package
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

| Product | Imports | Purpose |
| --- | --- | --- |
| `GlassWeave` | Metal (and simd) | Core types and rendering. Never imports UIKit or SwiftUI. |

UIKit presentation arrives as a separate product when a working slice needs it.
