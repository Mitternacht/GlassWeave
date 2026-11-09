# GlassWeave examples

Open `GlassWeave.xcworkspace`. It contains the package and the UIKit
laboratory, `GlassWeaveLab`, which consumes the package through a local
package reference.

The laboratory has one screen: a stage with the rendered background, and the
comparison controls below it (portrait) or beside it (landscape).

- **Background.** By default the stage shows an app-owned moving source
  (`ProceduralBackground.swift`, `ProceduralBackground.metal`): a GPU-rendered
  pattern that is a pure function of one deterministic clock, advanced one
  1/60 s step per `UIUpdateLink` tick. Each frame is produced inside the
  command buffer that GlassWeave then uses to sample it. A frame-ID strip (16
  bit cells, white for 1) runs through the panel and the background so both
  can be compared; the Frame ID switch turns it off. Pause stops the clock;
  Reset returns it to zero. Launch with `-lab.source pattern` to show the still
  four-corner orientation pattern (`PatternSource.swift`) instead.
- **Custom GlassWeave panel.** One rounded glass panel (`GlassRenderer`) drawn
  over the same frame, under native UIKit content: a title and a "Custom
  action" button. The glass panel follows that content's frame.
- **Native reference.** Beside the panel, genuine Apple glass
  (`NativeGlassView`, a public `UIGlassEffect`) around a real "Native action"
  button, over the same stage. The tint and Enabled controls change the
  comparison state; Reset restores untinted, enabled, interactive glass and
  clears both tap counts. This control creates no GlassWeave renderer; the
  stage's renderer belongs to the custom panel. The two are separate material
  systems: nothing here merges the native glass with the custom panel.

- **Lifecycle checks.** The Stage switch hides and shows the whole stage.
  While the custom surface is not visible (stage hidden, scene in the
  background) its clock stops, it submits nothing, and the background gives
  its free pooled textures back. On iPad, New window opens a second
  laboratory scene with its own stage, surface, and clock, and Close window
  closes the scene it is in.

The diagnostics list the clock state and content time, both tap counts, the
presented and produced frame IDs, the drawable size, the surface's
visibility and its own scene's activation state, the scheduler's counts
(submitted, in flight with peak and bound, deferred while hidden, deferred
at the bound, coalesced), the submissions during the last hidden period,
pooled textures with total allocations and coalesced ticks, the last
released frame, the panel's surface (glass or opaque), tint strength and
guaranteed text contrast, and the accessibility settings in effect.

Accessibility (GW-08): the stage's native content scrolls when it is taller
than the stage (for example at accessibility text sizes, where the panel also
takes the full width and the control rows stack vertically) and the glass
panel follows it. The panel tint is raised until its label text keeps 4.5:1
(7:1 with Increase Contrast) over any background. Reduce Motion stops the
clock; Reduce Transparency makes the panel opaque. For UI tests and
comparison runs, launch arguments fix the settings: `-lab.reduceMotion YES`,
`-lab.reduceTransparency YES`, and `-lab.appearance dark` or `light` (the
window's `overrideUserInterfaceStyle`).

Benchmark (GW-09): launch with `-lab.benchmark baseline`, `native`, `custom`,
`idle`, or `lifecycle` to run one mode of the fixed workload in
[the validation protocol](../docs/validation.md#implemented-scenario-and-measurement-gw-09)
(`BenchmarkScenario.swift`). Each mode shows only its composition: mode 1
the moving background alone, mode 2 with the native reference, mode 3 with
the custom panel too; mode 4 freezes the source; mode 5 runs 100 seeded
hide/show and resize cycles (`-lab.benchmark.seed <number>`) between two
settled allocation measurements. In a benchmark the stage fills the whole
screen and the controls sit above it on an opaque backdrop (scenario
version 2). The frame-ID strip starts off, the surface's
renderer records `RenderMetrics`, Reset restarts the measurement window,
Settle and measure stops the clock and reports allocated bytes, and the
diagnostics (refreshed once a second) add the workload, the metrics
percentiles and counts, and Metal allocations. The iOS Simulator reports no
allocation sizes.

## Clean consumer

`ConsumerCheck` is a separate package that depends on GlassWeave as an
outside project would: by a git URL at one revision, through the public
`GlassWeave` and `GlassWeaveUIKit` products only (no `@testable import`).
Its tests draw a fully tinted panel over the consumer's own produced
background offscreen and read it back (custom mode), put a working button in
`NativeGlassView` (native mode), and give `GlassSurfaceView` a producer and a
panel. Its manifest takes the URL and revision from `GLASSWEAVE_URL` and
`GLASSWEAVE_REVISION`; `scripts/consumer_check.sh [revision] [destination]...`
copies it to a temporary directory, points it at this clone, checks that
SwiftPM pins exactly that revision and nothing else, and runs the tests with
Metal API Validation (default destination `platform=macOS`; the UIKit tests
need an iOS Simulator destination). It is not part of the workspace.

Nothing here is evidence of physical device performance. The remaining work
and its acceptance gates are listed in [the task checklist](../tasks/todo.md).
