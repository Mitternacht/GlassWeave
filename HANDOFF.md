# GlassWeave: implementation handoff for Claude

Prepared 2026-11-08 as a plan. Since then the `implement/milestone-1` branch
has gained the v0.1 pre-alpha candidate: the Swift package, the UIKit
laboratory, the test suites, a committed clean-consumer check, and a CI
workflow that has not run on GitHub. Nothing is released. GW-09's
physical-device qualification and the other device-dependent items are still
open; [the task checklist](tasks/todo.md) records what is verified. The rest
of this page is the original handoff. The user deliberately reserved
implementation for Claude.

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
