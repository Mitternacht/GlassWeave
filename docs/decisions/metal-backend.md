# Decision: how the surface gets its drawable (GW-27 spike, input to GW-11)

Status: decided for GW-27 on 2026-11-09. Experimental; GW-11 may revisit.

## Question

`GlassSurfaceView` used to acquire its drawable on the main thread
(`MTKView.currentRenderPassDescriptor` calls `CAMetalLayer.nextDrawable()`),
which waits until a drawable is free or the layer's one-second timeout passes.
The proposal's preferred fix is a `CAMetalLayer` host driven by
`CAMetalDisplayLink`, whose update carries the drawable. Its fallback is a
render thread that calls `nextDrawable()`, which would make `FrameProducer`
`@Sendable` and off-main (a public API change).

## Spike (about 20 minutes)

A throwaway screen in the laboratory (iPhone 18 Pro simulator, iOS 27.2) and a
throwaway AppKit program (My Mac, macOS 27.2, Apple M3 Max, 120 Hz display)
each created a `CAMetalDisplayLink` on a `CAMetalLayer`, added it to the main
run loop, encoded a clear pass into the update's drawable and presented it with
`MTLCommandBuffer.present(_:)`. Neither program is in the repository; the
numbers are what they printed.

| Question | iOS 27.2 simulator | My Mac |
|---|---|---|
| Does the link deliver updates? | Yes: 45 updates in 1 s while running (callback interval min 15.5 / median 22.3 / max 33.4 ms; `targetPresentationTimestamp` delta min 16.7 / median 16.7 / max 33.3 ms; the simulator reports 60 fps) | Yes: 111 updates in 1 s (callback median 8.3 ms, target delta median 8.3 ms) |
| Is `present(_:)` accepted with the link's drawable? | Yes: 44 of 44 command buffers completed, no error | Yes: 111 of 111 completed, no error |
| Does pause stop updates? | Yes: 0 updates in 0.5 s | Yes: 0 updates in 0.5 s |
| Does resume give one update promptly? | Yes: resuming and pausing inside the first update gave exactly 1 update, after 0.4, 11.6 and 3.3 ms | Yes: exactly 1 update, after 8.4, 1.6 and 1.9 ms |
| Does the link follow its layer's display? | Not testable (one display); the link is created from the layer, which is the documented binding | Not testable (one display) |
| Is `nextDrawable()` allowed on the same layer? | **No.** The call raises `CAMetalLayerInvalidOperation`: "-nextDrawable should not be called when using CAMetalDisplayLink." It is an Objective-C exception, which Swift cannot catch: the app aborts. | Same API, not run |

Not measured: a 120 Hz iPhone, the effect of `CADisableMinimumFrameDurationOnPhone`
on a `CAMetalDisplayLink`, and what the link does when every drawable is
held (it cannot be provoked, see the last row).

## Decision

**Do not adopt `CAMetalDisplayLink` in this change. Take the drawable on a
background queue instead, and keep encoding and the producer on the main
thread.**

Why the link is not adopted now:

- The last row. A layer with a link attached cannot give a drawable to anyone
  else. `MTKView` itself, the package's synchronous test hook (`renderNow()`),
  the laboratory's drawable stress and any app code that asks the surface's
  layer for a drawable would crash instead of getting one. The surface's
  layer is reachable (`MTKView.layer`), so this is a trap for users of the
  hosted view, not only for tests.
- The signature test for this task needs to hold every drawable of the layer
  and watch the main thread. With a link attached that is impossible from
  outside, so the stall could not have been shown to fail first.
- Replacing `MTKView` by a bare layer host would also touch the shipped
  surface tests (`hostedMetalView` is an `MTKView` with `isPaused` and
  `enableSetNeedsDisplay`), which must keep passing unmodified.

What was built (the narrow form of the proposal's fallback):

- `DrawableAcquirer` (`GlassPresentationHost.swift`) calls `nextDrawable()` on
  a serial background queue and hands the drawable to the main actor. The
  surface starts an acquisition when a frame is pending, the surface is
  visible and below the in-flight bound, draws on the main thread when the
  drawable arrives, and releases a drawable it no longer wants. A timed-out
  wait is counted (`drawableTimeouts`) and retried after 100 ms.
- `FrameProducer` keeps its type and runs on the main thread. **No existing
  public API changes.** Added (experimental): `motionClass`,
  `beginInteraction()`, `endInteraction()`, `quality`, `qualityEnvironmentSource`
  and friends, `drawableTimeouts`, `GlassQuality`, `GlassMotionClass`,
  `GlassFrameRate`, `GlassQualityEnvironment`, `GlassQualityResolution`.
- Effect time still comes from the view's `UIUpdateLink` (`modelTime`); the
  `targetPresentationTimestamp` clock seam was not built.

## Open for GW-11

- A host that owns its layer exclusively (no `MTKView`, no other
  `nextDrawable()` caller) can use the link: the spike says the link, present,
  pause and resume all work. It would give effect time from
  `targetPresentationTimestamp` and remove the update link.
- Whether `presentsWithTransaction` is needed to keep native views and panels
  in step during a drag was not measured; the surface keeps the previous
  behavior (unsynchronized presentation). Recorded as open in `tasks/todo.md`.
- Device items: 120 Hz iPhone, the `CADisableMinimumFrameDurationOnPhone`
  effect, Instruments trace.

---

# Decision: the submission backend (GW-11)

Status: decided on 2026-11-09 after the one quiet timing run. **The
conventional path stays the only shipped backend.** Metal 4 did not meet the
margin the rule below set before the run: on the same workload its p95 was
higher than the conventional control's, on both cases and on both measures.
`Metal4Renderer` stays as a package-level characterization arm that no host
can reach. The last section has the numbers and the decision line.

## Question

Does submitting GlassWeave's glass workload through Metal 4 (`MTL4CommandQueue`,
command allocators, argument tables, residency sets) beat the conventional
`MTLCommandQueue` path by enough to justify a second backend, with identical
shaders, pipelines and records?

## What was built (package level, no public API commitment)

| File | What |
|---|---|
| `Sources/GlassWeave/Metal4Renderer.swift` | `Metal4Renderer` (the Metal 4 submission), `ConventionalPlanRenderer` (a control arm), `Metal4Staging` (the uniform ring), `Metal4PipelineCompileSample` and `Metal4Renderer.measurePipelineCompilation`. Compiled out for the iOS Simulator SDK. |
| `Sources/GlassWeave/GlassRenderer.swift` (an extension at the end) | `Metal4Plan`: the pipelines and `GWGlassUniforms` records the conventional `draw` would bind, so both paths encode the same records. The conventional `draw` is untouched. |
| `Sources/GlassWeave/RenderCapabilities.swift` | `SubmissionBackend` and `RenderCapabilities.submissionBackend(preferringMetal4:)`: `.metal4` only when asked for and `supportsMetal4`, otherwise `.conventional`, the defined fallback. |
| `Sources/GlassWeave/BackgroundRenderer.swift` | Two visibility changes only: the background pipeline is internal, `RendererCensus` is `package`. |
| `Tests/GlassWeaveCharacterizationTests/Metal4Comparison.swift`, `Metal4Stage.swift` | The agreement test and the comparison harness. No `@testable` import. |

How the Metal 4 path is chosen: a host asks `Metal4Renderer(renderer:)`, which
throws `Metal4RendererError.metal4Unavailable` unless
`RenderCapabilities.submissionBackend(preferringMetal4: true)` is `.metal4`.
Nothing in the package asks, so nothing in the package uses it. A draw the
experiment does not encode returns `Metal4SubmitOutcome.unsupportedPanels`
before anything is encoded and the caller draws conventionally.

What the Metal 4 path encodes: the producer pass (the laboratory's procedural
background) and then the background pass plus every panel that draws in the
`base`, `optics` or `lighting` variant, in one render pass. It uses the same
`MTLRenderPipelineState` objects the renderer built with
`MTLDevice.makeRenderPipelineState` (the Metal 4 render encoder accepts them),
so the shader library, the function constants and the pipelines are identical
by construction. Not encoded, and so declined to the conventional path: frost
(a compute pre-pass), grounding (pre-pass quads), freeform shapes, fills and
touch response (extra records). The experiment is offscreen: it presents no
drawable. On screen, Metal 4 presentation needs `MTL4CommandQueue.waitForDrawable`
and `signalDrawable` and the layer's residency set; none of that was built.

## Method

- **Workload:** the GW-09 workload, version 2: a 1206 x 2622 pixel target at
  scale 3, the laboratory's procedural background shader produced inside each
  frame's command buffer into a ring of three textures, then the background and
  one panel in one render pass, one request per 60 Hz tick, the surface's
  in-flight bound of two, three render targets cycling like drawables. Two
  cases: `panel` (the GW-09 panel, `base` variant) and `lens` (the same panel
  with a circular lens, thickness 28, dispersion 0.35: the `optics` variant).
- **Three arms**, each alone on the GPU in its own window: `conventional` (the
  shipped `GlassRenderer.drawProducing`, with its leases and validation),
  `conventionalRaw` (the control: the same plan and producer through
  conventional Metal without the lease machinery) and `metal4`. The decision
  comparison is `metal4` against `conventionalRaw`, because it isolates the
  submission API; `conventional` shows what the lease machinery costs on top.
- **Interleaving:** per run and per case the order of the three arms rotates, so
  none always goes first or runs warmest. Every window has a warm-up, then a
  measured stretch; the settings come from `GLASSWEAVE_CHARACTERIZATION_RUNS`,
  `..._SECONDS` and `..._WARMUP_SECONDS` (unset: one 1 s window per arm and
  case, a smoke).
- **Measures:** pipeline creation time per API (`MTLDevice.makeRenderPipelineState`
  against `MTL4Compiler.makeRenderPipelineState`, alternating which goes first);
  CPU encode time per frame (the call's start to just before the commit,
  without the producer's own time); GPU time per frame (`gpuStartTime` to
  `gpuEndTime` from the command buffer's completion, or from the Metal 4 commit
  feedback); memory (`MTLDevice.currentAllocatedSize` at each commit, and the
  creation footprint of each stage after 30 frames); steady state (the first
  third of a window's GPU times against the last third, failed command buffers,
  allocation growth). p50, p95, p99 and max are nearest-rank
  (`RenderMetrics.Distribution`).
- **Correctness:** one test renders four reference cases with each path into a
  1206 x 2622 target (background only, one glass panel, one lens panel, the
  glowing panel at pulse time 0.4 s), reads both back and requires every byte
  to agree within one 8-bit step. It also requires each panel case to differ
  from the background-only picture (two paths that draw nothing must not
  pass) and a frosted panel to be declined with `unsupportedPanels`.

## Verified API list

No Metal 4 name was written from memory. Each was checked three ways: the
selector in the Xcode 27.2 SDK headers (`MacOSX27.2.sdk/.../Metal.framework/Headers/MTL4*.h`
and `MTLDevice.h`, `MTLResidencySet.h`), the Swift spelling and the semantics
in Apple's documentation through the Xcode MCP `DocumentationSearch` tool (it
answered without an open workspace), and the compiler (`xcodebuild` for My Mac,
and for `generic/platform=iOS` with the iPhoneOS 27.2 SDK).

| Swift API used | Header selector | Notes from the documentation |
|---|---|---|
| `MTLGPUFamily.metal4` | `MTLGPUFamilyMetal4 = 5002` | the family check behind `supportsMetal4` |
| `MTLDevice.makeMTL4CommandQueue(descriptor:)`, `MTL4CommandQueueDescriptor.label` | `newMTL4CommandQueueWithDescriptor:error:` | the Metal 4 queue is separate from the `MTLCommandQueue` |
| `MTLDevice.makeCommandAllocator()`, `MTL4CommandAllocator.reset()`, `.allocatedSize()` | `newCommandAllocator`, `reset`, `allocatedSize` | reset only after the GPU finished the frames that used it |
| `MTLDevice.makeCommandBuffer()` returning `MTL4CommandBuffer`, `beginCommandBuffer(allocator:)`, `endCommandBuffer()`, `makeRenderCommandEncoder(descriptor:)` | `newCommandBuffer`, `beginCommandBufferWithAllocator:`, `endCommandBuffer`, `renderCommandEncoderWithDescriptor:` | a command buffer is reusable |
| `MTL4RenderPassDescriptor.colorAttachments` | `colorAttachments` | |
| `MTLDevice.makeArgumentTable(descriptor:)`, `MTL4ArgumentTableDescriptor.maxBufferBindCount` / `.maxTextureBindCount` / `.label`, `MTL4ArgumentTable.setAddress(_:index:)` / `.setTexture(_:index:)` | `newArgumentTableWithDescriptor:error:`, `setAddress:atIndex:`, `setTexture:atIndex:` | Metal 4 has no `setBytes`; every constant block is a buffer address |
| `MTLBuffer.gpuAddress`, `MTLTexture.gpuResourceID` | `gpuAddress`, `gpuResourceID` | |
| `MTL4RenderCommandEncoder.setRenderPipelineState(_:)`, `.setArgumentTable(_:stages:)`, `.drawPrimitives(primitiveType:vertexStart:vertexCount:)`, `pushDebugGroup`, `popDebugGroup` | `setRenderPipelineState:`, `setArgumentTable:atStages:`, `drawPrimitives:vertexStart:vertexCount:` | a pipeline made by `MTLDevice.makeRenderPipelineState` is accepted |
| `MTL4CommandEncoder.barrier(afterQueueStages:beforeStages:visibilityOptions:)`, `MTL4VisibilityOptions` (`.device`, `.resourceAlias`) | `barrierAfterQueueStages:beforeStages:visibilityOptions:` | a consumer barrier on earlier encoders of the same queue; the documentation's own "render pass, then a render pass that reads it" recipe. Metal 4 tracks no hazards, so this barrier is what orders the producer's write before the consumer's read |
| `MTLDevice.makeResidencySet(descriptor:)`, `MTLResidencySet.addAllocation(_:)` / `.addAllocations(_:)` / `.commit()` / `.requestResidency()` / `.allocatedSize`, `MTL4CommandQueue.addResidencySet(_:)` | `newResidencySetWithDescriptor:error:`, `addAllocation:`, `commit`, `requestResidency`, `allocatedSize`, `addResidencySet:` | Metal 4 does not make resources resident on its own |
| `MTL4CommandQueue.commit(_:options:)`, `MTL4CommitOptions.addFeedbackHandler(_:)`, `MTL4CommitFeedback.error` / `.gpuStartTime` / `.gpuEndTime` | `commit:count:options:`, `addFeedbackHandler:`, `error`, `GPUStartTime`, `GPUEndTime` | the Swift names are lower-cased by the importer; the header spells them `GPUStartTime` and `GPUEndTime` |
| `MTLDevice.makeCompiler(descriptor:)`, `MTL4CompilerDescriptor`, `MTL4Compiler.makeRenderPipelineState(descriptor:compilerTaskOptions:)`, `MTL4RenderPipelineDescriptor` (`vertexFunctionDescriptor`, `fragmentFunctionDescriptor`, `colorAttachments`), `MTL4LibraryFunctionDescriptor` (`name`, `library`), `MTL4SpecializedFunctionDescriptor` (`functionDescriptor`, `constantValues`) | `newCompilerWithDescriptor:error:`, `newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:` | used only by the compile-time measurement |

Simulator: the iPhone Simulator 27.2 SDK ships the `MTL4*.h` headers but
`MTLDevice.h` there declares none of `newMTL4CommandQueue`,
`newArgumentTableWithDescriptor` or `newCompilerWithDescriptor`, and the package
already reports `supportsMetal4 == false` for a simulator. The experiment is
`#if !targetEnvironment(simulator)`, so the simulator build contains none of it
and runs the conventional path alone. A header grep does not replace running
on a device: the iPhoneOS build below only proves the names compile.

## What was measured, and what was not

Run here (2026-11-09, one session, `xcodebuild` because the Xcode MCP bridge
cannot open a workspace on this Mac):

- **Agreement: passed.** The four reference cases, My Mac, Debug with Metal API
  Validation and Release without it: largest 8-bit difference 0, and 0 of
  12,648,528 bytes differ in every case. The frosted panel was declined with
  `unsupportedPanels` and left no frame in flight. No validation message.
- **Harness: runs, smoke only.** Debug with validation (1 s windows) and Release
  without it (1 s and 2 s windows): every arm, both cases, 60 or 120 frames per
  window, 0 failed command buffers, 0 skipped, every frame has a GPU time.
  Both queues report as expected (`MTLDebugCommandQueue` and
  `MTL4DebugCommandQueue` in Debug; `AGXG15XFamilyCommandQueue` and
  `AGXG15XFamilyCommandQueue_mtlnext` in Release).
- **Builds:** the package for My Mac (Debug and Release), the laboratory for the
  iPhone 18 Pro simulator (Metal 4 compiled out), and the package for
  `generic/platform=iOS` with the iPhoneOS 27.2 SDK (the Metal 4 code
  compiles; it was not run on a device).
- **Allocation facts, not timings** (the Release smoke; deterministic, so safe
  to quote): the Metal 4 path adds a 196,608 byte uniform ring and three command
  allocators that report 2,453,032 bytes. `currentAllocatedSize` counts the ring
  but not the allocators, and the conventional queue's command-buffer storage
  is not observable through any API, so the memory comparison is partial by
  construction. The six big textures are the same size in all arms (the shipped
  path allocates its third source texture lazily). Nothing was still allocated
  after any stage was dropped.
- **Pipeline compilation:** with the harness first in its process (0 renderers
  created before it) the first creation was 4.4 ms and every later creation of
  the same pipeline by either API was 0.1 to 0.3 ms, so on this machine the
  creation time is dominated by what is already cached, not by the API. A cold
  comparison (empty shader cache) was not taken. The Metal 4 path as built
  creates no pipelines of its own: it reuses the renderer's, so its
  pipeline-creation cost is zero beyond the conventional path's.

**Timing:** the one quiet run was taken after this smoke; its numbers are in
the last section. The smoke's own values (1 s windows, Debug, validation on,
another agent building) are not data and none is quoted.

**Not measured, and not claimed:** a physical iPhone or iPad, on-screen
presentation through a `CAMetalLayer`, a cold shader cache, thermal behavior
beyond the 21 minutes of the quiet run (the state stayed nominal), power
draw, frost, grounding, shapes, fills and touch (not encoded), Instruments
traces.

## Support matrix

| Class | Metal 4 family | Experiment | Status |
|---|---|---|---|
| My Mac, the GPU it reports as "Apple M3 Max" (Apple family 9, macOS 27.2) | yes | runs; characterization only | agreement proved again on the merged tree (0 of 12,648,528 bytes differ in each of four cases); quiet timing taken (see Decision): no benefit, so no host uses it. The task brief called this machine an Apple M5; the device's own `MTLDevice.name` says M3 Max and this record uses what the device reports. |
| iOS Simulator (iPhone 18 Pro, iOS 27.2) | no, by construction | compiled out | conventional path only; the two Metal 4 tests skip with a stated reason |
| Physical iPhone or iPad with the Metal 4 family | per `supportsMetal4` at runtime | compiles (iPhoneOS 27.2 SDK) | not run, not measured |
| Any GPU without the Metal 4 family | no | declines at `Metal4Renderer.init` | conventional path only |

## Decision rule

The conventional path stays the default and the only shipped backend unless the
quiet run shows, on the same workload, in the same interleaved windows, that
Metal 4 is better by a stated margin. Judged on the pooled windows of the
three runs, `metal4` against `conventionalRaw` (the API-only comparison):

1. **Benefit.** Metal 4's CPU encode p95 **or** GPU p95 is lower by at least
   20 percent and by at least 0.20 ms, on both cases, and the same direction
   holds in each of the three runs' windows (a win that appears in only some
   runs is noise).
2. **No harm.** On the other of the two measures neither p50 nor p95 is worse
   by more than 5 percent; there are no failed command buffers; the first-third
   and last-third GPU times of a window agree (no drift); Metal 4's extra
   memory (the ring plus the allocators, about 2.5 MiB in the smoke) is at
   most 4 MiB.
3. **Correctness.** The agreement test passes on the machine class that would
   select Metal 4.

Retaining two backends needs more than the margin, and the justification must
be written in this record before any host uses the second one:

- The conventional path cannot be removed: the iOS Simulator and GPUs without
  the Metal 4 family need it, so a second backend is permanent extra surface,
  not a replacement.
- The experiment encodes a subset (`base`, `optics`, `lighting`). Frost,
  grounding, shapes, fills and touch would each need a Metal 4 encoding (a
  compute pre-pass, extra argument-table records) and a second agreement case,
  or a panel using them would switch backends or fall back mid-surface.
- A measured win on the Mac is not a win on an iPhone. A device run with the
  same harness is needed before shipping to devices.
- Every new pipeline variant is encoded twice, and the two encodings are kept
  in agreement by the one test, which only runs where Metal 4 exists.

If the margin is not met, the outcome is: keep the conventional path as the
sole shipped backend, and either delete `Metal4Renderer` or keep it as a
characterization-only arm that no host can reach. If the margin is met only on
the Mac, record that and ship nothing until a device run exists.

## How to take the quiet run

Quiet means nothing else builds or renders on the Mac. The harness is the
second test of `Metal4ComparisonTests`; run it alone so that the pipeline
compilation measurement is first in its process, with the scheme's settings
(Release, no validation, 3 runs of 60 s after 10 s of warm-up per arm and
case, about 22 minutes):

```
cd Examples
xcodebuild test -workspace GlassWeave.xcworkspace -scheme GlassWeaveCharacterization \
  -destination 'platform=macOS' -derivedDataPath BUILD -resultBundlePath BUILD/results/NAME.xcresult \
  "-only-testing:GlassWeaveCharacterizationTests/Metal4ComparisonTests/compareBackends()" > BUILD/logs/NAME.log 2>&1
```

For a short smoke, put `TEST_RUNNER_GLASSWEAVE_CHARACTERIZATION_RUNS=1`,
`TEST_RUNNER_GLASSWEAVE_CHARACTERIZATION_SECONDS=2` and
`TEST_RUNNER_GLASSWEAVE_CHARACTERIZATION_WARMUP_SECONDS=0.5` in front (they
override the scheme's values). The report is printed and attached as
`glassweave-metal4-comparison.txt`; its "Pooled per case and arm" section has the
`metal4 - conventionalRaw` lines the rule reads (difference and ratio for GPU
and encode p50 and p95).

## Decision

**The conventional `MTLCommandQueue` path stays the only shipped backend.
Metal 4 does not meet the rule's margin on this workload and this machine, so
no host uses it and nothing is shipped.** `Metal4Renderer` and its harness stay
in the repository as a characterization-only arm (package access, no public
API, compiled out for the simulator) so the same comparison can be repeated on
a physical device or on another GPU. The rule's own wording for this outcome
was: "keep the conventional path as the sole shipped backend, and either
delete `Metal4Renderer` or keep it as a characterization-only arm that no host
can reach." It is kept for the second reason: a device might differ, and
deleting the harness would throw away the only code that can show it.

### The quiet run (2026-11-09)

One run, `xcodebuild test` of the `GlassWeaveCharacterization` scheme on My
Mac, Release (no Metal API validation), the test
`Metal4ComparisonTests/compareBackends()` alone in its process; 3 runs, 60 s
measured after 10 s of warm-up per window, 2 cases, 3 arms (18 windows,
10,800 frames per arm and case, 1,272 s in all); the arm order rotated per run
and case. Workload version 2 (1206 x 2622 at scale 3, 60 Hz, in-flight bound
2, three render targets). Zero failed and zero skipped command buffers in every
window. The harness reports the machine as Apple M3 Max, macOS 27.2 (26B123),
conventional queue `AGXG15XFamilyCommandQueue`, Metal 4 queue
`AGXG15XFamilyCommandQueue_mtlnext`.

Conditions: AC power attached (battery 80 percent, not charging) before, during
(mid-run) and after; thermal state nominal at the start and at the end (the
harness) and no thermal or performance warning level recorded (`pmset -g
therm`); Low Power Mode off. One-minute load average 2.76 at the start (the
five-minute settling wait I allowed after the build ended without the figure
reaching 2.0), 2.02 at the middle and 2.60 at the end (five- and
fifteen-minute figures 7.76 and 9.13 at the start, carrying the test batch
that ended before the build; 3.25 and 5.84 mid-run; 2.65 and 4.06 at the
end). The remaining load was the desktop session itself: `WindowServer` at 45
to 48 percent of a core and the Claude app's helper processes at 9 to 60
percent of a core each, present for every arm alike. No simulator was booted, nothing was
building, and `xctest` itself used 3 percent mid-run. Spotlight workers
(`mdworker_shared`, about 20 and 17 percent) show only in the snapshot taken at
the end of the run, not in the middle one, so the last window may have overlapped
them. Raw report: the result bundle's `glassweave-metal4-comparison.txt`
attachment (kept outside the repository).

**Pooled over the 3 runs, ms, p50 / p95 / p99 (max in brackets):**

| Case | Arm | GPU | CPU encode |
|---|---|---|---|
| panel | conventional (shipped) | 0.376 / 0.726 / 1.784 (4.594) | 0.213 / 0.405 / 0.833 (2.856) |
| panel | conventionalRaw (control) | 0.376 / 0.964 / 1.882 (4.565) | 0.127 / 0.235 / 0.723 (4.804) |
| panel | metal4 | 0.394 / 1.244 / 1.749 (4.727) | 0.128 / 0.307 / 0.803 (2.628) |
| lens | conventional (shipped) | 0.443 / 1.311 / 1.950 (4.602) | 0.231 / 0.608 / 1.056 (5.062) |
| lens | conventionalRaw (control) | 0.442 / 1.327 / 1.929 (4.453) | 0.145 / 0.243 / 0.756 (2.823) |
| lens | metal4 | 0.439 / 1.449 / 1.979 (4.526) | 0.142 / 0.293 / 0.787 (7.381) |

**The rule, `metal4` against `conventionalRaw` (the API-only comparison):**

| Case | Measure | conventionalRaw | metal4 | Difference | Ratio | Rule |
|---|---|---|---|---|---|---|
| panel | CPU encode p50 / p95 | 0.127 / 0.235 | 0.128 / 0.307 | +0.001 / +0.072 ms | 1.005 / 1.307 | benefit not met (p95 higher) |
| panel | GPU p50 / p95 | 0.376 / 0.964 | 0.394 / 1.244 | +0.017 / +0.280 ms | 1.046 / 1.291 | benefit not met (p95 higher) |
| lens | CPU encode p50 / p95 | 0.145 / 0.243 | 0.142 / 0.293 | -0.002 / +0.050 ms | 0.984 / 1.204 | benefit not met (p95 higher) |
| lens | GPU p50 / p95 | 0.442 / 1.327 | 0.439 / 1.449 | -0.003 / +0.123 ms | 0.993 / 1.092 | benefit not met (p95 higher) |
| both | Extra memory, drift, failures | | ring 196,608 B plus command allocators 4,828,712 B (5,025,320 B, 4.79 MiB) | 0 failed command buffers; GPU first third p50 / p95 0.407 / 1.364, last third 0.404 / 1.389 (no drift) | | extra memory above the 4 MiB bound |

Reading the rule:

1. **Benefit: not met.** It needed a p95 lower by at least 20 percent and 0.20
   ms on both cases, in each of the three runs. Metal 4's pooled p95 is higher
   on all four (GPU +29 percent and +9 percent, encode +31 percent and +20
   percent). Per run, its p95 is lower than the control's in 1 of 3 runs for the
   lens GPU time and 1 of 3 for the lens encode time, and in none for the panel
   (the per-run p95 values of one arm vary by a factor of two or more between
   runs, so single windows are noise; the pooled figures are the decision's basis).
   The p50 values are equal within 5 percent: the API does not change the typical
   frame.
2. **No harm** is moot once the benefit fails, and it also fails on its own:
   Metal 4's p95 is more than 5 percent worse on both measures, and its extra
   memory is 4.79 MiB (the command allocators report 4.6 MiB after the run, 2.3 MiB
   after the 1 s smoke), above the 4 MiB bound. It had no failed
   command buffers and no drift between the first and last third of a window.
3. **Correctness** passed: the agreement test on this machine class, again on
   the merged tree (largest 8-bit difference 0, and 0 of 12,648,528 bytes
   differ, in each of the four cases; the frosted panel is declined with
   `unsupportedPanels`).

Two more facts the run showed, neither of which changes the decision:

- Against the **shipped** path the Metal 4 path encodes cheaper (CPU encode p95
  -0.098 ms on the panel, -0.315 ms on the lens; ratios 0.76 and 0.48), and
  its GPU p95 is higher (+0.518 and +0.138 ms). The encode gap is the shipped
  path's lease and validation machinery (`conventional` against
  `conventionalRaw`: encode p50 +0.086 ms on both cases, p95 +0.170 and +0.364
  ms), not the API, which is why the rule compared against the control. It
  marks where the shipped path has CPU headroom if encode time ever matters
  (0.09 ms at the median and 0.17 to 0.36 ms at p95 per frame on this machine);
  a submission API switch is not what recovers it.
- Pipeline creation (a fresh process, the order alternated per pipeline, a warm
  on-disk shader cache): `MTL4Compiler` took 0.127 s for the base pipeline
  (second in its order, after the conventional 0.0025 s) and 0.101 s for the
  optics pipeline (first in its order, before the conventional 0.0002 s); every
  later creation by either API took 0.0001 to 0.0002 s. So the Metal 4
  compiler's first call was about 0.1 s slower in both orders. The experiment
  reuses the conventional pipelines, so it pays none of this. A cold-cache
  comparison was not taken.

Why this is a Mac result only: the workload is small (GPU p50 about 0.4 ms
and CPU encode p50 about 0.13 ms per frame, at most a few percent of a 16.7 ms
frame),
the machine is a desktop-class M3 Max, and nothing here says what an iPhone's
GPU and driver do. The record therefore makes no claim about devices; it
decides only that this experiment, on this workload, gives no reason to
carry a second backend.

### Support matrix after the decision

| Class | Backend any host uses | Metal 4 experiment |
|---|---|---|
| My Mac (Apple M3 Max, macOS 27.2) | conventional | runs in the characterization target only; no benefit measured |
| iOS Simulator | conventional | compiled out |
| Physical iPhone or iPad | conventional | compiles for the iPhoneOS 27.2 SDK; not run, not measured |
| GPU without the Metal 4 family | conventional | declines at `Metal4Renderer.init` |

### What would reopen it

Only a measurement: the same harness run on a physical device (or another GPU
class) showing the rule's margin, together with Metal 4 encodings of the
variants the experiment declines (frost, grounding, shapes, fills, touch) and
on-screen presentation through the layer (`waitForDrawable`, `signalDrawable`,
the layer's residency set), none of which exists. Until then the conventional
path is the only backend in use.

Decision line: **2026-11-09, quiet run on My Mac (Apple M3 Max, Release, 3 runs
of 60 s per window, 10,800 frames per arm and case): Metal 4 submission is
slower at p95 than the conventional control on both cases and both measures
(encode p95 +0.072 and +0.050 ms, GPU p95 +0.280 and +0.123 ms), so the margin
(at least 20 percent and 0.20 ms) is not met; the conventional path is the sole
shipped backend and `Metal4Renderer` remains a characterization-only arm.**
