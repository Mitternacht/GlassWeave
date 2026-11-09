# GlassWeave: implementation handoff for Claude

Prepared 2026-11-08 as a plan. Since then the `implement/milestone-1` branch
has gained the v0.1 pre-alpha candidate: the Swift package, the UIKit
laboratory, the test suites, a committed clean-consumer check, and a CI
workflow that has not run on GitHub. Nothing is released. GW-09's
physical-device qualification and the other device-dependent items are still
open; [the task checklist](tasks/todo.md) records what is verified. The rest
of this page is the original handoff. The user deliberately reserved
implementation for Claude.

## Pick up here (2026-11-09)

**Branches.** Nothing is merged into `main`.

- `implement/milestone-1`: the v0.1 candidate, GW-01 to GW-10.
- `implement/glow`: that candidate plus the user-requested glow work, GW-14 and GW-17
  to GW-20. Continue on this branch.

**The user's goal.** GlassWeave's own Metal glass must be far more capable and more
colorful than Apple's glass. Native glass takes one flat tint and nothing you can
shape or animate. The native and enhanced-native modes are a comparison baseline.
The custom mode is the product. Read [the scope change](tasks/plan.md) and
[the glow design](docs/glow.md).

**What the glow work delivers.** All of it is off by default, and the output stays
byte-identical when it is off.

- **GW-17:** rims in any sRGB color or a gradient of up to 4 stops, an inner glow,
  and a body that fades to a fully clear middle.
- **GW-18:** a halo outside the shape and a deterministic pulse on one effect clock.
- **GW-19:** animated interiors: energy, rays and embers.
- **GW-14:** a Core Animation rim and halo around genuine `UIGlassEffect`.
- **GW-20:** a "Glow gallery" screen in the lab.

The last full runs, on the iPhone 18 Pro simulator with iOS 27.2:

- Package scheme: 280 of 280 passed.
- Package scheme on My Mac (Apple M5): 198 of 198 passed.
- Lab UI tests: 46 passed, 1 skipped (iPad only).

Two independent reviews found 7 issues. All 7 are fixed; see the GW-20 "Review update"
in [the checklist](tasks/todo.md).

**Still open.**

1. Every physical-device item: the GW-09 qualification, the glow device costs, and a
   live VoiceOver pass.
2. GW-04 item 3: `MTKView.currentRenderPassDescriptor` can block the main thread for
   up to 1 s when every drawable is in flight.
3. CI has never run on GitHub.
4. GW-11, GW-12, GW-13, GW-15 and GW-16 have not started.

**Next round.** [The proposal](docs/proposals/glass-beyond-native.md) plans GW-21 to
GW-29, aimed at four target looks the user shared:

- a glowing liquid inside thick glass;
- a frosted capsule with dispersion;
- a prismatic ring button;
- a thick lens pill with a pooled colored glow.

The reference images are third-party work and are kept privately, outside this
repository; the user knows where they are. Never commit them. The proposal is **not
approved**. The user's open choice is "build all nine" or "build the first four, then
review". Ask before starting.

**Working rules learned the hard way.**

- In Xcode MCP, open only `Examples/GlassWeave.xcworkspace`. The package folder or a
  bare `.xcodeproj` leaves a stale package root, and builds then fail with "Missing
  package product".
- After a scheme switch, set the destination explicitly:
  - "My Mac" for GPU tests;
  - an iPhone simulator for UIKit tests and the lab.
- Count tests with `xcrun xcresulttool get test-results summary`. The MCP summary can
  merge stale results.
- Swift Testing exit tests run only on macOS.
- After a mutation run, rebuild and reinstall the lab before taking screenshots.
- This is a public repository:
  - commit with the account's GitHub noreply address;
  - keep personal paths, team IDs and device identifiers out of tracked files;
  - never add a signing team.

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
