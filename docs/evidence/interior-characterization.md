# Interior characterization (GW-19): Apple M5 Mac, offscreen

**Not device evidence.** This is `GlassWeaveCharacterizationTests` rendering
the GW-09 fixed workload offscreen on an Apple M5 Mac, extended for GW-19
with three interior modes. It describes that Mac's GPU only; no iPhone or
iPad has been measured. The interior modes are the GW-18 `glow` mode (the
320 × 180 pt panel at scale 3 with a rim, inner glow, 28-point halo, and
pulse) plus one interior each, with the laboratory presets' intensity
(0.85), speed 1, the documented center fade (1), and three fixed stand-in
colors, moving with the effect time (1/60 s per tick). Their increment over
`glow` isolates the interior; `glow` itself is the GW-17 rim and inner glow
plus the GW-18 halo and pulse, kept because the embers' sparks rise into
the halo. See [the glow design](../glow.md#gw-19-animated-interiors-implemented).

Run on 2026-11-09 through Xcode MCP `RunAllTests`, scheme
`GlassWeaveCharacterization` (Release, no Metal API Validation), destination
My Mac, three interleaved runs of 60 s per mode after 10 s warm-ups, thermal
state nominal at start and end. Times are milliseconds, nearest-rank p50 /
p95 / p99 / max; GPU time is one command buffer per frame (the laboratory's
procedural background into a pooled texture, the background pass, and the
panel).

| Mode | GPU p95, run 1 / 2 / 3 | Pooled GPU p50 / p95 / p99 / max (10,800 frames) |
| --- | --- | --- |
| background | 0.746 / 0.775 / 0.775 | 0.705 / 0.769 / 0.809 / 0.965 |
| panel | 0.911 / 0.927 / 0.921 | 0.831 / 0.920 / 0.946 / 1.045 |
| glow | 1.202 / 1.190 / 1.189 | 1.135 / 1.195 / 1.236 / 5.164 |
| energy | 1.811 / 1.784 / 1.778 | 1.728 / 1.794 / 1.847 / 2.104 |
| rays | 1.525 / 1.499 / 1.503 | 1.451 / 1.513 / 1.561 / 1.728 |
| embers | 1.718 / 1.702 / 1.707 | 1.645 / 1.710 / 1.757 / 1.922 |

- Interior increments, p95(mode) − p95(glow), runs 1 / 2 / 3 and pooled:
  energy +0.608 / +0.594 / +0.589, pooled **+0.600 ms**; rays +0.323 /
  +0.309 / +0.315, pooled **+0.318 ms**; embers +0.516 / +0.512 / +0.518,
  pooled **+0.515 ms**.
- For context: glow − panel +0.274 ms pooled (+0.260 in the GW-18 record),
  panel − background +0.151 ms pooled (+0.133 in the GW-18 record). This run's
  baselines are about 0.03 to 0.06 ms higher than the GW-18 record's
  throughout (background p95 0.769 against 0.743), which was not isolated;
  the comparisons within this run are what it reports.
- Every run drew all 3,600 ticks: no declined productions, no pool
  exhaustion, no coalesced requests, no deferrals at the in-flight bound, no
  skipped draws, no failed command buffers. One `glow` frame took 5.164 ms
  (its p99 is 1.236 ms); it was not investigated.
- Idle (300 display passes in 5 s with nothing requested) submitted and
  produced nothing; 100 lifecycle cycles left `currentAllocatedSize`
  unchanged (65,519,616 B before and after).
- The interior's cost before it was reduced (power-of-two lattice masks
  instead of integer division, sparks computed on the CPU, single-octave
  warps for energy, culled flame turbulence) was measured only in the short
  Debug passes of the `GlassWeave` scheme (60 frames, Metal API Validation
  on): energy +2.26, rays +0.37, embers +1.97 ms; the same passes after it
  gave +0.60, +0.30, +0.49 ms. Those short passes are indicative only.

The complete report:

```
GlassWeave characterization, workload version 2
Machine GPU: Apple M5, native; highest Apple family apple10, Metal 3 true, Metal 4 true
OS: Version 27.2 (Build 26B123)
Build: Release (DEBUG not defined); command queue class AGXG17GFamilyCommandQueue
Conditions: thermal state nominal at start, nominal at end; Low Power Mode off
Settings: 3 run(s) per mode, 60.0 s measured after 10.0 s warm-up, 100 lifecycle cycles
Workload: target 1206×2622 px at scale 3.0; panel 320×180 pt = 960×540 px; 60 Hz requests; in-flight bound 2; pool 3; frame-ID strip off
Interior modes (GW-19): the glow mode plus an energy, rays, or embers interior, 3 colors, intensity 0.85, speed 1.0, center fade 1.0, moving with the effect time
Glow mode (GW-18): the panel plus 2 colors, rim 2.0 + 2.5 pt, inner glow 22.0 pt × 0.75, halo 28.0 pt × 0.9 (quad 1130×710 px), pulse 1.8 s × 0.55, effect time advancing 1/60 s per tick

Per run (ms; nearest-rank percentiles p50/p95/p99/max):
  run 1 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.690 / 0.746 / 0.783 / 0.889 (n 3600) (0 frames without GPU time)
    encode  0.092 / 0.117 / 0.135 / 0.202 (n 3600)
    produce 0.039 / 0.058 / 0.073 / 0.126 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.825 / 0.911 / 0.934 / 1.002 (n 3600) (0 frames without GPU time)
    encode  0.099 / 0.127 / 0.151 / 0.290 (n 3600)
    produce 0.039 / 0.058 / 0.078 / 0.146 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.009 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 glow: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.129 / 1.202 / 1.236 / 5.164 (n 3600) (0 frames without GPU time)
    encode  0.102 / 0.160 / 0.217 / 1.082 (n 3600)
    produce 0.041 / 0.081 / 0.105 / 0.249 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.008 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 energy: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.740 / 1.811 / 1.861 / 1.975 (n 3600) (0 frames without GPU time)
    encode  0.105 / 0.150 / 0.193 / 0.567 (n 3600)
    produce 0.042 / 0.076 / 0.112 / 0.181 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.006 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 rays: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.463 / 1.525 / 1.574 / 1.728 (n 3600) (0 frames without GPU time)
    encode  0.103 / 0.140 / 0.172 / 0.968 (n 3600)
    produce 0.041 / 0.066 / 0.088 / 0.183 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 embers: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.653 / 1.718 / 1.770 / 1.879 (n 3600) (0 frames without GPU time)
    encode  0.103 / 0.136 / 0.176 / 0.392 (n 3600)
    produce 0.040 / 0.064 / 0.096 / 0.303 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.833 / 0.927 / 0.954 / 1.045 (n 3600) (0 frames without GPU time)
    encode  0.099 / 0.130 / 0.165 / 0.254 (n 3600)
    produce 0.040 / 0.064 / 0.092 / 0.158 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.003 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 glow: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.136 / 1.190 / 1.238 / 1.402 (n 3600) (0 frames without GPU time)
    encode  0.101 / 0.136 / 0.170 / 0.251 (n 3600)
    produce 0.040 / 0.068 / 0.091 / 0.164 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.005 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 energy: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.723 / 1.784 / 1.828 / 1.930 (n 3600) (0 frames without GPU time)
    encode  0.102 / 0.136 / 0.179 / 0.278 (n 3600)
    produce 0.040 / 0.065 / 0.093 / 0.159 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 rays: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.445 / 1.499 / 1.553 / 1.717 (n 3600) (0 frames without GPU time)
    encode  0.102 / 0.139 / 0.170 / 0.513 (n 3600)
    produce 0.040 / 0.066 / 0.087 / 0.176 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 embers: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.642 / 1.702 / 1.750 / 1.922 (n 3600) (0 frames without GPU time)
    encode  0.102 / 0.136 / 0.176 / 0.231 (n 3600)
    produce 0.039 / 0.063 / 0.089 / 0.138 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.714 / 0.775 / 0.816 / 0.937 (n 3600) (0 frames without GPU time)
    encode  0.092 / 0.118 / 0.146 / 0.234 (n 3600)
    produce 0.040 / 0.060 / 0.084 / 0.130 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 glow: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.138 / 1.189 / 1.230 / 1.622 (n 3600) (0 frames without GPU time)
    encode  0.101 / 0.131 / 0.169 / 0.322 (n 3600)
    produce 0.039 / 0.061 / 0.086 / 0.146 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 energy: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.723 / 1.778 / 1.831 / 2.104 (n 3600) (0 frames without GPU time)
    encode  0.102 / 0.133 / 0.164 / 0.318 (n 3600)
    produce 0.039 / 0.060 / 0.084 / 0.595 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 rays: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.448 / 1.503 / 1.552 / 1.664 (n 3600) (0 frames without GPU time)
    encode  0.101 / 0.133 / 0.155 / 0.210 (n 3600)
    produce 0.039 / 0.061 / 0.079 / 0.123 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 embers: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.641 / 1.707 / 1.751 / 1.856 (n 3600) (0 frames without GPU time)
    encode  0.104 / 0.141 / 0.187 / 0.268 (n 3600)
    produce 0.040 / 0.067 / 0.094 / 0.217 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.713 / 0.775 / 0.816 / 0.965 (n 3600) (0 frames without GPU time)
    encode  0.092 / 0.123 / 0.153 / 0.249 (n 3600)
    produce 0.039 / 0.062 / 0.087 / 0.140 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.835 / 0.921 / 0.946 / 0.985 (n 3600) (0 frames without GPU time)
    encode  0.099 / 0.127 / 0.153 / 0.359 (n 3600)
    produce 0.040 / 0.059 / 0.075 / 0.216 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.005 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB

Pooled per mode:
  background: 10800 frames
    GPU     0.705 / 0.769 / 0.809 / 0.965 (n 10800)
    encode  0.092 / 0.119 / 0.146 / 0.249 (n 10800)
    produce 0.039 / 0.060 / 0.081 / 0.140 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 10800)
  panel: 10800 frames
    GPU     0.831 / 0.920 / 0.946 / 1.045 (n 10800)
    encode  0.099 / 0.128 / 0.155 / 0.359 (n 10800)
    produce 0.039 / 0.060 / 0.084 / 0.216 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.009 (n 10800)
  glow: 10800 frames
    GPU     1.135 / 1.195 / 1.236 / 5.164 (n 10800)
    encode  0.101 / 0.140 / 0.198 / 1.082 (n 10800)
    produce 0.040 / 0.070 / 0.097 / 0.249 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.008 (n 10800)
  energy: 10800 frames
    GPU     1.728 / 1.794 / 1.847 / 2.104 (n 10800)
    encode  0.103 / 0.140 / 0.182 / 0.567 (n 10800)
    produce 0.040 / 0.068 / 0.100 / 0.595 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.006 (n 10800)
  rays: 10800 frames
    GPU     1.451 / 1.513 / 1.561 / 1.728 (n 10800)
    encode  0.102 / 0.137 / 0.167 / 0.968 (n 10800)
    produce 0.040 / 0.065 / 0.085 / 0.183 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 10800)
  embers: 10800 frames
    GPU     1.645 / 1.710 / 1.757 / 1.922 (n 10800)
    encode  0.103 / 0.138 / 0.178 / 0.392 (n 10800)
    produce 0.040 / 0.065 / 0.092 / 0.303 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 10800)

Comparative GPU statistic, p95(panel) − p95(background):
  run 1: +0.164 ms
  run 2: +0.151 ms
  run 3: +0.146 ms
  pooled: +0.151 ms
Comparative GPU statistic, p95(glow) − p95(panel):
  run 1: +0.292 ms
  run 2: +0.263 ms
  run 3: +0.267 ms
  pooled: +0.274 ms
Comparative GPU statistic, p95(glow) − p95(background):
  run 1: +0.456 ms
  run 2: +0.415 ms
  run 3: +0.414 ms
  pooled: +0.426 ms
Comparative GPU statistic, p95(energy) − p95(glow):
  run 1: +0.608 ms
  run 2: +0.594 ms
  run 3: +0.589 ms
  pooled: +0.600 ms
Comparative GPU statistic, p95(rays) − p95(glow):
  run 1: +0.323 ms
  run 2: +0.309 ms
  run 3: +0.315 ms
  pooled: +0.318 ms
Comparative GPU statistic, p95(embers) − p95(glow):
  run 1: +0.516 ms
  run 2: +0.512 ms
  run 3: +0.518 ms
  pooled: +0.515 ms

Idle: 300 display passes in 5.0 s with nothing requested: 0 submissions, 0 frames produced
Lifecycle: 100 cycles of hide (trim) / 2 hidden ticks / show / rotate / 4 ticks
  settled currentAllocatedSize before 65519616 B (62.5 MiB), after 65519616 B (62.5 MiB), change 0 B
  pool before: 2 textures, 24.3 MiB, 2 allocations; after: 2 textures, 24.3 MiB, 302 allocations, 300 discarded
```
