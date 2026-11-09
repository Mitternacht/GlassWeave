# Milestone 1 evidence

**Status: not qualified.** No physical iPhone or iPad was measured. Every
device target below is *not measured*. This report records the instrument
that the device run will use (the laboratory's benchmark scenario and
`RenderMetrics`), a clearly labelled Apple M5 Mac offscreen
characterization, and simulator functional results. None of these are
device evidence, and none of them qualify the milestone.

| Field | Value |
| --- | --- |
| Commit / date / operator | First recorded at the GW-09 commit `afb66d6` on `implement/milestone-1` (parent `3303967`; these are the hashes after the 2026-11-09 rewrite of the branch's author identity, formerly `120bafc` and `d4f6666`), 2026-11-08. Re-run on 2026-11-09 after review fixes (scenario v2, the scheduler's on-demand fix, an idle check that can fail): the Mac characterization with the package sources of `bb79792`, the package and laboratory test runs at `9b2c0c4`; later commits change documentation and comments only. Recorded by Claude (coding agent) on the project's development Mac. |
| Device and OS / SDK | **Physical devices: none.** The session was directed to the Mac; no baseline or modern iPhone was selected or measured, and no iPad. Mac: Apple M5 (MacBook Air, `Mac17,4`), macOS 27.2 (26B123), on AC power, Low Power Mode off. Simulators: iPhone 18 Pro and iPad Pro 13-inch (M5), iOS 27.2 runtime (24B8117). Xcode 27.2 (27B52), Swift 6.4.2, iOS/macOS 27.2 SDKs, deployment floor 26.0. No iOS 26 runtime is installed. |
| Build configuration / backend | Mac characterization: Release (`DEBUG` not defined), Metal API Validation off (the command queue is the driver's `AGXG17GFamilyCommandQueue`, not `MTLDebugCommandQueue`), scheme `GlassWeaveCharacterization`. Simulator runs: Debug lab build. Backend: conventional Metal command submission, the only backend (Metal 4 is GW-11). |
| Scenario version / seed / dimensions | Benchmark scenario v2 (`BenchmarkScenario.version`), lifecycle seed `0x67570009`. Laboratory in a benchmark mode: the surface fills the screen, 1206 × 2622 px on the iPhone 18 Pro simulator in portrait and 2064 × 2752 px on the iPad Pro 13-inch (M5) simulator, with the controls above it on an opaque backdrop; panel 320 × 180 pt at default text size, above the controls. Mac offscreen: the same 1206 × 2622 px target (402 × 874 pt at scale 3), panel 320 × 180 pt = 960 × 540 px centered on the surface, no native views or controls, 60 Hz requests, in-flight bound 2, pool capacity 3, frame-ID strip off. Version 1 (2026-11-08) rendered only the laboratory's stage above its controls (1206 × 1524 px), so its laboratory and Mac workloads differed; its results are superseded. |
| Tools / unavailable measurements | `RenderMetrics` (CPU encode, producer and target-acquisition time, `gpuStartTime`/`gpuEndTime` per command buffer, counts, `currentAllocatedSize`), `FrameStatistics`, `FrameTexturePool.Statistics`, Swift Testing, XCUITest, Xcode MCP. **Not used:** Instruments (Metal System Trace, Time Profiler, Allocations, Energy Log, os_signpost correlation), Metal frame capture, a physical display. **Unavailable here:** presentation intervals and missed display opportunities (offscreen has no display; the simulator's pacing is not a device's), on-device thermal and energy observations, five-minute device runs, iOS 26 runtime. The iOS Simulator reports zero for `currentAllocatedSize` and `allocatedSize`, so no simulator allocation figure exists. |

## Correctness

The functional correctness record is the per-task evidence in
[the task list](../../tasks/todo.md) (GW-04 to GW-08) and the
[accessibility matrix](../validation.md#recorded-accessibility-matrix-gw-08-2026-11-08).
On 2026-11-09 at `9b2c0c4`, Xcode MCP `RunAllTests` passed (counts of test
functions from `xcresulttool`):

| Scheme / destination | Result |
| --- | --- |
| `GlassWeave` package, My Mac (Apple M5), `MTL_DEBUG_LAYER=1` | 126 test functions passed (125 `GlassWeaveTests`, 1 `GlassWeaveCharacterizationTests`; the UIKit bundle is empty on macOS) |
| `GlassWeave` package, iPhone 18 Pro simulator, `MTL_DEBUG_LAYER=1` | 155 passed (124 core, 30 UIKit, 1 characterization; the core's exit test runs only on macOS) |
| `GlassWeaveLab`, iPhone 18 Pro simulator | 18 passed, 1 skipped (the iPad-only two-scene test) |
| `GlassWeaveLab`, iPad Pro 13-inch (M5) simulator | 18 passed, 1 skipped (the system-dark audit; see GW-08) |

At the GW-09 commit (scenario v1) the counts were 117, 142, 18 + 1 skipped,
and 18 + 1 skipped.

No Metal frame capture was taken. A capture of benchmark mode 3, scenario v2:
[simulator capture](captures/gw-09-benchmark-custom-v2-iphone18pro-sim.png)
(full-screen surface, frame-ID strip off, native reference below the custom
panel, controls on their backdrop). The scenario v1 capture is
[kept for reference](captures/gw-09-benchmark-custom-iphone18pro-sim.png).

## Cost

### Physical devices

**Not measured.** No device run, trace, pacing record, memory record, or
thermal/energy observation exists.

### Apple M5 Mac offscreen characterization (not device evidence)

`GlassWeaveCharacterizationTests`, scheme `GlassWeaveCharacterization`
(Release, validation off), run through Xcode MCP `RunAllTests` on My Mac:
three interleaved runs per mode (B, P, P, B, B, P), each 10 s warm-up then
60 s measured at 60 Hz (3,600 frames per run), thermal state nominal at
start and end. Mode *background* is the laboratory's mode 1 (owned moving
background, no panel); mode *panel* is GlassWeave's share of mode 3 (the same
background and one panel). The native reference glass is composited by the
system and is not part of an offscreen render, so mode 2 has no Mac
counterpart. Times in milliseconds, nearest-rank p50 / p95 / p99 / max.

| Run | GPU per frame | GlassWeave CPU encode | App producer (CPU) |
| --- | --- | --- | --- |
| 1 background | 0.685 / 0.746 / 0.775 / 0.905 | 0.098 / 0.131 / 0.160 / 0.327 | 0.042 / 0.067 / 0.092 / 0.376 |
| 1 panel | 0.738 / 0.849 / 0.893 / 3.657 | 0.104 / 0.176 / 0.214 / 1.202 | 0.046 / 0.098 / 0.123 / 6.490 |
| 2 panel | 0.736 / 0.843 / 0.882 / 2.035 | 0.104 / 0.169 / 0.223 / 0.475 | 0.046 / 0.089 / 0.120 / 0.249 |
| 2 background | 0.720 / 0.815 / 0.891 / 2.803 | 0.101 / 0.154 / 0.209 / 0.323 | 0.045 / 0.087 / 0.118 / 0.280 |
| 3 background | 0.715 / 0.828 / 0.895 / 3.258 | 0.109 / 0.178 / 0.225 / 1.714 | 0.054 / 0.106 / 0.148 / 2.237 |
| 3 panel | 0.738 / 0.829 / 0.871 / 0.959 | 0.104 / 0.182 / 0.261 / 0.363 | 0.046 / 0.102 / 0.145 / 0.197 |
| Pooled background (10,800) | 0.704 / 0.804 / 0.881 / 3.258 | 0.101 / 0.160 / 0.211 / 1.714 | 0.046 / 0.090 / 0.129 / 2.237 |
| Pooled panel (10,800) | 0.737 / 0.842 / 0.881 / 3.657 | 0.104 / 0.175 / 0.231 / 1.202 | 0.046 / 0.096 / 0.136 / 6.490 |

- GPU time is one command buffer: the producer's background render, the
  background pass, and (mode *panel*) the panel, at 1206 × 2622 px.
- Comparative statistic p95(panel) − p95(background): run 1 +0.103,
  run 2 +0.028, run 3 +0.001, pooled +0.037 ms. The run-to-run spread is as
  large as the statistic itself, so the Mac shows only that the panel's
  added GPU time is small against this background, not a stable figure.
  Maxima of 2 to 6.5 ms (GPU and CPU) appear in several runs while every p99
  stays below 0.9 ms (GPU) and 0.27 ms (encode); they are kept, not removed.
- Every run drew all 3,600 ticks: 0 declined productions, 0 pool-exhausted
  checkouts, 0 coalesced requests, 0 deferrals at the in-flight bound,
  0 skipped draws, 0 failed command buffers. Target acquisition (an
  offscreen texture here) was ≤ 0.013 ms.
- `currentAllocatedSize` peaked at 62.5 MiB in both modes: two pooled
  source textures (24.3 MiB) and three 1206 × 2622 render targets standing
  in for drawables (about 36 MiB), plus pipelines. The panel added no
  allocation: it samples the frame the background already produced.
- Idle: after drawing anything still pending, 300 display passes at 60 Hz
  over 5 s with nothing requested produced 0 frames and submitted 0. The
  check fails when the scheduler draws unrequested frames (a deliberate
  mutation gave a submission and a production per pass). The scenario v1
  idle line ("0 submissions in 5 s with no requests") came from a sleep with
  no display pass, which could not fail.
- Lifecycle: 100 cycles of hide (pool trimmed), two hidden ticks, show,
  and a portrait/landscape target change; settled `currentAllocatedSize`
  65,519,616 B before and after (change 0 B); the pool made 300 allocations
  and 300 discards and returned to 2 textures.
- The same test also runs in the regular package scheme as a short
  functional pass (1 s per mode, 10 lifecycle cycles, Debug, validation on);
  its timings are not characterization data.

The complete report is reproduced at the end of this file.

### Simulator functional results (not device evidence)

Lab `BenchmarkUITests`, Xcode MCP `RunSomeTests` and `RunAllTests`, Debug
build. Simulator GPU and CPU times describe the simulator on this Mac, not
any device; they show only that the measurement path works in the running
app.

| Check | iPhone 18 Pro simulator | iPad Pro 13-inch (M5) simulator |
| --- | --- | --- |
| Surface size in benchmark modes (scenario v2, full screen, portrait) | 1206 × 2622 px | 2064 × 2752 px |
| Modes 1–3: composition (native button only in 2 and 3, custom button only in 3), strip off at launch, clock running | Pass | Pass |
| Modes 1–3: 10 s window after Reset | 598 / 599 / 592 frames drawn, every one committed and completed, 0 failed, 0 declined, 0 skipped | 589 / 589 / 583 frames, 0 failed, 0 declined, 0 skipped |
| Mode 4: submissions over 30 s with the source frozen and the panel settled | 0 | 0 |
| Mode 5: 100 seeded hide/show + resize cycles, then 3 rotations and 3 background/foreground cycles | Pass: 2 pooled textures before, after the cycles, and at the end; peak in flight ≤ 2. Allocation sizes not reported by the simulator (not measured) | Pass, same |

## Interaction and accessibility

Recorded on simulators in GW-06 to GW-08 (both buttons act during motion,
rotation, pause and resume; Dynamic Type at the largest size; Reduce Motion;
Reduce Transparency; light and dark; accessibility audits). The live
VoiceOver pass (navigation order and double-tap activation) has not been
run: the iOS Simulator has no VoiceOver. No scripted control sequence was run
on a device, and no main-thread trace correlates interaction with rendering.

## Decision

| Target (provisional) | Result |
| --- | --- |
| Comparative GPU budget: p95(custom) − p95(native reference) ≤ 2.0 ms | **Not measured** on a device. Mac offscreen characterization only: +0.037 ms pooled (+0.001 to +0.103 ms per run) for the panel over the background alone; the native reference's system compositing is not included. |
| Custom CPU encoding p95 ≤ 1.0 ms | **Not measured** on a device. Mac: 0.175 ms pooled p95 (GlassWeave encode, panel mode, Release). |
| Presentation pacing: missed opportunities < 1 % over five minutes at 60 Hz | **Not measured.** No device display, no presentation-interval record. |
| Interaction: no added main-thread stall > 16.7 ms | **Not measured.** No main-thread trace. |
| Managed resources ≤ 64 MiB incremental | **Not measured** on a device. Mac: the panel added 0 B over the background; the whole process peaked at 62.5 MiB at the full-screen size. |
| Steady memory: no growth after warm-up or 100 lifecycle cycles | **Not measured** on a device. Mac: 0 B change after 100 cycles. Simulator: texture counts unchanged; allocation sizes unavailable. |
| Idle: no continuous submissions | **Not measured** on a device. Functional pass: mode 4 submitted nothing over 30 s on both simulators, and on the Mac 300 display passes in 5 s with nothing requested produced and submitted nothing. Mode 4 stops the source's clock, so it sends no requests; whether a host would suppress requests whose content did not change is not tested (it does not: every request draws). |
| Compilation: no pipeline compilation during steady interaction | **Not measured.** Pipelines are built when the renderer is created, but no Instruments compilation trace exists. |
| Thermal / energy observations | **Not measured** on a device. Mac thermal state nominal before and after. |

**Qualified device and support matrix:** none. Every iPhone and iPad class
is unqualified; see [support](../support.md).

**Required follow-up (GW-09 stays open):**

1. Select the baseline physical iPhone (the oldest representative device in
   the iOS 26 range) and one modern higher-refresh iPhone, and record them.
2. On each, build Release at a recorded commit, verify with Metal API
   Validation separately, then run modes 1–3 for five minutes three times,
   interleaved, after a 30 s warm-up (`-lab.benchmark baseline|native|custom`;
   Reset restarts the metrics window), with Metal System Trace, Time Profiler
   and signposts, and Allocations. Record presentation intervals and missed
   opportunities, thermal state and energy, and the settings in the device
   matrix of [the validation protocol](../validation.md).
3. Mode 4 for 30 s and mode 5 (`-lab.benchmark lifecycle`, then rotations and
   background/foreground, then Settle and measure) with allocation
   instrumentation.
4. Run the scripted control sequence and the live VoiceOver pass (closes
   GW-08 item 1).
5. Record an iPad layout run before any iPad support claim.

## Appendix: Mac characterization report

Printed by `CharacterizationTests` (scheme `GlassWeaveCharacterization`):

```text
GlassWeave characterization, workload version 2
Machine GPU: Apple M5, native; highest Apple family apple10, Metal 3 true, Metal 4 true
OS: Version 27.2 (Build 26B123)
Build: Release (DEBUG not defined); command queue class AGXG17GFamilyCommandQueue
Conditions: thermal state nominal at start, nominal at end; Low Power Mode off
Settings: 3 run(s) per mode, 60.0 s measured after 10.0 s warm-up, 100 lifecycle cycles
Workload: target 1206×2622 px at scale 3.0; panel 320×180 pt = 960×540 px; 60 Hz requests; in-flight bound 2; pool 3; frame-ID strip off

Per run (ms; nearest-rank percentiles p50/p95/p99/max):
  run 1 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.685 / 0.746 / 0.775 / 0.905 (n 3600) (0 frames without GPU time)
    encode  0.098 / 0.131 / 0.160 / 0.327 (n 3600)
    produce 0.042 / 0.067 / 0.092 / 0.376 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.738 / 0.849 / 0.893 / 3.657 (n 3600) (0 frames without GPU time)
    encode  0.104 / 0.176 / 0.214 / 1.202 (n 3600)
    produce 0.046 / 0.098 / 0.123 / 6.490 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.736 / 0.843 / 0.882 / 2.035 (n 3600) (0 frames without GPU time)
    encode  0.104 / 0.169 / 0.223 / 0.475 (n 3600)
    produce 0.046 / 0.089 / 0.120 / 0.249 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.009 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.720 / 0.815 / 0.891 / 2.803 (n 3600) (0 frames without GPU time)
    encode  0.101 / 0.154 / 0.209 / 0.323 (n 3600)
    produce 0.045 / 0.087 / 0.118 / 0.280 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.715 / 0.828 / 0.895 / 3.258 (n 3600) (0 frames without GPU time)
    encode  0.109 / 0.178 / 0.225 / 1.714 (n 3600)
    produce 0.054 / 0.106 / 0.148 / 2.237 (n 3600)
    acquire 0.000 / 0.000 / 0.001 / 0.006 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.738 / 0.829 / 0.871 / 0.959 (n 3600) (0 frames without GPU time)
    encode  0.104 / 0.182 / 0.261 / 0.363 (n 3600)
    produce 0.046 / 0.102 / 0.145 / 0.197 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.013 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB

Pooled per mode:
  background: 10800 frames
    GPU     0.704 / 0.804 / 0.881 / 3.258 (n 10800)
    encode  0.101 / 0.160 / 0.211 / 1.714 (n 10800)
    produce 0.046 / 0.090 / 0.129 / 2.237 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.006 (n 10800)
  panel: 10800 frames
    GPU     0.737 / 0.842 / 0.881 / 3.657 (n 10800)
    encode  0.104 / 0.175 / 0.231 / 1.202 (n 10800)
    produce 0.046 / 0.096 / 0.136 / 6.490 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.013 (n 10800)

Comparative GPU statistic, p95(panel) − p95(background):
  run 1: +0.103 ms
  run 2: +0.028 ms
  run 3: +0.001 ms
  pooled: +0.037 ms

Idle: 300 display passes in 5.0 s with nothing requested: 0 submissions, 0 frames produced
Lifecycle: 100 cycles of hide (trim) / 2 hidden ticks / show / rotate / 4 ticks
  settled currentAllocatedSize before 65519616 B (62.5 MiB), after 65519616 B (62.5 MiB), change 0 B
  pool before: 2 textures, 24.3 MiB, 2 allocations; after: 2 textures, 24.3 MiB, 302 allocations, 300 discarded
```
