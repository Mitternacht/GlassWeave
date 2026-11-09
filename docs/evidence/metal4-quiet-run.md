# GW-11 quiet timing run (2026-11-09)

The raw report of the one quiet run behind [the decision](../decisions/metal-backend.md#decision):
`xcodebuild test`, scheme `GlassWeaveCharacterization` (Release, no Metal API
validation), `Metal4ComparisonTests/compareBackends()` alone in its process, My Mac,
3 runs of 60 s per window after 10 s of warm-up. Experimental; one machine, no
physical device. The decision rule it was judged by is in the record; this file is
the unedited report plus the conditions recorded before, during and after the run
(power and thermal state, load averages, the busiest processes).

## Conditions

```text
=== before 2026-11-09 23:18:13
Now drawing from 'AC Power'
 -InternalBattery-0	80%; AC attached; not charging present: true
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
23:18  up 11:29, 1 user, load averages: 2.76 7.76 9.13
booted simulators: 0
 48.2 WindowServer
 24.5 Claude Helper.app/Contents/MacOS/Claude Helper
  9.2 Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
  6.1 claude
  2.5 com.apple.CoreSimulator.CoreSimulatorService
  2.3 /sbin/launchd
=== midrun 2026-11-09 23:28:13
Now drawing from 'AC Power'
 -InternalBattery-0	80%; AC attached; not charging present: true
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
23:28  up 11:39, 1 user, load averages: 2.02 3.25 5.84
booted simulators: 0
 59.7 Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
 45.4 WindowServer
 21.7 Claude Helper.app/Contents/MacOS/Claude Helper
  2.9 /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest
  2.5 /sbin/launchd
  2.2 /usr/sbin/bluetoothd
=== after 2026-11-09 23:39:25
Now drawing from 'AC Power'
 -InternalBattery-0	80%; AC attached; not charging present: true
Note: No thermal warning level has been recorded
Note: No performance warning level has been recorded
Note: No CPU power status has been recorded
23:39  up 11:50, 1 user, load averages: 2.60 2.65 4.06
booted simulators: 0
 45.4 WindowServer
 20.2 mdworker_shared
 17.1 mdworker_shared
 14.6 Claude Helper.app/Contents/MacOS/Claude Helper
  7.3 mds
  5.1 mds_stores
```

## Report

The report's last line ("This report is a smoke run unless the settings above say
otherwise") is the harness's fixed text; the settings above it (3 runs, 60 s, 10 s
warm-up) make this run the full one.

```text
GlassWeave GW-11: Metal 4 against conventional submission, workload version 2
Machine GPU: Apple M3 Max; highest Apple family apple9, Metal 3 true, Metal 4 true; backend selected for the experiment: metal4
OS: Version 27.2 (Build 26B123)
Build: Release (DEBUG not defined); conventional queue class AGXG15XFamilyCommandQueue; Metal 4 queue class AGXG15XFamilyCommandQueue_mtlnext
Conditions: thermal state nominal at start, nominal at end; Low Power Mode off
Settings: 3 run(s), 60.0 s measured after 10.0 s warm-up per window
Workload: target 1206×2622 px at scale 3.0; the GW-09 producer pass into a ring of 3 textures, then the background and one panel in one render pass; 60 Hz requests; in-flight bound 2; 3 render targets; frame-ID strip off
Arms: conventional = the shipped GlassRenderer.drawProducing (leases, validation); conventionalRaw = the control, the same plan through conventional Metal without the lease machinery; metal4 = Metal4Renderer.submit (argument tables, residency set, MTL4CommandQueue). All three use the same shader library, the same pipeline states and the same records. Cases: panel (base variant) and lens (optics variant: circular profile, thickness 28, dispersion 0.35).
Interleaving: per run and per case the order of the three arms rotates; each window is one arm alone (the GPU never runs two arms at once).

Pipeline compilation (seconds; the same functions, constants and attachment through each API). 0 GlassWeave renderer(s) had been created in this process before this measurement: 0 means these are the first creations in the process (the on-disk Metal shader cache can still be warm); more means the glass pipelines were already built by the legacy API, so the first Metal 4 compile is not comparable with it. Later creations of an identical pipeline can hit a shader cache.
  panel base via conventional, creation #0 of this pipeline: 0.0025 s
  panel base via metal4Compiler, creation #1 of this pipeline: 0.1269 s
  panel base via metal4Compiler, creation #2 of this pipeline: 0.0002 s
  panel base via conventional, creation #3 of this pipeline: 0.0001 s
  panel optics via metal4Compiler, creation #0 of this pipeline: 0.1007 s
  panel optics via conventional, creation #1 of this pipeline: 0.0002 s
  panel optics via conventional, creation #2 of this pipeline: 0.0001 s
  panel optics via metal4Compiler, creation #3 of this pipeline: 0.0001 s

Creation footprint (device.currentAllocatedSize with a stage alive after 30 frames, drained, minus the size before it existed; the textures are the six big resources, the remainder is renderer, queue, pipelines and API machinery):
  conventional (shipped): 81379328 B (77.6 MiB), textures 64602112 B, remainder 16777216 B; 0 B still allocated after the stage was dropped
  conventional control: 94142464 B (89.8 MiB), textures 77365248 B, remainder 16777216 B; 0 B still allocated after the stage was dropped
  metal4 (experiment): 94339072 B (90.0 MiB), textures 77365248 B, remainder 16973824 B; 0 B still allocated after the stage was dropped; command allocators 2453032 B, uniform ring 196608 B, residency set reports 77561856 B (it tracks the textures; not extra memory)
  remainder difference: metal4 − conventional control 196608 B; metal4 − conventional shipped 196608 B

Per window (ms; nearest-rank p50/p95/p99/max):
  run 1 panel conventional: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.361 / 0.659 / 0.747 / 4.144 (n 3600)
    encode  0.208 / 0.551 / 0.849 / 2.438 (n 3600)
    produce 0.088 / 0.185 / 0.471 / 1.830 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 1 panel conventionalRaw: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.354 / 0.884 / 1.349 / 2.346 (n 3600)
    encode  0.124 / 0.353 / 0.864 / 4.804 (n 3600)
    produce 0.083 / 0.174 / 0.494 / 2.511 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 1 panel metal4: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.362 / 1.037 / 1.466 / 2.730 (n 3600)
    encode  0.131 / 0.383 / 0.837 / 2.025 (n 3600)
    produce 0.098 / 0.249 / 0.688 / 1.462 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 1 lens conventionalRaw: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.407 / 1.362 / 1.900 / 4.360 (n 3600)
    encode  0.140 / 0.287 / 0.810 / 2.358 (n 3600)
    produce 0.082 / 0.141 / 0.428 / 1.811 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 1 lens metal4: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.481 / 1.888 / 2.006 / 2.108 (n 3600)
    encode  0.143 / 0.187 / 0.281 / 0.889 (n 3600)
    produce 0.100 / 0.137 / 0.214 / 0.725 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 1 lens conventional: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.443 / 1.333 / 1.891 / 3.629 (n 3600)
    encode  0.232 / 0.796 / 1.080 / 2.479 (n 3600)
    produce 0.090 / 0.173 / 0.523 / 1.797 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 2 panel conventionalRaw: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.369 / 1.257 / 1.776 / 3.643 (n 3600)
    encode  0.120 / 0.228 / 0.707 / 2.836 (n 3600)
    produce 0.079 / 0.145 / 0.330 / 1.613 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 2 panel metal4: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.412 / 1.318 / 1.862 / 4.000 (n 3600)
    encode  0.132 / 0.342 / 0.881 / 1.885 (n 3600)
    produce 0.101 / 0.203 / 0.715 / 2.926 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 2 panel conventional: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.342 / 1.244 / 1.730 / 4.214 (n 3600)
    encode  0.203 / 0.385 / 0.937 / 2.856 (n 3600)
    produce 0.089 / 0.156 / 0.346 / 2.906 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 2 lens metal4: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.471 / 1.277 / 1.613 / 4.221 (n 3600)
    encode  0.153 / 0.547 / 1.004 / 7.381 (n 3600)
    produce 0.105 / 0.296 / 0.806 / 3.132 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 2 lens conventional: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.446 / 1.371 / 1.914 / 4.288 (n 3600)
    encode  0.227 / 0.776 / 1.142 / 4.934 (n 3600)
    produce 0.092 / 0.186 / 0.738 / 4.645 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 2 lens conventionalRaw: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.443 / 1.376 / 1.934 / 3.978 (n 3600)
    encode  0.138 / 0.374 / 0.878 / 2.823 (n 3600)
    produce 0.082 / 0.164 / 0.660 / 1.740 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 3 panel metal4: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.379 / 0.818 / 1.393 / 4.727 (n 3600)
    encode  0.119 / 0.197 / 0.553 / 2.628 (n 3600)
    produce 0.096 / 0.169 / 0.520 / 1.423 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 3 panel conventional: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.383 / 0.470 / 1.945 / 4.594 (n 3600)
    encode  0.219 / 0.257 / 0.287 / 0.860 (n 3600)
    produce 0.098 / 0.134 / 0.156 / 1.145 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 3 panel conventionalRaw: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.399 / 0.477 / 1.937 / 4.565 (n 3600)
    encode  0.136 / 0.186 / 0.288 / 2.701 (n 3600)
    produce 0.094 / 0.157 / 0.207 / 2.640 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 3 lens conventional: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.437 / 0.550 / 2.021 / 4.602 (n 3600)
    encode  0.234 / 0.322 / 0.443 / 5.062 (n 3600)
    produce 0.107 / 0.182 / 0.263 / 7.363 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 3 lens conventionalRaw: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.443 / 0.553 / 1.987 / 4.453 (n 3600)
    encode  0.155 / 0.191 / 0.242 / 1.056 (n 3600)
    produce 0.090 / 0.126 / 0.174 / 1.111 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B
  run 3 lens metal4: 3600 ticks, 3600 drawn, 0 deferred at bound, 0 failed, 0 skipped
    GPU     0.334 / 0.622 / 1.490 / 4.526 (n 3600)
    encode  0.133 / 0.243 / 0.523 / 2.251 (n 3600)
    produce 0.089 / 0.164 / 0.332 / 3.322 (n 3600)
    allocated at commit: first 237371392 B, last 237371392 B, peak 237371392 B

Pooled per case and arm:
  panel conventional: 10800 frames
    GPU     0.376 / 0.726 / 1.784 / 4.594 (n 10800)
    encode  0.213 / 0.405 / 0.833 / 2.856 (n 10800)
    produce 0.093 / 0.149 / 0.326 / 2.906 (n 10800)
  panel conventionalRaw: 10800 frames
    GPU     0.376 / 0.964 / 1.882 / 4.565 (n 10800)
    encode  0.127 / 0.235 / 0.723 / 4.804 (n 10800)
    produce 0.085 / 0.157 / 0.366 / 2.640 (n 10800)
  panel metal4: 10800 frames
    GPU     0.394 / 1.244 / 1.749 / 4.727 (n 10800)
    encode  0.128 / 0.307 / 0.803 / 2.628 (n 10800)
    produce 0.099 / 0.203 / 0.651 / 2.926 (n 10800)
  panel metal4 − conventionalRaw (API only, the decision comparison): GPU p50 +0.017 ms, GPU p95 +0.280 ms, encode p50 +0.001 ms, encode p95 +0.072 ms
    ratios subject / baseline: GPU p50 1.046, GPU p95 1.291, encode p50 1.005, encode p95 1.307
  panel conventional − conventionalRaw (what the lease machinery costs): GPU p50 -0.000 ms, GPU p95 -0.238 ms, encode p50 +0.086 ms, encode p95 +0.170 ms
    ratios subject / baseline: GPU p50 0.999, GPU p95 0.753, encode p50 1.676, encode p95 1.724
  panel metal4 − conventional (experiment against the shipped path): GPU p50 +0.018 ms, GPU p95 +0.518 ms, encode p50 -0.085 ms, encode p95 -0.098 ms
    ratios subject / baseline: GPU p50 1.047, GPU p95 1.714, encode p50 0.599, encode p95 0.758
  lens conventional: 10800 frames
    GPU     0.443 / 1.311 / 1.950 / 4.602 (n 10800)
    encode  0.231 / 0.608 / 1.056 / 5.062 (n 10800)
    produce 0.096 / 0.181 / 0.509 / 7.363 (n 10800)
  lens conventionalRaw: 10800 frames
    GPU     0.442 / 1.327 / 1.929 / 4.453 (n 10800)
    encode  0.145 / 0.243 / 0.756 / 2.823 (n 10800)
    produce 0.085 / 0.143 / 0.415 / 1.811 (n 10800)
  lens metal4: 10800 frames
    GPU     0.439 / 1.449 / 1.979 / 4.526 (n 10800)
    encode  0.142 / 0.293 / 0.787 / 7.381 (n 10800)
    produce 0.099 / 0.180 / 0.597 / 3.322 (n 10800)
  lens metal4 − conventionalRaw (API only, the decision comparison): GPU p50 -0.003 ms, GPU p95 +0.123 ms, encode p50 -0.002 ms, encode p95 +0.050 ms
    ratios subject / baseline: GPU p50 0.993, GPU p95 1.092, encode p50 0.984, encode p95 1.204
  lens conventional − conventionalRaw (what the lease machinery costs): GPU p50 +0.000 ms, GPU p95 -0.016 ms, encode p50 +0.086 ms, encode p95 +0.364 ms
    ratios subject / baseline: GPU p50 1.001, GPU p95 0.988, encode p50 1.597, encode p95 2.497
  lens metal4 − conventional (experiment against the shipped path): GPU p50 -0.004 ms, GPU p95 +0.138 ms, encode p50 -0.089 ms, encode p95 -0.315 ms
    ratios subject / baseline: GPU p50 0.992, GPU p95 1.106, encode p50 0.616, encode p95 0.482

Steady state (per arm, cases pooled: GPU of the first third of each window's frames against the last third; device allocation across the windows):
  conventional: GPU first third 0.390 / 0.892 / 1.926 / 4.455 (n 7200), last third 0.397 / 1.187 / 1.928 / 4.594 (n 7200); failed command buffers 0; allocated bytes, first commit to last commit: +0 B (device-wide, so it includes the other arms' resources, which exist throughout)
  conventionalRaw: GPU first third 0.393 / 1.075 / 1.909 / 4.565 (n 7200), last third 0.400 / 1.302 / 1.924 / 4.540 (n 7200); failed command buffers 0; allocated bytes, first commit to last commit: +0 B (device-wide, so it includes the other arms' resources, which exist throughout)
  metal4: GPU first third 0.407 / 1.364 / 1.950 / 4.727 (n 7200), last third 0.404 / 1.389 / 1.921 / 4.433 (n 7200); failed command buffers 0; allocated bytes, first commit to last commit: +0 B (device-wide, so it includes the other arms' resources, which exist throughout)
  Metal 4 command allocators after the run: 4828712 B

Decision rule and status: see docs/decisions/metal-backend.md. This report is a smoke run unless the settings above say otherwise.
```
