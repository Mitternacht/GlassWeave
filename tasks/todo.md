# GlassWeave task checklist

All tasks below are planned. The repository currently contains documentation only: no package manifest, source code, tests, or CI implementation. Claude should execute GW-01 first. Check an acceptance item only after its evidence exists. File paths are proposed implementation locations.

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
- [x] Missing source, zero-size surface, and unavailable drawable produce defined skip or fallback behavior without waiting on the main thread.

**Evidence (2026-11-08):** The contract is implemented in `BackgroundFrame`, `BackgroundFrameLease`, `SourceUVTransform`, and `BackgroundRenderer` (mapped row by row in [the architecture](../docs/architecture.md#implemented-v01-contract-gw-04)); `GlassSurfaceView` in the new `GlassWeaveUIKit` product hosts the `MTKView`; `GlassWeaveShaderTypes` is the shared C layout target. Xcode MCP `RunAllTests`, package scheme `GlassWeave`, whose test action sets `MTL_DEBUG_LAYER=1` (a probe confirmed `MTLDebugDevice`/`MTLDebugCommandQueue` in the test process on both destinations): on "My Mac" (Apple M5) 47 test functions passed (`GlassWeaveTests`; the UIKit bundle is empty on macOS); on the "iPhone 18 Pro" simulator (iOS 27.2) 56 passed, adding `GlassWeaveUIKitTests`. Coverage: `SourceUVTransformTests` (aspect-fill crop, valid-rectangle crop, four rotations, vertical origin, display-scale independence, host rotation), `LeaseLedgerTests`/`LeaseCoreTests` (release exactly once after retire and all holds, outcome counts, dropped holds, 1,000 concurrent completions), `SourceFrameValidationTests` (format, device, queue, texture shape, valid rectangle, ordering, actionable messages), `BackgroundRendererTests` (offscreen render and readback: 1:1 sRGB round trip within one 8-bit step, eight orientation cases, quarter-turned source, centered crop, valid-rectangle clamp, defined skips, release after every submitted draw completes, rejected sources), `ShaderLayoutTests` (host size/alignment/offset/stride and a distinctive-value GPU round trip), and `GlassSurfaceViewTests` (pixel size from bounds × `displayScale` including a trait change, resize/rotation/fractional sizes, zero size never assigns an empty drawable, fallback without a source, decorative hit testing). Lab: scheme `GlassWeaveLab`, `RunAllTests` on "iPhone 18 Pro" (3x) and "iPad Pro 13-inch (M5)" (2x) simulators passed `CustomSurfaceUITests.testPatternStaysUprightThroughRotation` (reads element screenshots back and classifies all four corners after portrait, landscape left, landscape right, portrait) and `testResetPresentsANewFrameAndReleasesThePreviousOne`. Captures: [iPhone portrait](../docs/evidence/captures/gw-04-pattern-portrait-iphone18pro-sim.png), [iPhone landscape, asymmetric safe area](../docs/evidence/captures/gw-04-pattern-landscape-iphone18pro-sim.png), [iPad landscape](../docs/evidence/captures/gw-04-pattern-landscape-ipadpro13-sim.png). Limits: simulator and Mac only, no physical device; no Metal frame capture was recorded; `MTKView.currentDrawable` can still block up to the layer's one-second timeout if every drawable is in flight, so bounding in-flight frames remains part of GW-07. The updated CI commands (macOS `xcodebuild test` and generic iOS Simulator `build-for-testing` for both schemes) passed locally as a one-off check with a separate DerivedData folder; they have not run on GitHub yet.

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
- [ ] A clean consumer resolves the candidate revision and exercises native and custom modes; public API names reflect demonstrated behavior, with no Frostfield library dependency.
- [ ] Release notes state experimental API status and exclusions: no ripple, custom merging, enhanced-native effect, SwiftUI adapter, or external producer integration is required for v0.1.

**Verification:** Xcode builds/tests and a clean-consumer run; exported API and dependency-graph review; link the GW-09 evidence. A future tag/public release requires authorization in that implementation task and a complete validation record; this planning task publishes no versioned library release.

**Likely files:** `README.md`, `CHANGELOG.md`, `Sources/GlassWeave/GlassWeave.docc/GlassWeave.md`, `docs/support.md`, `docs/evidence/pre-alpha.md`.

### Checkpoint D: v0.1 candidate

- [ ] The clean-consumer check and support matrix cover the limited UIKit API.
- [ ] The implementation is ready for an authorized pre-alpha release; later tasks remain separate.

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
