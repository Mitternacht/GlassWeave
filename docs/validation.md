# GlassWeave validation protocol

This document defines the acceptance work. Sections headed "Recorded" or "Implemented" describe what exists and what was measured; everything else is the protocol. Every budget below is a provisional engineering target, not an observed result or a general device guarantee. No physical device has been measured yet; see [the Milestone 1 report](evidence/milestone-1.md).

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

### Implemented scenario and measurement (GW-09)

The laboratory runs this workload with `-lab.benchmark <mode>`
(`Examples/GlassWeaveLab/GlassWeaveLab/BenchmarkScenario.swift`, scenario
version 2). The modes are `baseline` (1), `native` (2), `custom` (3), `idle`
(4: mode 3 with the source frozen at content time zero), and `lifecycle` (5:
mode 3 with 100 hide/show and resize cycles drawn from
`-lab.benchmark.seed <number>`, default `0x67570009`, between two settled
allocation measurements). Every mode uses the same moving source, a pure
function of the deterministic clock, so frame *n* is identical in every mode
and run; the seed only orders the stress. In a benchmark the stage, and so
the rendered surface, fills the whole screen (1206 × 2622 px on the iPhone 18
Pro simulator in portrait), with the controls above it on an opaque backdrop
and the native content in the part of the stage the controls leave free;
version 1 rendered only the stage above the controls (1206 × 1524 px there).
The frame-ID strip starts off (the Frame ID switch turns it on), Reset also restarts the
metrics window, the diagnostics refresh once a second from a timer rather
than from frames, and Settle and measure stops the clock, waits for frames
in flight, and reports allocated bytes.

`RenderMetrics` (core, public) is the measurement: assign one to
`GlassRenderer.metrics`. Per committed command buffer it records the CPU time
of GlassWeave's preparation and encoding, of the app's producer, and of
target (drawable) acquisition, separately; `gpuStartTime`/`gpuEndTime`; and
`MTLDevice.currentAllocatedSize`. It counts draws, drawn frames, skips,
rejected and declined productions (a declined production is a dropped
frame), and committed, completed, and failed command buffers, and reduces a
bounded window of samples to nearest-rank p50/p95/p99/max. Coalesced
requests and deferrals at the in-flight bound come from `FrameStatistics`;
pooled textures and their bytes from `FrameTexturePool.Statistics`. It does
not measure presentation intervals or missed display opportunities,
main-thread stalls, pipeline compilation, or energy; those still need
Instruments on a device. The iOS Simulator reports zero for every Metal
allocation size, so `RenderMetrics` gives `nil` there and no simulator
allocation figure exists.

`Tests/GlassWeaveCharacterizationTests` renders an offscreen approximation
of the workload (the laboratory's shader, pool, in-flight bound, 60 Hz
requests; 1206 × 2622 px, the laboratory's full-screen size on the iPhone 18
Pro simulator; a 320 × 180 pt panel centered on the surface rather than
placed above the controls; no native views or controls) and compares mode 1
with GlassWeave's share of mode 3. It then runs an idle check (display
passes at 60 Hz for 5 s with nothing requested, which must produce and
submit nothing; it fails if the scheduler draws unrequested frames) and
compares allocations after lifecycle cycles. The `GlassWeave` scheme runs it briefly under Metal API
Validation; the `GlassWeaveCharacterization` scheme runs it in Release
without validation, three interleaved 60 s runs per mode after 10 s
warm-ups and 100 lifecycle cycles (environment variables
`GLASSWEAVE_CHARACTERIZATION_RUNS`, `_SECONDS`, `_WARMUP_SECONDS`,
`_LIFECYCLE_CYCLES`). On a Mac it characterizes the Mac only; the native
reference glass is not part of an offscreen render.

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

The first report is [`docs/evidence/milestone-1.md`](evidence/milestone-1.md). It must identify unavailable tools/counters or untested devices plainly. Missing measurements are not passes. As of GW-09 it records no device measurement: every device target is not measured.

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

### Recorded accessibility matrix (GW-08, 2026-11-08)

Simulators only (iOS 27.2: iPhone 18 Pro, iPad Pro 13-inch (M5)); no
physical device. Lab UI tests live in `AccessibilityUITests` and
`CoexistenceUITests`; package tests in `GlassLegibilityTests` and
`AccessibilityPolicyTests`. Settings were injected with launch arguments
(`-lab.reduceMotion YES`, `-lab.reduceTransparency YES`,
`-UIPreferredContentSizeCategoryName …`, `-lab.appearance dark|light`, which
sets the window's `overrideUserInterfaceStyle`) and `XCUIDevice.appearance`,
and the real system settings were also switched on the iPhone simulator by
hand (`defaults write com.apple.Accessibility ReduceMotionEnabled` /
`EnhancedBackgroundContrastEnabled` with the matching Darwin notifications,
and `simctl ui … increase_contrast`).

| Case | Owner | iPhone 18 Pro simulator | iPad Pro 13-inch (M5) simulator |
| --- | --- | --- | --- |
| VoiceOver: elements | Native controls; the surface is decorative | Pass: each control is exactly one button element with its label; the surface is absent from the accessibility tree; title, button, caption, button appear top to bottom in one stack; each control activates once | Pass (same test) |
| VoiceOver: live navigation and double-tap | — | Not run: the Simulator has no VoiceOver | Not run |
| Accessibility audit (`performAccessibilityAudit`, all types, source paused) | Lab | Pass in light and in system dark | Pass in light; dark skipped because the simulator's system appearance (`XCUIDevice.appearance` or `simctl ui appearance dark`) did not reach any app |
| Largest text (`AccessibilityXXXL`), portrait and landscape | Lab layout; native controls | Pass: title wraps whole inside the glass panel, buttons grow (> 60 pt tall, ≥ 44 pt), both act, the panel follows content as the stage scrolls; `.dynamicType` and `.textClipped` audits clean | Pass |
| Light: panel text over the moving source | App's tint, GlassWeave legibility rule | Worst sampled contrast 9.78:1 (350 samples, 5 frames); rule guarantees ≥ 9.6:1 at tint 0.45 | 9.78:1 |
| Dark: panel text over the moving source | App's tint, GlassWeave legibility rule | 5.65:1 (system dark); tint raised to 0.83, guaranteeing ≥ 4.6:1 over any background | 8.12:1 (window override) |
| Increase Contrast | Lab target 7:1 | Manual: dark glass tint 0.91, ≥ 7.1:1 guaranteed; opaque surface ≥ 15.5:1 | Not run |
| Reduce Motion | App (GlassWeave reports the setting; the panel has no motion) | Pass: clock stays at t 0.00 s, no submissions over 2 s, Pause/Resume keep it stopped, controls act; manual system setting: paused at launch and resumed live when turned off | Pass (launch argument) |
| Reduce Transparency | GlassWeave (`GlassAccessibilityPolicy`) | Pass: panel interior is `secondarySystemBackground` (242, 242, 247 light; 28, 28, 30 dark) within 3 steps in every sample over 3 frames while the source moves; controls act; manual system setting: opaque at launch, glass again live when turned off, opaque again live when turned on | Pass, light and dark (window override) |

Package evidence: `GlassLegibilityTests` (WCAG luminance and contrast, the
worst case over every background, minimum strengths for 4.5:1 and 7:1, and a
GPU render over black and white halves keeping the ratio) on My Mac and the
iPhone simulator; `AccessibilityPolicyTests` (opaque surface keeps the shape,
label text ≥ 7:1 on it in light/dark × normal/high contrast, fixed settings
applied and reported, trait changes re-resolve the color, the surface and its
Metal view contribute no accessibility element and hit tests reach the
control) on the iPhone simulator. Captures:
[largest text](evidence/captures/gw-08-largest-text-iphone18pro-sim.png),
[dark glass](evidence/captures/gw-08-dark-glass-iphone18pro-sim.png),
[Reduce Transparency and Reduce Motion, dark](evidence/captures/gw-08-reduce-transparency-and-motion-dark-iphone18pro-sim.png).

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

## Language and data-layout evidence

Follow [the language strategy](language-strategy.md). With the first actual GPU
records, verify host size/alignment/offsets/stride and a shader round-trip with
distinctive values. Record allocations, copied bytes where measurable, and
retain/release hotspots during state updates, resize, and steady rendering.
For foreign kernels, include conversion and FFI cost and a clean Swift consumer
build; do not infer a whole-app benefit from an isolated microbenchmark.
