# Milestone 1 evidence

**Status: not qualified.** No physical iPhone or iPad was measured. Every
device target below is *not measured*. This report records the instrument
that the device run will use (the laboratory's benchmark scenario and
`RenderMetrics`), a clearly labelled Apple M5 Mac offscreen
characterization, and simulator functional results. None of these are
device evidence, and none of them qualify the milestone.

| Field | Value |
| --- | --- |
| Commit / date / operator | The GW-09 commit on `implement/milestone-1` (parent `d4f6666`), 2026-11-08 to 2026-11-09, recorded by Claude (coding agent) on the project's development Mac |
| Device and OS / SDK | **Physical devices: none.** The session was directed to the Mac; no baseline or modern iPhone was selected or measured, and no iPad. Mac: Apple M5 (MacBook Air, `Mac17,4`), macOS 27.2 (26B123), on AC power, Low Power Mode off. Simulators: iPhone 18 Pro and iPad Pro 13-inch (M5), iOS 27.2 runtime (24B8117). Xcode 27.2 (27B52), Swift 6.4.2, iOS/macOS 27.2 SDKs, deployment floor 26.0. No iOS 26 runtime is installed. |
| Build configuration / backend | Mac characterization: Release (`DEBUG` not defined), Metal API Validation off (the command queue is the driver's `AGXG17GFamilyCommandQueue`, not `MTLDebugCommandQueue`), scheme `GlassWeaveCharacterization`. Simulator runs: Debug lab build. Backend: conventional Metal command submission, the only backend (Metal 4 is GW-11). |
| Scenario version / seed / dimensions | Benchmark scenario v1 (`BenchmarkScenario.version`), lifecycle seed `0x67570009`. Mac offscreen: 1206 × 2622 px target (402 × 874 pt at scale 3, the iPhone 18 Pro simulator's full screen), panel 320 × 180 pt = 960 × 540 px, 60 Hz requests, in-flight bound 2, pool capacity 3, frame-ID strip off. Laboratory on the iPhone 18 Pro simulator, portrait: stage drawable 1206 × 1524 px (the stage is the upper part of the screen), panel 320 × 180 pt at default text size. |
| Tools / unavailable measurements | `RenderMetrics` (CPU encode, producer and target-acquisition time, `gpuStartTime`/`gpuEndTime` per command buffer, counts, `currentAllocatedSize`), `FrameStatistics`, `FrameTexturePool.Statistics`, Swift Testing, XCUITest, Xcode MCP. **Not used:** Instruments (Metal System Trace, Time Profiler, Allocations, Energy Log, os_signpost correlation), Metal frame capture, a physical display. **Unavailable here:** presentation intervals and missed display opportunities (offscreen has no display; the simulator's pacing is not a device's), on-device thermal and energy observations, five-minute device runs, iOS 26 runtime. The iOS Simulator reports zero for `currentAllocatedSize` and `allocatedSize`, so no simulator allocation figure exists. |

## Correctness

The functional correctness record is the per-task evidence in
[the task list](../../tasks/todo.md) (GW-04 to GW-08) and the
[accessibility matrix](../validation.md#recorded-accessibility-matrix-gw-08-2026-11-08).
At the GW-09 commit, Xcode MCP `RunAllTests` passed:

| Scheme / destination | Result |
| --- | --- |
| `GlassWeave` package, My Mac (Apple M5), `MTL_DEBUG_LAYER=1` | 117 test functions passed (116 `GlassWeaveTests`, 1 `GlassWeaveCharacterizationTests`; the UIKit bundle is empty on macOS) |
| `GlassWeave` package, iPhone 18 Pro simulator, `MTL_DEBUG_LAYER=1` | 142 passed (116 core, 25 UIKit, 1 characterization) |
| `GlassWeaveLab`, iPhone 18 Pro simulator | 18 passed, 1 skipped (the iPad-only two-scene test) |
| `GlassWeaveLab`, iPad Pro 13-inch (M5) simulator | 18 passed, 1 skipped (the system-dark audit; see GW-08) |

No Metal frame capture was taken. A capture of benchmark mode 3:
[simulator capture](captures/gw-09-benchmark-custom-iphone18pro-sim.png)
(frame-ID strip off, native reference beside the custom panel).

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
| 1 background | 0.680 / 0.748 / 0.793 / 0.986 | 0.100 / 0.146 / 0.188 / 0.587 | 0.046 / 0.082 / 0.112 / 0.260 |
| 1 panel | 0.757 / 0.880 / 2.748 / 3.874 | 0.103 / 0.162 / 0.207 / 0.692 | 0.046 / 0.087 / 0.120 / 0.920 |
| 2 panel | 0.761 / 0.880 / 0.932 / 3.946 | 0.102 / 0.167 / 0.210 / 2.803 | 0.045 / 0.088 / 0.118 / 0.516 |
| 2 background | 0.735 / 0.810 / 0.869 / 0.976 | 0.098 / 0.134 / 0.166 / 0.690 | 0.043 / 0.071 / 0.101 / 0.570 |
| 3 background | 0.724 / 0.799 / 0.850 / 0.944 | 0.096 / 0.134 / 0.170 / 0.695 | 0.042 / 0.069 / 0.097 / 1.846 |
| 3 panel | 0.761 / 0.863 / 0.891 / 1.081 | 0.098 / 0.138 / 0.176 / 0.413 | 0.042 / 0.071 / 0.097 / 0.178 |
| Pooled background (10,800) | 0.712 / 0.796 / 0.849 / 0.986 | 0.098 / 0.138 / 0.175 / 0.695 | 0.044 / 0.075 / 0.104 / 1.846 |
| Pooled panel (10,800) | 0.760 / 0.875 / 1.011 / 3.946 | 0.101 / 0.157 / 0.203 / 2.803 | 0.044 / 0.084 / 0.113 / 0.920 |

- GPU time is one command buffer: the producer's background render, the
  background pass, and (mode *panel*) the panel, at 1206 × 2622 px.
- Comparative statistic p95(panel) − p95(background): run 1 +0.132,
  run 2 +0.070, run 3 +0.063, pooled +0.079 ms. Run 1's panel p99 (2.748 ms)
  is an outlier against runs 2 and 3 (0.932, 0.891); the run is kept, not
  averaged away.
- Every run drew all 3,600 ticks: 0 declined productions, 0 pool-exhausted
  checkouts, 0 coalesced requests, 0 deferrals at the in-flight bound,
  0 skipped draws, 0 failed command buffers. Target acquisition (an
  offscreen texture here) was ≤ 0.011 ms.
- `currentAllocatedSize` peaked at 62.5 MiB in both modes: two pooled
  source textures (24.3 MiB) and three 1206 × 2622 render targets standing
  in for drawables (about 36 MiB), plus pipelines. The panel added no
  allocation: it samples the frame the background already produced.
- Idle: 0 submissions in 5 s with no requests.
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
| Modes 1–3: composition (native button only in 2 and 3, custom button only in 3), strip off at launch, clock running | Pass | Pass |
| Modes 1–3: 10 s window after Reset | 578 / 602 / 602 frames drawn, every one committed and completed, 0 failed, 0 declined, 0 skipped | 615 / 587 / 587 frames, 0 failed, 0 declined, 0 skipped |
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
| Comparative GPU budget: p95(custom) − p95(native reference) ≤ 2.0 ms | **Not measured** on a device. Mac offscreen characterization only: +0.079 ms pooled for the panel over the background alone; the native reference's system compositing is not included. |
| Custom CPU encoding p95 ≤ 1.0 ms | **Not measured** on a device. Mac: 0.157 ms pooled p95 (GlassWeave encode, panel mode, Release). |
| Presentation pacing: missed opportunities < 1 % over five minutes at 60 Hz | **Not measured.** No device display, no presentation-interval record. |
| Interaction: no added main-thread stall > 16.7 ms | **Not measured.** No main-thread trace. |
| Managed resources ≤ 64 MiB incremental | **Not measured** on a device. Mac: the panel added 0 B over the background; the whole process peaked at 62.5 MiB at the full-screen size. |
| Steady memory: no growth after warm-up or 100 lifecycle cycles | **Not measured** on a device. Mac: 0 B change after 100 cycles. Simulator: texture counts unchanged; allocation sizes unavailable. |
| Idle: no continuous submissions | **Not measured** on a device. Functional pass: 0 submissions over 30 s (both simulators) and 5 s (Mac offscreen). |
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
GlassWeave characterization, workload version 1
Machine GPU: Apple M5, native; highest Apple family apple10, Metal 3 true, Metal 4 true
OS: Version 27.2 (Build 26B123)
Build: Release (DEBUG not defined); command queue class AGXG17GFamilyCommandQueue
Conditions: thermal state nominal at start, nominal at end; Low Power Mode off
Settings: 3 run(s) per mode, 60.0 s measured after 10.0 s warm-up, 100 lifecycle cycles
Workload: target 1206×2622 px at scale 3.0; panel 320×180 pt = 960×540 px; 60 Hz requests; in-flight bound 2; pool 3; frame-ID strip off

Per run (ms; nearest-rank percentiles p50/p95/p99/max):
  run 1 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.680 / 0.748 / 0.793 / 0.986 (n 3600) (0 frames without GPU time)
    encode  0.100 / 0.146 / 0.188 / 0.587 (n 3600)
    produce 0.046 / 0.082 / 0.112 / 0.260 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.007 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.757 / 0.880 / 2.748 / 3.874 (n 3600) (0 frames without GPU time)
    encode  0.103 / 0.162 / 0.207 / 0.692 (n 3600)
    produce 0.046 / 0.087 / 0.120 / 0.920 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.011 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.761 / 0.880 / 0.932 / 3.946 (n 3600) (0 frames without GPU time)
    encode  0.102 / 0.167 / 0.210 / 2.803 (n 3600)
    produce 0.045 / 0.088 / 0.118 / 0.516 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.002 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.735 / 0.810 / 0.869 / 0.976 (n 3600) (0 frames without GPU time)
    encode  0.098 / 0.134 / 0.166 / 0.690 (n 3600)
    produce 0.043 / 0.071 / 0.101 / 0.570 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.724 / 0.799 / 0.850 / 0.944 (n 3600) (0 frames without GPU time)
    encode  0.096 / 0.134 / 0.170 / 0.695 (n 3600)
    produce 0.042 / 0.069 / 0.097 / 1.846 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.761 / 0.863 / 0.891 / 1.081 (n 3600) (0 frames without GPU time)
    encode  0.098 / 0.138 / 0.176 / 0.413 (n 3600)
    produce 0.042 / 0.071 / 0.097 / 0.178 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB

Pooled per mode:
  background: 10800 frames
    GPU     0.712 / 0.796 / 0.849 / 0.986 (n 10800)
    encode  0.098 / 0.138 / 0.175 / 0.695 (n 10800)
    produce 0.044 / 0.075 / 0.104 / 1.846 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.007 (n 10800)
  panel: 10800 frames
    GPU     0.760 / 0.875 / 1.011 / 3.946 (n 10800)
    encode  0.101 / 0.157 / 0.203 / 2.803 (n 10800)
    produce 0.044 / 0.084 / 0.113 / 0.920 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.011 (n 10800)

Comparative GPU statistic, p95(panel) − p95(background):
  run 1: +0.132 ms
  run 2: +0.070 ms
  run 3: +0.063 ms
  pooled: +0.079 ms

Idle: 0 submissions in 5.0 s with no requests
Lifecycle: 100 cycles of hide (trim) / 2 hidden ticks / show / rotate / 4 ticks
  settled currentAllocatedSize before 65519616 B (62.5 MiB), after 65519616 B (62.5 MiB), change 0 B
  pool before: 2 textures, 24.3 MiB, 2 allocations; after: 2 textures, 24.3 MiB, 302 allocations, 300 discarded
```
