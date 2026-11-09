# GlassWeave task checklist

GW-01 through GW-08 and GW-10 have code in this repository. GW-09 has its measurement instrument (the laboratory's benchmark scenario, `RenderMetrics`, and a Mac characterization) but its device qualification has not been done, so none of its items is checked; GW-10 was carried out ahead of that GW-09 dependency, and its device-dependent item stays open. GW-11 through GW-16 are planned. GW-17 through GW-20 (glow effects, requested by the user on 2026-11-09, experimental and post-v0.1) are listed after Checkpoint F; GW-14 is pulled forward with them. Check an acceptance item only after its evidence exists; each task's evidence paragraph says why any box is still open. The **Likely files** lines are the original proposals, not a record: the evidence paragraphs name the files actually created, the laboratory's sources live in `Examples/GlassWeaveLab/GlassWeaveLab/`, and some proposed files (for example `Sources/GlassWeave/GlassWeave.swift` and `Tests/GlassWeaveTests/BackgroundFrameTests.swift`) were never created.

Use the native Xcode MCP tools for project edits, builds, tests, diagnostics, and device interaction when working in this environment, after loading the relevant Apple skills. Add meaningful Swift Testing coverage with the first testable behavior. CI can use equivalent Xcode command-line build and test actions.

**v0.1 scope:** GW-01 through GW-10. GW-11 through GW-16 are later work and must not delay the first useful UIKit package. See [the implementation plan](plan.md) and [validation protocol](../docs/validation.md).

## GW-01: Create the package baseline

**Description:** Turn this planning repository into a minimal Swift package and record the initial platform/capability policy before implementing a renderer.

**Dependencies:** None. **Scope:** Medium, four files.

**Acceptance criteria:**
- [x] A package using Swift tools 6.2 and Swift 6 language mode exposes the `GlassWeave` product with planned iOS/iPadOS 26 and macOS 26 minimums; core compilation does not import UIKit or SwiftUI.
- [ ] Xcode builds the package for macOS and an iOS simulator destination, and CI repeats the package build without account credentials.
- [x] The support note distinguishes OS availability from Metal GPU capabilities and macOS core compilation from a promised macOS UI adapter.

**Evidence (2026-11-08):** Xcode MCP `BuildProject` succeeded for "My Mac" and "Any iOS Simulator Device" (Xcode 27.2, iOS/macOS 27.2 SDKs). Documentation search confirmed `MTLDevice.supportsFamily(_:)` and `MTLGPUFamily.metal4`; the iOS Simulator SDK does not declare `.metal4`, recorded in [support](../docs/support.md). Toolchain, isolation, and MSL dialect are recorded in [the language strategy](../docs/language-strategy.md#recorded-toolchain-gw-01). The workflow `.github/workflows/build.yml` is written but has not run on GitHub yet, so the CI half of the second item stays open until it passes there.

**Verification:** Use Xcode documentation search to confirm the available SDK and capability APIs; build through Xcode MCP and inspect diagnostics. Record compiler, SDK, language mode, default actor isolation, and MSL dialect separately under `docs/language-strategy.md`. Do not add an always-passing test for an empty module; add tests when testable behavior first exists.

**Likely files:** `Package.swift`, `Sources/GlassWeave/GlassWeave.swift`, `.github/workflows/build.yml`, `docs/support.md`.

## GW-02: Open the UIKit laboratory

**Description:** Create a small iOS sample app that consumes the local package and provides one screen for all comparison modes.

**Dependencies:** GW-01. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] The app builds and launches on an iOS 26 simulator without a signing-account requirement.
- [x] One screen has a labeled reference region, a custom region, and a repeatable reset action.
- [x] The app uses a local package reference; the library has no dependency on the app.

**Evidence (2026-11-08):** Xcode MCP `BuildProject`, `RunProject`, and `RunAllTests` on the iPhone 18 Pro simulator (iOS 27.2): `GlassWeaveLabUITests.testLaunchShowsBothRegionsAndResetIsRepeatable` passed. [Launch capture](../docs/evidence/captures/gw-02-launch-iphone18pro-sim.png). The deployment target is iOS 26.0, but only the iOS 27.2 simulator runtime is installed on the development Mac, so the iOS 26 runtime launch in the first item is still outstanding. A fresh clone resolves the local package (`Resolved source packages: GlassWeave @ local`).

**Verification:** Xcode `BuildProject` and `RunProject`; record a launch screenshot and confirm a fresh checkout resolves the local package.

**Likely files:** `Examples/GlassWeaveLab/GlassWeaveLab.xcodeproj/project.pbxproj`, `AppDelegate.swift`, `SceneDelegate.swift`, `LabViewController.swift` within the example app.

## GW-03: Establish the native-glass baseline

**Description:** Add the minimal native mode and put a genuine glass control over a simple moving laboratory background.

**Dependencies:** GW-02. **Scope:** Medium, four files.

**Acceptance criteria:**
- [x] The reference control uses public `UIGlassEffect` tint and interaction configuration and remains actionable.
- [x] Its content is a native control; native-only use creates no GlassWeave Metal device, queue, or render loop.
- [x] The laboratory can reset tint and enabled state for repeatable comparisons.

**Evidence (2026-11-08):** `NativeGlassView` (`Sources/GlassWeaveUIKit/NativeGlassView.swift`) is a `UIVisualEffectView` whose effect is a public `UIGlassEffect` built from `Configuration(tintColor:isInteractive:)`; the laboratory's reference region puts a real `UIButton` in its `contentView` over a moving Core Animation stripe backdrop. Xcode MCP `RunAllTests`, package scheme `GlassWeave` on the "iPhone 18 Pro" simulator (iOS 27.2, `MTL_DEBUG_LAYER=1`): 61 test functions passed, including `NativeGlassViewTests` (effect carries the configured tint and interaction; defaults match `UIGlassEffect`; configuration changes replace the effect; hit testing reaches the button and its action fires; `Native mode creates no renderer, Metal view, or display loop`). That last test runs the whole native path inside `RendererCensus.counting`, a task-scoped count of every `BackgroundRenderer` creation (the same path that emits the "BackgroundRenderer created" os_signpost), and finds zero renderers and no `MTKView` in the hierarchy; `GlassSurfaceViewTests.A surface is a counted renderer` is the positive control. GlassWeave library code never calls `MTLCreateSystemDefaultDevice` or `makeCommandQueue`, and its only `MTKView` lives in `GlassSurfaceView`, which requires a renderer. On "My Mac" the same scheme passed its 47 core test functions. Lab scheme `GlassWeaveLab`, `RunAllTests` on "iPhone 18 Pro" and "iPad Pro 13-inch (M5)" simulators: `NativeReferenceUITests.testNativeGlassButtonIsActionableAndResetRestoresTintAndEnabledState` taps the button while the backdrop moves, tints the glass blue, disables the control (a further tap does not act), and checks that Reset restores untinted, enabled, interactive glass and a zero count, twice; the GW-02 and GW-04 UI tests still pass. Captures: [blue tint](../docs/evidence/captures/gw-03-native-glass-blue-iphone18pro-sim.png), [after Reset](../docs/evidence/captures/gw-03-native-glass-after-reset-iphone18pro-sim.png), [landscape](../docs/evidence/captures/gw-03-native-glass-landscape-iphone18pro-sim.png). Limits: simulator only, no physical device; the no-renderer evidence is the census counter and hierarchy check, not an Instruments signpost or allocation trace.

**Verification:** Build with Xcode; inspect interaction on a device or simulator; use allocation/signpost evidence to confirm no custom renderer is instantiated by the native-only path.

**Likely files:** `Package.swift`, `Sources/GlassWeaveUIKit/NativeGlassView.swift`, `Examples/GlassWeaveLab/LabViewController.swift`, `Tests/GlassWeaveUIKitTests/NativeGlassViewTests.swift`.

### Checkpoint A: laboratory

- [ ] GW-01 through GW-03 pass; native button behavior and reset are demonstrated.
- [ ] No custom optical or performance claim is made yet.

## GW-04: Display an explicit background source

**Description:** Establish the frame contract and display a deterministic app-owned texture through `MTKView` before introducing refraction.

**Dependencies:** GW-02. **Scope:** Medium, five files.

**Acceptance criteria:**
- [x] A source frame carries texture identity, frame identity, extent, UV transform, color/alpha convention, readiness, and a completion lease.
- [x] A test pattern stays correctly oriented and cropped through resize, rotation, safe-area changes, and display-scale changes derived from host bounds and traits.
- [ ] Missing source, zero-size surface, and unavailable drawable produce defined skip or fallback behavior without waiting on the main thread.

**Evidence (2026-11-08):** The contract is implemented in `BackgroundFrame`, `BackgroundFrameLease`, `SourceUVTransform`, and `BackgroundRenderer` (mapped row by row in [the architecture](../docs/architecture.md#implemented-v01-contract-gw-04)); `GlassSurfaceView` in the new `GlassWeaveUIKit` product hosts the `MTKView`; `GlassWeaveShaderTypes` is the shared C layout target. Xcode MCP `RunAllTests`, package scheme `GlassWeave`, whose test action sets `MTL_DEBUG_LAYER=1` (a probe confirmed `MTLDebugDevice`/`MTLDebugCommandQueue` in the test process on both destinations): on "My Mac" (Apple M5) 47 test functions passed (`GlassWeaveTests`; the UIKit bundle is empty on macOS); on the "iPhone 18 Pro" simulator (iOS 27.2) 56 passed, adding `GlassWeaveUIKitTests`. Coverage: `SourceUVTransformTests` (aspect-fill crop, valid-rectangle crop, four rotations, vertical origin, display-scale independence, host rotation), `LeaseLedgerTests`/`LeaseCoreTests` (release exactly once after retire and all holds, outcome counts, dropped holds, 1,000 concurrent completions), `SourceFrameValidationTests` (format, device, queue, texture shape, valid rectangle, ordering, actionable messages), `BackgroundRendererTests` (offscreen render and readback: 1:1 sRGB round trip within one 8-bit step, eight orientation cases, quarter-turned source, centered crop, valid-rectangle clamp, defined skips, release after every submitted draw completes, rejected sources), `ShaderLayoutTests` (host size/alignment/offset/stride and a distinctive-value GPU round trip), and `GlassSurfaceViewTests` (pixel size from bounds × `displayScale` including a trait change, resize/rotation/fractional sizes, zero size never assigns an empty drawable, fallback without a source, decorative hit testing). Lab: scheme `GlassWeaveLab`, `RunAllTests` on "iPhone 18 Pro" (3x) and "iPad Pro 13-inch (M5)" (2x) simulators passed `CustomSurfaceUITests.testPatternStaysUprightThroughRotation` (reads element screenshots back and classifies all four corners after portrait, landscape left, landscape right, portrait) and `testResetPresentsANewFrameAndReleasesThePreviousOne`. Captures: [iPhone portrait](../docs/evidence/captures/gw-04-pattern-portrait-iphone18pro-sim.png), [iPhone landscape, asymmetric safe area](../docs/evidence/captures/gw-04-pattern-landscape-iphone18pro-sim.png), [iPad landscape](../docs/evidence/captures/gw-04-pattern-landscape-ipadpro13-sim.png). Limits: simulator and Mac only, no physical device; no Metal frame capture was recorded; `MTKView.currentDrawable` can still block up to the layer's one-second timeout if every drawable is in flight, so bounding in-flight frames remains part of GW-07. The updated CI commands (macOS `xcodebuild test` and generic iOS Simulator `build-for-testing` for both schemes) passed locally as a one-off check with a separate DerivedData folder; they have not run on GitHub yet.

**Correction (2026-11-09):** The third item was checked in error and is now **open**. The renderer-level skips are defined and wait for nothing (`BackgroundRendererTests`, `ProducedFrameTests`, and `RenderMetricsTests` pass `acquireTarget: { nil }`), and the UIKit host's missing-source and zero-size skips return before a drawable is requested. But `GlassSurfaceView.render(in:)` runs on the main thread and acquires its target through `MTKView.currentRenderPassDescriptor`, which calls `CAMetalLayer.nextDrawable()`; with `allowsNextDrawableTimeout` at its default, that call waits until a drawable is free or one second passes (Xcode documentation search), so `.skipped(.drawableUnavailable)` is reached only after a main-thread wait. The two-frame in-flight bound (GW-07) normally keeps that wait to about one display refresh, but it is not zero, and no test exercises the no-drawable path through a real `MTKView`. Closing this item needs either a non-blocking acquisition path (for example a drawable source that does not wait) with a test, or a narrower criterion. The `GlassSurfaceView` documentation, the DocC failure table, and the pre-alpha known limitations now state the wait instead of claiming none.

**Verification:** Xcode build; Swift Testing for coordinate mapping and lease state; Metal API Validation; device/simulator rotation with a four-corner test pattern. Add host layout assertions and a distinctive-value GPU round-trip for uploaded records; split shared-layout packaging into a prerequisite subtask if needed to keep this slice focused.

**Likely files:** `Sources/GlassWeave/BackgroundFrame.swift`, `Sources/GlassWeave/BackgroundRenderer.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Sources/GlassWeave/Shaders/Background.metal`, `Tests/GlassWeaveTests/BackgroundFrameTests.swift`.

## GW-05: Refract one rounded panel

**Description:** Add one custom surface over the supplied texture, with a small optical model and explicit parameters.

**Dependencies:** GW-04. **Scope:** Medium, five files.

**Acceptance criteria:**
- [x] One rounded panel changes sampling according to bounded refraction and edge parameters; zero refraction reproduces the source within the documented render tolerance.
- [x] The material handles its edge, texture bounds, and alpha convention without halos or uninitialized pixels.
- [x] Invalid parameters are rejected or normalized by a documented rule; fixed inputs produce repeatable reference output.

**Evidence (2026-11-08):** `GlassParameters`/`GlassPanel`/`GlassTint` (`Sources/GlassWeave/GlassParameters.swift`) carry lengths in points and normalized coefficients with documented ranges and the normalization rule (non-finite rejected with `GlassParameterError.nonFinite(field)`, finite out-of-range values clamped); `GlassRenderer` draws the background pass and then one panel quad in the same render pass from the same frame and mapping; `Shaders/Glass.metal` implements the rounded-rectangle field, bounded rim displacement, tint, and restrained edge illumination; `GlassPanelGeometry` is the CPU mirror the tests compare against. The model, units, and tolerance are in [the architecture](../docs/architecture.md#implemented-optical-model-gw-05); the new `GWGlassUniforms` record is in [the language strategy](../docs/language-strategy.md#glass-panel-record-gw-05). Xcode MCP `RunAllTests`, package scheme `GlassWeave` with `MTL_DEBUG_LAYER=1`: "My Mac" (Apple M5) 76 test functions passed, "iPhone 18 Pro" simulator (iOS 27.2) 91 passed (counts from `xcresulttool`). Offscreen render and readback (`GlassRendererTests`): `Zero refraction reproduces the source within one step` (checkerboard; also equal to the background-only pass within one step, and a refraction-1 control changes it by more than 100 steps); `Refraction moves each sample where the CPU model predicts` (256 × 256 coordinate gradient, refraction 1, every pixel within one step of the model, more than 1,000 pixels displaced by four or more texels); `Panels in points render the same at every display scale`; `A uniform source shows no halo at the outline`; `Bright and dark edges refract without overshoot or color fringes` (quadrant edges through the rims: every value inside the dark/bright range, gray stays gray, unchanged outside the panel and in its flat interior, more than 50 rim pixels moved); `Edge illumination only brightens the rim, as the CPU model predicts` (never darker, nothing outside the rim, at most a quarter of the way to white); `Tint mixes in linear light`; `Refracted samples never leave the valid rectangle` (three panel placements over a magenta border); `Fixed inputs render identical bytes`; `An empty panel draws exactly the background`; `A rejected panel leaves the current panel in place`; `Skips run before the panel is converted`; `Release waits for every glass draw to complete`. Every readback target is cleared to transparent black and checked to be fully opaque afterwards, so no pixel is left unwritten. `GlassParametersTests` cover clamping, rejection of NaN/±infinity for every field, point-to-pixel conversion, signed distance, normals, the displacement bound and no-fold-over property, smooth corner normals, and the illumination bound. `ShaderLayoutTests` add host layout checks and a distinctive-value GPU round trip for `GWGlassUniforms`. A deliberate mutation (outward instead of inward displacement) made the model comparison fail by 27.5 steps and was reverted; the valid-rectangle test still passed under that mutation, so the clamp alone keeps outward samples inside. `GlassSurfaceViewTests.The panel stays in points and follows the normalization rule` covers the UIKit host. Lab scheme `GlassWeaveLab`, `RunAllTests` on "iPhone 18 Pro": the four existing UI tests pass with a panel centered over the pattern. [Capture](../docs/evidence/captures/gw-05-panel-over-pattern-iphone18pro-sim.png) (simulator). Limits: no Metal frame capture was inspected; no physical device; the panel parameters are lab-tuned, not final public API.

**Verification:** Xcode build; parameter/shape math tests; capture fixed reference frames against checkerboard, gradients, and bright/dark edges; inspect a Metal frame capture.

**Likely files:** `Sources/GlassWeave/GlassParameters.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Tests/GlassWeaveTests/GlassParametersTests.swift`, `Examples/GlassWeaveLab/LabViewController.swift`.

## GW-06: Prove moving coexistence

**Description:** Drive the source and custom panel with one deterministic clock while the native reference control remains visible alongside it.

**Dependencies:** GW-03, GW-05. **Scope:** Medium, four files.

**Acceptance criteria:**
- [x] The presented background and refracted sample refer to the same produced frame, including after resize and pause/resume.
- [x] Native text and a native button above the custom panel remain readable, tappable, and correctly ordered with the native reference control.
- [ ] A short capture shows moving content, working controls, and native/custom coexistence; it makes no claim of optical merging between the two systems.

**Evidence (2026-11-08):** `GlassRenderer.drawProducing` produces each frame inside the draw's own command buffer (new readiness `BackgroundFrameReadiness.encoded(in:)`), then samples it for the background and the panel later in that command buffer and commits it once; `GlassSurfaceView.setFrameProducer`/`requestFrame()` run that path for every draw, including resizes. The laboratory (`ProceduralBackground.swift`/`.metal`, `LabViewController.swift`) drives it from one `DeterministicClock` (one 1/60 s step per `UIUpdateLink` tick of the stage's own window), renders into a pool of at most three textures recycled only on lease release (a tick with none free is skipped and counted as coalesced), stamps a frame-ID strip that can be switched off, and places native text plus a "Custom action" `UIButton` on the custom panel with the native-glass reference control beside it. Paths and ordering are in [the architecture](../docs/architecture.md#first-rendering-composition). Xcode MCP `RunAllTests`, package scheme `GlassWeave` with `MTL_DEBUG_LAYER=1`: "My Mac" 83 test functions passed, "iPhone 18 Pro" simulator 99 passed. `ProducedFrameTests` (GPU readback): `Background and panel show the frame produced in the same command buffer` (three draws, each producing a different color; every pixel inside and outside the panel shows that draw's frame; each released once after its draw completed), `Producing nothing redraws the current frame`, `A produced frame without a drawable is still written and kept` (a later draw shows it; the release counts one skipped and one completed use only after completion), `A zero-size target skips before anything is produced`, `A produced frame encoded elsewhere is rejected and still released`, `Handing over a frame in an uncommitted command buffer is rejected until it is enqueued`, `Writes encoded on another queue are rejected`; `GlassSurfaceViewTests.A frame producer runs inside each draw and a rejected frame is reported`. Lab scheme `GlassWeaveLab`, `RunAllTests` on "iPhone 18 Pro" and "iPad Pro 13-inch (M5)" simulators, 5/5 each: `CoexistenceUITests.testBothControlsActWhileTheBackgroundMoves` checks the custom button lies inside the custom panel and the native glass does not overlap it, taps both buttons three times while frames advance (counts 1, 2, 3; presented frame = last produced frame = last submitted frame after each round), pauses (no new frame for 1 s; both buttons still act), decodes the frame-ID strip from a screenshot both beside the panel (background pass) and inside the panel (glass pass) and matches it to the presented frame ID, rotates to landscape and back while paused (a new frame is produced at the same content time and presented; both buttons act in landscape), resumes (frames and content time advance), turns the overlay off, and checks Reset clears both counts. A deliberate mutation (stamping frame ID + 1) made that test fail on the first strip cell and was reverted. The GW-02/03/04 UI tests still pass; the orientation tests now launch with `-lab.source pattern`. Captures (simulator, light appearance): [moving](../docs/evidence/captures/gw-06-coexistence-moving-iphone18pro-sim.png), [paused, frame 3982, both buttons tapped](../docs/evidence/captures/gw-06-coexistence-paused-iphone18pro-sim.png), [landscape](../docs/evidence/captures/gw-06-coexistence-landscape-iphone18pro-sim.png). A 55-second simulator screen recording (`simctl io recordVideo`) is kept out of git; frames sampled from it show the background, strip, and panel moving (frame 533 to 563 between 2.0 s and 2.5 s) and the landscape state after three taps on each control. The native reference's former Core Animation stripe backdrop (GW-03) is replaced by the shared stage, and `NativeReferenceUITests` still passes over it. The CI commands (macOS `xcodebuild test`, generic iOS Simulator `build-for-testing` for both schemes, macOS Release build) passed locally as a one-off with separate DerivedData; they have not run on GitHub. Limits: the third item needs the physical-device capture named in Verification and stays open; text readability is judged from captures (contrast is measured in GW-08); the Reduce Motion pause is unverified (GW-08); no Metal frame capture; a stationary paused surface still holds three pooled textures, and bounding in-flight drawables remains GW-07.

**Verification:** Xcode run on a physical device; record a frame-ID debug overlay and video; tap both controls during motion and check their action counts.

**Likely files:** `Examples/GlassWeaveLab/ProceduralBackground.swift`, `Examples/GlassWeaveLab/LabViewController.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`.

### Checkpoint B: optical proof

- [ ] GW-04 through GW-06 pass with the explicit source contract intact.
- [ ] A device capture demonstrates the central visual composition; sustained cost is still unqualified.

## GW-07: Bound the render lifecycle

**Description:** Make frame scheduling and resource retention correct for stationary, hidden, resized, and backgrounded surfaces.

**Dependencies:** GW-06. **Scope:** Medium, five files.

**Acceptance criteria:**
- [x] A stationary source and stationary surface render on demand; each host follows its owning `UIWindowScene` and visibility, without pausing a visible surface in another scene.
- [x] In-flight frames and reusable textures have a fixed bound; overload drops/coalesces obsolete work instead of building an unbounded queue.
- [x] Resize and teardown retain every resource until its last GPU consumer completes, with no main-thread `waitUntilCompleted` path.

**Evidence (2026-11-08):** `Sources/GlassWeave/FrameScheduler.swift` adds the per-host policy: `FrameLedger` (a value-type state machine: on demand, coalesced requests, visibility deferral with one pending frame, an in-flight bound of 2 that defers instead of queueing) behind the thread-safe `FrameScheduler`, plus the public `FrameStatistics`. `Sources/GlassWeave/FrameResources.swift` adds `FrameTexturePool` (fixed capacity counting textures in use; reuse only after the frame's lease is released; `nil` checkout under overload; discard on resize and `trim()`; a ledger that outlives the pool for late returns). The renderers hand each command buffer to the host just before every commit (`onCommit`, package access). `GlassSurfaceView` draws only through the scheduler, observes only its own window scene (typed `UIScene` messages re-subscribed in `didMoveToWindow`), treats foreground-active and foreground-inactive as visible, checks its own and its ancestors' hidden state and alpha, releases drawables when it stops being visible, and exposes `frameStatistics`, `isVisible`, `visibilityHandler`, and `maximumFramesInFlight`. The laboratory's moving source now uses `FrameTexturePool`, trims it and stops its clock while the surface is hidden, and gains a Stage switch and (iPad) New window / Close window; its diagnostics print the scheduler counts, scene state, pool counts, and the submissions of the last hidden period. Rules and limits are in [the architecture](../docs/architecture.md#implemented-lifecycle-gw-07). Xcode MCP `RunAllTests`, package scheme `GlassWeave` (test action sets `MTL_DEBUG_LAYER=1`): "My Mac" (Apple M5) 103 test functions passed; "iPhone 18 Pro" simulator 124 passed (103 core + 21 UIKit), counts from `xcresulttool`. Swift Testing: `FrameLedgerTests` (request consumed by one draw, coalescing, hidden deferral drawn once on show, bound defers until completion, skipped draw frees its slot, completions while hidden, show at the bound, and a seeded 5,000-step random sequence per bound 1/2/3 checking the bound, `submitted == completed + inFlight`, and that a pending frame on a visible host always has a scheduled pass or a completion coming); `FrameSchedulerTests` (1,000 concurrent completions); `TexturePoolLedgerTests` (capacity then exhaustion, reuse after return, resize and trim discard rules, idempotent returns, failed allocation, seeded random sequence never above capacity). GPU tests (`FrameLifecycleTests`, offscreen host using the same scheduler, renderer, and pool): `A stalled GPU holds the in-flight bound and nothing queues behind it` (each produced command buffer waits on an `MTLSharedEvent`; 10 requests and passes give 2 submissions, 8 deferrals at the bound, one pending frame, no release; after signalling, exactly one more frame is drawn and every frame is released once after completion); `Teardown keeps in-flight resources until their GPU work completes` (renderer, scheduler, and pool dropped while a frame is held on the GPU: no release and the pooled texture is still alive; after signalling, the release reports one completed submission and the texture is freed); `100 hide and show cycles and 100 resizes keep submissions and allocations bounded` (attached summary on iPhone 18 Pro: hide/show 100 submissions, 400 deferrals while hidden, 200 coalesced, 1 allocation; resizes 100 submissions, 100 allocations, 101 discards, 113 deferrals at the bound; peak 2 frames in flight, peak 2 live textures; 201 frames produced, released, and completed; 0 live textures after trim). UIKit tests (`SurfaceLifecycleTests`, iPhone 18 Pro simulator; the test process has no window scenes, so the scene state is substituted while hidden state is real): visibility table over every scene state, a surface outside a window draws nothing, `Two surfaces follow their own scene and visibility` (one foreground, one background, then swapped to background and foreground-inactive: each submits only while its own scene is visible and the pending frame is drawn once), hiding the surface, an ancestor, or setting alpha 0 defers, and a 100-cycle hide/request/show/resize stress with trimming on hide (201 submitted, 300 deferred while hidden, peak 2 in flight, 1 live texture while hidden, 201 frames released). Deliberate mutations (removing the bound check; treating every scene state as visible) failed `FrameLedgerTests`/`FrameLifecycleTests` and `SurfaceLifecycleTests`, and were reverted. Lab scheme `GlassWeaveLab`, `RunAllTests`: "iPad Pro 13-inch (M5)" 9/9; "iPhone 18 Pro" 8 passed and 1 skipped (the two-scene test skips where `supportsMultipleScenes` is false). `LifecycleUITests`: `testAStationarySourceSubmitsNothing` (paused moving source and the still pattern: no submission over 2 s, read through a diagnostics refresh that requests no frame), `testHidingTheStageStopsSubmissionsAndReturnsTextures` (10 cycles: clock paused while hidden, one texture left, 0 submissions in each hidden period, drawing resumes), `testBackgroundingTheAppStopsSubmissions` (Home, 2 s, activate: 0 submissions while in the background), and on iPad `testTwoWindowScenesFollowTheirOwnActivationState` (New window brings a second scene forward and sends the first to the background; the background scene shows 0 new submissions and one texture while the active one keeps drawing; Close window, then activating the app returns the first scene, which draws again with 0 submissions in its hidden period). A manual run on the iPhone 18 Pro simulator launched with `MTL_DEBUG_LAYER=1` (stage hide/show, four rotations, Home and return) logged no Metal errors; that the debug layer was active in the app process was not independently confirmed (the package tests confirm it). CI gains a step that fails on `waitUntilCompleted`/`waitUntilScheduled` in package or laboratory sources (none exist). Limits: simulator and Mac only, no physical device or Instruments trace; a completed but not yet presented frame can make the next drawable wait up to one display refresh; an ancestor's `isHidden` is noticed at the next request, layout pass, or draw; iPad Stage Manager/windowed side-by-side scenes were not exercised (the simulator ran in full-screen apps mode, where the second scene replaces the first).

**Evidence (2026-11-09, review fix):** Two scheduling defects were confirmed and fixed. (1) `FrameLedger.beginDraw()` granted a draw with nothing pending, so a duplicate wake-up (a completion racing a request's own display pass) or a pass UIKit started itself produced and submitted an unrequested frame; it now returns `.nothingPending` and `GlassSurfaceView` draws nothing and calls no producer. A hidden pass with nothing pending also no longer invents a pending frame. (2) A request or completion during a draw that then skipped could be stranded (pending, visible, nothing in flight, nothing scheduled); `drawSkipped()` now returns whether the pending frame can be drawn, the surface ends the draw before calling `renderObserver`, and display passes asked for from inside a draw are requested after it returns. Tests: `FrameLedgerTests` adds `A display pass with nothing requested draws nothing`, `A completion racing a scheduled pass adds no frame`, `A request during a skipped draw is woken by the skip` (bounds 1 and 2, the reported sequence), and `A skip with the request still unable to draw leaves the wake-up to visibility`; the seeded random test now runs 20,000 steps with requests, completions, and visibility changes arriving in the middle of a draw, checks that every draw answers a request and that a pending frame on a visible host always has a pass scheduled or a committed frame in flight once no draw is in progress; `GlassSurfaceViewTests.A display pass with nothing requested produces and submits nothing`. Mutations: removing the `.nothingPending` guard failed 4 `FrameLedgerTests`; making `drawSkipped()` return `false` failed the skip test (both bounds) and the random test (bounds 1 and 2). Both were reverted. Xcode MCP `RunSomeTests`, package scheme: "My Mac" `FrameLedgerTests`, `FrameSchedulerTests`, `FrameLifecycleTests` pass; "iPhone 18 Pro" simulator `GlassSurfaceViewTests`, `SurfaceLifecycleTests`, `DocumentationExampleTests`, `AccessibilityPolicyTests`, `FrameLedgerTests` pass (73 tests).

**Correction (2026-11-09):** The evidence above said `GlassSurfaceView` "releases drawables when it stops being visible". It called `MTKView.releaseDrawables()`, which (Xcode documentation search) releases only `depthStencilTexture` and `multisampleColorTexture`; the surface creates neither, so the call freed nothing and the `CAMetalLayer` kept its drawable pool while hidden. The no-op call is removed, and the class documentation and the architecture's "Hidden resources" row now say that hiding frees nothing in GlassWeave: the layer keeps up to three drawables at the drawable size, and the app frees its own memory from `visibilityHandler` (the laboratory trims its source pool). Freeing the layer's drawables while hidden is not implemented or measured. The checked items are unaffected: the in-flight and texture bounds and the hidden-period submission counts never depended on that call. `GlassSurfaceViewTests` and `SurfaceLifecycleTests` pass on the "iPhone 18 Pro" simulator (Xcode MCP `RunSomeTests`, 21 tests).

**Verification:** Swift Testing for scheduler/lease transitions; Xcode run with Metal API Validation; stress 100 show/hide and resize cycles while recording allocation and submission counts. Include two hosts with independent visibility and, where supported, two scenes with different active states.

**Likely files:** `Sources/GlassWeave/FrameScheduler.swift`, `Sources/GlassWeave/FrameResources.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Tests/GlassWeaveTests/FrameLifecycleTests.swift`.

## GW-08: Preserve accessible native controls

**Description:** Define accessible rendering behavior and verify the first panel with real native content.

**Dependencies:** GW-06. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] VoiceOver reaches and activates the native controls once each; decorative surfaces introduce no duplicate accessibility elements.
- [x] Large Dynamic Type preserves content and target geometry; light/dark appearances keep the reference text readable.
- [x] Reduce Motion removes nonessential motion and Reduce Transparency selects a documented opaque/legible surface while retaining the control's behavior.

**Evidence (2026-11-08):** `Sources/GlassWeaveUIKit/GlassAccessibilityPolicy.swift` adds `GlassAccessibilitySettings` (Reduce Transparency, Reduce Motion; `.system` from `UIAccessibility`) and `GlassAccessibilityPolicy` (under Reduce Transparency the panel keeps frame and corner radius and becomes opaque `secondarySystemBackground` resolved for the traits, with no refraction or edge illumination; Reduce Motion leaves the motionless panel unchanged and is reported to the app). `GlassSurfaceView` hides its accessibility elements, reads settings from the system (updated on the change notifications) or from `accessibilitySettingsSource = .fixed(…)`, re-resolves the opaque color on appearance and contrast changes, and separates `panel` (the app's) from `presentedPanel` (drawn). `Sources/GlassWeave/GlassLegibility.swift` adds the core legibility rule for see-through glass: WCAG relative luminance and contrast, the interior luminance range over any background, `worstCaseContrast(againstTextLuminance:)`, and `minimumStrength(forContrast:againstTextLuminance:)`. The laboratory uses the rule to raise its tint (light 0.45, which already guarantees ≥ 9.6:1; dark 0.83, ≥ 4.6:1; 7:1 targets with Increase Contrast give 0.91), follows the surface's settings for its clock, takes fixed settings from launch arguments, scrolls the stage's native content when it does not fit (the glass panel follows; at accessibility sizes the panel takes the full width, its title wraps instead of truncating, and control rows stack), keeps panel text out of the 22-point rim, and prints the panel's surface, tint, guaranteed contrast, and settings. The full matrix is in [the validation protocol](../docs/validation.md#recorded-accessibility-matrix-gw-08-2026-11-08). Xcode MCP `RunAllTests`, package scheme `GlassWeave` with `MTL_DEBUG_LAYER=1`: "My Mac" 109 test functions passed; "iPhone 18 Pro" simulator 134 passed (109 core + 25 UIKit), from `xcresulttool`. `GlassLegibilityTests`: WCAG values (21:1, the 4.54:1 #767676), the worst case equals a brute-force minimum over 1,001 backgrounds, minimum strengths reach 4.5:1 and 7:1 and 0.001 less does not, impossible cases return `nil`, and a GPU render of the lab tints over black and white halves keeps the ratio at every sampled interior pixel. `AccessibilityPolicyTests` (simulator): opaque panel keeps its shape; label text on it ≥ 7:1 in light/dark × normal/high contrast; fixed settings are applied, reported, and drawn; trait changes re-resolve the color; a new panel keeps the policy; the surface and its Metal view contribute no element even if a subview claims to be one, and hit tests reach the control above. Lab scheme `GlassWeaveLab`, `RunAllTests`: "iPhone 18 Pro" 15 passed, 1 skipped (the iPad-only two-scene test); "iPad Pro 13-inch (M5)" 15 passed, 1 skipped (the system-dark audit: neither `XCUIDevice.appearance` nor `simctl ui appearance dark` reached any app on that simulator). `AccessibilityUITests`: `testNativeControlsAreSingleElementsInReadingOrderAndActivate` (one labeled button element per control, the surface absent from the accessibility tree, stack order title → button → caption → button, each control activates once), `testAccessibilityAuditInLight`/`InDark` (`performAccessibilityAudit`, every audit type, no issue; dark on iPhone only), `testLargestTextSizeKeepsContentAndTargets` (`AccessibilityXXXL` portrait and landscape: whole title inside the panel, buttons ≥ 44 pt and > 60 pt tall, both act after scrolling, `.dynamicType`/`.textClipped` audits clean), `testReduceMotionStopsTheMovingSource` (t stays 0.00 s, no submission over 2 s, Pause/Resume cannot restart it, controls act), `testReduceTransparencyDrawsTheDocumentedOpaqueSurface` (light and dark: every interior sample within 3 steps of (242, 242, 247) or (28, 28, 30) over three frames while the source moves; controls act), `testPanelTextKeepsContrastOverTheMovingSource` (350 samples over 5 frames; worst 9.78:1 light and 5.65:1 dark on iPhone, 9.78:1 and 8.12:1 on iPad). A deliberate mutation (ignoring Reduce Transparency in the policy) failed the Reduce Transparency UI test and was reverted. Real system settings on the iPhone simulator (by hand): Reduce Motion and Reduce Transparency on at launch gave a paused clock and an opaque panel ([capture](../docs/evidence/captures/gw-08-reduce-transparency-and-motion-dark-iphone18pro-sim.png)); turning them off and on while running switched the panel and clock live through the change notifications; Increase Contrast raised the dark tint to 0.91 (≥ 7.1:1). Captures: [largest text](../docs/evidence/captures/gw-08-largest-text-iphone18pro-sim.png), [dark glass](../docs/evidence/captures/gw-08-dark-glass-iphone18pro-sim.png). `CustomSurfaceUITests` now screenshot the stage, which the surface fills exactly, because the surface is no longer in the accessibility tree; `CoexistenceUITests` waits for the rotation to settle before reading the frame-ID strip and attaches the screenshot on failure. Open: the first item needs a live VoiceOver pass (navigation order and double-tap activation), which the iOS Simulator cannot run; everything short of that (single labeled elements, the decorative surface hidden, order, touch activation, the audits) passes, and the pass belongs with the GW-09 device run. Limits: simulator only; contrast is guaranteed by the rule for the panel's flat interior and measured from screenshots, not on a device display; the iPad dark checks use the window override.

**Evidence (2026-11-09, review fix):** The legibility functions trapped on a tint strength above 1 or NaN (`interiorLuminanceRange` formed a reversed `ClosedRange`). They now follow the `GlassParameters` normalization rule: components, strength, and luminances outside 0...1 are clamped as the renderer clamps a tint, so the answer describes the drawn panel, and a non-finite input stops with a precondition message naming it. New `GlassLegibilityTests`: `Out-of-range tints are judged as the renderer clamps them` (five tints compared with the renderer's own normalization), `A strength just above one answers like full strength` (strength 1.01, the reported crash), `Luminances outside zero to one are clamped`, and on macOS an exit test `A non-finite input stops with a message that names it` (NaN strength, infinite red, NaN text luminance, NaN ratio; each child process fails with its message). Xcode MCP `RunSomeTests`, package scheme on "My Mac" and the "iPhone 18 Pro" simulator: all legibility tests pass (the exit test exists only on macOS; Swift Testing has no exit tests on iOS).

**Verification:** Load the matching Apple accessibility skills; inspect and interact through Xcode's device tools; record the accessibility matrix in the validation report.

**Likely files:** `Sources/GlassWeaveUIKit/GlassAccessibilityPolicy.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Examples/GlassWeaveLab/LabViewController.swift`, `Tests/GlassWeaveUIKitTests/AccessibilityPolicyTests.swift`.

## GW-09: Qualify the first milestone on devices

**Description:** Measure the fixed coexistence workload, identify the actual bottleneck, and record whether the provisional budgets are met.

**Dependencies:** GW-07, GW-08. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] The report names hardware, OS, build, render size, refresh setting, workload, and measurement tools; it includes native-only and custom-panel comparisons.
- [ ] The five-minute sustained run, idle run, and lifecycle stress run have CPU/GPU, frame pacing, memory, and thermal/energy observations.
- [ ] Every provisional target has a measured pass/fail result or an explicit measurement limitation; a failed target blocks an unqualified milestone pass.

**Evidence (2026-11-08):** No physical device was measured, so every acceptance item stays open; the session was directed to the Mac and no baseline or modern iPhone was selected. What exists is the instrument and Mac/simulator results, all in [the Milestone 1 report](../docs/evidence/milestone-1.md), which states plainly that every device target is not measured and why. Implemented: `Examples/GlassWeaveLab/GlassWeaveLab/BenchmarkScenario.swift` (scenario v1; `-lab.benchmark baseline|native|custom|idle|lifecycle` selects the protocol's five modes; `-lab.benchmark.seed`, default `0x67570009`, orders mode 5's 100 hide/show and resize cycles; the frame-ID strip starts off; Reset restarts the metrics window; Settle and measure reports settled allocations; diagnostics refresh once a second from a timer) and `Sources/GlassWeave/RenderMetrics.swift` (public, opt-in through `GlassRenderer.metrics`: per committed command buffer the CPU time of GlassWeave's encoding, the app's producer, and target acquisition, `gpuStartTime`/`gpuEndTime`, status, and `currentAllocatedSize`, `nil` where the device reports none; counts of draws, drawn frames, skips, rejected and declined (dropped) productions, committed/completed/failed command buffers; a bounded sample window; nearest-rank p50/p95/p99/max). Coalesced and at-bound counts remain in `FrameStatistics`. New test target `GlassWeaveCharacterizationTests` (public and package API only) renders the workload offscreen with the laboratory's shader (a copy CI keeps identical), and a new shared scheme `GlassWeaveCharacterization` runs it in Release without Metal API Validation. Xcode MCP `RunAllTests`, scheme `GlassWeaveCharacterization`, My Mac (Apple M5, AC power, thermal nominal before and after, validation off as the queue class `AGXG17GFamilyCommandQueue` shows): three interleaved 60 s runs per mode at 60 Hz, 1206 × 2622 px, 10,800 frames per mode, all drawn, 0 dropped, 0 failed; pooled GPU p50/p95/p99 0.712/0.796/0.849 ms (background) and 0.760/0.875/1.011 ms (panel), comparative p95 difference +0.132/+0.070/+0.063 ms per run and +0.079 ms pooled; GlassWeave CPU encode p95 0.138 and 0.157 ms; `currentAllocatedSize` 62.5 MiB in both modes (the panel adds no allocation); 0 idle submissions in 5 s; 0 B change after 100 lifecycle cycles. These are Mac characterization, not device evidence. Package scheme `GlassWeave` (`MTL_DEBUG_LAYER=1`): My Mac 117 test functions passed (116 core including 7 new `RenderMetricsTests`, 1 characterization), iPhone 18 Pro simulator 142 passed (116 core, 25 UIKit, 1 characterization), counts from `xcresulttool`. `RenderMetricsTests`: nearest-rank percentiles against the definition for 1 to 240 seeded values and exact ranks of 1...100, the window keeps the newest samples and counts all, summaries use drawn and completed frames, a measured renderer records CPU and GPU cost for five produced frames (GPU times required off the simulator), skips/declined/rejected/no-drawable paths counted, and reset ignores a command buffer held on an `MTLSharedEvent` across it. Deliberate mutations (floor instead of ceiling rank; recording samples from before a reset) failed these tests and were reverted. Lab scheme `GlassWeaveLab`: iPhone 18 Pro and iPad Pro 13-inch (M5) simulators each 18 passed, 1 skipped (as before). `BenchmarkUITests` on both: modes 1–3 show only their composition and record 578–615 frames in 10 s with 0 failed, 0 declined, 0 skipped; mode 4 submits nothing for 30 s; mode 5's 100 cycles plus 3 rotations and 3 background/foreground cycles end with the same 2 pooled textures and peak in flight ≤ 2 (simulator allocation sizes are zero, so bytes are not measured there). [Capture](../docs/evidence/captures/gw-09-benchmark-custom-iphone18pro-sim.png) (simulator, mode 3). Limits: no device, Instruments trace, presentation-interval record, main-thread trace, compilation trace, thermal/energy record, or iOS 26 runtime; the Mac's offscreen numbers exclude the system compositor and the native glass.

**Evidence (2026-11-09, review fix):** The Mac characterization's idle check could not fail: it slept 5 s with no display pass, and the offscreen stage submits only from ticks, resizes, and visibility changes, so "0 idle submissions" held by construction. The idle phase now first draws anything pending and waits for completion, then runs display passes at 60 Hz for 5 s with nothing requested (as UIKit or a late completion can start them) and requires 0 frames produced and 0 submitted, with at least half the nominal passes run. A deliberate mutation (removing the scheduler's `.nothingPending` guard) made it fail with 60 submissions and 60 productions in the 1 s functional pass, and was reverted. Xcode MCP `RunSomeTests`, package scheme on "My Mac": `CharacterizationTests` passes (60 idle passes, 0 submissions, 0 produced).

**Evidence (2026-11-09, review fix: scenario v2):** The protocol's workload is a full-screen background, but scenario v1 benchmark modes rendered only the stage above the controls (1206 × 1524 px on the iPhone 18 Pro simulator) while the Mac characterization rendered 1206 × 2622 px and claimed to mirror the laboratory. In scenario v2 the benchmark surface fills the screen (1206 × 2622 px on the iPhone 18 Pro simulator, 2064 × 2752 px on the iPad Pro 13-inch (M5) simulator), the controls sit above it on an opaque backdrop, and the native content stays above the controls ([capture](../docs/evidence/captures/gw-09-benchmark-custom-v2-iphone18pro-sim.png), simulator). The characterization keeps the 1206 × 2622 px target, moves to workload version 2, and is described as an approximation (centered panel, no native views or controls). Xcode MCP `RunAllTests`, scheme `GlassWeaveCharacterization` on My Mac (Release, validation off, AC power, thermal nominal before and after), three interleaved 60 s runs per mode: pooled GPU p50/p95/p99 0.704/0.804/0.881 ms (background) and 0.737/0.842/0.881 ms (panel), comparative p95 difference +0.103/+0.028/+0.001 ms per run and +0.037 ms pooled; encode p95 0.160 and 0.175 ms; 62.5 MiB peak in both modes; idle 300 display passes in 5 s with nothing requested, 0 produced, 0 submitted; 0 B change after 100 lifecycle cycles. Lab scheme `GlassWeaveLab`, `RunAllTests` at `9b2c0c4`: "iPhone 18 Pro" 18 passed, 1 skipped; "iPad Pro 13-inch (M5)" 18 passed, 1 skipped; `BenchmarkUITests` modes 1–3 recorded 598/599/592 (iPhone) and 589/589/583 (iPad) frames in 10 s with 0 failed, 0 declined, 0 skipped; mode 4 submitted nothing for 30 s; mode 5 ended with 2 pooled textures. Package scheme at `9b2c0c4` (`MTL_DEBUG_LAYER=1`): My Mac 126 test functions passed, iPhone 18 Pro simulator 155. The [Milestone 1 report](../docs/evidence/milestone-1.md) carries the full v2 numbers and marks the v1 results superseded. Every acceptance item stays open: no device was measured.

**Verification:** Follow [the validation recipe](../docs/validation.md) on the selected baseline and modern physical devices; preserve concise trace summaries and reproducible settings.

**Likely files:** `Examples/GlassWeaveLab/BenchmarkScenario.swift`, `Sources/GlassWeave/RenderMetrics.swift`, `docs/validation.md`, `docs/evidence/milestone-1.md`.

### Checkpoint C: first milestone

- [ ] GW-01 through GW-09 pass and the physical-device report is linked.
- [ ] Native/custom coexistence, interaction, accessibility, and sustained cost are demonstrated.
- [ ] The first milestone is qualified before the effects catalogue grows.

## GW-10: Package the limited v0.1 pre-alpha

**Description:** Review the demonstrated native/custom UIKit API and document the first deliberately small version. Effects and additional adapters remain later work.

**Dependencies:** GW-09. **Scope:** Medium, five files.

**Acceptance criteria:**
- [ ] Documentation covers one rounded custom panel, native mode, UIKit presentation, source ownership, lifecycle, failure behavior, accessibility, and measured device limitations; all shown examples compile.
- [x] A clean consumer resolves the candidate revision and exercises native and custom modes; public API names reflect demonstrated behavior, with no Frostfield library dependency.
- [x] Release notes state experimental API status and exclusions: no ripple, custom merging, enhanced-native effect, SwiftUI adapter, or external producer integration is required for v0.1.

**Evidence (2026-11-08):** Candidate revision `4767ed7` (DocC catalog and example tests); the following commit changes documentation only. Documentation: `Sources/GlassWeave/GlassWeave.docc/GlassWeave.md` covers native mode, one rounded custom panel over an app-owned producer, the UIKit host, source ownership, lifecycle, failure behavior, accessibility, measurement, and limitations; its five Swift examples are copied verbatim into `Tests/GlassWeaveTests/DocumentationExamples.swift` and `Tests/GlassWeaveUIKitTests/DocumentationExamples.swift`, compiled by the package build, and run by `DocumentationExampleTests` (native glass around an acting button with no renderer created; the `GlassStage` example producing and drawing three frames with its panel and deferring while hidden; a committed still upload presented and released; the legible tint reaching 4.5:1 and 7:1 in light/dark × normal/high contrast; the measuring example reporting the recorder's GPU p95). `scripts/check_doc_examples.py`, a new CI step, fails when the catalog and the copies differ (5 of 5 match). A one-off `xcodebuild docbuild` (iOS Simulator) built both catalogs with no documentation warnings after fixing the existing ones (parameter docs for `BackgroundFrame.init` and `FrameTexturePool.init`; cross-module symbol links in GlassWeaveUIKit comments). Xcode MCP `RunAllTests`, package scheme with `MTL_DEBUG_LAYER=1`: My Mac 118 test functions passed, iPhone 18 Pro simulator 147 (117 core, 29 UIKit, 1 characterization), from `xcresulttool`. The first item stays **open**: the documentation states that no device limitation has been measured, but "measured device limitations" needs the GW-09 device run; everything else in that item is done. Clean consumer (second item): a separate package outside the repository depended on GlassWeave by a `file://` git URL at revision `4767ed76bac268a97adfa0b194bd8469f221fce0`; SwiftPM cloned and pinned exactly that revision (one pin, no other package); opened as its own workspace and run with Xcode MCP `BuildProject`/`RunAllTests` (`MTL_DEBUG_LAYER=1`), its public-API-only tests passed 3/3 on the iPhone 18 Pro simulator (custom mode: the consumer's own producer and a fully tinted panel drawn offscreen and read back, background outside and tint inside within one step, one frame counted by `RenderMetrics`; native mode: `UIGlassEffect`, an acting button, no `MTKView`; the UIKit host accepts a producer and panel and defers while not in a window) and 1/1 on My Mac (the UIKit tests compile only with UIKit). API review from the DocC archive: 24 public types in `GlassWeave` and 4 in `GlassWeaveUIKit`, each exercised by tests of the behavior its name states, none a placeholder; scheduler types and commit hooks are `package` access; `BackgroundRenderer` staying public and `OrientationPattern` as a public test pattern are recorded as choices to revisit. Dependency graph: `swift package show-dependencies` reports none; Frostfield appears in neither the manifest nor the sources. Release notes: [pre-alpha notes](../docs/evidence/pre-alpha.md) state the experimental API status, the exclusions (ripple, custom merging, enhanced-native, SwiftUI, external producers, Metal 4, and more), the limitations, the consumer check, the API inventory, and the graph. Also updated: [README](../README.md) (what exists versus planned), [CHANGELOG](../CHANGELOG.md), and the [support matrix](../docs/support.md) of tested and untested combinations. No tag, release, or push. Limits: the lab UI tests were run at the GW-09 commit `120bafc` (18 passed, 1 skipped on each simulator); the candidate changes package sources only in documentation comments.

**Evidence (2026-11-09, review fixes):** The branch's commits were rewritten on 2026-11-09 to the repository's noreply author identity (trees unchanged), so the hashes above changed: `4767ed7` is now `6c2ac6a`, `120bafc` is `afb66d6`, `d4f6666` is `3303967`, and `afd61b7` is `407ad07`. After the review fixes the candidate revision is `9b2c0c4` ([pre-alpha notes](../docs/evidence/pre-alpha.md)). The clean consumer is now in the repository (`Examples/ConsumerCheck`, public API only, GlassWeave by URL and revision from the environment) with `scripts/consumer_check.sh`, which copies it to a temporary directory, requires exactly one pin at the requested revision, and runs its tests with Metal API Validation (the custom-mode test checks for `MTLDebugCommandQueue`); CI runs it on macOS. At `9b2c0c4` it pinned exactly that revision and passed 1/1 on My Mac and 3/3 on the "iPhone 18 Pro" simulator (`xcodebuild test` from the script, a terminal check that keeps the combined workspace the only one open in Xcode); it also passed from a shallow clone in a directory with another name. The release notes no longer present the 26.0 floors as tested or iPad presentation as supported (`CHANGELOG.md`, pre-alpha "What v0.1 is" and limitations, including the main-thread drawable wait reopened in GW-04). The first item stays open as before.

**Verification:** Xcode builds/tests and a clean-consumer run; exported API and dependency-graph review; link the GW-09 evidence. A future tag/public release requires authorization in that implementation task and a complete validation record; this planning task publishes no versioned library release.

**Likely files:** `README.md`, `CHANGELOG.md`, `Sources/GlassWeave/GlassWeave.docc/GlassWeave.md`, `docs/support.md`, `docs/evidence/pre-alpha.md`.

### Checkpoint D: v0.1 candidate

- [x] The clean-consumer check and support matrix cover the limited UIKit API.
- [ ] The implementation is ready for an authorized pre-alpha release; later tasks remain separate.

Checkpoint D evidence (2026-11-08): the consumer check exercises `NativeGlassView` and `GlassSurfaceView`'s public API, and [the support matrix](../docs/support.md#support-matrix) lists each UIKit API with what checks it and what does not. The second item stays open: GW-09's physical-device qualification and GW-10's first item are outstanding, so the candidate is not ready for a release.

## GW-11: Decide the Metal submission backend

**Description:** Run a narrow Metal 4 experiment against the existing conventional Metal path, with identical shaders and workload.

**Dependencies:** GW-10. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] OS and GPU capability checks choose a supported experiment path; unsupported devices continue through a defined conventional or fallback path.
- [ ] Both paths render the same reference cases and report compilation, CPU encoding, GPU, memory, and steady-state behavior.
- [ ] A decision record chooses the shipped backend/support matrix and explains the measured tradeoff; retaining two backends is justified explicitly.

**Verification:** Xcode builds and Metal validation on both capability classes where available; compare physical traces and reference captures rather than API novelty.

**Likely files:** `Sources/GlassWeave/Metal4Renderer.swift`, `Sources/GlassWeave/RenderCapabilities.swift`, `Examples/GlassWeaveLab/BenchmarkScenario.swift`, `docs/decisions/metal-backend.md`.

## GW-12: Add a touch-driven ripple

**Description:** Add one bounded interactive deformation without changing native control ownership.

**Dependencies:** GW-10. **Scope:** Medium, five files.

**Acceptance criteria:**
- [ ] A touch drives a deterministic ripple with a finite duration and a bounded optical displacement.
- [ ] Gesture observation preserves the native button's tap/cancellation behavior and respects Reduce Motion.
- [ ] The effect settles back to on-demand rendering and has measured incremental CPU/GPU cost.

**Verification:** Swift Testing with a controlled clock; device tap/drag/cancel checks; compare captures and metrics with the GW-09 baseline.

**Likely files:** `Sources/GlassWeave/RippleState.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Tests/GlassWeaveTests/RippleStateTests.swift`, `Examples/GlassWeaveLab/LabViewController.swift`.

## GW-13: Merge two custom surfaces

**Description:** Implement a small two-surface morphing example where GlassWeave owns both optical surfaces.

**Dependencies:** GW-12. **Scope:** Medium, five files.

**Acceptance criteria:**
- [ ] Two custom shapes merge and separate continuously under deterministic progress with no seams at their intersection.
- [ ] Native content follows a documented layout/hit-test policy throughout the transition.
- [ ] The example clearly identifies custom/custom merging; the native reference stays a separate material system.

**Verification:** Shape-field tests, captured progress samples, interrupt/reverse checks on device, and incremental performance comparison.

**Likely files:** `Sources/GlassWeave/SurfaceField.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Sources/GlassWeaveUIKit/SurfaceTransition.swift`, `Tests/GlassWeaveTests/SurfaceFieldTests.swift`, `Examples/GlassWeaveLab/MergingViewController.swift`.

### Checkpoint E: controlled effects

- [ ] The backend choice is documented and custom effects preserve the frame contract.
- [ ] No effect regresses lifecycle or accessibility guarantees.

## GW-14: Compose one enhanced-native effect

**Description:** Add a restrained edge illumination effect around genuine native glass, with composition cost measured separately.

**Dependencies:** GW-10. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] Apple's glass remains responsible for the material; GlassWeave's added illumination is a separately composited effect.
- [ ] Native control interaction, clipping, and layout remain correct during the effect.
- [ ] Disabled/settled behavior incurs no continuous custom rendering, and the incremental cost is recorded.

**Pulled forward (2026-11-09):** The user-requested glow work (see [Glow effects](#glow-effects-user-requested-2026-11-09)) pulls this task forward and extends it with color. `UIGlassEffect` offers a tint for the whole material and interactivity, but no way to recolor its edge separately or to make its middle transparent, so the colored rim and halo are drawn around the native glass with Core Animation, using the GW-17 color model; [the glow design](../docs/glow.md#enhanced-native-glow-gw-14) has the details. The criteria above stay; these are added:
- [ ] A rim and a halo in any SDR color, or an angular gradient of up to four stops (the `GlassGlow` color model), surround a genuine `UIGlassEffect` view; the glass interior is still Apple's material, and its own `tintColor` stays the app's choice.
- [ ] The rim and halo follow the native view's corner configuration and frame through layout, rotation, and Dynamic Type changes, and add no accessibility element or touch target.
- [ ] Reduce Transparency, Increase Contrast, and Reduce Motion follow the mapping in the glow design; a pulse runs only while requested and visible, and a settled glow runs no animation.

**Verification:** Device comparison with native-only mode; appearance/rotation checks; submission and GPU metrics under the GW-09 workload.

**Likely files:** `Sources/GlassWeaveUIKit/EnhancedNativeGlassView.swift`, `Sources/GlassWeave/EdgeIllumination.swift`, `Examples/GlassWeaveLab/EnhancedNativeViewController.swift`, `docs/evidence/enhanced-native.md`.

## GW-15: Add the SwiftUI presentation adapter

**Description:** Expose the existing native presentation through a small optional SwiftUI product, without moving frame simulation into SwiftUI updates.

**Dependencies:** GW-10. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] A SwiftUI example updates low-frequency configuration without recreating the renderer or its resources every update.
- [ ] Appear/disappear, identity change, and teardown preserve the same lifecycle and accessibility behavior as UIKit.
- [ ] The core and UIKit products remain usable without importing the SwiftUI adapter.

**Verification:** Load current SwiftUI data-flow guidance; Xcode build and preview/run; count renderer lifetime events during repeated state updates and navigation.

**Likely files:** `Package.swift`, `Sources/GlassWeaveSwiftUI/GlassSurface.swift`, `Examples/GlassWeaveLab/SwiftUIExample.swift`, `Tests/GlassWeaveSwiftUITests/AdapterLifecycleTests.swift`.

## GW-16: Prove external texture interoperability

**Description:** Consume a texture produced by Frostfield's offscreen proof through the documented frame contract, in an optional example app.

**Dependencies:** GW-11; Frostfield offscreen texture proof. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] A same-`MTLDevice` source carries matching frame, UV, color/alpha, readiness, and completion information; producer reuse waits for consumption.
- [ ] The example proves synchronization with a changing frame-ID pattern; missing/stale sources exercise the documented fallback.
- [ ] Only the example depends on both packages; GlassWeave's library manifest has no scene-engine dependency or package cycle.

**Verification:** Metal validation and frame capture on device; producer-consumer stress run; inspect the resolved dependency graph. Defer cross-queue import unless an explicit event protocol is implemented and tested.

**Likely files:** `Examples/InteropLab/InteropLab.xcodeproj/project.pbxproj`, `Examples/InteropLab/InteropViewController.swift`, `Sources/GlassWeave/BackgroundFrame.swift`, `docs/evidence/texture-interop.md`.

### Checkpoint F: broader adoption

- [ ] UIKit and SwiftUI consumers retain native control behavior.
- [ ] Texture interoperability introduces no library dependency on Frostfield scenes.
- [ ] Later features have their own measured costs and documented support, independent of v0.1 evidence.

## Glow effects (user-requested, 2026-11-09)

The user asked for glass that takes tints and glows at its edges in any color while the middle stays see-through or fades. These tasks are experimental and post-v0.1: they do not change the v0.1 candidate's scope, and no simulator or Mac result here is device evidence. The design, units, and accessibility mapping are in [the glow design](../docs/glow.md). The demos are original; no third-party artwork, icon, name, text, or layout is copied.

## GW-17: Colored rim, inner glow, and center fade (custom mode)

**Description:** Give a custom panel a glow in any SDR color or an angular gradient of up to four stops: a bright rim at the outline, an inner glow that fades toward the middle, and an optional center fill whose opacity sets how see-through the middle stays, lit from a chosen direction.

**Dependencies:** GW-05 (panel), GW-08 (accessibility policy). Post-v0.1; it does not wait for GW-09's device run. **Scope:** Medium, six files plus tests.

**Acceptance criteria:**
- [ ] `GlassParameters.glow` (`GlassGlow`, default `.none`) documents the unit, range, and default of every field (rim width, softness, and intensity; inner glow radius and intensity; center opacity; light angle and directionality; color stops) and follows the normalization rule: a non-finite value is rejected with an error naming its field, finite out-of-range values are clamped, angles are reduced modulo 360°, at most four stops are kept, and `GlassRenderer.panel` reports the glow actually drawn.
- [ ] Any SDR rim color, and each stop of a four-stop angular gradient at its documented angle, lands on the rim with the requested color within the documented tolerance (offscreen readback for several colors), blended in linear light, with an ordered dither on soft glow and no NaN or infinite output.
- [ ] With center opacity 0, every pixel deeper than the rim and the inner glow equals the glow-off output exactly; rim width, softness, and intensity, the inner glow radius, the light angle, and directionality match the CPU model and their documented behavior (readback); no pixel outside the outline's antialiasing band changes.
- [ ] Default parameters render byte-identical output to the pre-glow (GW-05) shader, kept as a frozen copy in the tests; the extended GPU record has C, MSL, and Swift layout checks and a distinctive-value GPU round trip.
- [ ] Reduce Transparency presents an opaque, legible body with at most a thin uniform rim; Increase Contrast removes the inner glow and center fill, so the GW-08 legibility rule still holds for text in the interior (UIKit tests); a laboratory launch argument shows a colored rim on the custom panel (simulator capture).

**Verification:** Swift Testing with offscreen render and readback on My Mac (Apple M5) under Metal API Validation, compared with a CPU model; a deliberate mutation per key test, reverted; UIKit tests on the iPhone 18 Pro simulator; a simulator capture of the laboratory panel, inspected.

**Likely files:** `Sources/GlassWeave/GlassGlow.swift`, `Sources/GlassWeave/GlassParameters.swift`, `Sources/GlassWeave/GlassPanelGeometry.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Sources/GlassWeaveShaderTypes/include/GlassWeaveShaderTypes.h`, `Sources/GlassWeaveUIKit/GlassAccessibilityPolicy.swift`, `Tests/GlassWeaveTests/GlassGlowTests.swift`, `Examples/GlassWeaveLab/GlassWeaveLab/LabViewController.swift`.

## GW-18: Outer halo and pulse (custom mode)

**Description:** Let the glow spill outside the shape as a soft halo within the surface, and let rim, inner glow, and halo pulse from one shared effect clock that runs only while something animates.

**Dependencies:** GW-17, GW-07 (scheduling). **Scope:** Medium, five files plus tests.

**Acceptance criteria:**
- [ ] A halo in the glow colors extends outside the outline by a documented radius and falloff, shaped by the light direction, and is composited in linear light over the background inside the surface; pixels beyond the halo are unchanged, and a halo of radius zero leaves the GW-17 output byte-identical (readback).
- [ ] A pulse modulates the glow with a documented period and depth from one shared effect clock; the surface requests frames only while a pulse runs and the surface is visible, and none when the pulse is removed, while hidden or backgrounded, or under Reduce Motion, which shows a steady glow at the documented level (submission counts while pulsing versus idle).
- [ ] The in-flight bound and on-demand policy are unchanged while pulsing (peak in flight at most two, coalesced ticks counted, `FrameLedgerTests` unchanged); Reduce Transparency removes the halo, and Increase Contrast keeps text legible.

**Verification:** GPU readback on My Mac; UIKit scheduling tests with a controlled clock on the iPhone 18 Pro simulator; a laboratory UI test counting submissions while pulsing, settled, hidden, and under Reduce Motion; `RenderMetrics` GPU time against the GW-17 panel on My Mac (characterization, not device evidence).

**Likely files:** `Sources/GlassWeave/GlassGlow.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Tests/GlassWeaveUIKitTests/GlowAnimationTests.swift`.

## GW-19: Animated interiors (custom mode)

**Description:** Add three procedural interiors that animate inside the glass in the glow colors: energy filaments, radial rays, and rising embers.

**Dependencies:** GW-18 (shared clock). **Scope:** Medium, four files plus tests.

**Acceptance criteria:**
- [ ] Energy filaments, radial rays, and rising embers draw only inside the outline, in the glow colors, under the documented center fade, as deterministic functions of the effect time and a seed (the same time and seed give identical bytes; different times differ).
- [ ] Interiors animate on the GW-18 clock and frame policy: frames only while animating and visible, none when settled or hidden, and a documented still frame under Reduce Motion (submission counts).
- [ ] Cost is bounded (fixed loop counts, no texture reads beyond the source) and measured with `RenderMetrics` against the GW-17 panel on My Mac; Reduce Transparency and Increase Contrast remove the interiors behind text.

**Verification:** GPU readback and determinism tests on My Mac; scheduling tests on the iPhone 18 Pro simulator; captures inspected for seams, banding, and clipping.

**Likely files:** `Sources/GlassWeave/GlassGlow.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Tests/GlassWeaveTests/GlowInteriorTests.swift`, `docs/glow.md`.

## GW-20: Glow gallery in the laboratory

**Description:** A laboratory screen of original demos built from GW-14 and GW-17 to GW-19: a glowing light/dark theme toggle, three element capsules, and an energy-orb button, all with native controls.

**Dependencies:** GW-14, GW-17, GW-18, GW-19, GW-08. **Scope:** Medium, four files plus UI tests.

**Acceptance criteria:**
- [ ] The gallery shows original designs: a theme toggle with a soft glass knob, a warm top rim light, a halo, and a smooth transition between themes; three element capsules with their own edge colors, where the selected one brightens with a fill, a bloom, and its animated interior over a faint floor reflection; and an energy-orb button with filaments, a pulsing glow, and a bright rim on a dark bar.
- [ ] Every control is a native UIKit control with a VoiceOver label, value, and traits; the decorative surface adds no element; the accessibility audit passes in light and dark; the largest text size keeps content and targets; Reduce Motion, Reduce Transparency, and Increase Contrast follow the glow design.
- [ ] The shapes are drawn as the design specifies (one surface, several panels in one pass), with halos unclipped; the screen submits nothing when settled, hidden, or backgrounded; captures on the iPhone 18 Pro simulator are inspected and committed.

**Verification:** Laboratory UI tests (interaction, audits, submission counts) on the iPhone 18 Pro simulator; simulator captures; a live VoiceOver pass and device presentation stay open until a device run.

**Likely files:** `Examples/GlassWeaveLab/GlassWeaveLab/GlowGalleryViewController.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Examples/GlassWeaveLab/GlassWeaveLabUITests/GlowGalleryUITests.swift`, `docs/evidence/captures/`.
