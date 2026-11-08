# GlassWeave task checklist

All tasks below are planned. The repository currently contains documentation only: no package manifest, source code, tests, or CI implementation. Claude should execute GW-01 first. Check an acceptance item only after its evidence exists. File paths are proposed implementation locations.

Use the native Xcode MCP tools for project edits, builds, tests, diagnostics, and device interaction when working in this environment, after loading the relevant Apple skills. Add meaningful Swift Testing coverage with the first testable behavior. CI can use equivalent Xcode command-line build and test actions.

**v0.1 scope:** GW-01 through GW-10. GW-11 through GW-16 are later work and must not delay the first useful UIKit package. See [the implementation plan](plan.md) and [validation protocol](../docs/validation.md).

## GW-01: Create the package baseline

**Description:** Turn this planning repository into a minimal Swift package and record the initial platform/capability policy before implementing a renderer.

**Dependencies:** None. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] A package using Swift tools 6.2 and Swift 6 language mode exposes the `GlassWeave` product with planned iOS/iPadOS 26 and macOS 26 minimums; core compilation does not import UIKit or SwiftUI.
- [ ] Xcode builds the package for macOS and an iOS simulator destination, and CI repeats the package build without account credentials.
- [ ] The support note distinguishes OS availability from Metal GPU capabilities and macOS core compilation from a promised macOS UI adapter.

**Verification:** Use Xcode documentation search to confirm the available SDK and capability APIs; build through Xcode MCP and inspect diagnostics. Record compiler, SDK, language mode, default actor isolation, and MSL dialect separately under `docs/language-strategy.md`. Do not add an always-passing test for an empty module; add tests when testable behavior first exists.

**Likely files:** `Package.swift`, `Sources/GlassWeave/GlassWeave.swift`, `.github/workflows/build.yml`, `docs/support.md`.

## GW-02: Open the UIKit laboratory

**Description:** Create a small iOS sample app that consumes the local package and provides one screen for all comparison modes.

**Dependencies:** GW-01. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] The app builds and launches on an iOS 26 simulator without a signing-account requirement.
- [ ] One screen has a labeled reference region, a custom region, and a repeatable reset action.
- [ ] The app uses a local package reference; the library has no dependency on the app.

**Verification:** Xcode `BuildProject` and `RunProject`; record a launch screenshot and confirm a fresh checkout resolves the local package.

**Likely files:** `Examples/GlassWeaveLab/GlassWeaveLab.xcodeproj/project.pbxproj`, `AppDelegate.swift`, `SceneDelegate.swift`, `LabViewController.swift` within the example app.

## GW-03: Establish the native-glass baseline

**Description:** Add the minimal native mode and put a genuine glass control over a simple moving laboratory background.

**Dependencies:** GW-02. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] The reference control uses public `UIGlassEffect` tint and interaction configuration and remains actionable.
- [ ] Its content is a native control; native-only use creates no GlassWeave Metal device, queue, or render loop.
- [ ] The laboratory can reset tint and enabled state for repeatable comparisons.

**Verification:** Build with Xcode; inspect interaction on a device or simulator; use allocation/signpost evidence to confirm no custom renderer is instantiated by the native-only path.

**Likely files:** `Package.swift`, `Sources/GlassWeaveUIKit/NativeGlassView.swift`, `Examples/GlassWeaveLab/LabViewController.swift`, `Tests/GlassWeaveUIKitTests/NativeGlassViewTests.swift`.

### Checkpoint A: laboratory

- [ ] GW-01 through GW-03 pass; native button behavior and reset are demonstrated.
- [ ] No custom optical or performance claim is made yet.

## GW-04: Display an explicit background source

**Description:** Establish the frame contract and display a deterministic app-owned texture through `MTKView` before introducing refraction.

**Dependencies:** GW-02. **Scope:** Medium, five files.

**Acceptance criteria:**
- [ ] A source frame carries texture identity, frame identity, extent, UV transform, color/alpha convention, readiness, and a completion lease.
- [ ] A test pattern stays correctly oriented and cropped through resize, rotation, safe-area changes, and display-scale changes derived from host bounds and traits.
- [ ] Missing source, zero-size surface, and unavailable drawable produce defined skip or fallback behavior without waiting on the main thread.

**Verification:** Xcode build; Swift Testing for coordinate mapping and lease state; Metal API Validation; device/simulator rotation with a four-corner test pattern. Add host layout assertions and a distinctive-value GPU round-trip for uploaded records; split shared-layout packaging into a prerequisite subtask if needed to keep this slice focused.

**Likely files:** `Sources/GlassWeave/BackgroundFrame.swift`, `Sources/GlassWeave/BackgroundRenderer.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Sources/GlassWeave/Shaders/Background.metal`, `Tests/GlassWeaveTests/BackgroundFrameTests.swift`.

## GW-05: Refract one rounded panel

**Description:** Add one custom surface over the supplied texture, with a small optical model and explicit parameters.

**Dependencies:** GW-04. **Scope:** Medium, five files.

**Acceptance criteria:**
- [ ] One rounded panel changes sampling according to bounded refraction and edge parameters; zero refraction reproduces the source within the documented render tolerance.
- [ ] The material handles its edge, texture bounds, and alpha convention without halos or uninitialized pixels.
- [ ] Invalid parameters are rejected or normalized by a documented rule; fixed inputs produce repeatable reference output.

**Verification:** Xcode build; parameter/shape math tests; capture fixed reference frames against checkerboard, gradients, and bright/dark edges; inspect a Metal frame capture.

**Likely files:** `Sources/GlassWeave/GlassParameters.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeave/Shaders/Glass.metal`, `Tests/GlassWeaveTests/GlassParametersTests.swift`, `Examples/GlassWeaveLab/LabViewController.swift`.

## GW-06: Prove moving coexistence

**Description:** Drive the source and custom panel with one deterministic clock while the native reference control remains visible alongside it.

**Dependencies:** GW-03, GW-05. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] The presented background and refracted sample refer to the same produced frame, including after resize and pause/resume.
- [ ] Native text and a native button above the custom panel remain readable, tappable, and correctly ordered with the native reference control.
- [ ] A short capture shows moving content, working controls, and native/custom coexistence; it makes no claim of optical merging between the two systems.

**Verification:** Xcode run on a physical device; record a frame-ID debug overlay and video; tap both controls during motion and check their action counts.

**Likely files:** `Examples/GlassWeaveLab/ProceduralBackground.swift`, `Examples/GlassWeaveLab/LabViewController.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`.

### Checkpoint B: optical proof

- [ ] GW-04 through GW-06 pass with the explicit source contract intact.
- [ ] A device capture demonstrates the central visual composition; sustained cost is still unqualified.

## GW-07: Bound the render lifecycle

**Description:** Make frame scheduling and resource retention correct for stationary, hidden, resized, and backgrounded surfaces.

**Dependencies:** GW-06. **Scope:** Medium, five files.

**Acceptance criteria:**
- [ ] A stationary source and stationary surface render on demand; each host follows its owning `UIWindowScene` and visibility, without pausing a visible surface in another scene.
- [ ] In-flight frames and reusable textures have a fixed bound; overload drops/coalesces obsolete work instead of building an unbounded queue.
- [ ] Resize and teardown retain every resource until its last GPU consumer completes, with no main-thread `waitUntilCompleted` path.

**Verification:** Swift Testing for scheduler/lease transitions; Xcode run with Metal API Validation; stress 100 show/hide and resize cycles while recording allocation and submission counts. Include two hosts with independent visibility and, where supported, two scenes with different active states.

**Likely files:** `Sources/GlassWeave/FrameScheduler.swift`, `Sources/GlassWeave/FrameResources.swift`, `Sources/GlassWeave/GlassRenderer.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Tests/GlassWeaveTests/FrameLifecycleTests.swift`.

## GW-08: Preserve accessible native controls

**Description:** Define accessible rendering behavior and verify the first panel with real native content.

**Dependencies:** GW-06. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] VoiceOver reaches and activates the native controls once each; decorative surfaces introduce no duplicate accessibility elements.
- [ ] Large Dynamic Type preserves content and target geometry; light/dark appearances keep the reference text readable.
- [ ] Reduce Motion removes nonessential motion and Reduce Transparency selects a documented opaque/legible surface while retaining the control's behavior.

**Verification:** Load the matching Apple accessibility skills; inspect and interact through Xcode's device tools; record the accessibility matrix in the validation report.

**Likely files:** `Sources/GlassWeaveUIKit/GlassAccessibilityPolicy.swift`, `Sources/GlassWeaveUIKit/GlassSurfaceView.swift`, `Examples/GlassWeaveLab/LabViewController.swift`, `Tests/GlassWeaveUIKitTests/AccessibilityPolicyTests.swift`.

## GW-09: Qualify the first milestone on devices

**Description:** Measure the fixed coexistence workload, identify the actual bottleneck, and record whether the provisional budgets are met.

**Dependencies:** GW-07, GW-08. **Scope:** Medium, four files.

**Acceptance criteria:**
- [ ] The report names hardware, OS, build, render size, refresh setting, workload, and measurement tools; it includes native-only and custom-panel comparisons.
- [ ] The five-minute sustained run, idle run, and lifecycle stress run have CPU/GPU, frame pacing, memory, and thermal/energy observations.
- [ ] Every provisional target has a measured pass/fail result or an explicit measurement limitation; a failed target blocks an unqualified milestone pass.

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
