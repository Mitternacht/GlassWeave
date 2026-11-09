# GlassWeave v0.1 pre-alpha: candidate notes

**Draft release notes. Nothing has been released or tagged.** A pre-alpha
release needs explicit authorization and a complete validation record, and
the validation record is not complete: the physical-device qualification of
Milestone 1 (GW-09) has not been done. See
[the Milestone 1 report](milestone-1.md).

Candidate revision for the checks below: `9b2c0c4` on `implement/milestone-1`
(2026-11-09, after review fixes to the scheduler, the legibility rule, the
benchmark workload, and the evidence). Later commits change documentation
and comments only. The first candidate, `6c2ac6a` (recorded as `4767ed7`
before the branch's author identity was rewritten on 2026-11-09; the
rewrite changed no tree), is superseded.

## API status

**Experimental.** Every public type and member may change or disappear
without notice or deprecation. Names were reviewed against the behavior the
tests demonstrate (below), but the parameter set of the panel is lab-tuned,
and which of its parameters stay public is still open (plan decision 3).

## What v0.1 is

- One rounded custom refractive panel (`GlassRenderer`, `GlassPanel`,
  `GlassParameters`, `GlassTint`) over one explicit, app-owned background
  source, presented by a UIKit host (`GlassSurfaceView`).
- A thin native mode (`NativeGlassView`) around Apple's public
  `UIGlassEffect`, with no GlassWeave renderer.
- A documented source contract (one format, same-queue ordering, leases
  released after the last GPU use), on-demand per-scene scheduling with a
  fixed in-flight bound, a bounded producer texture pool, accessibility
  behavior, and opt-in measurement (`RenderMetrics`).
- UIKit presentation with an iOS/iPadOS 26 deployment floor, run only on the
  iOS 27.2 simulator (no iOS 26 runtime was available); iPad presentation is
  not claimed. macOS 26 is a declared floor for the core, which was compiled
  and GPU-tested on macOS 27.2 only; there is no macOS view.

## Exclusions

None of the following is part of v0.1, and none is required for it:

- touch-driven ripple (GW-12);
- merging of custom surfaces (GW-13), and any optical merging with Apple's
  glass, which is not promised at all;
- enhanced-native effects around Apple's glass (GW-14);
- a SwiftUI adapter (GW-15);
- external producer or texture interoperability, including Frostfield
  (GW-16), cross-queue or shared-event synchronization;
- a Metal 4 backend (GW-11);
- wide color, HDR, transparent, or video sources; a macOS view; visionOS.

## Known limitations

- **No physical device has been measured.** Every provisional budget (GPU,
  CPU encoding, pacing, interaction stalls, memory, idle, compilation,
  thermal) is *not measured* on hardware. The evidence is simulator
  functional results and an Apple M5 Mac offscreen characterization, which
  are not device evidence.
- No iOS 26 runtime was available; only iOS 27.2 simulators ran.
- Live VoiceOver navigation has not been exercised.
- iPad: full-screen apps mode only; Stage Manager and side-by-side scenes not
  exercised.
- A produced frame that gets no drawable becomes current but is presented
  only by the next draw; nothing schedules a retry.
- `GlassSurfaceView` acquires its drawable on the main thread through
  `MTKView.currentRenderPassDescriptor` (`CAMetalLayer.nextDrawable()`),
  which blocks until a drawable is free: normally at most about one display
  refresh with the two-frame in-flight bound, up to the layer's one-second
  timeout when no drawable is free. The "no drawable" skip is reached only
  after that wait, and no test exercises it through a real `MTKView`.
- The CI workflow has not run on GitHub.
- `swift build` cannot compile the Metal shaders; build with Xcode.

## Clean-consumer check

The consumer is in the repository, `Examples/ConsumerCheck`, and
`scripts/consumer_check.sh [revision] [destination]...` repeats the check
(CI runs it on macOS). It depends on GlassWeave as an outside project would:

- `.package(url: GLASSWEAVE_URL, revision: GLASSWEAVE_REVISION)` from the
  environment, products `GlassWeave` and `GlassWeaveUIKit`, Swift 6 language
  mode, iOS 26 and macOS 26 floors. The script copies the package to a
  temporary directory and points it at the local clone by a `file://` URL.
- Resolution at `9b2c0c4`: SwiftPM cloned the repository and pinned exactly
  that revision; the script requires one pin, `glassweave`, kind
  `localSourceControl`, at the requested revision, and found it. No other
  package was resolved. The package's Metal shaders compiled from the
  checkout and loaded from GlassWeave's resource bundle inside the consumer.
- The script runs `xcodebuild test` (a terminal check, so the combined
  workspace stays the only one open in Xcode) with Metal API Validation on;
  the custom-mode test checks that the command queue is
  `MTLDebugCommandQueue`.
- Its tests use public API only (no `@testable import` of GlassWeave):
  - **Custom mode:** the consumer creates its own device and queue, a
    `GlassRenderer`, a `FrameTexturePool`, and a producer, draws one produced
    frame with a fully tinted panel into an offscreen target, reads it back,
    and finds the consumer's background color outside the panel and the tint
    inside, within one 8-bit step; `RenderMetrics` counts one drawn frame.
  - **Native mode:** `NativeGlassView` holds a public `UIGlassEffect`, a
    button in its content view acts, and no `MTKView` appears.
  - **UIKit host:** `GlassSurfaceView` accepts a frame producer and a panel,
    is hidden from accessibility, and, outside any window, defers requests
    without producing or submitting anything. A test process has no window
    scene, so the consumer cannot make the surface visible; drawing through
    the surface is covered by the laboratory's UI tests.
- Results at `9b2c0c4` (2026-11-09): iPhone 18 Pro simulator 3/3 passed;
  My Mac 1/1 passed (the two UIKit tests are compiled only where UIKit
  exists). The script also passed from a shallow clone in a directory with
  another name, as a CI checkout would be.
- The first run (2026-11-08, at `6c2ac6a`, then `4767ed7`) used the same
  sources from a package outside the repository, opened in Xcode as its own
  workspace; it gave the same results.

## Exported API surface

Listed from the DocC archive of the candidate (`xcodebuild docbuild`, a
one-off check; it built with no documentation warnings).

| Module | Public types |
| --- | --- |
| `GlassWeave` | Custom rendering: `GlassRenderer`, `GlassPanel`, `GlassParameters`, `GlassTint`, `GlassParameterError`. Background source: `BackgroundFrame`, `BackgroundFrameLease`, `BackgroundFrameRelease`, `BackgroundFrameReadiness`, `BackgroundColorConvention`, `SourceOrientation`, `PixelRect`, `BackgroundSourceError`. Producer textures: `FrameTexturePool`, `PooledTexture`. Drawing without the view: `BackgroundRenderer`, `BackgroundDrawTarget`, `BackgroundRenderOutcome`, `BackgroundRenderSkipReason`, `BackgroundRendererError`. Scheduling and measurement: `FrameStatistics`, `RenderCapabilities`, `RenderMetrics`. Test pattern: `OrientationPattern`. |
| `GlassWeaveUIKit` | `GlassSurfaceView`, `NativeGlassView`, `GlassAccessibilitySettings`, `GlassAccessibilityPolicy` |

Review findings:

- Every public type is exercised by tests that check the behavior its name
  states; none is a placeholder, and no public method is a no-op.
- `BackgroundRenderer` (background without a panel) is public and tested,
  but only `GlassRenderer` is used by the UIKit host. Keeping both public is
  a choice to revisit before a stable API.
- `OrientationPattern` is a deterministic test image. It is public so apps
  and tests can check orientation; it is documented as a test pattern.
- The scheduler (`FrameScheduler`, `FrameLedger`) and the hooks that hand a
  host each command buffer are `package` access, not public.
- `GlassSurfaceView.sceneStateOverride` is internal (tests only).

## Dependency graph

`swift package show-dependencies`: no external dependencies. Products:
`GlassWeave` (target `GlassWeave`, which depends on the internal C target
`GlassWeaveShaderTypes`) and `GlassWeaveUIKit` (depends on `GlassWeave`).
Test targets: `GlassWeaveTests`, `GlassWeaveUIKitTests`,
`GlassWeaveCharacterizationTests`. Neither the manifest nor any source file
mentions Frostfield.

## Documentation

`Sources/GlassWeave/GlassWeave.docc/GlassWeave.md` covers native mode, one
rounded custom panel with an app-owned producer, source ownership, lifecycle,
failure behavior, accessibility, measurement, and the measured limitations,
which are so far only that nothing has been measured on a device. Its five
Swift examples are copied verbatim into `Tests/*/DocumentationExamples.swift`,
compiled by the package build, and run by `DocumentationExampleTests`;
`scripts/check_doc_examples.py` (a CI step) fails when the catalog and the
copies differ.

## Verification at the candidate revision

Xcode MCP `RunAllTests`, Metal API Validation on:

- `GlassWeave` package, My Mac (Apple M5): 126 test functions passed.
- `GlassWeave` package, iPhone 18 Pro simulator: 155 passed.
- `GlassWeaveLab`, iPhone 18 Pro and iPad Pro 13-inch (M5) simulators: 18
  passed and 1 skipped each.

All at `9b2c0c4`. At the first candidate the counts were 118 and 147, with
the laboratory run at the GW-09 commit (`afb66d6`, recorded as `120bafc`
before the identity rewrite).

No tag was created, nothing was pushed, and nothing was released.
