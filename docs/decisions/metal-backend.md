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

Status: experiment built, correctness proved, comparison harness built and run
as a smoke on 2026-11-09. **The shipped-backend decision is pending the quiet
timing run** (the last section states the rule it will be judged by). Until
then the conventional path stays the only backend any host uses.

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

**Not measured, and not claimed:** every timing. The smoke durations, another
agent building on this Mac at the same time, and Debug validation make the
smoke p50/p95 values unusable as data, so none is quoted. Not measured at all: a physical iPhone or iPad, on-screen presentation
through a `CAMetalLayer`, a cold shader cache, thermal behavior over minutes,
power, frost, grounding, shapes, fills and touch (not encoded), Instruments
traces.

## Support matrix

| Class | Metal 4 family | Experiment | Status |
|---|---|---|---|
| My Mac, the GPU it reports as "Apple M3 Max" (Apple family 9, macOS 27.2) | yes | runs | agreement proved; smoke harness run; timing pending the quiet run. The task brief called this machine an Apple M5; the device's own `MTLDevice.name` says M3 Max and this record uses what the device reports. |
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

**Pending the quiet timing run.** Until it is taken and the rule above is
applied, the shipped backend is the conventional path, the Metal 4 path stays a
package-level experiment with no host using it, and nothing in this record
claims a measured Metal 4 advantage or disadvantage.

Numbers to fill in after the quiet run (do not edit the rule afterwards):

| Case | Measure | conventionalRaw | metal4 | Difference | Ratio | Rule |
|---|---|---|---|---|---|---|
| panel | CPU encode p50 / p95 | | | | | |
| panel | GPU p50 / p95 | | | | | |
| lens | CPU encode p50 / p95 | | | | | |
| lens | GPU p50 / p95 | | | | | |
| both | Extra memory, drift, failures | | | | | |

Decision line: _pending the quiet timing run._
