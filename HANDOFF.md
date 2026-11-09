# GlassWeave: implementation handoff for Claude

Prepared 2026-11-08 as a plan. Since then the `implement/milestone-1` branch
has gained the v0.1 pre-alpha candidate: the Swift package, the UIKit
laboratory, the test suites, a committed clean-consumer check, and a CI
workflow that has not run on GitHub. Nothing is released. GW-09's
physical-device qualification and the other device-dependent items are still
open; [the task checklist](tasks/todo.md) records what is verified. The rest
of this page is the original handoff. The user deliberately reserved
implementation for Claude.

## Pick up here (2026-11-09, after the glass-beyond round)

**Branches.** Nothing is merged into `main`, nothing is pushed, nothing is tagged.

- `implement/milestone-1`: the v0.1 candidate, GW-01 to GW-10.
- `implement/glow`: that candidate plus the glow work, GW-14 and GW-17 to GW-20.
- `implement/glass-beyond`: **continue here.** The glow branch plus GW-21 to GW-29,
  the REFINE and ENHANCE-LOOK looks, and the amber vessel. The vessel work was built on
  `implement/glass-host` and joined with a real merge commit.
- `implement/glass-host`: already merged into `glass-beyond`. Its sibling worktree
  folder still exists next to the main checkout; remove it after review.

**The user's goal.** GlassWeave's own Metal glass must be far more capable and more
visually interesting than Apple's `UIGlassEffect`, in Apple's own restraint: a mostly
clear body, one light, a thin rim, calm shadows, color as a quiet tint or pooled
light, never bubbly or fake. The native and enhanced-native modes are a comparison
baseline; the custom mode is the product. The four private reference pictures
(third-party work) stay outside this repository; never commit them, a crop, or their
path.

**What exists (all experimental, unreleased, off by default, byte-identical when off).**
Read [the README](README.md#glass-beyond-native-experimental-unreleased) for the list
and for how to open every lab page with its launch argument, and
[glass-optics](docs/glass-optics.md), [frost](docs/frost.md),
[presentation](docs/presentation.md) and [studies](docs/studies.md) for the design.

- GW-21 light fields; GW-22 thick lens, dispersion and inlays; GW-23 light model;
  GW-24 frost (pyramid and shader); GW-25 shadows and caustics; GW-26 freeform shapes;
  GW-27 non-blocking presentation and quality tiers (closes GW-04 item 3); GW-28 liquid
  and gel fill (the curved amber vessel); GW-29 four studies and the Apple vs GlassWeave
  screen.
- Each task has one safety test (the new path off is byte-identical to a frozen copy of
  the previous shader). Every other acceptance item that needs a further test, a CPU
  mirror, an M5 run or a device is unchecked in [the checklist](tasks/todo.md) with a
  reason (fast pass: not tested, device only, ...).

**Final verification run (VERIFY-FINAL, one quiet batch, `xcresulttool` counts).**

Xcode MCP could not open a workspace here, so everything used `xcodebuild`; counts are from
`xcresulttool`.

| Destination | Result |
| --- | --- |
| Package scheme, My Mac | 206 passed, 0 failed; three later runs: 206, 205 passed with 1 failed (`FrameLifecycleTests`, below), 206 |
| Package scheme, iPhone 18 Pro simulator (iOS 27.2) | first run 287 passed, 1 failed (the pulse check below); after the test fix 288 passed, 0 failed, three runs in a row |
| All lab UI tests, iPhone 18 Pro simulator | 50 results: 46 passed, 1 failed (the gallery dark audit below), 3 skipped (two dark audits that skip because the system appearance does not reach the app on this simulator, and the iPad-only two-scene test) |
| Studies and versus smoke, iPad Pro 13-inch (M5) simulator | 2 passed, 0 failed |

All seven frozen-shader safety suites (`GlassBaselineGW20` to `GW25` and `GW28`) pass on both
package destinations.

**Still open.**

1. Every physical-device item: the GW-09 qualification, every effect's cost and
   shimmer, the GW-27 120 Hz trace, a live VoiceOver pass.
2. One combined M5 characterization run for all effects and tiers; no cost claim exists.
3. The skipped test groups: CPU-mirror comparisons for the lens, dispersion, light
   model, frost, shadows, shapes and fill; the 1,000-background legibility sweeps; the
   accessibility audit, largest-text and right-to-left runs for the studies; the
   controlled-clock UIKit tests; the numeric tests for the refined and enhanced terms.
4. The gallery's dark accessibility audit (pre-existing) and two timing-sensitive tests, below.
5. CI has never run on GitHub.
6. GW-11, GW-12, GW-13, GW-15 and GW-16 have not started.
7. Visual gaps against the references: see [the plan](tasks/plan.md).

**The two known failures.**

- **`GlowGalleryUITests` `testAccessibilityAuditPassesInLightAndDark`**: a pre-existing
  environment issue. It fails identically (the dark audit flags the "Energy orb" header) on
  the shipped glow tip `d1f9b81` and here, alone 3 of 3. The system appearance does not reach
  the app on this simulator; the two sibling audits skip for that reason and this test has no
  such guard. Not changed. Fix: add the same skip guard, or fix the header colors for the
  gallery's dark theme.
- **`EnhancedNativeGlassViewTests` "The pulse resumes where it stopped"**: not a flake. It
  passed on `d1f9b81` (full scheme, 280 of 280, three runs) and failed in every full run here
  (resume offsets 0.74 to 0.80 s against a 0.55 s bound). Cause: this round made
  `GlassRenderer.init` about 6 times slower (16 pipeline variants built eagerly, 6 to 15 ms
  against 1 to 4 ms), about 45 UIKit tests create one at once, and the shared main actor is
  busy for about 0.45 s just as this wall-clock test's 300 ms sleep ends. The test now measures
  how long the pulse really ran and expects the resume offset within 0.1 s of it. The eager
  build was left as GW-22 decided; building the extra variants lazily or in the background is
  a possible follow-up. Two more timing-sensitive tests fail now and then and were not changed: "A new corner
  configuration..." (UIKit layout timing) and `FrameLifecycleTests` "100 hide and show
  cycles..." (a race in the test: it reads the scheduler's in-flight count while a GPU
  completion handler can change it; the test and `FrameScheduler` are unchanged since GW-07;
  1 of 7 simulator runs and 1 of 4 My Mac runs, passes alone 3 of 3).

**Visual verdict (simulator captures `docs/evidence/captures/gw-final-*`, compared with a real
`UIGlassEffect` on the same backdrop and, locally, with the four private references).**

- *Better than Apple's.* Hues inside the material: the pill is a clear lens body with a deep
  pink-to-violet pool along its bottom, where native glass takes one flat tint. A lens bevel with
  real dispersion and a frost with a clear center (the shelf capsule over a rainbow). A polished
  banded chrome ring with glints, freeform pebbles, and a curved luminous liquid in thick smoky
  glass (Amber). It stays in the same family as native: one light, a thin rim, soft shadows,
  calm color, no bubbles or neon.
- *Still short of Apple's.* No live bending of whatever is behind it (the backdrop must be
  supplied), no touch response or morphing, no system integration, and every look is tuned by
  eye per backdrop, where native adapts to any content.
- *Still short of the references.* Reference 1 (liquid): ours is smoother and more diffuse, with
  no white-hot sheet edges, no specular spot on the liquid's own curved surface, no parallax and
  no gray studio reflections on the rim (the last on purpose). Reference 2 (frosted capsule):
  the blur is gentler and the fringes subtler. Reference 3 (ring): ours is a smaller
  steel-silver ring with fainter prismatic glints than the chunky polished chrome. Reference 4
  (lens pill): the bend at the edges is weak over soft backdrops, the pooled glow is quieter, and
  the dome button sits inside the pill instead of overlapping its end.

**How to build and run here.** The Xcode MCP bridge times out when it opens a workspace
on this Mac (`XcodeOpenWorkspace` after 10 s, on every path), so the whole round used
narrow `xcodebuild` commands with a private derived-data folder:

- Build the lab for a simulator, then install and launch it with launch arguments:

  ```sh
  cd Examples
  xcodebuild build -workspace GlassWeave.xcworkspace -scheme GlassWeaveLab \
    -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath <BUILD> > <BUILD>/logs/lab.log 2>&1
  xcrun simctl install <UDID> <BUILD>/Build/Products/Debug-iphonesimulator/GlassWeaveLab.app
  xcrun simctl launch <UDID> dev.glassweave.GlassWeaveLab -lab.study pill -lab.studyTime 20 -lab.studyTwin YES
  xcrun simctl io <UDID> screenshot pill.png
  ```

- The four studies: `-lab.study pill|pearl|shelf|vessel`; `-lab.studyTime <s>` pins the
  script (a capture is repeatable), `-lab.studyTwin YES` adds a real `UIGlassEffect`
  beside it. The versus screen: `-lab.versus YES -lab.versusAnimate NO`.
- Tests: `xcodebuild test -workspace GlassWeave.xcworkspace -scheme GlassWeave
  -destination 'platform=macOS' -derivedDataPath <BUILD> -resultBundlePath
  <BUILD>/results/<unique name>.xcresult`, the same with an iPhone simulator
  destination, and `-scheme GlassWeaveLab` for the lab UI tests (`-only-testing:` to
  narrow). The result bundle path must not exist yet. Redirect the output to a log and
  grep it; count with `xcrun xcresulttool get test-results summary --path <bundle>`.
- Package scheme on My Mac takes about 45 s; the whole lab UI suite about 20 minutes.

**Working rules learned the hard way.**

- In Xcode MCP (when it works), open only `Examples/GlassWeave.xcworkspace`. The package
  folder or a bare `.xcodeproj` leaves a stale package root, and builds then fail with
  "Missing package product".
- After a scheme switch, set the destination explicitly: "My Mac" for GPU tests, an
  iPhone simulator for UIKit tests and the lab.
- Swift Testing exit tests run only on macOS.
- After a code change, rebuild and reinstall the lab before taking screenshots.
- Do not run the test suites between edits while iterating; build, look at a capture,
  tune, and run the tests once at the end.
- This is a public repository: commit with the account's GitHub noreply address; keep
  personal paths, team IDs and device identifiers out of tracked files; never add a
  signing team; never write a reference picture's path into a tracked file.

## Read in order

1. [AGENTS.md](AGENTS.md) — repository and Apple-tool requirements.
2. [Product and delivery plan](tasks/plan.md).
3. [Architecture and source-frame contract](docs/architecture.md).
4. [Verification and performance protocol](docs/validation.md).
5. [Ordered implementation tasks](tasks/todo.md) — the only completion checklist.

Read the [language strategy](docs/language-strategy.md) before creating the package.
It specifies Swift CPU code, MSL shaders, a verified data-layout boundary, and gates
for adding C/C++ or Rust.

## The outcome to prove first

Build a UIKit laboratory app with native Apple glass beside a custom refractive
rounded panel, over an animated background owned by the app. Place native text
and a real native button above the custom surface. The button must remain
interactive and accessible while the background moves and the panel renders.
Verify rotation, resizing, lifecycle, accessibility preferences, and sustained
physical-device cost. This is **Milestone 1**, not a catalogue of glass effects.

Start with **GW-01**, then follow dependencies through GW-09 and its milestone
checkpoint. GW-10 prepares the limited v0.1 candidate; later effects are separate.
Create only the package targets needed by each working slice.
Split oversized tasks into focused substeps before implementation.

## Boundaries to preserve

- **Native mode:** genuine Apple material and system-managed backdrop; no custom
  Metal renderer should be created merely to use a native control.
- **Enhanced-native mode:** native glass plus separately composited effects.
  This does not replace the optics inside Apple's material.
- **Custom mode:** GlassWeave owns the optical rendering and needs an explicit
  background texture/source. A transparent Metal view cannot read arbitrary UI
  behind it. Whole-window capture is not the architecture.
- Custom merging is between surfaces that GlassWeave owns. Do not promise an
  optical union with an unchanged Apple glass control.
- Native controls, text, focus, hit testing, and accessibility remain native.
- [Frostfield](https://github.com/Mitternacht/Frostfield) is optional. No scene
  graph, mesh loader, or general 3D engine may be required for one glass panel.

## Settled direction and open experiments

The first implementation uses UIKit and MTKView, Swift 6 language mode, and a
proposed iOS/iPadOS 26 deployment baseline. macOS is initially a core compilation
target, not a shipped presentation adapter. These are documented engineering
defaults; revise them with evidence when needed rather than treating them as
explicit user choices.

The conventional Metal path is the small reference implementation. After the
coexistence proof, compare Metal 4 using the same scene and quality. Do not make
device-name assumptions or select an API based only on the OS version.
Physical baseline devices, final quality tiers, and final performance budgets
remain to be established. Provisional targets in the validation plan are gates
to measure, not achieved benchmark results.

Before writing optics, settle the source-frame contract: GPU device, dimensions,
coordinate transform, color encoding, alpha convention, sampling margins,
timestamp, producer completion, and ownership until consumer completion. A Swift
actor does not synchronize GPU work. Start with one explicit supported source
format; make unsupported input behavior predictable before widening the contract.

## Working contract

For Apple work, load the matching installed Xcode 27 skill and use the native
Xcode MCP server for documentation, project edits, builds, runs, diagnostics,
tests, and previews. Verify bridge access before relying on build results.
Record any package-bootstrap tool limitation explicitly; do not silently switch
regular development to terminal builds.

Implement in short, reviewable slices. Use meaningful Swift Testing coverage for
logic and resource contracts; use UI automation/device inspection for interaction.
Add CI with the first executable slice. Do not add placeholder assertions,
speculative public APIs, or effects that delay the integration proof.

Record each checkpoint's commit, toolchain, device, settings, build/test results,
screenshots or clips, and profiling evidence. Mark a task complete only when its
acceptance criteria pass. If hardware access is missing, keep the physical gate
open and continue independent work; do not invent measurements or describe a
simulator run as device qualification.

## Suggested Claude kickoff

> Read AGENTS.md and HANDOFF.md, then the linked plan, architecture, validation
> protocol, and task list. Implement GlassWeave Milestone 1 starting with GW-01,
> in dependency order through the coexistence and device-evidence checkpoint.
> Use the required Apple skills and native Xcode MCP tools. Keep native content
> native, make custom backgrounds explicit, and keep Frostfield optional.
> Record verification, update the checklist as slices pass, and keep unavailable
> physical-device evidence visibly outstanding. Do not expand into later glass
> effects before the first integration proof works.
