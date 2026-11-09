# Glow characterization (GW-18): Apple M5 Mac, offscreen

**Not device evidence.** This is `GlassWeaveCharacterizationTests` rendering
the GW-09 fixed workload offscreen on an Apple M5 Mac, extended with a glow
mode for GW-18. It describes that Mac's GPU only; no iPhone or iPad has been
measured. See [the glow design](../glow.md#cost-apple-m5-mac-offscreen-characterization-not-device-evidence)
for what the modes contain.

Run on 2026-11-09 through Xcode MCP `RunAllTests`, scheme
`GlassWeaveCharacterization` (Release, no Metal API Validation), destination
My Mac, at the commit that added the glow mode. Times are milliseconds,
nearest-rank p50 / p95 / p99 / max. GPU time is one command buffer per
frame: the laboratory's procedural background rendered into a pooled
texture, the background pass, and (modes *panel* and *glow*) the panel.

| Mode | GPU p95, run 1 / 2 / 3 | Pooled GPU p50 / p95 / p99 / max (10,800 frames) |
| --- | --- | --- |
| background | 0.743 / 0.741 / 0.743 | 0.688 / 0.743 / 0.774 / 1.135 |
| panel | 0.878 / 0.875 / 0.874 | 0.782 / 0.876 / 0.899 / 0.966 |
| glow | 1.136 / 1.138 / 1.133 | 1.083 / 1.136 / 1.174 / 1.330 |

- p95(glow) − p95(panel), the glow's increment over the plain panel:
  +0.258, +0.263, +0.259 ms; pooled +0.260 ms.
- p95(panel) − p95(background): +0.135, +0.134, +0.131 ms; pooled +0.133 ms.
  The GW-09 record measured +0.037 ms (runs +0.001 to +0.103) for the
  panel before the glow existed. Short A/B runs during GW-18 showed that a
  `discard_fragment()` in the panel shader alone had raised it to about
  +0.2 ms, so GW-18 does not discard; the remaining difference from the GW-09
  figure was not isolated (its runs had a spread as large as the statistic,
  and the panel shader has grown since GW-05).
- Every run drew all 3,600 ticks: no declined productions, no pool
  exhaustion, no coalesced requests, no deferrals at the in-flight bound, no
  skipped draws, no failed command buffers.
- Idle (300 display passes in 5 s with nothing requested) submitted and
  produced nothing; 100 lifecycle cycles left `currentAllocatedSize`
  unchanged (65,519,616 B before and after).

The complete report:

```
GlassWeave characterization, workload version 2
Machine GPU: Apple M5, native; highest Apple family apple10, Metal 3 true, Metal 4 true
OS: Version 27.2 (Build 26B123)
Build: Release (DEBUG not defined); command queue class AGXG17GFamilyCommandQueue
Conditions: thermal state nominal at start, nominal at end; Low Power Mode off
Settings: 3 run(s) per mode, 60.0 s measured after 10.0 s warm-up, 100 lifecycle cycles
Workload: target 1206×2622 px at scale 3.0; panel 320×180 pt = 960×540 px; 60 Hz requests; in-flight bound 2; pool 3; frame-ID strip off
Glow mode (GW-18): the panel plus 2 colors, rim 2.0 + 2.5 pt, inner glow 22.0 pt × 0.75, halo 28.0 pt × 0.9 (quad 1130×710 px), pulse 1.8 s × 0.55, effect time advancing 1/60 s per tick

Per run (ms; nearest-rank percentiles p50/p95/p99/max):
  run 1 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.688 / 0.743 / 0.773 / 0.862 (n 3600) (0 frames without GPU time)
    encode  0.094 / 0.118 / 0.144 / 0.205 (n 3600)
    produce 0.040 / 0.060 / 0.083 / 0.153 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.784 / 0.878 / 0.900 / 0.954 (n 3600) (0 frames without GPU time)
    encode  0.097 / 0.124 / 0.151 / 0.276 (n 3600)
    produce 0.039 / 0.058 / 0.080 / 0.449 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 1 glow: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.084 / 1.136 / 1.172 / 1.295 (n 3600) (0 frames without GPU time)
    encode  0.099 / 0.128 / 0.162 / 0.577 (n 3600)
    produce 0.040 / 0.061 / 0.088 / 0.170 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.782 / 0.875 / 0.899 / 0.925 (n 3600) (0 frames without GPU time)
    encode  0.098 / 0.123 / 0.147 / 0.238 (n 3600)
    produce 0.039 / 0.059 / 0.078 / 0.145 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 glow: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.083 / 1.138 / 1.180 / 1.330 (n 3600) (0 frames without GPU time)
    encode  0.100 / 0.133 / 0.163 / 0.302 (n 3600)
    produce 0.040 / 0.065 / 0.097 / 0.164 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 2 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.687 / 0.741 / 0.775 / 0.921 (n 3600) (0 frames without GPU time)
    encode  0.093 / 0.121 / 0.145 / 0.342 (n 3600)
    produce 0.040 / 0.062 / 0.087 / 0.160 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 glow: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     1.081 / 1.133 / 1.165 / 1.270 (n 3600) (0 frames without GPU time)
    encode  0.099 / 0.127 / 0.153 / 0.280 (n 3600)
    produce 0.039 / 0.059 / 0.078 / 0.223 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 background: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.688 / 0.743 / 0.774 / 1.135 (n 3600) (0 frames without GPU time)
    encode  0.092 / 0.119 / 0.147 / 0.221 (n 3600)
    produce 0.039 / 0.060 / 0.080 / 0.255 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB
  run 3 panel: 3600 ticks, 3600 drawn, 0 declined productions, 0 pool-exhausted, 0 coalesced, 0 deferred at bound, 0 skipped, 0 failed
    GPU     0.781 / 0.874 / 0.898 / 0.966 (n 3600) (0 frames without GPU time)
    encode  0.098 / 0.124 / 0.145 / 0.212 (n 3600)
    produce 0.040 / 0.058 / 0.076 / 0.128 (n 3600)
    acquire 0.000 / 0.000 / 0.000 / 0.000 (n 3600)
    Metal allocated: peak 62.5 MiB, pool textures 24.3 MiB

Pooled per mode:
  background: 10800 frames
    GPU     0.688 / 0.743 / 0.774 / 1.135 (n 10800)
    encode  0.093 / 0.119 / 0.145 / 0.342 (n 10800)
    produce 0.039 / 0.061 / 0.084 / 0.255 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 10800)
  panel: 10800 frames
    GPU     0.782 / 0.876 / 0.899 / 0.966 (n 10800)
    encode  0.098 / 0.124 / 0.147 / 0.276 (n 10800)
    produce 0.040 / 0.058 / 0.078 / 0.449 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 10800)
  glow: 10800 frames
    GPU     1.083 / 1.136 / 1.174 / 1.330 (n 10800)
    encode  0.100 / 0.129 / 0.161 / 0.577 (n 10800)
    produce 0.040 / 0.061 / 0.089 / 0.223 (n 10800)
    acquire 0.000 / 0.000 / 0.000 / 0.001 (n 10800)

Comparative GPU statistic, p95(panel) − p95(background):
  run 1: +0.135 ms
  run 2: +0.134 ms
  run 3: +0.131 ms
  pooled: +0.133 ms
Comparative GPU statistic, p95(glow) − p95(panel):
  run 1: +0.258 ms
  run 2: +0.263 ms
  run 3: +0.259 ms
  pooled: +0.260 ms
Comparative GPU statistic, p95(glow) − p95(background):
  run 1: +0.393 ms
  run 2: +0.397 ms
  run 3: +0.390 ms
  pooled: +0.393 ms

Idle: 300 display passes in 5.0 s with nothing requested: 0 submissions, 0 frames produced
Lifecycle: 100 cycles of hide (trim) / 2 hidden ticks / show / rotate / 4 ticks
  settled currentAllocatedSize before 65519616 B (62.5 MiB), after 65519616 B (62.5 MiB), change 0 B
  pool before: 2 textures, 24.3 MiB, 2 allocations; after: 2 textures, 24.3 MiB, 302 allocations, 300 discarded
```
