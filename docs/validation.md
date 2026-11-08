# GlassWeave validation protocol

This document defines future acceptance work. No implementation, build, runtime test, trace, or performance measurement has been completed by this planning repository. Every number below is a provisional engineering target, not an observed result or a general device guarantee.

## What each kind of evidence proves

| Evidence | Establishes | Does not establish |
| --- | --- | --- |
| Package build | Manifest/module integration and compiler correctness | Optical quality, interaction, GPU safety, or performance. |
| Swift Testing | Deterministic contract, shape, scheduling, and lifecycle logic | Correct output on a real display or safe GPU execution by itself. |
| Simulator run | Basic presentation and control behavior | Physical GPU timings, energy use, or thermal sustainability. |
| Metal API Validation/frame capture | Resource use and encoded rendering behavior | Production performance with validation disabled. |
| Physical-device trace | Cost under a recorded workload and device state | A universal performance promise. |
| Accessibility interaction | Behavior under the tested assistive settings | Every possible combination of content, language, and layout. |

For local Apple work, load the relevant Xcode 27 skill first, then use native Xcode MCP for builds, runs, tests, diagnostics, and device interaction. Use Xcode/Instruments for profiling. Do not substitute the simulator for physical measurement.

## Fixed first-milestone workload

The laboratory shows a full-screen, deterministic moving SDR background; one rounded custom panel with a nominal 320 × 180 point size constrained to available layout width; native text and a native button on that panel; and one adjacent genuine native-glass reference control. Render at native drawable scale initially. Record the resulting pixel size and the actual panel size on every device.

Use a fixed random seed, repeatable animation clock, reset action, and frame-ID overlay that can be disabled for timing. Maintain exactly the same source workload in the native-only comparison. Measure these modes:

1. Owned moving background, no custom panel: baseline cost.
2. Same background plus native reference glass.
3. Same background plus native reference and one custom panel.
4. Frozen source and settled panel: idle scheduling check.
5. Repeated hide/show, resize/rotation, and app background/foreground: lifetime stress.

For initial optical correctness, add fixed four-corner orientation patterns, checkerboards, gradients, bright/dark edges, and a zero-refraction case. Keep deterministic stills separate from the timed workload.

## Device matrix

Before GW-09, name the available baseline physical iPhone and one modern higher-refresh iPhone. Prefer the oldest representative device available within the intended iOS 26 support range. Record an iPad layout run before claiming iPad presentation support. If a device class cannot be tested, keep it unqualified in the support matrix.

| Dimension | Record |
| --- | --- |
| Hardware | Model, SoC, physical RAM where known, display refresh capability. |
| Software | OS build, Xcode/SDK version, compiler version, commit, build configuration. |
| Rendering | Selected backend, GPU feature support, drawable pixels, panel pixels, texture formats, in-flight limit. |
| Conditions | Brightness, Low Power Mode, thermal state, charging state, orientation, accessibility settings. |
| Workload | Seed, scenario version, elapsed time, source/update rate, requested refresh target. |

An operating system baseline is not a GPU capability check. Record actual supported features rather than inferring them only from the OS or marketing name.

## Provisional budgets for the first panel

Use the selected baseline device at 60 Hz for the initial gate. Revisit these targets transparently after the first trace if the chosen workload/device makes them inappropriate; record the old target, reason, and new target rather than silently lowering the bar.

| Measure | Initial target | Measurement definition |
| --- | --- | --- |
| Comparative GPU budget | p95(custom total GPU duration) − p95(native-reference total GPU duration) ≤ 2.0 ms | A comparative statistic from repeated matched runs, not the p95 of per-frame incremental cost. Retain and report both complete distributions. Where tooling can isolate custom GPU work, also report its directly measured distribution. |
| Custom CPU encoding | p95 ≤ 1.0 ms/frame | Time spent preparing/encoding custom work; report UI submission separately. |
| Presentation pacing | Missed display opportunities < 1% in the steady five-minute 60 Hz run | Record actual presentation intervals and chosen tolerance; do not classify the requested FPS alone as achieved FPS. |
| Interaction | No added main-thread stall > 16.7 ms attributable to GlassWeave during scripted control interaction | Correlate signposts and main-thread traces. Do not describe this as measured touch-to-photon latency. |
| Managed resources | ≤ 64 MiB incremental retained Metal allocation for the fixed one-panel workload | Count allocated texture/buffer bytes, including pools and retained in-flight storage, and explain which source allocations are shared with the baseline. |
| Steady memory | No sustained growth after warm-up or 100 lifecycle cycles | Compare settled allocations and process memory; investigate retained per-cycle resources. |
| Idle | No continuous custom submissions after source/effect settles | Submission count may change only for explicit invalidation or lifecycle transitions. |
| Compilation | No pipeline/shader compilation during steady interaction | Instrument compilation and compare first-use vs warmed behavior. |

The 120 Hz scenario is initially characterization only. If later claimed as supported, establish its own 8.33 ms frame-budget gate. Energy and thermal behavior should be reported comparatively; a portable numeric energy threshold is not presumed. Any serious/critical thermal transition or progressive frame degradation must be explained before claiming sustained efficiency.

## Capture recipe

1. Build a Release configuration at a recorded commit. Verify with Metal API Validation in a separate correctness run, then disable expensive validation for timing. Warm required pipelines and run a 30-second warm-up.
2. On the baseline device, run each moving scenario for five minutes, three times. Reset the scene between runs. Interleave baseline and custom modes to reduce order/temperature bias; allow the device to return to the recorded starting thermal state.
3. Use Metal System Trace/GPU counters as available for GPU and submission timing, Time Profiler/signposts for CPU work, and allocation/memory instrumentation for retained resources. Name the exact instruments and any unsupported counters.
4. Report p50/p95/p99 CPU and GPU samples, presentation intervals, missed-opportunity count, steady/peak memory, source/rendered/dropped frame counts, and thermal/energy observations. Preserve the individual runs; do not present an average that hides one failing run.
5. Execute a fixed control sequence while rendering: tap each button, drag/scroll adjacent native content, rotate, hide/show, and background/foreground. Use recorded UI actions where possible; verify resulting action counts and content state.
6. Freeze the source and let all effects settle for 30 seconds. Verify no repeating custom submissions. Then perform 100 lifecycle cycles and compare retained allocations after pending GPU work retires.
7. Repeat the defined scenarios on the modern device. Store a concise report and representative captures under `docs/evidence/`; link large traces through an agreed artifact location instead of committing large binary traces by default.

The first report is planned at `docs/evidence/milestone-1.md`. It must identify unavailable tools/counters or untested devices plainly. Missing measurements are not passes.

## Correctness cases

- Source and display frame IDs agree; no background/refraction temporal mismatch during animation or resizing.
- All four orientation markers remain correct across point/pixel scale, rotation, cropping, safe areas, and asymmetric layout changes. Size comes from host bounds and display-scale traits, not a global screen size.
- Zero-size drawable, unavailable drawable, missing source, invalid source metadata, invalid parameters, and unsupported capability have defined behavior.
- Resource reuse waits for all consumers; teardown, cancellation, producer stalls, and overload do not leak a lease or reuse a live texture.
- Two hosts retain independent visibility/lifecycle state; a hidden or inactive owning scene does not globally pause another visible scene's renderer.
- Zero-refraction output matches the reference within a documented per-format tolerance; edge sampling does not reveal uninitialized texels.
- The same optical inputs produce repeatable images. Image differences are evaluated with a documented tolerance and inspected, not hidden with an arbitrarily high threshold.

Use Swift Testing for deterministic math, validation, and lifecycle state. Use native device/UI tests for interaction. GPU reference tests must pin the scene, format, OS/backend metadata, and tolerance; a deliberate rendering change requires a reviewed reference update.

## Accessibility and integration matrix

| Case | Expected behavior |
| --- | --- |
| VoiceOver | Native control labels, focus order, and activation work; no duplicate decorative element. |
| Largest Dynamic Type used by the sample | Text remains visible, layout expands or scrolls, and controls remain actionable. |
| Reduce Motion | Nonessential background/effect motion is removed or substituted without changing content meaning. |
| Reduce Transparency | A legible opaque surface keeps the native content and action intact. |
| Light/dark appearance | Optical and text contrast remain legible over bright/dark source regions. |
| Native scrolling/gestures | Decorative gesture observation does not cancel expected scroll or button behavior. |
| Window/layout changes | Source UVs, native content, and optical bounds remain aligned. |

Load the matching Apple accessibility skills when implementing or auditing these behaviors. If a setting intentionally changes only the app's demonstration background rather than the framework's surface, document that ownership clearly.

## Milestone report template

```markdown
# Milestone 1 evidence
Commit / date / operator:
Device and OS / SDK:
Build configuration / backend:
Scenario version / seed / dimensions:
Tools / unavailable measurements:

## Correctness
Cases passed, failures, screenshots/frame-capture references.

## Cost
Per-run baseline and custom results, distributions, retained bytes, pacing,
idle submissions, compilation events, thermal/energy observations.

## Interaction and accessibility
Tested settings, action counts, findings, and unresolved cases.

## Decision
Each target: measured pass, measured fail, or not measured.
Qualified device/support matrix.
Required follow-up tasks and evidence links.
```

Successful repository creation or a clean package build never substitutes for this report.
